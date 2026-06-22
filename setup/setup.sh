#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="argocd-test"
ARGOCD_VERSION="v2.14.1"

# Load configuration
if [[ -f "${SCRIPT_DIR}/config.local.env" ]]; then
    source "${SCRIPT_DIR}/config.local.env"
    echo "==> Loaded config from config.local.env"
else
    echo "WARNING: config.local.env not found. Using template values from config.env"
    source "${SCRIPT_DIR}/config.env"
fi

echo "==> Creating kind cluster: ${CLUSTER_NAME}"
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster ${CLUSTER_NAME} already exists"
else
    kind create cluster --name "${CLUSTER_NAME}"
fi

echo "==> Installing ArgoCD ${ARGOCD_VERSION}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> Waiting for ArgoCD to be ready"
kubectl wait --for=condition=available --timeout=300s \
    deployment/argocd-server \
    deployment/argocd-repo-server \
    deployment/argocd-notifications-controller \
    -n argocd

echo "==> Creating ArgoCD notifications secret from config"
# Expand tilde in path
PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH/#\~/$HOME}"

if [[ -n "${PRIVATE_KEY_PATH:-}" ]] && [[ -f "${PRIVATE_KEY_PATH}" ]]; then
    PRIVATE_KEY=$(cat "${PRIVATE_KEY_PATH}")
    kubectl create secret generic argocd-notifications-secret \
        -n argocd \
        --from-literal=github-app-id="${GITHUB_APP_ID}" \
        --from-literal=github-installation-id="${GITHUB_INSTALLATION_ID}" \
        --from-literal=github-app-private-key="${PRIVATE_KEY}" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "Created secret with private key from ${PRIVATE_KEY_PATH}"
else
    echo "ERROR: Private key file not found at: ${PRIVATE_KEY_PATH:-<not set>}"
    echo "Please download the GitHub App private key and update GITHUB_APP_PRIVATE_KEY_PATH in config.local.env"
    exit 1
fi

echo "==> Configuring ArgoCD reconciliation interval (30s for faster Git polling)"
kubectl patch configmap argocd-cm -n argocd --type merge -p '{"data":{"timeout.reconciliation":"30s"}}'

echo "==> Applying ArgoCD notifications ConfigMap"
kubectl apply -f "${SCRIPT_DIR}/../argocd/notifications-cm.yaml"

echo "==> Restarting notifications controller to pick up new config"
kubectl rollout restart deployment/argocd-notifications-controller -n argocd
kubectl rollout status deployment/argocd-notifications-controller -n argocd

echo "==> Applying app-of-apps (manages all child applications)"
kubectl apply -f "${SCRIPT_DIR}/../argocd/app-of-apps.yaml"

echo ""
echo "==> Setup complete!"
echo ""
echo "ArgoCD will now:"
echo "  1. Sync the 'all-apps' parent application"
echo "  2. Create child applications: test-app, test-app-2"
echo "  3. Sync all child applications"
echo "  4. Send notifications when each app syncs (per-app status)"
echo "  5. Send aggregate notification when ALL apps are synced"
echo ""
echo "To access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "Get admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "Watch applications sync:"
echo "  kubectl get applications -n argocd -w"
