#!/bin/bash
set -euo pipefail

CLUSTER_NAME="argocd-test"

echo "==> Deleting kind cluster: ${CLUSTER_NAME}"
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    echo "Cluster deleted"
else
    echo "Cluster ${CLUSTER_NAME} does not exist"
fi
