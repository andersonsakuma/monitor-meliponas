#!/usr/bin/env bash
# Compila o APK do Monitor Meliponas sem Android Studio (Ubuntu 22.04/24.04).
# Uso: ./build.sh            -> gera saida/MonitorMeliponas.apk
# Variáveis opcionais: SUPABASE_URL, SUPABASE_ANON_KEY, CODIGO_PROJETO (gravadas em assets/config.js)
#                      KEYSTORE (arquivo .jks), KEYSTORE_SENHA, KEY_ALIAS
set -euo pipefail
cd "$(dirname "$0")"
command -v aapt >/dev/null || sudo apt-get install -y aapt apksigner zipalign dalvik-exchange android-sdk-platform-23 openjdk-17-jdk-headless
AJ=/usr/lib/android-sdk/platforms/android-23/android.jar
if [ -n "${SUPABASE_URL:-}" ]; then
  printf 'window.CONFIG = { url: "%s", chave: "%s", codigo: "%s" };\n' "$SUPABASE_URL" "${SUPABASE_ANON_KEY:-}" "${CODIGO_PROJETO:-}" > assets/config.js
fi
mkdir -p assets/logos && cp -f ../logos/*.png assets/logos/ 2>/dev/null || true
rm -rf build && mkdir -p build/gen build/obj saida
aapt package -f -m -J build/gen -M AndroidManifest.xml -S res -I "$AJ"
javac -encoding UTF-8 --release 8 -nowarn -d build/obj -classpath "$AJ" src/br/org/fis/meliponas/*.java build/gen/br/org/fis/meliponas/R.java
dalvik-exchange --dex --output=build/classes.dex build/obj
aapt package -f -M AndroidManifest.xml -S res -A assets -I "$AJ" -F build/unsigned.apk
(cd build && aapt add unsigned.apk classes.dex >/dev/null)
zipalign -f -p 4 build/unsigned.apk build/aligned.apk
KS="${KEYSTORE:-chave.jks}"; SENHA="${KEYSTORE_SENHA:-fis2026}"; ALIAS="${KEY_ALIAS:-fis}"
if [ ! -f "$KS" ]; then
  echo "AVISO: chave de assinatura não encontrada; criando uma nova ($KS)."
  echo "       Aplicativos assinados com outra chave não atualizam por cima da versão instalada."
  keytool -genkeypair -keystore "$KS" -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$SENHA" -keypass "$SENHA" -dname "CN=FIS Meliponicultura, O=FIS IPE, C=BR"
fi
apksigner sign --ks "$KS" --ks-key-alias "$ALIAS" --ks-pass "pass:$SENHA" --key-pass "pass:$SENHA" --out saida/MonitorMeliponas.apk build/aligned.apk
apksigner verify saida/MonitorMeliponas.apk && echo "APK pronto: app-android/saida/MonitorMeliponas.apk"
