#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Applying updated notifications ConfigMap"
kubectl apply -f "${SCRIPT_DIR}/../argocd/notifications-cm.yaml"

echo "==> Restarting notifications controller to pick up changes"
kubectl rollout restart deployment/argocd-notifications-controller -n argocd

echo "==> Waiting for rollout to complete"
kubectl rollout status deployment/argocd-notifications-controller -n argocd

echo ""
echo "==> Notifications configuration updated!"
echo ""
echo "To view logs:"
echo "  kubectl logs -n argocd deployment/argocd-notifications-controller -f"
