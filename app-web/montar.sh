#!/usr/bin/env bash
# Monta a versão para navegador em <destino> (padrão: ../site/app) a partir das telas do aplicativo.
# Variáveis opcionais: SUPABASE_URL, SUPABASE_ANON_KEY, CODIGO_PROJETO
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:-../site/app}"
rm -rf "$DEST"; mkdir -p "$DEST/logos"
cp -R ../app-android/assets/. "$DEST/"
cp web-ponte.js sw.js manifest.webmanifest icone-192.png icone-512.png apple-touch-icon.png qr-web.png "$DEST/"
cp -f ../logos/*.png "$DEST/logos/" 2>/dev/null || true
if [ -n "${SUPABASE_URL:-}" ]; then
  printf 'window.CONFIG = { url: "%s", chave: "%s", codigo: "%s" };\n' "$SUPABASE_URL" "${SUPABASE_ANON_KEY:-}" "${CODIGO_PROJETO:-}" > "$DEST/config.js"
fi
# Liga a ponte do navegador e os dados de instalação na tela.
python3 - "$DEST/index.html" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
cab='''<script src="config.js"></script>
<script src="web-ponte.js"></script>
<link rel="manifest" href="manifest.webmanifest">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Meliponas">
<meta name="theme-color" content="#3B2414">
<style>header{padding-top:calc(14px + env(safe-area-inset-top))} nav{padding-bottom:env(safe-area-inset-bottom)} .topo-form{padding-top:calc(12px + env(safe-area-inset-top))} .tela-cheia .conteudo{padding-bottom:calc(40px + env(safe-area-inset-bottom))}</style>'''
assert '<script src="config.js"></script>' in s
s=s.replace('<script src="config.js"></script>',cab,1)
s=s.replace('content="width=device-width, initial-scale=1, maximum-scale=1"','content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover"')
open(p,'w',encoding='utf-8').write(s)
PY
echo "Versão web montada em $DEST"
