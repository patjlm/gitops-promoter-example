# ArgoCD Notifications Strategy

This repository demonstrates ArgoCD notifications with full sync lifecycle tracking.

## ArgoCD Notifications (Reactive Approach)

**When it fires**: When an app sync operation starts, succeeds, or fails

**Lifecycle stages**:
1. **on-sync-running**: Posts "pending" status when sync starts
2. **on-sync-succeeded**: Posts "success" status when sync completes
3. **on-sync-failed**: Posts "failure" status if sync fails

**Configured in**: `argocd/notifications-cm.yaml`

**What it sends**:
- Per-app commit status: `ArgoCD/test-app`, `ArgoCD/test-app-2`
- Per-app check run: `ArgoCD / test-app`, `ArgoCD / test-app-2`
- Aggregate status: `ArgoCD/all-apps` (app-of-apps pattern)
- Aggregate check: `ArgoCD / All Applications`
- Deployments: GitHub Deployments API

**Pros**:
- Native ArgoCD integration
- Rich notification content (uses app metadata)
- No external dependencies

**Cons**:
- Only fires when an app syncs
- Commits that don't affect any app manifests won't trigger notifications
- Can't report "no changes needed"

## Alternative: Proactive Status Reporting

If you need status on EVERY commit regardless of manifest changes:

**When it fires**: On EVERY commit to the branch

**Configured in**: `.github/workflows/argocd-status.yaml`

**What it sends**:
- Commit status for ALL apps on EVERY commit
- Reports status even if manifests didn't change
- Can query ArgoCD API to get actual sync state

**Pros**:
- Fires on every commit
- Can report "already synced" or "no changes needed"
- Consistent status on all commits

**Cons**:
- Requires GitHub Actions
- Needs access to ArgoCD API (or cluster)
- Less real-time than reactive notifications

## Current Implementation

This repository uses the **reactive ArgoCD approach only**:

- **Per-app notifications**: Each app sends pending → success/failure as it syncs
- **Aggregate notifications**: App-of-apps sends aggregate status for all children
- **Full lifecycle**: GitHub shows pending while syncing, then flips to success/failure

### What You'll See on GitHub

For a commit that changes `app/configmap.yaml`:

**Reactive (ArgoCD)**:
- `ArgoCD/test-app` → success (manifest changed, app synced)
- `ArgoCD/test-app-2` → success (uses same base, app synced)
- `ArgoCD/all-apps` → success (all children synced)

**Proactive (GitHub Actions)**:
- `ArgoCD/all-apps-proactive` → success (queried all apps)

For a commit that only changes `README.md`:

**Reactive (ArgoCD)**:
- *(nothing - no apps synced)*

**Proactive (GitHub Actions)**:
- `ArgoCD/test-app` → success (already synced, no change needed)
- `ArgoCD/test-app-2` → success (already synced, no change needed)
- `ArgoCD/all-apps-proactive` → success (all apps healthy)

## Implementation Notes

### For Production

The GitHub Actions workflow needs to:

1. **Authenticate to ArgoCD**:
   ```bash
   argocd login $ARGOCD_SERVER --grpc-web --auth-token $ARGOCD_TOKEN
   ```

2. **Query app status**:
   ```bash
   argocd app get test-app -o json | jq -r '.status.sync.status'
   ```

3. **Check if synced to this commit**:
   ```bash
   REVISION=$(argocd app get test-app -o json | jq -r '.status.sync.revision')
   if [[ "$REVISION" == "$GITHUB_SHA" ]]; then
     echo "Synced to this commit"
   fi
   ```

4. **Post status via GitHub API**:
   ```bash
   gh api repos/$REPO/statuses/$SHA \
     -f state=success \
     -f context="ArgoCD/test-app" \
     -f description="Synced to $SHA"
   ```

### Alternative: Webhook-Based Proactive Reporting

Instead of GitHub Actions, you could run a service that:
- Watches for new commits (GitHub webhooks)
- Queries ArgoCD for all apps
- Posts statuses for all apps to that commit

This is closer to how gitops-promoter works.

## For GCP-840

Consider which approach fits your requirements:

1. **Reactive only**: Simple, native ArgoCD, but gaps on commits with no changes
2. **Proactive only**: Every commit gets status, but need to build the reporting service
3. **Hybrid**: Best of both worlds, more complex setup

The app-of-apps pattern shown here provides good aggregate status in the reactive approach.
