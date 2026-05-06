#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_DIR}/config.local.env"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

PROMOTER_IMAGE="${PROMOTER_IMAGE:-quay.io/argoprojlabs/gitops-promoter}"
PROMOTER_TAG="${PROMOTER_TAG:-activepath-dev}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-promoter-example}"
PR_NUMBER="${1:-1337}"
PROMOTER_REPO="${PROMOTER_REPO:-https://github.com/argoproj-labs/gitops-promoter.git}"
BUILD_DIR="${SCRIPT_DIR}/.build/gitops-promoter"

echo "=== Building gitops-promoter from PR #${PR_NUMBER} ==="
echo "  Image: ${PROMOTER_IMAGE}:${PROMOTER_TAG}"
echo ""

# Clone or update the repo
if [[ -d "$BUILD_DIR" ]]; then
  echo "Updating existing clone..."
  git -C "$BUILD_DIR" fetch origin
else
  echo "Cloning gitops-promoter..."
  mkdir -p "$(dirname "$BUILD_DIR")"
  git clone "$PROMOTER_REPO" "$BUILD_DIR"
fi

# Fetch and checkout the PR
echo "Checking out PR #${PR_NUMBER}..."
git -C "$BUILD_DIR" fetch origin "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
git -C "$BUILD_DIR" checkout "pr-${PR_NUMBER}"

# Build the image
echo "Building Docker image..."
make -C "$BUILD_DIR" docker-build "IMG=${PROMOTER_IMAGE}:${PROMOTER_TAG}"

# Generate install.yaml
echo "Generating install.yaml..."
make -C "$BUILD_DIR" build-installer "IMG=${PROMOTER_IMAGE}:${PROMOTER_TAG}"
cp "$BUILD_DIR/dist/install.yaml" "${SCRIPT_DIR}/install.yaml"

# Load into minikube if running
if minikube status -p "$MINIKUBE_PROFILE" &>/dev/null; then
  echo "Loading image into minikube..."
  minikube -p "$MINIKUBE_PROFILE" image load "${PROMOTER_IMAGE}:${PROMOTER_TAG}"
fi

echo ""
echo "=== Build complete ==="
echo "  install.yaml: ${SCRIPT_DIR}/install.yaml"
echo "  Image: ${PROMOTER_IMAGE}:${PROMOTER_TAG}"
echo ""
echo "Now update config.local.env:"
echo "  PROMOTER_IMAGE=${PROMOTER_IMAGE}"
echo "  PROMOTER_TAG=${PROMOTER_TAG}"
echo "  PROMOTER_INSTALL_URL=          # clear this to use the custom image"
echo ""
echo "Then run: ./setup/setup.sh"
