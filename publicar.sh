#!/usr/bin/env bash
# Publica este projeto no seu GitHub, configura os segredos e liga o GitHub Pages.
# Requisitos: git e GitHub CLI (https://cli.github.com) instalados.
# Uso: ./publicar.sh [nome-do-repositorio]
set -euo pipefail
cd "$(dirname "$0")"
NOME="${1:-monitor-meliponas}"

gh auth status >/dev/null 2>&1 || gh auth login
DONO=$(gh api user -q .login)
echo "Conta GitHub: $DONO   Repositório: $NOME"
echo
read -rp "Endereço do Supabase (ex.: https://abcd.supabase.co): " SUPABASE_URL
read -rp "Chave pública anon do Supabase: " SUPABASE_ANON_KEY
read -rp "Código do projeto (o mesmo gravado no banco): " CODIGO_PROJETO
read -rp "Arquivo da chave de assinatura [chave.jks]: " KS; KS="${KS:-chave.jks}"
read -rp "Senha da chave de assinatura [fis2026]: " KSENHA; KSENHA="${KSENHA:-fis2026}"

gh repo create "$NOME" --public --description "Monitor Meliponas — aplicativo, banco de dados e painel (FIS | IPÊ e Amazônia Bee)"
R="$DONO/$NOME"
gh secret set SUPABASE_URL      -R "$R" -b "$SUPABASE_URL"
gh secret set SUPABASE_ANON_KEY -R "$R" -b "$SUPABASE_ANON_KEY"
gh secret set CODIGO_PROJETO    -R "$R" -b "$CODIGO_PROJETO"
gh secret set KEYSTORE_SENHA    -R "$R" -b "$KSENHA"
if [ -f "$KS" ]; then base64 -w0 "$KS" | gh secret set KEYSTORE_B64 -R "$R"; else echo "AVISO: $KS não encontrado; o GitHub criará uma chave nova a cada compilação."; fi
gh api -X POST "repos/$R/pages" -f build_type=workflow >/dev/null 2>&1 || echo "AVISO: ative o GitHub Pages em Settings > Pages > Source: GitHub Actions."

[ -d .git ] || git init -q -b main
git add -A
git commit -qm "Monitor Meliponas: aplicativo, banco de dados e painel" || true
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/$R.git"
git push -u origin main

echo
echo "Pronto. Em alguns minutos:"
echo "  Painel:     https://$DONO.github.io/$NOME/"
echo "  Aplicativo: https://github.com/$R/releases/latest"
echo "  Andamento:  https://github.com/$R/actions"
