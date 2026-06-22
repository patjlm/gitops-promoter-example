#!/bin/bash
set -euo pipefail

REPO="patjlm/gitops-promoter-example"
BRANCH="argocd-notifications-example"

# Track what we've seen: "sha:context:state:description"
SEEN_FILE=$(mktemp)
trap "rm -f $SEEN_FILE" EXIT

echo "Watching commit statuses for ${REPO} on ${BRANCH}..." >&2

while true; do
    # Get HEAD commit SHA
    SHA=$(gh api "repos/${REPO}/git/ref/heads/${BRANCH}" --jq '.object.sha' 2>/dev/null) || continue
    SHORT_SHA="${SHA:0:7}"

    # Get all statuses for this commit
    gh api "repos/${REPO}/commits/${SHA}/status" --jq '.statuses[]' 2>/dev/null | \
    while IFS= read -r status; do
        CONTEXT=$(echo "$status" | jq -r '.context')
        STATE=$(echo "$status" | jq -r '.state')
        DESC=$(echo "$status" | jq -r '.description')

        # Create unique key for this status
        KEY="${SHA}:${CONTEXT}:${STATE}:${DESC}"

        # Only print if we haven't seen this exact status before
        if ! grep -qF "$KEY" "$SEEN_FILE" 2>/dev/null; then
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            echo "[$TIMESTAMP] $SHORT_SHA | $CONTEXT | $STATE | $DESC"
            echo "$KEY" >> "$SEEN_FILE"
        fi
    done

    sleep 5
done
