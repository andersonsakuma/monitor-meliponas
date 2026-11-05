# Monitor Meliponas

Sistema de acompanhamento do **Protótipo de Meliponicultura** — FIS | IPÊ e Amazônia Bee, Cametá do Ramos (AM).

Os monitores registram no celular as visitas semanais às 12 colônias, com fotos e áudios. Os dados ficam guardados no aparelho e são enviados ao banco de dados ao terminar cada visita, quando houver internet. A equipe acompanha tudo pelo painel web.

| Parte | Pasta | O que é |
| --- | --- | --- |
| Aplicativo Android | `app-android/` | Registro das visitas, fotos, áudios, download dos aparelhos por Bluetooth e sincronização. Funciona sem internet. |
| Versão para navegador | `app-web/` | As mesmas telas no navegador (iPhone, Android ou computador), publicadas em `andersonsakuma.github.io/monitor-meliponas/app`. Funciona sem internet depois de adicionada à Tela de Início. Bluetooth com o BeeMeter no Chrome e, no iPhone, no navegador Bluefy. |
| Aplicativo iOS | `ios-app/` | Mesmo aplicativo para iPhone e iPad (mesmas telas, Bluetooth, câmera e áudio nativos). Instalação pelo TestFlight. Ver `ios-app/LEIA-ME.md`. |
| Firmware do aparelho | `firmware/` | BeeMeter 2.3.0-BLE (ESP32): sensores, tela, registro de 31 dias, Bluetooth e proteções para 12 aparelhos lado a lado. Ver `firmware/PROTOCOLO_BLE.md`. |
| Banco de dados | `backend/` | Tabelas, regras de acesso, função de sincronização e armazenamento de arquivos (Supabase). |
| Painel da equipe | `painel/` | Visão geral, mapa semanal das colônias, visitas, fotos e áudios, problemas e planilha. |
| Logotipos | `logos/` | `ipe-fis.png` e `amazonia-bee.png`, usados no aplicativo e no painel. |
| Automação | `.github/workflows/` | Compila o APK e publica o painel a cada atualização. |

## Manual

- Manual do monitor: `docs/Manual_Monitor_Meliponas.docx` e `.pdf`, publicado em `andersonsakuma.github.io/monitor-meliponas/manual.pdf`.
- QR code do manual em PDF (cartaz e etiquetas) e em STL para impressora 3D: `docs/qr-manual/`.
- Dúvidas: Anderson Sakuma (IPÊ/FIS) · (41) 99193-2677 · anderson.sakuma.tecpar@gmail.com

## Aparelhos de medição (BeeMeter)

Cada colônia tem um aparelho BeeMeter que mede temperatura e umidade do ambiente, luz, três temperaturas dentro da caixa (fundo, divisão e melgueira) e o peso da colmeia, e guarda um registro a cada 10 minutos por até 31 dias. Na visita, o monitor abre a colônia no aplicativo e toca em **Baixar dados do aparelho**: o celular conecta por Bluetooth, acerta o relógio do aparelho, mostra as medidas do momento e baixa só os registros novos. As medições vão para a tabela `medicoes` e aparecem no painel, na aba **Medições**.

## Leitura ao vivo e painel de acompanhamento (aplicativo 3.2)

- Ao abrir a ficha de uma colônia, o aplicativo conecta ao aparelho, baixa os registros novos e continua lendo as medidas **a cada 10 segundos** enquanto a ficha estiver aberta (até 30 minutos).
- Tudo o que é medido (registros do aparelho e leituras ao vivo) fica num **histórico permanente no celular, que nunca é apagado**, mesmo depois de enviado ao servidor. Pode ser baixado como planilha CSV na aba **Painel** ou em **Ajustes**.
- As leituras ao vivo vão para a tabela `leituras_vivo` do banco.
- A aba **Painel** mostra o peso de cada colônia (produção), as temperaturas do ninho e a umidade, com **avisos de anomalias**: queda de peso sem colheita anotada, peso parado por 7 dias, ninho acima de 36 °C ou abaixo de 22 °C, ninho acompanhando a temperatura de fora, umidade acima de 90 %, sensor sem leitura e aparelho sem registrar. Os problemas aparecem também numa mensagem na tela.
- Os limites dos avisos ficam na constante `LIM` de `app-android/assets/index.html` e devem ser ajustados com os dados do primeiro mês.


1. Durante a visita, tudo é gravado no celular, sem precisar de internet.
2. Ao tocar em **Terminar visita**, o aplicativo tenta enviar os registros.
3. Sem internet, os dados esperam. O aplicativo tenta de novo ao ser aberto e a cada 2 minutos quando está no Wi-Fi.
4. Fotos e áudios são enviados só no Wi-Fi (pode ser mudado em Ajustes).
5. O envio pode ser repetido sem duplicar dados.

## Instalação (uma vez, cerca de 30 minutos)

### 1. Banco de dados (Supabase, plano gratuito)

1. Crie uma conta em <https://supabase.com> e um projeto novo (região São Paulo).
2. Abra **SQL Editor**, cole o conteúdo de `backend/schema.sql` e clique em **Run**.
3. Faça o mesmo com `backend/storage.sql`.
4. Defina o código do projeto (troque pelo seu):
   ```sql
   update config set valor = 'MELIPONAS-CAMETA-2026' where chave = 'codigo_projeto';
   ```
5. Em **Authentication > Users > Add user**, crie o login de cada pessoa da equipe que vai usar o painel.
6. Em **Authentication > Sign In / Providers**, desligue **Allow new users to sign up**, para que só a equipe tenha acesso.
7. Em **Project Settings > API**, copie o **Project URL** e a chave **anon public**.

### 2. GitHub

Com o [GitHub CLI](https://cli.github.com) instalado, na pasta do projeto:

```bash
./publicar.sh monitor-meliponas
```

O script cria o repositório, grava os segredos, liga o GitHub Pages e envia o código. Tenha em mãos o endereço e a chave do Supabase, o código do projeto e o arquivo `chave.jks`.

Sem o script: crie o repositório, envie os arquivos e, em **Settings > Secrets and variables > Actions**, cadastre:

| Segredo | Valor |
| --- | --- |
| `SUPABASE_URL` | Project URL do Supabase |
| `SUPABASE_ANON_KEY` | chave anon public |
| `CODIGO_PROJETO` | o mesmo código gravado no banco |
| `KEYSTORE_B64` | conteúdo de `chave.jks` em base64 (`base64 -w0 chave.jks`) |
| `KEYSTORE_SENHA` | senha da chave |

Depois, em **Settings > Pages**, escolha **Source: GitHub Actions**.

> O GitHub Pages em repositório privado exige plano pago. O código não contém senhas: os dados ficam no Supabase, protegidos por login.

### 3. Aplicativo nos celulares

<img src="docs/qr-app.png" width="200" alt="QR code para baixar o aplicativo">

Aponte a câmera do celular para o código acima, ou abra a folha de instalação para imprimir: `https://andersonsakuma.github.io/monitor-meliponas/instalar.html`. O código sempre leva à versão mais recente.


1. Em **Actions**, aguarde a compilação terminar. O APK fica em **Releases**.
2. Abra o link da versão mais recente no celular do monitor e baixe `MonitorMeliponas.apk`.
3. Se o Play Protect avisar, toque em **Mais detalhes > Instalar assim mesmo**.
4. O aplicativo já vem configurado. Para conferir: **Ajustes > Dados do servidor > Testar conexão**.

Para instalar sem avisos, registre o aplicativo em <https://android.google.com/developerconsole> (conta de distribuição limitada, gratuita, até 20 celulares).

> Use sempre a mesma `chave.jks`. Um APK assinado com outra chave não atualiza o que já está instalado, e seria preciso desinstalar (perdendo o que não foi sincronizado).

## Atualizações

Toda alteração enviada para a branch `main` gera automaticamente um novo APK (em `app-android/`) e uma nova versão do painel (em `painel/`). Para uma nova versão do aplicativo, aumente `versionCode` e `versionName` em `app-android/AndroidManifest.xml`.

## Compilar o APK no próprio computador (Ubuntu)

```bash
cd app-android
SUPABASE_URL=... SUPABASE_ANON_KEY=... CODIGO_PROJETO=... KEYSTORE=../chave.jks ./build.sh
```

## Estrutura do banco

| Tabela | Conteúdo |
| --- | --- |
| `visitas` | uma linha por visita: monitor, início, fim, dados dos sensores enviados |
| `registros` | uma linha por colônia em cada visita: as respostas da ficha e os problemas |
| `midias` | fotos e áudios, com o caminho do arquivo no armazenamento `midias` |
| `colonias` | identificação das 12 colônias: espécie, ambiente, melgueira, aparelho, local |
| `dispositivos` | celulares que já sincronizaram, com o último contato |
| `config` | código do projeto (não fica visível pela internet) |
| `aparelhos` | aparelhos BeeMeter: colônia, firmware, último download e último registro |
| `medicoes` | registros dos aparelhos a cada 10 min: hora, temperaturas, umidade, luz e peso |
| `medicoes_diarias` | médias diárias por colônia (comparação no painel) |

O aplicativo não acessa as tabelas diretamente: ele só chama a função `sincronizar`, que confere o código do projeto. A equipe logada no painel pode ler tudo e editar a identificação das colônias e a marcação de dados dos sensores.

## Segurança

- Quem tiver o APK consegue enviar dados (o código do projeto vai dentro dele), mas ninguém consegue ler dados sem login no painel.
- Se um celular for perdido, troque o código no banco (passo 1.4), atualize o segredo `CODIGO_PROJETO` e reinstale o aplicativo nos outros celulares.
