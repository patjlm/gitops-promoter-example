# Complete Requirements for Reliable App-of-Apps Status Reporting

This document describes all requirements needed to make a parent ArgoCD Application (app-of-apps) accurately report the overall status of all children apps across all commits.

## Problem Statement

The goal is for a root Application (app-of-apps) to accurately report the overall status of all children Applications after the root app's revision changes.

Children may:
- Follow the same branch/revision as the root app
- Follow different branches or commits
- Follow completely different repositories
- Need to sync when root changes, or stay as-is

The root app should wait long enough for:
1. Children to sync if their sources changed
2. Health checks to run and stabilize
3. Then report the accurate aggregate status

By default, ArgoCD app-of-apps patterns have issues:
1. Parent reports success before children have synced (if needed)
2. Notifications fire multiple times for the same state
3. Health changes after sync (Progressing → Healthy) don't trigger notifications
4. Same revision synced multiple times (retries) only notifies once

This guide solves all these issues.

---

## 1. ArgoCD Configuration (`argocd/argocd-cm.yaml`)

### 1.1 Reconciliation Period

```yaml
timeout.reconciliation: "30s"
```

**Purpose**: Sets how often ArgoCD checks for changes  
**Critical**: Stabilization delay must be 2× this value  
**Effect**: Faster reconciliation = quicker detection of changes

### 1.2 Custom Health Check for Applications

```yaml
resource.customizations.health.argoproj.io_Application: |
  hs = {}
  hs.status = "Progressing"
  hs.message = ""
  if obj.status ~= nil then
    if obj.status.health ~= nil then
      hs.status = obj.status.health.status
      if obj.status.health.message ~= nil then
        hs.message = obj.status.health.message
      end
    end
  end
  return hs
```

**Purpose**: Makes parent apps reflect child Application health status  
**Why needed**: ArgoCD removed this in v1.8; without it, parent app health doesn't aggregate child app health  
**Effect**: When a child app is unhealthy/progressing, the parent becomes unhealthy/progressing

---

## 2. Notification Configuration (`argocd/notifications-cm.yaml`)

### 2.1 Three Consolidated Triggers

ArgoCD notifications need to track three distinct state transitions:
1. Pending states (sync running OR health progressing)
2. Success states (sync succeeded AND health healthy AND stabilization delay passed)
3. Failure states (sync failed OR health degraded)

#### a. `on-pending` - Detects in-progress states

```yaml
trigger.on-pending: |
  # Fires when sync operation is running
  - when: app.status.operationState != nil and app.status.operationState.phase in ['Running']
    oncePer: app.status.sync.revision + "-" + app.status.operationState?.startedAt
    send: [github-status-pending]
  # Fires when health becomes Progressing
  - when: app.status.health.status == 'Progressing'
    oncePer: app.status.sync.revision + "-health-" + app.status.health.lastTransitionTime
    send: [github-status-pending]
```

**Multiple `when` conditions**: Each trigger can have multiple conditions with their own `oncePer` keys  
**First condition**: Catches active sync operations  
**Second condition**: Catches health changes - **critical for parent apps** waiting for children  
**Why needed**: Parent health goes to Progressing when children are syncing

#### b. `on-deployed` - Success with stabilization delay

```yaml
trigger.on-deployed: |
  - when: app.status.operationState != nil and app.status.operationState.phase in ['Succeeded'] and app.status.health.status == 'Healthy' and (time.Parse(app.status.health.lastTransitionTime) >= time.Parse(app.status.operationState.startedAt)) and (time.Now().Sub(time.Parse(app.status.health.lastTransitionTime)).Seconds() >= 60)
    oncePer: app.status.sync.revision + "-" + app.status.operationState?.finishedAt
    send: [github-status-success]
```

**60s stabilization delay**: 2× reconciliation period (30s × 2)  
**Why needed**: Gives children time to auto-sync after parent syncs  
**Measured from**: `health.lastTransitionTime` (updates when children change and affect parent health)  
**Critical**: Without this delay, parent reports success immediately after its own sync, before children catch up

**Timing flow**:
```
Parent sync finishes (t=0) → 
Children detect change (t=0-30s) → 
Children sync (t=30s) → 
Children become healthy (t=45s) → 
Parent health updates to Healthy (t=45s) → 
60s delay from t=45s → 
Notification fires (t=105s)
```

#### c. `on-failed` - Failure detection

```yaml
trigger.on-failed: |
  # Fires when sync operation fails
  - when: app.status.operationState != nil and app.status.operationState.phase in ['Error', 'Failed']
    oncePer: app.status.sync.revision + "-" + app.status.operationState?.finishedAt
    send: [github-status-failure]
  # Fires when health becomes Degraded
  - when: app.status.health.status == 'Degraded'
    oncePer: app.status.sync.revision + "-health-" + app.status.health.lastTransitionTime
    send: [github-status-failure]
```

**Multiple conditions**: Catches both sync failures AND health degradation  
**Why needed**: Apps can succeed sync but then degrade (common in real deployments)

### 2.2 Status Message Templates

```yaml
template.github-status-success: |
  message: |
    Phase: {{.app.status.operationState.phase}} | Sync: {{.app.status.sync.status}} | Health: {{.app.status.health.status}} ({{.app.status.health.lastTransitionTime}})
  github:
    repoURLPath: "{{.app.spec.source.repoURL}}"
    revisionPath: "{{.app.status.sync.revision}}"
    status:
      state: success
      label: "ArgoCD/{{.app.metadata.name}}"
      targetURL: "https://argocd.example.com/applications/{{.app.metadata.name}}"
```

**Show all three status domains**: phase, sync, health  
**Include health timestamp**: Shows when app actually became healthy (vs when notification sent after delay)  
**Use `sync.revision`**: Not `syncResult.revision` - reports the commit being compared against

Apply similar patterns to `github-status-pending` and `github-status-failure` templates.

---

## 3. oncePer Key Design Principles

The `oncePer` key is a **consumed lock**: once ArgoCD sends a notification for a given key, it will never re-send for that exact key. Choosing the right key is critical.

### 3.1 Use `sync.revision` not `syncResult.revision`

```yaml
oncePer: app.status.sync.revision + "-" + ...  # CORRECT
oncePer: app.status.operationState.syncResult.revision + "-" + ...  # WRONG
```

**Why**: 
- `sync.revision`: The revision **being compared to right now** (updates on every reconciliation)
- `syncResult.revision`: The revision of the last **actual sync operation**

**Effect**: Using `sync.revision` triggers fire for every commit ArgoCD sees, even if no actual sync occurred  
**Matches**: What's reported to GitHub via `revisionPath` in templates

### 3.2 Include Timestamps to Handle Oscillation

```yaml
# For operation-based triggers:
oncePer: app.status.sync.revision + "-" + app.status.operationState?.finishedAt

# For health-based triggers:
oncePer: app.status.sync.revision + "-health-" + app.status.health.lastTransitionTime
```

**Why**: Same revision can be synced multiple times (retries, health oscillation)  
**Without timestamp**: Second sync of same revision is silently dropped  
**With timestamp**: Each distinct operation/health change fires a notification

**Example**: 
- Revision `abc123` syncs successfully at 10:00 → finishedAt=10:00 → notification sent
- Health degrades, auto-sync retries `abc123` at 10:05 → finishedAt=10:05 → **new notification sent**
- Without finishedAt in key, the retry would be silently dropped

### 3.3 Use Safe Navigation Operator (`?.`)

```yaml
oncePer: app.status.operationState?.finishedAt  # CORRECT
oncePer: app.status.operationState.finishedAt   # WRONG - causes null pointer errors
```

**Why**: ArgoCD expression evaluator attempts to parse field accesses even when `when` condition checks for nil  
**Without `?.`**: Null pointer errors when operationState is nil  
**With `?.`**: Safe evaluation, returns empty string if field doesn't exist

---

## 4. Stabilization Delay is Sufficient

**Key insight**: The 60s stabilization delay (2× reconciliation period) is sufficient to ensure accurate status reporting. You do NOT need to force children to sync on every commit.

### 4.1 How It Works

When the root app's revision changes:

1. **Root app syncs** (t=0s)
2. **Wait 60s for stabilization**
3. **During the 60s window**:
   - If children's sources changed → they auto-sync (within 30s reconciliation period)
   - If children's sources didn't change → they stay as-is (already healthy)
   - Health checks run and stabilize
4. **After 60s** → root app reports accurate aggregate status

### 4.2 Children Can Follow Any Source

Children are not required to sync on every root app commit. They can:
- Follow the same repository/branch as root
- Follow different branches or specific commits
- Follow completely different repositories
- Use any combination of the above

The root app waits long enough (60s) for whatever needs to happen to happen, then reports the true status.

### 4.3 Optional: Force Sync for Testing/Demos

In this example repository, `test-app-2` uses a Helm parameter to force a new deployment on every commit:

```yaml
# argocd/apps/test-app-2.yaml - EXAMPLE ONLY, NOT REQUIRED
spec:
  source:
    path: app2
    helm:
      parameters:
        - name: revision
          value: $ARGOCD_APP_REVISION_SHORT
```

**Purpose**: Demonstrates health transitions (Progressing → Healthy) on every commit for testing  
**Production**: Not needed - children sync only when their sources actually change  
**Effect**: Creates new Deployment with revision-based name on each commit

### 4.4 App-of-Apps Directory Structure

```yaml
# argocd/apps/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - test-app.yaml
  - test-app-2.yaml

# argocd/app-of-apps.yaml
spec:
  source:
    path: argocd/apps
```

**Purpose**: Shows bundling of child Applications using Kustomize  
**Not needed**: The `kustomization.yaml` file itself (could just use directory with `directory: {}`)  
**Benefit**: Makes it explicit which Applications are part of the app-of-apps

---

## 5. Auto-Sync Policy on All Apps

```yaml
spec:
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Why needed**: Children must auto-sync when parent updates their manifests  
**Must apply to**: Parent AND all children  
**Without it**: Manual sync required, status never updates automatically

---

## 6. Application Annotations (Subscribe to Triggers)

```yaml
metadata:
  annotations:
    notifications.argoproj.io/subscribe.on-pending.github: ""
    notifications.argoproj.io/subscribe.on-deployed.github: ""
    notifications.argoproj.io/subscribe.on-failed.github: ""
```

**Must match trigger names**: Use the exact trigger names defined in notifications-cm  
**Apply to**: All apps (parent and children)  
**Effect**: Apps subscribe to triggers; notifications only sent for subscribed apps

---

## 7. Understanding ArgoCD's Three Status Domains

ArgoCD Application status has three **orthogonal** dimensions that update independently:

### 7.1 `status.sync` - Git Comparison Result

**What**: Result of comparing desired state (Git) against actual state (cluster)  
**Values**: `Synced`, `OutOfSync`, `Unknown`  
**Updates**: Every reconciliation cycle (every 30s)  
**Key fields**:
- `sync.status`: Current sync status
- `sync.revision`: The revision **being compared to right now**

### 7.2 `status.health` - Aggregated Cluster Health

**What**: Worst health status among all managed resources  
**Values**: `Healthy`, `Progressing`, `Degraded`, `Missing`, `Suspended`, `Unknown`  
**Updates**: Every reconciliation cycle  
**Key fields**:
- `health.status`: Current health status
- `health.lastTransitionTime`: When status **CHANGED** (not just checked)

**Critical for parent apps**: With custom health check, parent health = worst child health

### 7.3 `status.operationState` - Sync Operation Lifecycle

**What**: Full lifecycle of the last/current sync operation  
**Phase values**: `Running`, `Succeeded`, `Failed`, `Error`, `Terminating`  
**Updates**: Only when sync operation occurs (not every reconciliation)  
**Key fields**:
- `operationState.phase`: Current operation phase
- `operationState.startedAt`: When sync started (always set)
- `operationState.finishedAt`: When sync completed (nil while Running)
- `operationState.syncResult.revision`: What was actually synced

**Important distinction**:
- `sync.revision`: What's being compared against now (updates every reconciliation)
- `operationState.syncResult.revision`: What was last successfully synced (only updates on sync)

---

## 8. Timing Relationships

### 8.1 Reconciliation Period → Stabilization Delay

```
reconciliation period = 30s
stabilization delay = 60s (2× reconciliation period)
```

**Why 2×**: Ensures at least 2 reconciliation cycles pass before notification  
**Effect**: Children have time to auto-sync and report health  
**Formula**: `delay = 2 × timeout.reconciliation`

### 8.2 Complete Event Timeline

```
t=0s    Parent sync completes
        └─ Parent health: Healthy → Progressing (children not synced yet)
        └─ Notification: pending (health progressing)

t=0-30s Children detect their manifests changed in cluster

t=30s   Children start syncing
        └─ Child notifications: pending (sync running)

t=45s   Children sync completes
        └─ Children health: Progressing → Healthy

t=50s   Parent detects children healthy
        └─ Parent health: Progressing → Healthy
        └─ Parent health.lastTransitionTime = t=50s

t=110s  60s delay from health transition (t=50s + 60s)
        └─ Parent notification: success (with health timestamp showing t=50s)
```

**Key insight**: Success notification timestamp shows when app became healthy (t=50s), not when notification sent (t=110s)

---

## 9. Edge Cases Handled

### 9.1 Health Timestamp Before Operation Start

**Scenario**: App was already healthy, manifests didn't change  
**Trigger condition**: `health.lastTransitionTime >= operationState.startedAt`  
**Result**: Condition fails, no notification sent  
**Production impact**: Not a concern for parent apps (they always change when children update via revision injection)

### 9.2 Same Revision, Multiple Syncs

**Scenario**: Auto-sync retries same commit (health degraded, then auto-healed)  
**Without finishedAt in oncePer**: Second sync of revision silently dropped  
**With finishedAt**: Each sync fires notification with unique `finishedAt` timestamp

### 9.3 Children Syncing at Different Times

**Scenario**: test-app-2 syncs at t=30s, test-app syncs at t=60s  
**Without delay**: Parent reports success when first child syncs (incomplete state)  
**With 60s delay**: Parent waits for all children to settle before reporting success

### 9.4 Health Oscillation Without Sync

**Scenario**: Child goes Healthy → Degraded → Healthy without parent syncing  
**Trigger**: Health-based oncePer key captures each transition  
**Effect**: Pending → Failure → Success notifications, all on same sync.revision

---

## 10. Required Files Summary

| File | Purpose | Key Settings |
|------|---------|--------------|
| `argocd/argocd-cm.yaml` | Health check & reconciliation | Custom Application health script, 30s reconciliation |
| `argocd/notifications-cm.yaml` | Triggers & templates | 3 triggers with multiple conditions, 60s delay, proper oncePer keys |
| `argocd/app-of-apps.yaml` | Parent app | Auto-sync, kustomize with revision annotation |
| `argocd/apps/kustomization.yaml` | Kustomize for children | Lists child Application manifests |
| `argocd/apps/test-app.yaml` | Child app | Auto-sync, kustomize with revision annotation, trigger subscriptions |
| `argocd/apps/test-app-2.yaml` | Child app | Auto-sync, helm with revision parameter, trigger subscriptions |

---

## 11. Verification Checklist

### Configuration Files
- [ ] `timeout.reconciliation: "30s"` set in argocd-cm
- [ ] Custom health check for Applications in argocd-cm
- [ ] Three triggers defined (on-pending, on-deployed, on-failed)
- [ ] Each trigger has multiple `when` conditions
- [ ] on-deployed has 60s delay (2× reconciliation period)

### oncePer Keys
- [ ] All oncePer keys use `sync.revision` not `syncResult.revision`
- [ ] All oncePer keys include timestamps (finishedAt or lastTransitionTime)
- [ ] Safe navigation operator (`?.`) used in all oncePer expressions

### Child App Configuration
- [ ] All children have auto-sync enabled
- [ ] Children can follow any source (same repo, different branch, different repo)
- [ ] Optional: Revision injection for testing (forces sync on every commit)

### Sync & Subscription
- [ ] All apps have auto-sync enabled
- [ ] All apps subscribe to all three triggers
- [ ] Subscription annotations match trigger names exactly

### Templates
- [ ] Status templates show all three domains (phase, sync, health)
- [ ] Success template includes health.lastTransitionTime
- [ ] All templates use sync.revision not syncResult.revision

---

## 12. Common Pitfalls to Avoid

| Pitfall | Effect | Solution |
|---------|--------|----------|
| Using `syncResult.revision` in oncePer | Won't fire for commits without manifest changes | Use `sync.revision` |
| No timestamp in oncePer | Duplicate syncs of same revision silently dropped | Add `finishedAt` or `lastTransitionTime` |
| Using `.` instead of `?.` | Null pointer errors in expression evaluator | Use safe navigation `?.` |
| No stabilization delay | Parent reports success before children sync (if needed) | Add 60s delay (2× reconciliation period) |
| Delay from wrong timestamp | Missing health state changes | Use `lastTransitionTime` not `finishedAt` |
| Delay too short | Children don't have time to sync and report health | Use 2× reconciliation period (60s for 30s reconciliation) |
| Missing health check | Parent health doesn't reflect children | Add custom health script to argocd-cm |
| Wrong reconciliation period | Inconsistent timing, delay doesn't match | Set to 30s, delay to 60s |
| Trigger name mismatch | Apps don't receive notifications | Match annotation names to trigger names exactly |

---

## 13. How It All Works Together

### Scenario: Commit Changes Child App Sources

1. **Commit pushed** to repository (changes affect child sources)
2. **Parent detects change** (reconciliation cycle, every 30s)
3. **Parent syncs** (if parent manifests changed)
   - Parent notification: **pending** (sync running, if triggered)
4. **Parent health changes** to Progressing (children need to sync)
   - Parent notification: **pending** (health progressing)
5. **Children detect change** (within 30s reconciliation period)
6. **Children sync** (their sources changed)
   - Children notifications: **pending** (sync running)
7. **Children become healthy**
   - Children notifications: **success** (after 60s delay)
8. **Parent health updates** to Healthy (aggregates children health)
   - Parent `health.lastTransitionTime` set to current time
9. **60s delay passes** from parent health transition
10. **Parent notification**: **success** (with timestamp showing when health became healthy)

### Scenario: Commit Does NOT Change Child App Sources

1. **Commit pushed** to repository (e.g., only README changed)
2. **Children don't need to sync** (their sources unchanged)
3. **Children stay healthy** (no change)
4. **Parent stays/becomes healthy** (children already healthy)
5. **60s delay passes** from when parent became healthy
6. **Parent notification**: **success**

This ensures the parent accurately reports overall status after waiting long enough for any necessary syncs and health checks to complete.
