# GitOps Promoter Example: Multi-Component Monorepo

Example repository demonstrating [gitops-promoter](https://github.com/argoproj-labs/gitops-promoter)'s **activePath monorepo mode** ([PR #1337](https://github.com/argoproj-labs/gitops-promoter/pull/1337)) for independent promotion of multiple components through a shared set of environment branches.

This repo serves as a test bed for [discussion #1385](https://github.com/argoproj-labs/gitops-promoter/discussions/1385).

## Architecture

```
                    main (DRY branch - users edit here)
                      |
         GitHub Actions hydrator (renders per env)
                      |
    ┌─────────┬───────┼───────┬─────────┐
    v         v       v       v         v
  app-a    app-b   app-c   app-d    infra-e
  (helm)  (kust)  (helm)  (kust)    (tf)
    |         |       |       |         |
    └─────────┴───────┴───────┴─────────┘
                      |
              Proposed branches:
        environment/<env>/<activePath>-next
                      |
              gitops-promoter
          (opens PRs, gates on CI checks)
                      |
              Active branches:
            environment/<env>
```

### Promotion Pipeline

```
development → integration → stage → prod-1 → prod-2 → prod-3
  (auto)        (auto)      (auto)  (manual)  (manual)  (manual)
```

- **development → stage**: auto-merge when CI checks pass
- **stage → prod-1**: requires 30-minute soak time (`TimedCommitStatus`)
- **prod-***: manual PR approval required (`autoMerge: false`)

### Components

| Component | Type | Path | Description |
|-----------|------|------|-------------|
| app-a | Helm | `apps/app-a/` | Nginx web application |
| app-b | Kustomize | `apps/app-b/` | httpbin web service |
| app-c | Helm | `apps/app-c/` | Redis config service |
| app-d | Kustomize | `apps/app-d/` | Batch processing CronJob |
| infra-e | Terraform | `infra/infra-e/` | Generic cloud infrastructure |

Each component promotes **independently** through all 6 stages via its own `PromotionStrategy` with `activePath`.

## How It Works

### 1. DRY Branch (`main`)

Users only edit files on `main`. This branch contains the unrendered source for all components.

### 2. Hydration (GitHub Actions)

On push to `main`, the [hydrate workflow](.github/workflows/hydrate.yaml):
- Detects which components changed
- Renders each component for every environment:
  - **Helm** (app-a, app-c): `helm template` with env-specific values
  - **Kustomize** (app-b, app-d): `kustomize build` with env overlay
  - **Terraform** (infra-e): copies `.tf` files + selects env-specific `.tfvars`
- Pushes hydrated output to proposed branches with `hydrator.metadata`
- Skips push if output is unchanged (dedup)

### 3. Promotion (gitops-promoter)

For each component, a `PromotionStrategy` with `activePath`:
- Watches proposed branches for new hydrated commits
- Opens PRs from proposed → active branches
- Gates merges on `WebRequestCommitStatus` (polls GitHub commit status API)
- Chains environments: a commit must be healthy in dev before promoting to integration, etc.

### 4. Gating (CI + WebRequestCommitStatus)

The [ci-checks workflow](.github/workflows/ci-checks.yaml) runs on pushes to `environment/**` branches, validating manifests. `WebRequestCommitStatus` polls GitHub's commit status API to detect when CI jobs pass, automatically creating the `CommitStatus` CRs that gate promotion.

No ArgoCD dependency. No external systems creating CommitStatus CRs via kubectl.

## Branch Layout

**Shared active branches** (one per environment):
- `environment/development`
- `environment/integration`
- `environment/stage`
- `environment/prod-1`, `environment/prod-2`, `environment/prod-3`

**Per-component proposed branches** (created by hydrator):
- `environment/development/apps/app-a-next`
- `environment/development/apps/app-b-next`
- `environment/development/infra/infra-e-next`
- ... (6 envs x 5 components = 30 proposed branches)

## Setup

### Prerequisites

- A Kubernetes cluster with gitops-promoter installed (with activePath support from PR #1337)
- A GitHub App with permissions: Checks (R/W), Contents (R/W), Pull requests (R/W)

### 1. Configure the GitHub App

Edit `k8s/scm-provider.yaml`:
- Set `appID` and `installationID`
- Replace the Secret's `githubAppPrivateKey` with your actual key

### 2. Configure the repository

Edit `k8s/git-repository.yaml`:
- Set `owner` to your GitHub org/user

Edit all files in `k8s/commit-status/ci-check-*.yaml`:
- Replace `<OWNER>/<REPO>` in `httpRequest.urlTemplate` with your actual values

### 3. Apply CRDs

```bash
kubectl apply -k k8s/
```

### 4. Create environment branches

```bash
for env in development integration stage prod-1 prod-2 prod-3; do
  git checkout --orphan "environment/$env"
  git rm -rf . 2>/dev/null || true
  git commit --allow-empty -m "initialize environment/$env"
  git push origin "environment/$env"
  git checkout main
done
```

### 5. Push to main

Any push to `main` that modifies a component will trigger hydration and start the promotion pipeline.

## Repository Structure

```
.
├── apps/
│   ├── app-a/          # Helm chart (nginx)
│   ├── app-b/          # Kustomize (httpbin)
│   ├── app-c/          # Helm chart (redis config service)
│   └── app-d/          # Kustomize (batch CronJob)
├── infra/
│   └── infra-e/        # Terraform (generic cloud infra)
├── k8s/                # gitops-promoter CRDs
│   ├── scm-provider.yaml
│   ├── git-repository.yaml
│   ├── promotion-strategies/
│   ├── commit-status/
│   └── kustomization.yaml
├── .github/workflows/
│   ├── hydrate.yaml    # Custom hydrator
│   └── ci-checks.yaml  # CI validation
└── README.md
```

## Testing activePath (PR #1337)

This repo is specifically designed to test the `activePath` monorepo mode. Key things to verify:

1. **Independent promotion**: changing app-a should only create PRs for app-a, not affect other components
2. **Shared active branches**: all components share `environment/development`, etc.
3. **Path-scoped merges**: PRs only touch files under the component's `activePath`
4. **hydrator.metadata placement**: at `<activePath>/hydrator.metadata`, not repo root
5. **Concurrent promotion**: multiple components can have open PRs for the same environment branch simultaneously
