# ArgoCD Application Status: Complete Reference

This document describes the three orthogonal status domains on an ArgoCD `Application` resource, when each field is updated, all relevant timestamps, and how to derive a comprehensive set of global application states from them.

Sources:
- [`pkg/apis/application/v1alpha1/types.go`](https://github.com/argoproj/argo-cd/blob/master/pkg/apis/application/v1alpha1/types.go) — all Application types and enums
- [`controller/appcontroller.go`](https://github.com/argoproj/argo-cd/blob/master/controller/appcontroller.go) — reconciliation and operation lifecycle
- [`gitops-engine/pkg/health/health.go`](https://github.com/argoproj/argo-cd/blob/master/gitops-engine/pkg/health/health.go) — `HealthStatusCode` values and ordering
- [`gitops-engine/pkg/sync/common/types.go`](https://github.com/argoproj/argo-cd/blob/master/gitops-engine/pkg/sync/common/types.go) — `OperationPhase` values and helper methods
- [`notifications_catalog/triggers/`](https://github.com/argoproj/argo-cd/tree/master/notifications_catalog/triggers) — built-in trigger definitions
- [Notifications docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/) — official operator documentation

---

## The Three Status Domains

`Application.status` tracks three orthogonal dimensions simultaneously. They are updated independently at different points in the reconciliation loop.

---

## 1. `status.sync` — Git Comparison Result

**What it is:** The result of comparing the desired state (from Git/Helm) against the live state in the cluster. Updated on **every reconciliation cycle** (typically every 3 minutes, or immediately after a change).

Struct: [`SyncStatus`](https://github.com/argoproj/argo-cd/blob/master/pkg/apis/application/v1alpha1/types.go#L1942)

```yaml
status:
  sync:
    status: "Synced" | "OutOfSync" | "Unknown"
    revision: "<git SHA or helm chart version>"   # single-source
    revisions: ["sha1", "sha2"]                   # multi-source
    comparedTo:
      source: {...}           # what git source was compared
      destination: {...}      # what cluster/namespace was compared
      ignoreDifferences: [...] # fields excluded from diff
```

### SyncStatusCode values

Defined in [`types.go#L1879-L1890`](https://github.com/argoproj/argo-cd/blob/master/pkg/apis/application/v1alpha1/types.go#L1879).

| Value | Meaning |
|-------|---------|
| `Unknown` | Comparison could not be performed (git unreachable, spec invalid) |
| `Synced` | Live state matches desired state exactly (or within `ignoreDifferences`) |
| `OutOfSync` | Drift detected between Git and cluster |

### Key distinction: `sync.revision` vs `history[].revision`

- `sync.revision`: The revision **being compared to right now** — not the last successfully deployed revision.
- `history[last].revision`: The revision of the last *successful* sync operation.

### `status.reconciledAt`

Set to `now()` after each comparison that fetched the latest Git version. This is your "last time we checked Git" timestamp. Use `now() - reconciledAt` to detect stale status.

---

## 2. `status.health` — Aggregated Cluster Health

**What it is:** The worst health status among all managed resources. Updated on every reconciliation cycle after resources are inspected.

Struct: [`AppHealthStatus`](https://github.com/argoproj/argo-cd/blob/master/pkg/apis/application/v1alpha1/types.go#L1954)

```yaml
status:
  health:
    status: "Healthy" | "Progressing" | "Degraded" | "Missing" | "Suspended" | "Unknown"
    lastTransitionTime: "2024-01-15T10:30:00Z"  # when status CHANGED (not just refreshed)
```

### HealthStatusCode values

Defined in [`gitops-engine/pkg/health/health.go#L14-L30`](https://github.com/argoproj/argo-cd/blob/master/gitops-engine/pkg/health/health.go#L14).

| Value | Meaning |
|-------|---------|
| `Healthy` | All resources fully operational |
| `Progressing` | Resources exist but not yet ready (e.g., Deployment rolling out) |
| `Suspended` | Resources paused (e.g., CronJob with `suspend: true`) |
| `Missing` | Resource does not exist in cluster |
| `Degraded` | Resource in failure state (e.g., CrashLoopBackOff, failed Job) |
| `Unknown` | Health could not be assessed (no health check defined, or check errored) |

### Health ordering (best → worst)

```
Healthy > Suspended > Progressing > Missing > Degraded > Unknown
```

The application-level health is the **worst** among all resources ([`IsWorse()`](https://github.com/argoproj/argo-cd/blob/master/gitops-engine/pkg/health/health.go#L55) in `gitops-engine/pkg/health/health.go`).

### `health.lastTransitionTime`

Set **only when the health status code changes**, not on every reconciliation. This makes it precise for duration calculations — it marks the exact moment health transitioned to its current value (e.g., exactly when the app became `Healthy` after a deploy).

> **Note:** `health.message` is deprecated; per-resource messages are in `status.resources[].health.message`.

---

## 3. `status.operationState` — Active / Last Sync Operation

**What it is:** Present only when a sync has been triggered (manually or via auto-sync). Contains the full lifecycle of the operation. `nil` if no sync has ever been performed.

Struct: [`OperationState`](https://github.com/argoproj/argo-cd/blob/master/pkg/apis/application/v1alpha1/types.go#L1451)

```yaml
status:
  operationState:
    phase: "Running" | "Terminating" | "Succeeded" | "Failed" | "Error"
    message: "successfully synced"        # human-readable status or error
    startedAt: "2024-01-15T10:00:00Z"    # always set, never nil
    finishedAt: "2024-01-15T10:02:30Z"   # nil while Running or Terminating
    retryCount: 0
    operation:
      sync:
        revision: "HEAD"        # what was requested (may be branch name)
        revisions: [...]
    syncResult:                  # populated when phase is terminal
      revision: "abc123def456"  # resolved SHA actually applied
      revisions: [...]
      resources: [...]          # per-resource sync results
      source: {...}
      sources: [...]
```

### OperationPhase values

Defined in [`gitops-engine/pkg/sync/common/types.go#L74-L101`](https://github.com/argoproj/argo-cd/blob/master/gitops-engine/pkg/sync/common/types.go#L74).

| Value | Meaning | `finishedAt` |
|-------|---------|--------------|
| `Running` | Sync in progress | `nil` |
| `Terminating` | User aborted, waiting for cleanup | `nil` |
| `Succeeded` | Sync completed without errors | set |
| `Failed` | Sync failed (may retry) | set (cleared on retry) |
| `Error` | Unrecoverable sync error | set |

### Phase transition diagram

```
(nil) ──trigger──► Running ──────────────► Succeeded
                      │
                      ├── abort ──────────► Terminating ──► Failed
                      │
                      ├── failure (retry) ─► Failed ──► Running (retryCount++)
                      │
                      └── failure (final) ─► Failed
                                           └── unrecoverable ─► Error
```

### When `finishedAt` is set

[`setOperationState()`](https://github.com/argoproj/argo-cd/blob/master/controller/appcontroller.go#L1621) in `controller/appcontroller.go` automatically sets `finishedAt = now()` the moment [`phase.Completed()`](https://github.com/argoproj/argo-cd/blob/master/gitops-engine/pkg/sync/common/types.go#L84) returns true (i.e., `Succeeded`, `Failed`, or `Error`). On retry, `finishedAt` is explicitly cleared back to `nil`.

### `operation.sync.revision` vs `syncResult.revision`

- `operation.sync.revision`: What was *requested* (e.g., `"HEAD"` or a branch name like `"main"`)
- `syncResult.revision`: The *resolved* SHA that was actually applied — use this as the canonical revision identifier for deduplication (`oncePer` in notifications)

---

## 4. `status.history` — Sync History Log

Struct: [`RevisionHistory`](https://github.com/argoproj/argo-cd/blob/master/pkg/apis/application/v1alpha1/types.go#L1833)

```yaml
status:
  history:
    - id: 42
      revision: "abc123"
      revisions: []
      deployStartedAt: "2024-01-15T10:00:00Z"   # mirrors operationState.startedAt
      deployedAt: "2024-01-15T10:02:30Z"          # mirrors operationState.finishedAt
      initiatedBy:
        username: "admin"    # or "automated" for auto-sync
        automated: false
      source: {...}
      sources: [...]
```

A new entry is appended **only when a sync succeeds** (`phase=Succeeded`). Failed syncs do not appear here.

`history[last].deployedAt` = "last successful sync completion time".

---

## Timestamp Reference for Duration Calculations

| Duration | Formula |
|---------|---------|
| Sync operation duration | `operationState.finishedAt − operationState.startedAt` |
| Time since last sync finished | `now() − operationState.finishedAt` |
| Time from sync completion to health change | `health.lastTransitionTime − operationState.finishedAt` |
| Total time from sync start to healthy | `health.lastTransitionTime − operationState.startedAt` |
| Time since last *successful* sync | `now() − history[last].deployedAt` |
| Age of last Git check | `now() − reconciledAt` |

---

## Global Application States

These are the distinct observable states derivable by combining the three dimensions. They go well beyond what the built-in notification triggers cover.

### Operational States (based on `operationState.phase`)

| State | Condition |
|-------|-----------|
| No operation | `operationState == nil` |
| Sync running | `operationState.phase == "Running"` |
| Sync terminating | `operationState.phase == "Terminating"` |
| Sync succeeded | `operationState.phase == "Succeeded"` |
| Sync failed | `operationState.phase == "Failed"` |
| Sync error | `operationState.phase == "Error"` |
| Sync retrying | `operationState.phase == "Running" && operationState.retryCount > 0` |

### Combined States (operation + health + sync)

| State Name | Conditions | Notes |
|------------|-----------|-------|
| **Deployed & Healthy** | `operationState.phase == "Succeeded"` AND `health.status == "Healthy"` AND `health.lastTransitionTime` within sync window | The `on-deployed` trigger targets this |
| **Synced, Waiting for Health** | `operationState.phase == "Succeeded"` AND `health.status in ["Progressing", "Unknown"]` | Sync done, resources still rolling out |
| **Synced but Degraded** | `operationState.phase == "Succeeded"` AND `health.status == "Degraded"` | Sync succeeded but app is broken |
| **Synced but Missing** | `operationState.phase == "Succeeded"` AND `health.status == "Missing"` | Resources not found post-sync |
| **Out of Sync, Idle** | `sync.status == "OutOfSync"` AND (`operationState == nil` OR `operationState.phase.Completed()`) | Drift detected, no sync in flight |
| **Out of Sync, Syncing** | `sync.status == "OutOfSync"` AND `operationState.phase == "Running"` | Sync catching up to drift |
| **Unknown Sync** | `sync.status == "Unknown"` | Git unreachable or invalid spec |
| **Degraded, No Recent Sync** | `health.status == "Degraded"` AND `operationState.phase.Completed()` | App broke after a previously successful sync |
| **Stuck Progressing** | `health.status == "Progressing"` AND `now() − operationState.finishedAt > threshold` | Rollout taking too long |

### Pending / Success / Failure Classification

```
PENDING =
  operationState != nil && operationState.phase == "Running"
  operationState != nil && operationState.phase == "Terminating"

SUCCESS =
  operationState.phase == "Succeeded" && health.status == "Healthy"
  # Use health.lastTransitionTime >= operationState.startedAt to confirm
  # health became Healthy AFTER this sync, not a pre-existing stale status

SYNC_OK_HEALTH_PENDING =
  operationState.phase == "Succeeded"
  && health.status in ["Progressing", "Unknown", "Missing", "Suspended"]

FAILURE =
  operationState.phase in ["Failed", "Error"]
  operationState.phase == "Succeeded" && health.status == "Degraded"
  # Post-sync degradation — not captured by any built-in trigger
```

---

## Built-in Notification Triggers

For reference, these are the 8 built-in triggers and their exact conditions. Source: [`notifications_catalog/triggers/`](https://github.com/argoproj/argo-cd/tree/master/notifications_catalog/triggers).

| Trigger | Source | Condition | `oncePer` |
|---------|-----------|-----------|
| `on-created` | [yaml](https://github.com/argoproj/argo-cd/blob/master/notifications_catalog/triggers/on-created.yaml) | `true` | `app.metadata.name` |
| `on-deleted` | [yaml](https://github.com/argoproj/argo-cd/blob/master/notifications_catalog/triggers/on-deleted.yaml) | `app.metadata.deletionTimestamp != nil` | `app.metadata.name` |
| `on-sync-running` | [yaml](https://github.com/argoproj/argo-cd/blob/master/notifications_catalog/triggers/on-sync-running.yaml) | `operationState != nil && operationState.phase in ['Running']` | `syncResult.revision` |
| `on-sync-succeeded` | [yaml](https://github.com/argoproj/argo-cd/blob/master/notifications_catalog/triggers/on-sync-succeeded.yaml) | `operationState != nil && operationState.phase in ['Succeeded']` | `syncResult.revision` |
| `on-sync-failed` | [yaml](https://github.com/argoproj/argo-cd/blob/master/notifications_catalog/triggers/on-sync-failed.yaml) | `operationState != nil && operationState.phase in ['Error', 'Failed']` | `syncResult.revision` |
| `on-deployed` | [yaml](https://github.com/argoproj/argo-cd/blob/master/notifications_catalog/triggers/on-deployed.yaml) | `operationState.phase == 'Succeeded'` AND `health.status == 'Healthy'` AND (`health.lastTransitionTime + 1m` ≥ `operationState.finishedAt` OR `health.lastTransitionTime` < `operationState.startedAt`) | `syncResult.revision` |
| `on-health-degraded` | [yaml](https://github.com/argoproj/argo-cd/blob/master/notifications_catalog/triggers/on-health-degraded.yaml) | `health.status == 'Degraded'` | `syncResult.revision` |
| `on-sync-status-unknown` | [yaml](https://github.com/argoproj/argo-cd/blob/master/notifications_catalog/triggers/on-sync-status-unknown.yaml) | `sync.status == 'Unknown'` | `syncResult.revision` |

### The `on-deployed` timestamp logic explained

The condition `(!time.Parse(health.lastTransitionTime).Add(1m).Before(operationState.finishedAt) OR health.lastTransitionTime.Before(operationState.startedAt))` handles two cases:

1. **Health became Healthy after the sync** (normal case): `health.lastTransitionTime` is within 1 minute after `finishedAt` — the 1-minute window absorbs the propagation delay between sync completion and health re-assessment.
2. **App was already Healthy before the sync started**: `health.lastTransitionTime < operationState.startedAt` — fires immediately on sync success since health was never in question.

It intentionally does NOT fire if the app transitioned to `Healthy` long after the sync completed (which would indicate health was re-established by something other than this sync).

---

## States Missing from Built-in Triggers

| Missing State | How to Detect |
|--------------|--------------|
| Sync retrying | `operationState.phase == "Running" && operationState.retryCount > 0` |
| Sync terminated/aborted | `operationState.phase == "Terminating"` |
| Sync succeeded but health degraded | `operationState.phase == "Succeeded" && health.status == "Degraded"` |
| Health recovered after degraded | `health.status == "Healthy"` transition — requires tracking previous state |
| Stuck progressing | `health.status == "Progressing"` for `> N minutes` after `operationState.finishedAt` |
| Out of sync with no operation | `sync.status == "OutOfSync"` AND `operationState == nil` |
| App condition errors | `conditions[].type in ["SyncError", "ComparisonError", "InvalidSpecError"]` |
| Stale status (git unreachable) | `now() − reconciledAt > statusRefreshTimeout` |

---

## Designing Reliable `oncePer` Keys

`oncePer` is a **consumed lock**: once ArgoCD sends a notification for a given key, it will never re-send for that exact key — even if the trigger condition becomes true again. Choosing the right key is therefore critical for capturing all state transitions without spamming.

### Why `(revision, phase)` is insufficient

A naive key like:

```yaml
oncePer: app.status.operationState?.syncResult?.revision + "-" + app.status.operationState?.phase
```

fails under oscillation. If an app syncs revision `abc123`, succeeds, health degrades, auto-sync retriggers, and succeeds again — the second success on the same revision is silently dropped because `abc123-Succeeded` was already consumed. The same applies to failure: you see the first failure, then silence.

### Use `finishedAt` as the key instead of `phase`

Every completed sync operation has a unique `finishedAt` timestamp. Keying on it captures every distinct operation completion event, regardless of how many times the same revision cycles through:

```yaml
oncePer: app.status.operationState?.syncResult?.revision + "-" + app.status.operationState?.finishedAt
```

The trigger's `when` condition already constrains which phase fires — phase does not need to be in the key. If auto-sync retries the same commit (because health degraded), the new `finishedAt` produces a new key and the trigger fires again.

### Adding a stabilization delay

ArgoCD evaluates trigger conditions on every reconciliation cycle (every few seconds). Without a delay, a status that flips quickly (Running → Succeeded → health Degraded → re-sync) can generate a burst of notifications before settling. A time guard in the `when` condition approximates a debounce:

```yaml
when: >
  app.status.operationState != nil
  and app.status.operationState.phase in ['Succeeded']
  and time.Parse(app.status.operationState.finishedAt).Add(30 * time.Second).Before(time.Now())
oncePer: app.status.operationState?.syncResult?.revision + "-" + app.status.operationState?.finishedAt
```

This interacts cleanly with `finishedAt`-keyed `oncePer`:

- At T+0: `finishedAt` is just set; `finishedAt + 30s` is not yet before `now()` → condition false, nothing sent
- If the app flips state within 30s: `finishedAt` changes → the old `oncePer` key is never consumed → the 30s clock resets from the new `finishedAt`
- At T+30s with stable state: condition becomes true → fires once → key consumed

A flapping app keeps resetting its own 30s window and only posts when it actually stabilizes. The `time.Parse(...).Add(...).Before(time.Now())` pattern is consistent with how the built-in `on-deployed` trigger already uses `time.Parse()`.

### Health oscillation is a separate case

Post-sync health changes (Healthy → Degraded → Healthy with no new sync) do not touch `operationState` at all — `finishedAt` stays unchanged. For those, key on `health.lastTransitionTime`, which changes on every health code transition:

```yaml
oncePer: app.status.operationState?.syncResult?.revision + "-health-" + app.status.health.lastTransitionTime
```

The same 30s delay can be applied using `lastTransitionTime` as the reference:

```yaml
when: >
  app.status.health.status == 'Degraded'
  and time.Parse(app.status.health.lastTransitionTime).Add(30 * time.Second).Before(time.Now())
oncePer: app.status.operationState?.syncResult?.revision + "-health-" + app.status.health.lastTransitionTime
```

### Summary: recommended keys per trigger type

| Trigger type | Recommended `oncePer` | Delay reference field |
|-------------|----------------------|----------------------|
| Sync phase (running / succeeded / failed) | `revision + "-" + finishedAt` | `operationState.finishedAt` |
| Health change (degraded / recovered) | `revision + "-health-" + health.lastTransitionTime` | `health.lastTransitionTime` |
| App created / deleted | `app.metadata.name` | n/a |
