# Monitor Meliponas para iPhone e iPad

Mesmo aplicativo do Android: as telas são as mesmas (pasta `app-android/assets`), e a parte própria do iPhone fica em `Fontes/`:

| Arquivo | Função |
| --- | --- |
| `TelaPrincipal.swift` | Abre as telas e cria a ponte `window.Android` com os mesmos nomes do Android |
| `Ponte.swift` | Atende cada chamada das telas |
| `Midias.swift` | Câmera, galeria e gravação de áudio (mesmos formatos do Android) |
| `BeeMeterBLE.swift` | Bluetooth com o aparelho BeeMeter (mesmo protocolo e mesmo lote de medições) |
| `Rede.swift` | Saber se está no Wi-Fi, em dados móveis ou sem internet |

O banco, o painel e o firmware são os mesmos; não há nada a mudar neles.

## Diferenças em relação ao Android

- **Instalação:** o iPhone não instala arquivos soltos. Os monitores instalam pelo aplicativo **TestFlight**, com um convite por e-mail ou link público.
- **Permissões:** o iPhone pede Bluetooth, câmera e microfone na primeira vez. Não pede localização.
- **Botão voltar:** o iPhone não tem; usa-se a seta no alto de cada tela.
- **Fotos:** ficam só no aplicativo (o Android guarda também uma cópia na galeria).

## O que é preciso

1. Conta no **Apple Developer Program** (US$ 99 por ano), de preferência em nome da instituição.
2. Um **Mac com Xcode** ou a compilação automática do GitHub (máquina macOS do próprio GitHub).

## Publicar pelo GitHub (sem Mac)

1. Em <https://appstoreconnect.apple.com>, crie o app: nome *Monitor Meliponas*, identificador `br.org.fis.meliponas`, idioma Português (Brasil).
2. Em **Usuários e acesso > Integrações > Chaves da API da App Store Connect**, gere uma chave com papel *App Manager*. Anote o **Key ID** e o **Issuer ID** e baixe o arquivo `.p8`.
3. No repositório, em **Settings > Secrets and variables > Actions**:
   - segredos `ASC_KEY_ID`, `ASC_ISSUER_ID` e `ASC_KEY_P8` (conteúdo do arquivo `.p8`);
   - variável `APPLE_TEAM_ID` (Team ID, em developer.apple.com > Membership).
4. Rode o fluxo **Compilar aplicativo iOS** em **Actions**. Ele confere o código e, com as chaves acima, envia a versão ao TestFlight.
5. Na App Store Connect, em **TestFlight**, adicione os monitores como testadores (por e-mail ou link público). Eles instalam o TestFlight e depois o Monitor Meliponas.

As versões do TestFlight valem por 90 dias; cada nova compilação renova o prazo.

## Compilar num Mac

```bash
brew install xcodegen
cd ios-app
./preparar.sh          # copia as telas; aceita SUPABASE_URL, SUPABASE_ANON_KEY e CODIGO_PROJETO
xcodegen generate
open MonitorMeliponas.xcodeproj
```

No Xcode, escolha a equipe em *Signing & Capabilities* e rode num iPhone ligado por cabo (o simulador não tem Bluetooth nem câmera).
