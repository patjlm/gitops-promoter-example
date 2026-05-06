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
