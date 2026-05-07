Testing report for PR #1337 (activePath)

I built a [5-component × 6-environment example repo](https://github.com/patjlm/gitops-promoter-example) to test the `activePath` monorepo mode. Components use a mix of Helm, Kustomize, and Terraform, promoting through `development → integration → stage → prod-{1,2,3}` with shared active branches.

I found and fixed 4 issues (5 commits). Fixes are in [PR #1408](https://github.com/argoproj-labs/gitops-promoter/pull/1408) targeting the PR #1337 branch.

### 1. Git ref conflict: proposed branch names conflict with active branch names

**Severity**: Blocker

The current naming generates proposed branches as `<active-branch>/<activePath>-next`, e.g. `environment/development/apps/app-a-next`. Git cannot create this ref because `environment/development` already exists as a branch (ref file), and Git needs `environment/development/` to be a directory.

```
error: cannot lock ref 'refs/heads/environment/development/apps/app-a-next':
  'refs/heads/environment/development' exists
```

**Fix** ([`35a2978`](https://github.com/patjlm/gitops-promoter/commit/35a2978)): Append activePath to the existing `-next` convention — `environment/development-next/apps/app-a`. No conflict, consistent with non-activePath naming.

### 2. Shared commit status keys collide in activePath mode

**Severity**: Blocker

When multiple PromotionStrategies share the same active branch (the whole point of activePath), they share the same commit SHA. If they use the same commit status keys (e.g. `ci-check`), the CTP controller finds multiple CommitStatus CRs with the same `(sha, key)` and errors:

```
there are too many matching SHAs for the 'ci-check' commit status
```

This blocks promotion for all components. The workaround is component-specific keys (`ci-check-app-a`), but that defeats the simplicity of activePath.

**Fix** ([`6724e03`](https://github.com/patjlm/gitops-promoter/commit/6724e03), [`179f7e4`](https://github.com/patjlm/gitops-promoter/commit/179f7e4)): Add an `ActivePathLabel` to CommitStatus CRs and filter on it in `setCommitStatusState`. The label must be set everywhere CommitStatus CRs are created: WebRequestCommitStatus controller, TimedCommitStatus controller, and `createOrUpdatePreviousEnvironmentCommitStatus` in the PromotionStrategy controller. Without the label on `promoter-previous-environment` CRs, promotion beyond the first environment is blocked.

### 3. PR title and description should include activePath

**Severity**: Enhancement

With shared active branches, all PRs are titled `Promote <sha> to environment/development` — indistinguishable. The activePath should be included to identify which component is being promoted.

**Fix** ([`78ea4e6`](https://github.com/patjlm/gitops-promoter/commit/78ea4e6)): Update the default PR title template to conditionally include activePath: `` Promote `apps/app-a` (32119) to `environment/development` ``.

### 4. FindOpen returns wrong PR when multiple PRs target the same base branch

**Severity**: Medium (not activePath-specific, but exposed by it)

`FindOpen` in the GitHub SCM provider passes `pullRequest.Spec.SourceBranch` directly as the `Head` filter to GitHub's List Pull Requests API. GitHub requires `owner:branch` format — without the `owner:` prefix, GitHub silently ignores the filter and returns **all** open PRs for the base branch. `FindOpen` then picks `pullRequests[0]` (whichever GitHub returns first), and the subsequent `Update` call overwrites that PR's title with the wrong component's data.

Verified with the GitHub API:
```
# Without owner: prefix — returns ALL open PRs (4 results)
GET /repos/.../pulls?base=environment/development&head=environment/development-next/apps/app-b&state=open → 4

# With owner: prefix — correctly filters (0 results, PR already merged)
GET /repos/.../pulls?base=environment/development&head=patjlm:environment/development-next/apps/app-b&state=open → 0
```

**Fix** ([`f6d17cc`](https://github.com/patjlm/gitops-promoter/commit/f6d17cc)): Prefix `Head` with `gitRepo.Spec.GitHub.Owner`.
