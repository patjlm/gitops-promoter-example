# GitOps Promoter Example: Multi-Component Monorepo

Example repository demonstrating [gitops-promoter](https://github.com/argoproj-labs/gitops-promoter)'s **activePath monorepo mode** ([PR #1337](https://github.com/argoproj-labs/gitops-promoter/pull/1337)) for independent promotion of multiple components through a shared set of environment branches.

Test bed for [discussion #1385](https://github.com/argoproj-labs/gitops-promoter/discussions/1385).

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
        environment/<env>-next/<activePath>
                      |
              gitops-promoter
         (opens PRs, gates on CI + deploy)
                      |
              Active branches:
            environment/<env>
```

### Promotion Pipeline

```
development → integration → stage → prod-1 → prod-2 → prod-3
  (auto)        (auto)      (auto)  (manual)  (manual)  (manual)
```

- **development → stage**: auto-merge when CI checks and deploy status pass
- **stage → prod-1**: additionally requires 2-minute soak time (`TimedCommitStatus`)
- **prod-\***: manual PR approval required (`autoMerge: false`)

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
- Gates merges on commit status checks
- Chains environments: a commit must be healthy in dev before promoting to integration, etc.

### 4. Gating

| Gate | Type | Trigger | What it checks |
|------|------|---------|----------------|
| `ci-check` | `WebRequestCommitStatus` | Polls GitHub API | Combined commit status on active branch |
| `deploy` | `WebRequestCommitStatus` | Polls GitHub API | `context=deploy` status set by the fake deploy workflow |
| `timer` | `TimedCommitStatus` | Time-based | 2-minute soak time (only on `environment/stage`) |

**CI checks** ([ci-checks.yaml](.github/workflows/ci-checks.yaml)): runs on PRs targeting active branches and on post-merge pushes. Validates K8s manifests or runs `terraform validate`.

**Fake deploy** ([deploy.yaml](.github/workflows/deploy.yaml)): runs on post-merge pushes to active branches. Simulates a deployment and sets a `deploy` GitHub commit status on the commit.

**No ArgoCD dependency.** No external systems creating CommitStatus CRs via kubectl. gitops-promoter reads CI/deploy job results directly from GitHub.

### 5. End-to-End Flow

1. User pushes a change to `main`
2. Hydrate workflow renders per-env content, pushes to `-next` branches
3. Promoter opens PRs from `-next` → active branches
4. CI checks run on the PR
5. Promoter merges the PR (if `autoMerge: true`)
6. Deploy workflow runs post-merge, sets `deploy` commit status
7. WebRequestCommitStatus polls GitHub API, picks up `ci-check` and `deploy` as success
8. Promoter chains to the next environment (repeats from step 3)
9. At stage: TimedCommitStatus enforces 2-minute soak
10. At prod-\*: PR opened but requires human approval

## Branch Layout

**Shared active branches** (one per environment):
- `environment/development`, `environment/integration`, `environment/stage`
- `environment/prod-1`, `environment/prod-2`, `environment/prod-3`

**Per-component proposed branches** (created by hydrator):
- `environment/development-next/apps/app-a`
- `environment/development-next/apps/app-b`
- `environment/development-next/infra/infra-e`
- ... (6 envs x 5 components = 30 proposed branches)

## Setup

See [setup/README.md](setup/README.md) for local development with minikube.

### Prerequisites

- A Kubernetes cluster with gitops-promoter installed (with activePath support from PR #1337)
- A GitHub App with permissions: Checks (R/W), Contents (R/W), Pull requests (R/W), Commit statuses (R/W)

### Quick Start

```bash
cp setup/config.env setup/config.local.env   # edit with GitHub App creds
./setup/setup.sh                              # bootstraps minikube + promoter
```

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
├── setup/              # Local dev scripts
├── gitops-promoter/    # Submodule (PR #1337)
├── .github/workflows/
│   ├── hydrate.yaml    # Custom hydrator
│   ├── ci-checks.yaml  # CI validation
│   └── deploy.yaml     # Fake deploy + status
├── CLAUDE.md
└── README.md
```

## Testing activePath (PR #1337)

This repo is specifically designed to test the `activePath` monorepo mode. Key things to verify:

1. **Independent promotion**: changing app-a should only create PRs for app-a, not affect other components
2. **Shared active branches**: all components share `environment/development`, etc.
3. **Path-scoped merges**: PRs only touch files under the component's `activePath`
4. **hydrator.metadata placement**: at `<activePath>/hydrator.metadata`, not repo root
5. **Concurrent promotion**: multiple components can have open PRs for the same environment branch simultaneously
