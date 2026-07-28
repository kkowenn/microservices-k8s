#!/bin/bash
set -e

echo "========================================="
echo "  Microservices K8s - Create Secrets"
echo "========================================="

NAMESPACE="${1:-demo-dev}"

echo ""
echo "Target namespace: $NAMESPACE"
echo ""

# ─── GCR Image Pull Secret ───
echo "========================================="
echo "  [1/2] GCR Image Pull Secret"
echo "========================================="
echo ""
echo "This creates a secret for pulling images from Google Container Registry"
echo "or Artifact Registry."
echo ""

read -p "Set up GCR image pull secret? (y/N): " setup_gcr
if [[ "$setup_gcr" == "y" || "$setup_gcr" == "Y" ]]; then

  # Check for gcloud
  if ! command -v gcloud &> /dev/null; then
    echo "ERROR: gcloud CLI is not installed."
    echo "  Install: https://cloud.google.com/sdk/docs/install"
    exit 1
  fi

  read -p "GCP project ID: " GCP_PROJECT
  if [[ -z "$GCP_PROJECT" ]]; then
    echo "ERROR: Project ID is required."
    exit 1
  fi

  read -p "Use existing service account key file? (y/N): " use_existing_key
  if [[ "$use_existing_key" == "y" || "$use_existing_key" == "Y" ]]; then
    read -p "Path to service account key JSON: " KEY_FILE
    if [[ ! -f "$KEY_FILE" ]]; then
      echo "ERROR: File not found: $KEY_FILE"
      exit 1
    fi
  else
    echo ""
    echo "Creating service account for image pulling..."
    SA_NAME="k8s-image-puller"
    SA_EMAIL="$SA_NAME@$GCP_PROJECT.iam.gserviceaccount.com"

    # Create service account
    gcloud iam service-accounts create "$SA_NAME" \
      --project="$GCP_PROJECT" \
      --display-name="K8s Image Puller" 2>/dev/null || echo "  Service account already exists."

    # Grant Artifact Registry reader role
    gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
      --member="serviceAccount:$SA_EMAIL" \
      --role="roles/artifactregistry.reader" \
      --quiet > /dev/null

    # Create key file
    KEY_FILE="/tmp/gcr-key-$GCP_PROJECT.json"
    gcloud iam service-accounts keys create "$KEY_FILE" \
      --iam-account="$SA_EMAIL" \
      --project="$GCP_PROJECT"

    echo "  Service account key created: $KEY_FILE"
  fi

  # Create namespace if needed
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true

  # Create the image pull secret
  kubectl create secret docker-registry gcr-secret \
    --namespace="$NAMESPACE" \
    --docker-server="https://gcr.io" \
    --docker-username="_json_key" \
    --docker-password="$(cat "$KEY_FILE")" \
    --docker-email="noreply@example.com" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Also create for Artifact Registry
  kubectl create secret docker-registry ar-secret \
    --namespace="$NAMESPACE" \
    --docker-server="https://us-docker.pkg.dev" \
    --docker-username="_json_key" \
    --docker-password="$(cat "$KEY_FILE")" \
    --docker-email="noreply@example.com" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo ""
  echo "  GCR secret created: gcr-secret"
  echo "  Artifact Registry secret created: ar-secret"
  echo ""
  echo "  To use in deployments, add to your pod spec:"
  echo "    imagePullSecrets:"
  echo "      - name: gcr-secret"
  echo ""
fi

# ─── PostgreSQL Secret ───
echo "========================================="
echo "  [2/2] PostgreSQL Secret"
echo "========================================="
echo ""
echo "This creates/updates the postgres-credentials secret."
echo "Default values: demouser / demopass / demodb"
echo ""

read -p "Set up PostgreSQL secret? (y/N): " setup_pg
if [[ "$setup_pg" == "y" || "$setup_pg" == "Y" ]]; then

  read -p "PostgreSQL username [demouser]: " PG_USER
  PG_USER="${PG_USER:-demouser}"

  read -sp "PostgreSQL password [demopass]: " PG_PASS
  PG_PASS="${PG_PASS:-demopass}"
  echo ""

  read -p "PostgreSQL database [demodb]: " PG_DB
  PG_DB="${PG_DB:-demodb}"

  # Create namespace if needed
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true

  # Create the secret
  kubectl create secret generic postgres-credentials \
    --namespace="$NAMESPACE" \
    --from-literal=POSTGRES_USER="$PG_USER" \
    --from-literal=POSTGRES_PASSWORD="$PG_PASS" \
    --from-literal=POSTGRES_DB="$PG_DB" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo ""
  echo "  PostgreSQL secret created in namespace: $NAMESPACE"
  echo "    User: $PG_USER"
  echo "    DB:   $PG_DB"
  echo ""
fi

echo "========================================="
echo "  Done!"
echo "========================================="
echo ""
echo "  Verify secrets: kubectl get secrets -n $NAMESPACE"
echo ""
