-- =====================================================================
-- Monitor Meliponas — armazenamento de fotos e áudios (Supabase Storage)
-- Executar DEPOIS de schema.sql, no SQL Editor do Supabase.
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('midias', 'midias', false, 10485760, array['image/jpeg','audio/mp4','audio/m4a','audio/x-m4a'])
on conflict (id) do nothing;

-- O aplicativo só envia arquivos (não lê, não apaga, não substitui).
drop policy if exists "app envia midias" on storage.objects;
create policy "app envia midias" on storage.objects
  for insert to anon
  with check (bucket_id = 'midias' and (storage.foldername(name))[1] = 'visitas');

-- A equipe logada no painel vê os arquivos.
drop policy if exists "equipe le midias" on storage.objects;
create policy "equipe le midias" on storage.objects
  for select to authenticated
  using (bucket_id = 'midias');
