#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# Deploy de client_web → Oracle (taxiseguro.it-services.center) en UN comando.
#
#   Uso:  ./client_web/deploy.sh
#
# Qué hace:
#  1. Sincroniza el CÓDIGO FUENTE local a ~/taxiseguro en la VM Oracle (alias
#     SSH `sshoracle`), via rsync.
#  2. PRESERVA la config de Oracle: NO toca `docker-compose.yaml` (que tiene las
#     keys de Firebase/Maps como build args) ni `.env*`.
#  3. Reconstruye y levanta el contenedor Next.js (`docker compose up -d --build`).
#
# Requiere: alias `sshoracle` en ~/.ssh/config y rsync local.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE_HOST="sshoracle"
REMOTE_DIR="/home/ubuntu/taxiseguro"

echo "→ Sincronizando código a ${REMOTE_HOST}:${REMOTE_DIR} (preservando config de Oracle)…"
rsync -az --delete \
  --exclude 'node_modules' \
  --exclude '.next' \
  --exclude '.git' \
  --exclude 'deploy.sh' \
  --exclude 'docker-compose.yaml' \
  --exclude '.env' \
  --exclude '.env.*' \
  "${HERE}/" "${REMOTE_HOST}:${REMOTE_DIR}/"

echo "→ Reconstruyendo y levantando el contenedor…"
ssh "${REMOTE_HOST}" "cd ${REMOTE_DIR} && sudo docker compose up -d --build taxiseguro"

echo ""
echo "✅ Deploy listo. Verifica: https://taxiseguro.it-services.center"
