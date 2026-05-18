#!/usr/bin/env bash
# =====================================================================
#  Deploy del cliente web a Google Cloud Run.
#
#  Cloud Run encaja perfecto para esta app: scale-to-zero (no pagas
#  cuando nadie la usa), pricing por requests (~$0/mes para tráfico
#  bajo), HTTPS automático, dominio personalizado fácil.
#
#  Pre-requisitos (una sola vez):
#    1. gcloud CLI instalado y autenticado:
#         gcloud auth login
#         gcloud config set project taxis-f0f51
#    2. APIs habilitadas:
#         gcloud services enable run.googleapis.com
#         gcloud services enable artifactregistry.googleapis.com
#         gcloud services enable cloudbuild.googleapis.com
#    3. Repositorio de Artifact Registry (una sola vez):
#         gcloud artifacts repositories create client-web \
#           --repository-format=docker \
#           --location=us-central1 \
#           --description="Imagen del cliente web"
#
#  Uso:
#    # Edita las variables NEXT_PUBLIC_* abajo o exporta como env vars,
#    # luego corre:
#    bash client_web/deploy-cloud-run.sh
#
#  El script hace:
#    1. Build de la imagen con Cloud Build (más rápido que docker local
#       y no consume tu disco).
#    2. Push a Artifact Registry.
#    3. Deploy en Cloud Run con HTTPS y dominio asignado por Google.
#    4. Imprime la URL pública al final.
# =====================================================================

set -euo pipefail

# ----- Configuración -----
PROJECT_ID="${PROJECT_ID:-taxis-f0f51}"
REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-taxis-client-web}"
REPO="${REPO:-client-web}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE_NAME}:latest"

# Variables públicas de Firebase (NEXT_PUBLIC_*). Si están en el shell
# las usa; si no, edita aquí o pásalas como env vars al ejecutar.
: "${NEXT_PUBLIC_FIREBASE_API_KEY:?Falta NEXT_PUBLIC_FIREBASE_API_KEY}"
: "${NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN:=taxis-f0f51.firebaseapp.com}"
: "${NEXT_PUBLIC_FIREBASE_PROJECT_ID:=taxis-f0f51}"
: "${NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET:=taxis-f0f51.appspot.com}"
: "${NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID:?Falta NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID}"
: "${NEXT_PUBLIC_FIREBASE_APP_ID:?Falta NEXT_PUBLIC_FIREBASE_APP_ID}"

# El script vive en client_web/, así que cd a esa carpeta.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== 1/3 Build de imagen con Cloud Build ==="
echo "    Imagen: $IMAGE"
gcloud builds submit \
  --project="$PROJECT_ID" \
  --tag="$IMAGE" \
  --substitutions="_API_KEY=$NEXT_PUBLIC_FIREBASE_API_KEY,_AUTH_DOMAIN=$NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN,_PROJECT_ID=$NEXT_PUBLIC_FIREBASE_PROJECT_ID,_STORAGE_BUCKET=$NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET,_MESSAGING_SENDER_ID=$NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID,_APP_ID=$NEXT_PUBLIC_FIREBASE_APP_ID" \
  --config=- <<EOF
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '--build-arg=NEXT_PUBLIC_FIREBASE_API_KEY=\${_API_KEY}'
      - '--build-arg=NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=\${_AUTH_DOMAIN}'
      - '--build-arg=NEXT_PUBLIC_FIREBASE_PROJECT_ID=\${_PROJECT_ID}'
      - '--build-arg=NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=\${_STORAGE_BUCKET}'
      - '--build-arg=NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=\${_MESSAGING_SENDER_ID}'
      - '--build-arg=NEXT_PUBLIC_FIREBASE_APP_ID=\${_APP_ID}'
      - '-t'
      - '$IMAGE'
      - '.'
images:
  - '$IMAGE'
EOF

echo
echo "=== 2/3 Deploy a Cloud Run ==="
gcloud run deploy "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --image="$IMAGE" \
  --region="$REGION" \
  --platform=managed \
  --allow-unauthenticated \
  --port=3000 \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=5 \
  --timeout=60s \
  --concurrency=80

echo
echo "=== 3/3 Listo ==="
URL=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format='value(status.url)')
echo "✅ Cliente web desplegado:"
echo "   $URL"
echo
echo "Próximos pasos opcionales:"
echo "  - Apuntar dominio personalizado:"
echo "      gcloud run domain-mappings create --service=$SERVICE_NAME --domain=cliente.tudominio.com --region=$REGION"
echo "  - Ver logs en vivo:"
echo "      gcloud run services logs tail $SERVICE_NAME --project=$PROJECT_ID --region=$REGION"
