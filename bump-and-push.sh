#!/bin/bash
set -euo pipefail

# Get current version from kustomization.yaml
CURRENT=$(grep 'nameSuffix:' app2/kustomization.yaml | sed 's/.*-v//' || echo "0")
NEXT=$((CURRENT + 1))

# Update version
sed -i "s/nameSuffix: -v.*/nameSuffix: -v${NEXT}/" app2/kustomization.yaml

echo "Bumped version: v${CURRENT} -> v${NEXT}"

# Show what changed
git diff app2/kustomization.yaml

# Commit and push
if [[ "${1:-}" == "--commit" ]]; then
    MESSAGE="${2:-Bump job version to v${NEXT} to trigger sync}"
    git add app2/kustomization.yaml
    git commit -m "$MESSAGE"
    git push
    echo "Committed and pushed: v${NEXT}"
else
    echo
    echo "Run with --commit to commit and push:"
    echo "  $0 --commit [message]"
fi
