#!/usr/bin/env bash
# Copia as telas do aplicativo (as mesmas do Android) para o projeto iOS e grava a configuração do servidor.
# Uso: ./preparar.sh   (variáveis opcionais: SUPABASE_URL, SUPABASE_ANON_KEY, CODIGO_PROJETO)
set -euo pipefail
cd "$(dirname "$0")"
rm -rf Recursos/www
mkdir -p Recursos/www/logos
cp -R ../app-android/assets/. Recursos/www/
cp -f ../logos/*.png Recursos/www/logos/ 2>/dev/null || true
if [ -n "${SUPABASE_URL:-}" ]; then
  printf 'window.CONFIG = { url: "%s", chave: "%s", codigo: "%s" };\n' "$SUPABASE_URL" "${SUPABASE_ANON_KEY:-}" "${CODIGO_PROJETO:-}" > Recursos/www/config.js
fi
echo "Telas copiadas para ios-app/Recursos/www"
