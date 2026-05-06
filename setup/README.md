# Local Setup

Scripts to deploy gitops-promoter on a local minikube cluster for testing.

## Prerequisites

- [minikube](https://minikube.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- A [GitHub App](https://docs.github.com/en/apps/creating-github-apps) installed on the target repo with permissions:
  - Checks: Read and write
  - Contents: Read and write
  - Pull requests: Read and write
  - Commit statuses: Read and write

## Quick Start

```bash
# 1. Configure
cp config.env config.local.env
# Edit config.local.env with your GitHub App ID, Installation ID, and private key path

# 2. Run setup
./setup.sh

# 3. Verify
kubectl -n promoter-system get pods
kubectl -n promoter-system get promotionstrategy
kubectl -n promoter-system get changetransferpolicy
```

## Scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | Start minikube, install gitops-promoter, configure ScmProvider, apply CRDs, create env branches |
| `teardown.sh` | Delete minikube cluster |
| `build-from-pr.sh` | Build gitops-promoter from a PR (defaults to #1337 for activePath) |

## Configuration

`config.local.env` (gitignored):

| Variable | Description |
|----------|-------------|
| `GITHUB_APP_ID` | GitHub App ID |
| `GITHUB_APP_INSTALLATION_ID` | Installation ID (from the URL after installing the app) |
| `GITHUB_APP_PRIVATE_KEY_FILE` | Path to the `.pem` private key file |
| `PROMOTER_IMAGE` | Container image for gitops-promoter |
| `PROMOTER_TAG` | Image tag |
| `PROMOTER_INSTALL_URL` | Release manifest URL (leave empty to use `setup/install.yaml`) |
| `MINIKUBE_PROFILE` | Minikube profile name (default: `promoter-example`) |

## Using a Custom Build

To test with a custom gitops-promoter build (e.g. PR #1337):

```bash
# Option 1: Use the submodule
cd ../gitops-promoter
make docker-build IMG=quay.io/youruser/gitops-promoter:custom-tag
make build-installer IMG=quay.io/youruser/gitops-promoter:custom-tag
cp dist/install.yaml ../setup/install.yaml

# Option 2: Use the helper script
./build-from-pr.sh 1337
```

Then update `config.local.env`:
```
PROMOTER_IMAGE=quay.io/youruser/gitops-promoter
PROMOTER_TAG=custom-tag
PROMOTER_INSTALL_URL=
```

## Notes

- ArgoCD CRDs must be installed (the promoter controller watches Application resources) even though ArgoCD itself is not required
- The `setup/install.yaml` file is gitignored — generate it from the submodule or download from a release
- Environment branches (`environment/*`) are created as empty orphan branches on GitHub
