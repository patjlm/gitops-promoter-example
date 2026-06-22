# Testing ArgoCD Notifications with GitHub App

This guide walks through testing different ArgoCD notification configurations for GCP-840.

## Prerequisites

1. Download the GitHub App private key:
   - Go to: https://github.com/settings/apps/argocd-notifications-gop-example
   - Generate and download a new private key
   - Default expected location: `~/argocd-notifications-gop-example.2026-06-22.private-key.pem`
   - Or update `GITHUB_APP_PRIVATE_KEY_PATH` in `setup/config.local.env`

2. Install required tools:
   - `kind` (Kubernetes in Docker)
   - `kubectl`

## Initial Setup

```bash
cd setup

# Create local config with GitHub App credentials
cp config.env config.local.env
# Edit config.local.env to verify paths are correct

# Create kind cluster and install ArgoCD
./setup.sh
```

## Test Scenarios

### Test 1: Commit Status on Sync

1. Make a change to `app/configmap.yaml`
2. Commit and push to this branch
3. Check GitHub for commit status:
   - Navigate to: https://github.com/patjlm/gitops-promoter-example/commits/argocd-notifications-example
   - Verify commit status shows "ArgoCD/sync" context
   - Shows as a simple checkmark/X in the commit list

### Test 2: GitHub Check Run

1. After the same sync, check GitHub Checks:
   - Navigate to the commit on GitHub
   - Click on the "Checks" tab
   - Verify "ArgoCD Sync Check" appears with rich details:
     - Summary with app name, sync status, health status, revision
     - Title shows sync status
     - Link to ArgoCD UI
   - Check Runs display differently than commit statuses - they show in the Checks tab with formatted markdown content

### Test 3: Deployment Creation

1. After sync completes, check GitHub deployments:
   - Navigate to: https://github.com/patjlm/gitops-promoter-example/deployments
   - Verify new deployment appears for the "default" environment

### Comparison: Commit Status vs Check Run

Both will be created on sync, allowing you to compare:

| Feature | Commit Status | Check Run |
|---------|--------------|-----------|
| Display | Simple label in commit list | Rich UI in Checks tab |
| Content | State + label only | Title, summary, markdown formatting |
| Context | `ArgoCD/sync` | `ArgoCD Sync Check` |
| Details | Just a link | Full markdown with multiple fields |
| API | Older statuses API | Modern checks API |

### Test 4: Different Notification Templates

Modify `argocd/notifications-cm.yaml` to test different notification formats:

- Commit status with different states (pending, success, failure)
- Check run with different conclusions (success, failure, neutral, cancelled)
- Deployment with different environments
- Custom labels and descriptions

After modifying the ConfigMap, apply changes:
```bash
cd setup
./update-notifications.sh
```

### Test 5: Trigger Conditions

Test different trigger conditions in `argocd/notifications-cm.yaml`:

- `app.status.sync.status == 'Synced'` - On successful sync
- `app.status.operationState.phase == 'Succeeded'` - On successful operation
- `app.status.health.status == 'Healthy'` - On healthy app

After modifying triggers, run `./update-notifications.sh` to apply changes.

## Debugging

Check notifications controller logs:
```bash
./status.sh
```

Or directly:
```bash
kubectl logs -n argocd deployment/argocd-notifications-controller -f
```

Check ArgoCD Application status:
```bash
kubectl get application test-app -n argocd -o yaml
```

Verify secret is properly created:
```bash
kubectl get secret argocd-notifications-secret -n argocd -o yaml
```

## Cleanup

```bash
./teardown.sh
```

## Configuration Reference

### GitHub Service (in notifications-cm.yaml)

```yaml
service.github: |
  appID: $github-app-id
  installationID: $github-installation-id
  privateKey: $github-app-private-key
```

### Commit Status Template

```yaml
template.github-commit-status: |
  message: |
    Application {{.app.metadata.name}} sync {{.app.status.sync.status}}
  github:
    status:
      state: "success"  # or "pending", "failure", "error"
      label: "ArgoCD/sync"  # Shows as context in GitHub UI
      targetURL: "https://argocd.example.com/applications/{{.app.metadata.name}}"
```

### Check Run Template

```yaml
template.github-check-run: |
  message: |
    ArgoCD sync check for {{.app.metadata.name}}
  github:
    repoURLPath: "{{.app.spec.source.repoURL}}"
    revisionPath: "{{.app.status.sync.revision}}"
    checkRun:
      name: "ArgoCD Sync Check"  # Shows as check name in Checks tab
      conclusion: "success"  # or "failure", "neutral", "cancelled", "skipped", "timed_out", "action_required"
      title: "Sync Status: {{.app.status.sync.status}}"
      summary: |
        Markdown-formatted summary with details
      detailsURL: "https://argocd.example.com/applications/{{.app.metadata.name}}"
```

### Deployment Template

```yaml
template.github-deployment: |
  message: |
    Deployment of {{.app.metadata.name}}
  github:
    deployment:
      state: "success"
      environment: "{{.app.spec.destination.namespace}}"
      reference: "{{.app.status.sync.revision}}"
```

## Links

- Jira Issue: [GCP-840](https://redhat.atlassian.net/browse/GCP-840)
- ArgoCD Notifications Docs: https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/
- GitHub App: https://github.com/settings/apps/argocd-notifications-gop-example
