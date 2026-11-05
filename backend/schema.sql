-- =====================================================================
-- Monitor Meliponas — banco de dados (Supabase / PostgreSQL)
-- FIS | IPÊ e Amazônia Bee — Protótipo de Meliponicultura, Cametá do Ramos (AM)
--
-- Como usar: Supabase > SQL Editor > New query > cole este arquivo > Run.
-- Pode ser executado mais de uma vez sem perder dados.
-- =====================================================================

-- ---------- tabelas ----------
create table if not exists public.config (
  chave text primary key,
  valor text not null
);

create table if not exists public.dispositivos (
  id              text primary key,
  monitor         text,
  versao_app      text,
  primeiro_contato timestamptz not null default now(),
  ultimo_contato  timestamptz not null default now()
);

create table if not exists public.colonias (
  numero        int primary key check (numero between 1 and 12),
  especie       text,
  ambiente      text,
  melgueira     text,
  aparelho      text,
  local         text,
  atualizado_por text,
  atualizado_em timestamptz not null default now()
);

create table if not exists public.visitas (
  id              text primary key,
  dispositivo_id  text references public.dispositivos(id),
  monitor         text not null,
  inicio          timestamptz not null,
  fim             timestamptz,
  dados_enviados_sistema boolean not null default false,
  recebido_em     timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);

create table if not exists public.registros (
  visita_id  text not null references public.visitas(id) on delete cascade,
  colonia    int  not null check (colonia between 1 and 12),
  hora       timestamptz,
  dados_baixados text,
  movimento  text,
  pragas     text,
  praga_qual text,
  caixa      text,
  placa_fios text,
  aparelho   text,
  manejo     text,
  observacoes text,
  problemas  text[] not null default '{}',
  leitura    jsonb,
  primary key (visita_id, colonia)
);
alter table public.registros add column if not exists leitura jsonb;

create table if not exists public.midias (
  id         text primary key,
  visita_id  text not null references public.visitas(id) on delete cascade,
  colonia    int  not null check (colonia between 1 and 12),
  tipo       text not null check (tipo in ('foto','audio')),
  caminho    text not null,
  duracao_s  int,
  tamanho_bytes bigint,
  criado_em  timestamptz,
  recebido_em timestamptz not null default now()
);

create index if not exists visitas_inicio_idx on public.visitas (inicio desc);
create index if not exists registros_colonia_idx on public.registros (colonia);
create index if not exists midias_visita_idx on public.midias (visita_id, colonia);

insert into public.colonias (numero)
select g from generate_series(1,12) g
on conflict (numero) do nothing;

-- Código do projeto: o aplicativo só consegue enviar dados com este código.
-- TROQUE o valor abaixo por um código seu antes de distribuir o aplicativo.
insert into public.config (chave, valor) values ('codigo_projeto', 'TROCAR-ESTE-CODIGO')
on conflict (chave) do nothing;

-- ---------- regras de acesso ----------
-- O aplicativo não lê nem escreve nas tabelas diretamente: ele só chama a
-- função sincronizar(). A equipe, logada no painel, pode ler tudo.
alter table public.config       enable row level security;
alter table public.dispositivos enable row level security;
alter table public.colonias     enable row level security;
alter table public.visitas      enable row level security;
alter table public.registros    enable row level security;
alter table public.midias       enable row level security;

do $$
declare t text;
begin
  foreach t in array array['dispositivos','colonias','visitas','registros','midias'] loop
    execute format('drop policy if exists "equipe le" on public.%I', t);
    execute format('create policy "equipe le" on public.%I for select to authenticated using (true)', t);
  end loop;
end $$;

-- A equipe pode editar a identificação das colônias e marcar dados enviados.
drop policy if exists "equipe edita colonias" on public.colonias;
create policy "equipe edita colonias" on public.colonias for update to authenticated using (true) with check (true);
drop policy if exists "equipe edita visitas" on public.visitas;
create policy "equipe edita visitas" on public.visitas for update to authenticated using (true) with check (true);

grant select on public.dispositivos, public.colonias, public.visitas, public.registros, public.midias to authenticated;
grant update on public.colonias, public.visitas to authenticated;

-- ---------- função de sincronização (chamada pelo aplicativo) ----------
create or replace function public.sincronizar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb; r jsonb; m jsonb; c jsonb;
  nv int := 0; nr int := 0; nm int := 0;
  disp text := p->>'dispositivo';
begin
  if not exists (select 1 from config where chave = 'codigo_projeto' and valor = coalesce(p->>'codigo','')) then
    raise exception 'Código do projeto inválido' using errcode = '28000';
  end if;
  if coalesce(disp,'') = '' then
    raise exception 'Dispositivo não informado';
  end if;

  insert into dispositivos (id, monitor, versao_app)
  values (disp, p->>'monitor', p->>'versao')
  on conflict (id) do update
    set monitor = excluded.monitor, versao_app = excluded.versao_app, ultimo_contato = now();

  for c in select * from jsonb_array_elements(coalesce(p->'colonias','[]'::jsonb)) loop
    if concat(c->>'especie', c->>'ambiente', c->>'melgueira', c->>'aparelho', c->>'local') <> '' then
      update colonias set
        especie   = coalesce(nullif(c->>'especie',''),   especie),
        ambiente  = coalesce(nullif(c->>'ambiente',''),  ambiente),
        melgueira = coalesce(nullif(c->>'melgueira',''), melgueira),
        aparelho  = coalesce(nullif(c->>'aparelho',''),  aparelho),
        local     = coalesce(nullif(c->>'local',''),     local),
        atualizado_por = p->>'monitor',
        atualizado_em  = now()
      where numero = (c->>'n')::int;
    end if;
  end loop;

  for v in select * from jsonb_array_elements(coalesce(p->'visitas','[]'::jsonb)) loop
    insert into visitas (id, dispositivo_id, monitor, inicio, fim, dados_enviados_sistema)
    values (v->>'id', disp, coalesce(v->>'monitor', p->>'monitor', 'Não informado'), (v->>'inicio')::timestamptz,
            nullif(v->>'fim','')::timestamptz, coalesce((v->>'enviadoSistema')::boolean, false))
    on conflict (id) do update set
      fim = coalesce(excluded.fim, visitas.fim),
      dados_enviados_sistema = excluded.dados_enviados_sistema or visitas.dados_enviados_sistema,
      atualizado_em = now();
    nv := nv + 1;

    for r in select * from jsonb_array_elements(coalesce(v->'registros','[]'::jsonb)) loop
      insert into registros (visita_id, colonia, hora, dados_baixados, movimento, pragas, praga_qual,
                             caixa, placa_fios, aparelho, manejo, observacoes, problemas, leitura)
      values (v->>'id', (r->>'colonia')::int, nullif(r->>'hora','')::timestamptz, r->>'dados', r->>'mov',
              r->>'pragas', r->>'pragaQual', r->>'caixa', r->>'placa', r->>'aparelho', r->>'manejo', r->>'obs',
              coalesce(array(select jsonb_array_elements_text(r->'problemas')), '{}'),
              case when jsonb_typeof(r->'leitura') = 'object' then r->'leitura' end)
      on conflict (visita_id, colonia) do update set
        hora = excluded.hora, dados_baixados = excluded.dados_baixados, movimento = excluded.movimento,
        pragas = excluded.pragas, praga_qual = excluded.praga_qual, caixa = excluded.caixa,
        placa_fios = excluded.placa_fios, aparelho = excluded.aparelho, manejo = excluded.manejo,
        observacoes = excluded.observacoes, problemas = excluded.problemas,
        leitura = coalesce(excluded.leitura, registros.leitura);
      nr := nr + 1;
    end loop;
  end loop;

  for m in select * from jsonb_array_elements(coalesce(p->'midias','[]'::jsonb)) loop
    insert into midias (id, visita_id, colonia, tipo, caminho, duracao_s, tamanho_bytes, criado_em)
    values (m->>'id', m->>'visita', (m->>'colonia')::int, m->>'tipo', m->>'caminho',
            nullif(m->>'duracao','')::int, nullif(m->>'tamanho','')::bigint, nullif(m->>'criado','')::timestamptz)
    on conflict (id) do nothing;
    nm := nm + 1;
  end loop;

  return jsonb_build_object('visitas', nv, 'registros', nr, 'midias', nm, 'servidor', now());
end;
$$;

revoke all on function public.sincronizar(jsonb) from public;
grant execute on function public.sincronizar(jsonb) to anon, authenticated;

-- Teste do código pelo aplicativo (botão "Testar conexão")
create or replace function public.testar_codigo(codigo text)
returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from config where chave = 'codigo_projeto' and valor = codigo);
$$;
revoke all on function public.testar_codigo(text) from public;
grant execute on function public.testar_codigo(text) to anon, authenticated;

-- ---------- visão para o painel ----------
create or replace view public.resumo_visitas with (security_invoker = true) as
select v.id, v.monitor, v.inicio, v.fim, v.dados_enviados_sistema, v.recebido_em,
       count(r.colonia)                                         as colonias_registradas,
       count(r.colonia) filter (where r.dados_baixados = 'Sim') as dados_baixados,
       count(r.colonia) filter (where cardinality(r.problemas) > 0) as colonias_com_problema,
       (select count(*) from midias m where m.visita_id = v.id and m.tipo = 'foto')  as fotos,
       (select count(*) from midias m where m.visita_id = v.id and m.tipo = 'audio') as audios
from visitas v
left join registros r on r.visita_id = v.id
group by v.id;
grant select on public.resumo_visitas to authenticated;

-- =====================================================================
-- Aparelhos de medição BeeMeter (firmware 2.2.0-BLE) e suas medições
-- =====================================================================
create table if not exists public.aparelhos (
  id              text primary key,          -- BM-XXXXXX
  colonia         int check (colonia between 1 and 12),
  firmware        text,
  ultimo_seq      bigint,
  ultimo_download timestamptz,
  ultimo_dispositivo text references public.dispositivos(id)
);

create table if not exists public.medicoes (
  aparelho     text not null references public.aparelhos(id),
  seq          bigint not null,
  colonia      int check (colonia between 1 and 12),
  momento      timestamptz,                   -- nulo quando o relógio do aparelho não pôde ser reconstituído
  boot         int,
  uptime_s     bigint,
  temp_amb     numeric(5,1),
  umidade      numeric(5,1),
  lux          int,
  tc_fundo     numeric(6,2),
  tc_divisao   numeric(6,2),
  tc_melgueira numeric(6,2),
  peso_kg      numeric(8,3),
  recebido_em  timestamptz not null default now(),
  primary key (aparelho, seq)
);
create index if not exists medicoes_colonia_momento_idx on public.medicoes (colonia, momento);

alter table public.aparelhos enable row level security;
alter table public.medicoes  enable row level security;
drop policy if exists "equipe le" on public.aparelhos;
create policy "equipe le" on public.aparelhos for select to authenticated using (true);
drop policy if exists "equipe le" on public.medicoes;
create policy "equipe le" on public.medicoes for select to authenticated using (true);
grant select on public.aparelhos, public.medicoes to authenticated;

create or replace function public.enviar_medicoes(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ap text := p->>'aparelho';
  col int := nullif(p->>'colonia','')::int;
  n int := 0;
  maior bigint;
begin
  if not exists (select 1 from config where chave = 'codigo_projeto' and valor = coalesce(p->>'codigo','')) then
    raise exception 'Código do projeto inválido' using errcode = '28000';
  end if;
  if ap is null or ap !~ '^BM-[0-9A-F]{6}$' then
    raise exception 'Aparelho inválido';
  end if;

  insert into aparelhos (id, colonia, firmware, ultimo_download, ultimo_dispositivo)
  values (ap, col, p->>'fw', now(), (select id from dispositivos where id = p->>'dispositivo'))
  on conflict (id) do update set
    colonia = coalesce(excluded.colonia, aparelhos.colonia),
    firmware = coalesce(excluded.firmware, aparelhos.firmware),
    ultimo_download = now(),
    ultimo_dispositivo = coalesce(excluded.ultimo_dispositivo, aparelhos.ultimo_dispositivo);

  insert into medicoes (aparelho, seq, colonia, momento, boot, uptime_s, temp_amb, umidade, lux,
                        tc_fundo, tc_divisao, tc_melgueira, peso_kg)
  select ap, (r->>'seq')::bigint, col,
         case when jsonb_typeof(r->'m') = 'number' then to_timestamp((r->>'m')::bigint) end,
         nullif(r->>'b','')::int, nullif(r->>'u','')::bigint,
         nullif(r->>'t','')::numeric, nullif(r->>'ur','')::numeric, nullif(r->>'lux','')::numeric::int,
         nullif(r->>'tc1','')::numeric, nullif(r->>'tc2','')::numeric, nullif(r->>'tc3','')::numeric,
         nullif(r->>'p','')::numeric
  from jsonb_array_elements(coalesce(p->'registros','[]'::jsonb)) r
  on conflict (aparelho, seq) do nothing;
  get diagnostics n = row_count;

  select max(seq) into maior from medicoes where aparelho = ap;
  update aparelhos set ultimo_seq = maior where id = ap;
  return jsonb_build_object('novas', n, 'ultimo_seq', maior);
end;
$$;

revoke all on function public.enviar_medicoes(jsonb) from public;
grant execute on function public.enviar_medicoes(jsonb) to anon, authenticated;

-- Médias diárias por colônia (painel: comparação entre colônias)
create or replace view public.medicoes_diarias with (security_invoker = true) as
select colonia,
       (momento at time zone 'America/Manaus')::date as dia,
       count(*)                      as n,
       round(avg(temp_amb), 1)       as temp_amb,
       round(avg(umidade), 1)        as umidade,
       round(avg(tc_fundo), 2)       as tc_fundo,
       round(avg(tc_divisao), 2)     as tc_divisao,
       round(avg(tc_melgueira), 2)   as tc_melgueira,
       round(avg(peso_kg), 3)        as peso_medio,
       min(peso_kg)                  as peso_min,
       max(peso_kg)                  as peso_max
from public.medicoes
where momento is not null and colonia is not null
group by colonia, (momento at time zone 'America/Manaus')::date;
grant select on public.medicoes_diarias to authenticated;

-- =====================================================================
-- Leituras ao vivo: o aplicativo lê o aparelho a cada 10 s enquanto o
-- monitor preenche a ficha da colônia (aplicativo 3.2)
-- =====================================================================
create table if not exists public.leituras_vivo (
  aparelho     text not null references public.aparelhos(id),
  momento      timestamptz not null,
  colonia      int check (colonia between 1 and 12),
  visita_id    text,
  temp_amb     numeric(5,1),
  umidade      numeric(5,1),
  lux          int,
  tc_fundo     numeric(6,2),
  tc_divisao   numeric(6,2),
  tc_melgueira numeric(6,2),
  peso_kg      numeric(8,3),
  recebido_em  timestamptz not null default now(),
  primary key (aparelho, momento)
);
create index if not exists leituras_vivo_colonia_idx on public.leituras_vivo (colonia, momento);
alter table public.leituras_vivo enable row level security;
drop policy if exists "equipe le" on public.leituras_vivo;
create policy "equipe le" on public.leituras_vivo for select to authenticated using (true);
grant select on public.leituras_vivo to authenticated;

create or replace function public.enviar_leituras_vivo(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ap text := p->>'aparelho';
  col int := nullif(p->>'colonia','')::int;
  n int := 0;
begin
  if not exists (select 1 from config where chave = 'codigo_projeto' and valor = coalesce(p->>'codigo','')) then
    raise exception 'Código do projeto inválido' using errcode = '28000';
  end if;
  if ap is null or ap !~ '^BM-[0-9A-F]{6}$' then
    raise exception 'Aparelho inválido';
  end if;
  insert into aparelhos (id, colonia) values (ap, col) on conflict (id) do nothing;
  insert into leituras_vivo (aparelho, momento, colonia, visita_id, temp_amb, umidade, lux,
                             tc_fundo, tc_divisao, tc_melgueira, peso_kg)
  select ap, to_timestamp((r->>'m')::bigint), col, nullif(p->>'visita',''),
         nullif(r->>'t','')::numeric, nullif(r->>'ur','')::numeric, nullif(r->>'lux','')::numeric::int,
         nullif(r->>'tc1','')::numeric, nullif(r->>'tc2','')::numeric, nullif(r->>'tc3','')::numeric,
         nullif(r->>'p','')::numeric
  from jsonb_array_elements(coalesce(p->'registros','[]'::jsonb)) r
  where jsonb_typeof(r->'m') = 'number'
  on conflict (aparelho, momento) do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('novas', n);
end;
$$;
revoke all on function public.enviar_leituras_vivo(jsonb) from public;
grant execute on function public.enviar_leituras_vivo(jsonb) to anon, authenticated;
