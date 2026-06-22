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

- `app/` — Kustomize application deploying a dummy ConfigMap
- `argocd/` — ArgoCD Application and notifications configuration
- `setup/` — Local kind cluster setup scripts

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
4. Notifications controller posts commit status and deployment to GitHub
5. Verify on GitHub: commit status and deployment shows in the UI
