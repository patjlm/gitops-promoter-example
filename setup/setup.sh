#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Load config
CONFIG_FILE="${SCRIPT_DIR}/config.local.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found."
  echo "Copy config.env to config.local.env and fill in your values:"
  echo "  cp ${SCRIPT_DIR}/config.env ${CONFIG_FILE}"
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Validate required config
for var in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_FILE; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set in $CONFIG_FILE"
    exit 1
  fi
done

if [[ ! -f "${GITHUB_APP_PRIVATE_KEY_FILE}" ]]; then
  echo "ERROR: GitHub App private key file not found: ${GITHUB_APP_PRIVATE_KEY_FILE}"
  exit 1
fi

PROMOTER_IMAGE="${PROMOTER_IMAGE:-quay.io/argoprojlabs/gitops-promoter}"
PROMOTER_TAG="${PROMOTER_TAG:-v0.27.1}"
PROMOTER_INSTALL_URL="${PROMOTER_INSTALL_URL:-}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-promoter-example}"

echo "=== gitops-promoter local setup ==="
echo "  Minikube profile:  $MINIKUBE_PROFILE"
echo "  Promoter image:    $PROMOTER_IMAGE:$PROMOTER_TAG"
echo "  Install URL:       ${PROMOTER_INSTALL_URL:-<custom image>}"
echo ""

# --- Step 1: Minikube ---
echo "--- Step 1: Starting minikube ---"
if minikube status -p "$MINIKUBE_PROFILE" &>/dev/null; then
  echo "Minikube profile '$MINIKUBE_PROFILE' already running."
else
  minikube start -p "$MINIKUBE_PROFILE" --memory=4096 --cpus=2
fi
kubectl config use-context "$MINIKUBE_PROFILE"

# --- Step 2: Install gitops-promoter ---
echo "--- Step 2: Installing gitops-promoter ---"
if [[ -n "$PROMOTER_INSTALL_URL" ]]; then
  echo "Installing from release manifest: $PROMOTER_INSTALL_URL"
  curl -sL "$PROMOTER_INSTALL_URL" | kubectl apply -f -

  # Override image if it differs from what's in the manifest
  MANIFEST_DEFAULT_TAG=$(curl -sL "$PROMOTER_INSTALL_URL" | grep -oP 'image: \K.*gitops-promoter:\S+' | head -1 || true)
  DESIRED="${PROMOTER_IMAGE}:${PROMOTER_TAG}"
  if [[ -n "$MANIFEST_DEFAULT_TAG" && "$MANIFEST_DEFAULT_TAG" != "$DESIRED" ]]; then
    echo "Overriding image to $DESIRED"
    kubectl -n promoter-system set image deployment/promoter-controller-manager \
      manager="${DESIRED}"
  fi
else
  echo "No install URL set. Loading custom image into minikube..."
  # If the image is local (e.g. built from PR #1337), load it into minikube
  if ! minikube -p "$MINIKUBE_PROFILE" image ls | grep -q "${PROMOTER_IMAGE}:${PROMOTER_TAG}"; then
    echo "Loading ${PROMOTER_IMAGE}:${PROMOTER_TAG} into minikube..."
    minikube -p "$MINIKUBE_PROFILE" image load "${PROMOTER_IMAGE}:${PROMOTER_TAG}"
  fi

  # Apply CRDs and deployment from the repo's dist/ or a local build
  echo "ERROR: Custom image mode requires a local install.yaml."
  echo "Build gitops-promoter and place install.yaml in setup/install.yaml,"
  echo "or set PROMOTER_INSTALL_URL in config.local.env."
  echo ""
  echo "To build from PR #1337:"
  echo "  git clone https://github.com/argoproj-labs/gitops-promoter.git"
  echo "  cd gitops-promoter"
  echo "  git fetch origin pull/1337/head:activepath"
  echo "  git checkout activepath"
  echo "  make docker-build IMG=${PROMOTER_IMAGE}:${PROMOTER_TAG}"
  echo "  make build-installer IMG=${PROMOTER_IMAGE}:${PROMOTER_TAG}"
  echo "  cp dist/install.yaml /path/to/gitops-promoter-example/setup/install.yaml"

  if [[ -f "${SCRIPT_DIR}/install.yaml" ]]; then
    echo ""
    echo "Found setup/install.yaml, applying..."
    kubectl apply -f "${SCRIPT_DIR}/install.yaml"
    # Retry to handle CRD registration race condition
    sleep 3
    kubectl apply -f "${SCRIPT_DIR}/install.yaml" 2>/dev/null || true
    kubectl -n promoter-system set image deployment/promoter-controller-manager \
      manager="${PROMOTER_IMAGE}:${PROMOTER_TAG}"
  else
    exit 1
  fi
fi

# Install ArgoCD CRDs (the promoter controller watches Application resources)
echo "Installing ArgoCD CRDs..."
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/application-crd.yaml 2>/dev/null
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/appproject-crd.yaml 2>/dev/null

echo "Waiting for promoter controller to be ready..."
kubectl -n promoter-system rollout status deployment/promoter-controller-manager --timeout=120s

# --- Step 3: Create GitHub App secret and ScmProvider ---
echo "--- Step 3: Configuring ScmProvider ---"
kubectl create namespace promoter-system 2>/dev/null || true

kubectl create secret generic github-app-key \
  --namespace=promoter-system \
  --from-file=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply ScmProvider and GitRepository with correct App IDs
sed \
  -e "s/appID: 0/appID: ${GITHUB_APP_ID}/" \
  -e "s/installationID: 0/installationID: ${GITHUB_APP_INSTALLATION_ID}/" \
  "${REPO_DIR}/k8s/scm-provider.yaml" | kubectl apply -f -

kubectl apply -f "${REPO_DIR}/k8s/git-repository.yaml"

# --- Step 4: Apply PromotionStrategies and commit status resources ---
echo "--- Step 4: Applying PromotionStrategies and commit status gates ---"
kubectl apply -f "${REPO_DIR}/k8s/promotion-strategies/"
kubectl apply -f "${REPO_DIR}/k8s/commit-status/"

# --- Step 5: Create environment branches ---
echo "--- Step 5: Creating environment branches (if missing) ---"
cd "$REPO_DIR"
ENVIRONMENTS="development integration stage prod-1 prod-2 prod-3"
for env in $ENVIRONMENTS; do
  BRANCH="environment/$env"
  if git ls-remote --exit-code origin "$BRANCH" &>/dev/null; then
    echo "  Branch $BRANCH already exists."
  else
    echo "  Creating $BRANCH..."
    git checkout --orphan "$BRANCH"
    git rm -rf . 2>/dev/null || true
    git -c commit.gpgsign=false commit --allow-empty -m "initialize $BRANCH"
    git push origin "$BRANCH"
    git checkout main
  fi
done

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Verify the controller is running:"
echo "     kubectl -n promoter-system get pods"
echo ""
echo "  2. Check PromotionStrategy status:"
echo "     kubectl -n promoter-system get promotionstrategy"
echo ""
echo "  3. Make a change on main and push to trigger hydration:"
echo "     # edit any component, commit, push"
echo ""
echo "  4. Watch the promoter dashboard:"
echo "     gitops-promoter dashboard"
