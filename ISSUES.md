# Issues Found Testing gitops-promoter activePath (gitops-promoter-activepath branch)

Issues discovered while testing the activePath monorepo mode with the
[gitops-promoter-activepath](https://github.com/patjlm/gitops-promoter/tree/gitops-promoter-activepath)
branch (merged activePath support).

Test setup: 5 components × 6 environments, shared active branches, GitHub Actions custom hydrator.

## 1. Git ref lock contention with shared active branches

**Severity**: Minor (self-healing)

**Problem**: With activePath, multiple ChangeTransferPolicies share the same active branch (e.g. `environment/prod-2`). When a webhook or requeue triggers all component CTPs to reconcile simultaneously, they all attempt `git fetch origin environment/prod-2` into the same local git cache concurrently, causing ref lock collisions:

```
error: cannot lock ref 'refs/remotes/origin/environment/prod-2':
  is at 8cea2ed... but expected c98c719...
  ! c98c719..8cea2ed  environment/prod-2 -> origin/environment/prod-2 (unable to update local ref)
```

The failing CTPs retry on their next reconcile cycle and succeed. However, the collision adds latency proportional to the number of components sharing a branch — with 5 components × 6 environments (30 CTPs), several lock collisions can occur per reconcile wave.

**Root cause**: activePath-specific. Without activePath, each PromotionStrategy has dedicated branches so no two CTPs ever race on the same ref. With activePath, all components share environment branches, making concurrent fetches inevitable under high reconcile concurrency.

**Suggestion**: Serialize git fetch operations per branch (mutex or queue in the git layer), or use per-CTP git clones to eliminate sharing entirely.
