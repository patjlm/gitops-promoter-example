# ArgoCD Notifications Example

Testing ArgoCD notifications configurations for Jira [GCP-840](https://redhat.atlassian.net/browse/GCP-840).

## Overview

This repository demonstrates ArgoCD notifications using a GitHub App to set commit statuses and create/update deployments via the GitHub API.

## GitHub App

- **Name**: argocd-notifications-gop-example
- **App ID**: 4114944
- **Installation ID**: 141875402
- **Repository**: patjlm/gitops-promoter-example (this branch)
- **Permissions**:
  - Read: metadata
  - Read & Write: checks, commit statuses, deployments, pull requests

## Repository Structure

- `app/` — Kustomize application deploying a dummy ConfigMap (test-app)
- `app2/` — Second Kustomize application (test-app-2, same ConfigMap with suffix)
- `argocd/apps/` — Child Application manifests (managed by app-of-apps)
- `argocd/app-of-apps.yaml` — Parent Application that aggregates child app status
- `argocd/notifications-cm.yaml` — Notification templates and triggers
- `setup/` — Local kind cluster setup scripts

## App-of-Apps Pattern

This repository uses the app-of-apps pattern:

- **Child Apps** (`test-app`, `test-app-2`): Each sends per-app notifications
- **Parent App** (`all-apps`): Sends aggregate notification when ALL children are synced

This gives you both:
1. Per-application status/checks (e.g., `ArgoCD/test-app`, `ArgoCD/test-app-2`)
2. Aggregate status/check (e.g., `ArgoCD/all-apps`) that only succeeds when all apps are synced

## Quick Start

```bash
# Ensure you have the GitHub App private key downloaded
# Default location: ~/argocd-notifications-gop-example.2026-06-22.private-key.pem
# Or update GITHUB_APP_PRIVATE_KEY_PATH in setup/config.local.env

# Create kind cluster and install ArgoCD
cd setup
./setup.sh

# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Testing Workflow

1. Make a change to `app/configmap.yaml`
2. Commit and push to this branch
3. ArgoCD detects the change and syncs
4. Notifications controller posts commit status, check run, and deployment to GitHub
5. Verify on GitHub: commit status and deployment shows in the UI

## Updating Notifications Configuration

When you modify `argocd/notifications-cm.yaml`:

```bash
cd setup
./update-notifications.sh
```

This will:
- Apply the updated ConfigMap
- Restart the notifications controller
- Wait for the rollout to complete
