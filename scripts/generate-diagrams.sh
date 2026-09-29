#!/bin/bash
set -e

echo "========================================="
echo "  Microservices K8s - Generate Diagrams"
echo "========================================="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/docs/diagrams"

# ─── Check prerequisites ───
echo ""
echo "[1/4] Checking prerequisites..."

MISSING=0

if ! command -v kustomize &> /dev/null; then
  echo "  ERROR: kustomize is not installed."
  echo "    → brew install kustomize (macOS)"
  echo "    → https://kubectl.docs.kubernetes.io/installation/kustomize/"
  MISSING=1
fi

if ! command -v kube-diagrams &> /dev/null; then
  echo "  ERROR: kube-diagrams is not installed."
  echo "    → pip install KubeDiagrams"
  MISSING=1
fi

if ! command -v dot &> /dev/null; then
  echo "  ERROR: Graphviz (dot) is not installed."
  echo "    → brew install graphviz (macOS)"
  echo "    → sudo apt install graphviz (Debian/Ubuntu)"
  MISSING=1
fi

if [ "$MISSING" -eq 1 ]; then
  echo ""
  echo "Install missing prerequisites and try again."
  exit 1
fi

echo "  kustomize: OK"
echo "  kube-diagrams: OK"
echo "  graphviz: OK"

# ─── Create output directory ───
echo ""
echo "[2/4] Creating output directory..."

mkdir -p "$OUTPUT_DIR"
echo "  $OUTPUT_DIR"

# ─── Generate base diagram ───
echo ""
echo "[3/4] Generating base diagram..."

kustomize build "$PROJECT_DIR/k8s/base" | kube-diagrams -o "$OUTPUT_DIR/base.png" -
echo "  Generated: docs/diagrams/base.png"

# ─── Generate overlay diagrams ───
echo ""
echo "[4/4] Generating overlay diagrams..."

OVERLAYS=("dev" "staging" "prod" "dev-cnpg")

for overlay in "${OVERLAYS[@]}"; do
  OVERLAY_DIR="$PROJECT_DIR/k8s/overlays/$overlay"
  if [ ! -d "$OVERLAY_DIR" ]; then
    echo "  Skipped: $overlay (directory not found)"
    continue
  fi

  if kustomize build "$OVERLAY_DIR" | kube-diagrams -o "$OUTPUT_DIR/${overlay}.png" - 2>/dev/null; then
    echo "  Generated: docs/diagrams/${overlay}.png"
  else
    echo "  Skipped: $overlay (build failed — may require CRDs)"
  fi
done

# ─── Summary ───
echo ""
echo "========================================="
echo "  Summary"
echo "========================================="
echo ""
echo "Generated diagrams:"
for f in "$OUTPUT_DIR"/*.png; do
  [ -f "$f" ] && echo "  $(basename "$f")"
done
echo ""
echo "Output directory: docs/diagrams/"
echo "========================================="
