#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_DIR}/config.local.env"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-promoter-example}"

echo "Deleting minikube profile '$MINIKUBE_PROFILE'..."
minikube delete -p "$MINIKUBE_PROFILE"
echo "Done."
