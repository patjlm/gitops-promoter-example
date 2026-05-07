#!/bin/bash
# Usage: watch -n5 ./setup/status.sh
# Shows promotion status for all components across environments

NAMESPACE="${NAMESPACE:-promoter-system}"

for ps in $(kubectl -n "$NAMESPACE" get promotionstrategy -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n "$NAMESPACE" get promotionstrategy "$ps" -o json | jq -r '
    def icon: if . == "success" then "✓" elif . == "pending" then "⏳" else "✗" end;
    def pad($n): tostring | . + (" " * ($n - length)) | .[:$n];
    "=== " + .metadata.name + " (" + (.spec.activePath // "no activePath") + ") ===",
    (.status.environments[] |
      "  " +
      (.branch | ltrimstr("environment/") | pad(14)) +
      ("dry:" + (.active.dry.sha // "-" | .[:7]) | pad(12)) +
      (if .proposed.dry.sha and .proposed.dry.sha != .active.dry.sha then "→" + (.proposed.dry.sha | .[:7]) + " " else "" end | pad(10)) +
      ([.active.commitStatuses // [] | .[] | "\(.key)=\(.phase | icon)"] | join(" ") | pad(36)) +
      "PR:" + (if .pullRequest.state == "merged" then "auto-merged"
         elif .pullRequest.state == "open" then "open"
         elif .pullRequest.state == "closed" then "closed"
         elif .pullRequest.externallyMergedOrClosed then "ext-merged/closed"
         elif .pullRequest.id then "unknown"
         else "-" end) +
      (if .pullRequest.id then " #" + .pullRequest.id else "" end)
    ),
    ""
  '
done
