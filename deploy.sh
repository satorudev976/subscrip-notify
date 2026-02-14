#!/bin/bash
set -euo pipefail

# ---- Configuration ----
PROJECT_ID="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
REGION="${GCP_REGION:-asia-northeast1}"
SERVICE_NAME="mihari"
SERVICE_ACCOUNT="mihari-runner@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"

echo "=== Building and deploying ${SERVICE_NAME} ==="

# 1) Ensure IAM roles for the runtime service account
echo "[1/5] Granting IAM roles to ${SERVICE_ACCOUNT}..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member "serviceAccount:${SERVICE_ACCOUNT}" \
  --role "roles/secretmanager.secretAccessor" \
  --condition=None \
  --quiet \
  --project "${PROJECT_ID}"

# 2) Build & push container
echo "[2/5] Building container..."
cd backend
gcloud builds submit --tag "${IMAGE}" --project "${PROJECT_ID}"
cd ..

# 3) Deploy to Cloud Run
echo "[3/5] Deploying to Cloud Run..."
gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --platform managed \
  --allow-unauthenticated \
  --service-account "${SERVICE_ACCOUNT}" \
  --set-env-vars "NODE_ENV=production" \
  --set-secrets "GOOGLE_CLIENT_ID=google-client-id:latest,LINE_CHANNEL_ACCESS_TOKEN=line-channel-access-token:latest,LINE_CHANNEL_SECRET=line-channel-secret:latest,TOKEN_ENCRYPTION_KEY=token-encryption-key:latest,SCHEDULER_SECRET=scheduler-secret:latest" \
  --project "${PROJECT_ID}"

# Get service URL
SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --format "value(status.url)")
echo "Service URL: ${SERVICE_URL}"

# 4) Create Cloud Scheduler jobs
echo "[4/5] Creating Cloud Scheduler jobs..."

# Free tier: every 15 minutes
gcloud scheduler jobs create http "${SERVICE_NAME}-poll-free" \
  --location "${REGION}" \
  --schedule "*/15 * * * *" \
  --uri "${SERVICE_URL}/jobs/poll" \
  --http-method POST \
  --headers "x-scheduler-secret=\${SCHEDULER_SECRET}" \
  --time-zone "Asia/Tokyo" \
  --project "${PROJECT_ID}" \
  --quiet 2>/dev/null || \
gcloud scheduler jobs update http "${SERVICE_NAME}-poll-free" \
  --location "${REGION}" \
  --schedule "*/15 * * * *" \
  --uri "${SERVICE_URL}/jobs/poll" \
  --http-method POST \
  --headers "x-scheduler-secret=\${SCHEDULER_SECRET}" \
  --time-zone "Asia/Tokyo" \
  --project "${PROJECT_ID}"

echo "[5/5] Done!"
echo ""
echo "Next steps:"
echo "  1. Set secrets in Secret Manager"
echo "  2. Configure LINE webhook URL: ${SERVICE_URL}/line/webhook"
echo "  3. Configure Google OAuth redirect URI in GCP Console"
