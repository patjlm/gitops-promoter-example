#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_DIR}/config.local.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

NAMESPACE="${NAMESPACE:-promoter-system}"
LOCAL_PORT=3333

if [[ -z "${NGROK_DOMAIN:-}" ]]; then
  echo "ERROR: NGROK_DOMAIN is not set in $CONFIG_FILE"
  exit 1
fi

# Start port-forward if not already running
if ! lsof -iTCP:${LOCAL_PORT} -sTCP:LISTEN -t &>/dev/null; then
  echo "Starting port-forward on localhost:${LOCAL_PORT}..."
  kubectl -n "$NAMESPACE" port-forward svc/promoter-webhook-receiver ${LOCAL_PORT}:3333 &
  PF_PID=$!
  sleep 2
  echo "Port-forward started (PID $PF_PID)"
else
  echo "Port-forward already listening on :${LOCAL_PORT}"
fi

echo "Starting ngrok tunnel → https://${NGROK_DOMAIN}"
ngrok http ${LOCAL_PORT} --domain="${NGROK_DOMAIN}"
