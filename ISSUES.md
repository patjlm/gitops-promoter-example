# Issues Found Testing gitops-promoter activePath (PR #1337)

Issues discovered while testing the activePath monorepo mode. To be reported on [discussion #1385](https://github.com/argoproj-labs/gitops-promoter/discussions/1385) and/or [PR #1337](https://github.com/argoproj-labs/gitops-promoter/pull/1337).

## 1. Git ref conflict: proposed branch names conflict with active branch names

**Severity**: Blocker

**Problem**: PR #1337 generates proposed branch names as `<active-branch>/<activePath>-next`, e.g. `environment/development/apps/app-a-next`. Git cannot create this ref because `environment/development` already exists as a branch (ref file), and Git needs `environment/development/` to be a directory to store the proposed branch ref.

```
error: cannot lock ref 'refs/heads/environment/development/apps/app-a-next':
  'refs/heads/environment/development' exists;
  cannot create 'refs/heads/environment/development/apps/app-a-next'
```

**Code**: `internal/controller/promotionstrategy_controller.go:237`
```go
proposedBranch = path.Join(environment.Branch, ps.Spec.ActivePath+"-next")
```

**Proposed fix**: Append activePath to the existing `-next` branch convention:
```go
proposedBranch = path.Join(proposedBranch, ps.Spec.ActivePath)
// proposedBranch is already "<branch>-next", e.g. "environment/development-next"
```

This produces `environment/development-next/apps/app-a` — no conflict with active branch `environment/development`, and consistent with the non-activePath convention (`environment/development-next`).

## 2. ArgoCD CRD dependency even when not using ArgoCD

**Severity**: Minor

**Problem**: The promoter controller crashes on startup if the ArgoCD `Application` CRD is not installed, even when no `ArgoCDCommitStatus` resources are configured.

```
ERROR  setup  unable to start  {"error": "no matches for kind \"Application\" in version \"argoproj.io/v1alpha1\""}
```

**Workaround**: Install ArgoCD CRDs without ArgoCD:
```bash
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/application-crd.yaml
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/appproject-crd.yaml
```

**Suggestion**: The controller should gracefully skip the ArgoCDCommitStatus controller when the CRD is not present.

## 3. CRD race condition on fresh install

**Severity**: Minor

**Problem**: `install.yaml` contains both CRD definitions and a `ControllerConfiguration` custom resource. On first apply, the CRD may not be registered by the time the CR is processed:

```
error: resource mapping not found for name: "promoter-controller-configuration"
  namespace: "promoter-system" from "install.yaml":
  no matches for kind "ControllerConfiguration" in version "promoter.argoproj.io/v1alpha1"
```

**Workaround**: Apply `install.yaml` twice:
```bash
kubectl apply -f install.yaml
sleep 3
kubectl apply -f install.yaml
```

**Suggestion**: Split CRDs into a separate manifest, or document the two-pass apply.

## 4. Shared commit status keys collide in activePath mode

**Severity**: Blocker (for activePath multi-component use)

**Problem**: When multiple components share the same active branch (the whole point of activePath), they also share the same commit SHA on that branch. If different PromotionStrategies use the same commit status keys (e.g. `ci-check`, `deploy`), the controller creates multiple `CommitStatus` CRs with the same SHA+key combination. The CTP then fails with:

```
there are too many matching SHAs for the 'deploy' commit status:
  promoter-system/deploy-app-c-..., promoter-system/deploy-app-d-..., and 3 more...
```

This completely blocks promotion for all components.

**Root cause**: `CommitStatus` CRs are matched by `(sha, key)`. With shared active branches, all components see the same SHA, so their CommitStatus CRs collide when using the same key.

**Workaround**: Use component-specific keys: `ci-check-app-a`, `deploy-app-a`, etc. instead of shared `ci-check`, `deploy`.

**Root cause in code**: `internal/controller/changetransferpolicy_controller.go:667-673` matches CommitStatus CRs by label `commit-status=<key>` + field `spec.sha=<sha>`. With shared branches, all components produce CommitStatus CRs with the same SHA and key.

**Proposed fix**: Add a `promotionStrategyRef` or `changeTransferPolicy` label to CommitStatus CRs, and filter on it in the CTP controller. The WebRequestCommitStatus controller already sets a `web-request-commit-status` label — a similar approach for PromotionStrategy ownership would scope the lookup correctly.

**Current workaround**: Use component-specific keys (`ci-app-a`, `deploy-app-a`) instead of shared keys (`ci-check`, `deploy`). This works but defeats the simplicity of the activePath pattern.

## 5. Default memory limit too low for activePath monorepo

**Severity**: Minor

**Problem**: The default `install.yaml` sets a 128Mi memory limit on the controller. With activePath mode, each PromotionStrategy creates CTPs for all environments, and each CTP clones the repo. For our 5-component × 6-environment setup (30 CTPs), the controller OOMKills.

**Workaround**: Increase memory limit:
```bash
kubectl -n promoter-system patch deployment promoter-controller-manager \
  --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"512Mi"}]'
```

**Suggestion**: Document memory requirements based on number of components × environments, or auto-scale based on CTP count.

## 6. PR title and description should include activePath

**Severity**: Enhancement

**Problem**: In activePath mode, PRs are titled `Promote <sha> to environment/development`. With multiple components sharing branches, all PRs look identical. The activePath (component being promoted) should be included.

**Current**: `Promote 32119 to environment/development`
**Expected**: `Promote apps/app-a (32119) to environment/development` or similar

**Suggestion**: When `activePath` is set, include it in the PR title and body to distinguish per-component promotions.

**Status**: Fixed in our submodule (commit `cc6efb5`). The default PR template now uses `{{ with .ChangeTransferPolicy.Spec.ActivePath }}` to conditionally include the path.

## 7. Potential for duplicate/mismatched PRs with shared active branches

**Severity**: Medium

**Problem**: Two PRs titled `Promote apps/app-d` were created — one with the wrong source branch (`app-b` instead of `app-d`). This happened during a clean run: push to main → hydration → promoter creates PRs for all 5 components targeting the same active branch.

**Investigation**: CTP names are 38 chars (under the 63-char `KubeSafeLabel` limit), so label truncation collisions are NOT the cause. The root cause is unknown — possibly a race condition in `setPullRequestState` or `mergePullRequests` when multiple CTPs targeting the same active branch reconcile concurrently.

**Code area**: `setPullRequestState` (line ~748) and `mergePullRequests` (line ~1183) in `changetransferpolicy_controller.go` look up PullRequest CRs by label only. Neither validates that the found PR's `spec.sourceBranch` matches the CTP's `proposedBranch`.

**Observed data**:
- PR #36: title `apps/app-d`, head branch `apps/app-b`, PR #37: title `apps/app-d`, head branch `apps/app-d` — both created at `2026-05-07T10:40:54Z`
- PR #44: title `infra/infra-e`, head branch `apps/app-a`
- CTP names are 38 chars (no `KubeSafeLabel` truncation)
- PullRequest CRs had correct `spec.sourceBranch` and `spec.title` at time of inspection
- GitHub `Create` API is called with correct `head`/`title` from the PullRequest CR spec

**Root cause**: `FindOpen` in `internal/scms/github/pullrequest.go:206` passes `pullRequest.Spec.SourceBranch` directly as the `Head` filter parameter to GitHub's List Pull Requests API. GitHub requires the format `owner:branch` for the `head` filter — without the `owner:` prefix, GitHub silently ignores the filter and returns **all** open PRs for the base branch. `FindOpen` then picks `pullRequests[0]` (whichever GitHub returns first) and adopts its ID. The subsequent `Update` call overwrites that PR's title with the wrong component's data.

Verified with the GitHub API:
```
# Without owner: prefix — returns ALL open PRs for base (4 results)
GET /repos/patjlm/gitops-promoter-example/pulls?base=environment/development&head=environment/development-next/apps/app-b&state=open → 4

# With owner: prefix — correctly filters (0 results, PR already merged)
GET /repos/patjlm/gitops-promoter-example/pulls?base=environment/development&head=patjlm:environment/development-next/apps/app-b&state=open → 0
```

**Fix**: In `FindOpen`, prefix the `Head` parameter with the repo owner: `Head: fmt.Sprintf("%s:%s", gitRepo.Spec.GitHub.Owner, pullRequest.Spec.SourceBranch)`.

