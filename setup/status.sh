#!/bin/bash
set -euo pipefail

echo "==> ArgoCD Application Status"
kubectl get applications -n argocd

echo ""
echo "==> Application Details"
kubectl get application test-app -n argocd -o yaml | grep -A 20 "^status:"

echo ""
echo "==> Notifications Controller Logs (last 50 lines)"
kubectl logs -n argocd deployment/argocd-notifications-controller --tail=50

echo ""
echo "==> Recent Events"
kubectl get events -n argocd --sort-by='.lastTimestamp' | tail -20
