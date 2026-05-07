#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

ENVIRONMENTS="development integration stage prod-1 prod-2 prod-3"

echo "=== Resetting all environment and proposed branches ==="

# Delete all proposed (-next) branches
echo "--- Deleting proposed branches ---"
proposed=$(git ls-remote origin 2>&1 | grep "next/" | awk '{print $2}' | sed 's|refs/heads/||' || true)
if [[ -n "$proposed" ]]; then
  for branch in $proposed; do
    echo "  Deleting $branch"
    git push origin --delete "$branch" 2>&1
  done
else
  echo "  No proposed branches to delete."
fi

# Delete all environment branches
echo "--- Deleting environment branches ---"
for env in $ENVIRONMENTS; do
  BRANCH="environment/$env"
  if git ls-remote --exit-code origin "$BRANCH" > /dev/null 2>&1; then
    echo "  Deleting $BRANCH"
    git push origin --delete "$BRANCH" 2>&1
  fi
done

# Recreate environment branches as empty orphans
echo "--- Creating fresh environment branches ---"
for env in $ENVIRONMENTS; do
  BRANCH="environment/$env"
  echo "  Creating $BRANCH"
  git checkout --orphan "$BRANCH"
  git rm -rf . 2>/dev/null || true
  git -c commit.gpgsign=false commit --allow-empty -m "initialize $BRANCH"
  git push origin "$BRANCH" 2>&1
  git checkout main
  git branch -D "$BRANCH"
done

# Clean up stale CommitStatus CRs if kubectl is available
if command -v kubectl &> /dev/null && kubectl -n promoter-system get commitstatus &> /dev/null; then
  echo "--- Cleaning up CommitStatus CRs ---"
  kubectl -n promoter-system delete commitstatus --all 2>&1
fi

echo ""
echo "=== Reset complete ==="
echo "Push to main to trigger hydration, then scale the promoter back up."
