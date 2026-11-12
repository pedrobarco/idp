# Deployment Lifecycles

## Context

Not every change to the platform follows the same path to production. A new application image, a configuration change, and a multi-environment commit each carry different levels of risk and require different promotion strategies.

The platform must support distinct lifecycles depending on what changed, while ensuring that every change to a production environment is verified before it receives traffic.

## Change Types

### 1. Application image update

A new version of application code is built and pushed to the container registry.

**Path:** dev → qa → stage → prod → prod-1 and prod-2. prod is a manual gate and deploys nothing. prod-1 and prod-2 promote from it automatically, in parallel.

**Trigger:** The `hello-app` Warehouse detects a new tag in the registry and creates a Freight. dev promotes it immediately. qa, stage, and prod wait for a Promote click. Each deploying stage writes the tag into its overlay, syncs that Application, and succeeds only when `status.summary.images` contains the freight tag. See [progressive-delivery.md](progressive-delivery.md). Argo Rollouts analysis is still planned; it is not what gates promotion today.

### 2. Environment-scoped configuration

Operational changes that apply to a single environment: replica count, resource limits, annotations, HPA settings. These do not affect application behavior — they tune the deployment for a specific environment.

**Path:** The same chain as a behavior-affecting config change. The patch is specific to one stage, and the other stages render their own env directory from that same commit.

**Trigger:** A PR changes `gitops/apps/hello-app/envs/<stage>`. The config Warehouse creates a Freight. dev renders first. Stages whose env directory did not change produce an empty commit and still have to succeed before the stage that owns the patch can render it.

Today, before that split exists, a PR to `clusters/<cluster>/<namespace>/hello-app` is applied by Argo CD on merge. That is the behavior this lifecycle replaces.

### 3. Behavior-affecting configuration

Changes to environment variables, secrets, feature flags, or ingress rules that alter how the application behaves at runtime. These carry similar risk to a code change.

**Path:** dev → qa → stage → prod → prod-1 and prod-2, same as an image. The image Freight and the config Freight stay independent and are promoted as a pair.

**Trigger:** People merge into the proposal tree, `gitops/apps/hello-app`. A second Warehouse, `hello-app-config`, subscribes to that path only. Argo CD does not watch it. The ApplicationSet keeps watching `clusters/*/*/hello-app`.

A deploying promotion checks out the config commit, renders `apps/hello-app/envs/<stage>` with the image Freight's tag, and replaces that stage's live directory with the plain manifests. It commits only under `clusters/`. The config Warehouse does not include `clusters/`, so the promotion commit does not create another Freight. `argocd-update`, `argocd-wait`, and the image check then run as they do for an image promotion. prod still deploys nothing.

```text
gitops/apps/hello-app/                  proposal, Warehouse includePaths
  kustomization.yaml                    shared base
  envs/{dev,qa,stage,prod-1,prod-2}/    env patches
gitops/clusters/<cluster>/<ns>/hello-app/   rendered YAML, Argo CD auto-sync
```

Pull requests do not edit the live directories. `make sync` keeps a Forgejo file when the local tree has not changed it, which is how rendered output and image tags survive the next publish.

### 4. Multi-environment commit

A single commit that touches overlays for multiple environments. Examples: updating a shared label across all clusters, changing a resource limit everywhere.

**Path:** One config Freight through the same chain.

A change to the shared base is one config commit. Each stage renders it when that Freight is promoted, so prod-1 and prod-2 still wait on the prod gate instead of receiving the merge together.

CI rejects pull requests that edit `clusters/*/*/hello-app`. Those directories are the promotion output. A commit that changes them directly is applied by Argo CD on merge and skips the chain.

### 5. Multi-app commit

A single commit that touches multiple applications within the same environment.

**Path:** Each application syncs and rolls out independently, in parallel.

ArgoCD treats each Application as an independent unit. A commit that changes both `hello-app` and `api-gateway` in the same environment triggers two separate syncs and two separate Rollout analyses. A failure in one does not affect the other.

The exception is coupled applications that must be deployed together (e.g. an API and a worker that share a database migration). These require explicit ordering via ArgoCD sync waves or an app-of-apps pattern to ensure the migration runs before the dependents roll out.

## Summary

| Change type                 | Promotion chain                                      | Gate                                      | Automation                                      |
| --------------------------- | ---------------------------------------------------- | ----------------------------------------- | ----------------------------------------------- |
| New image                   | dev → qa → stage → prod → prod-1 and prod-2          | Promote clicks, then the running image    | `hello-app` Warehouse, dev auto, prod fan-out   |
| Env-scoped config           | Same chain; only the owning stage's render changes  | Same as config                            | `hello-app-config` Warehouse on `envs/<stage>` |
| Behavior-affecting config   | Same chain, paired with the current image Freight    | Same as an image                          | `hello-app-config` Warehouse on `apps/hello-app` |
| Multi-env commit (non-prod) | One config Freight, rendered per stage               | Per-stage promotion                       | Render, not a direct Argo CD sync               |
| Multi-env commit (prod)     | Same Freight, held at the prod gate                  | One Promote, then both prod stages        | CI rejects edits under the live directories     |
| Multi-app commit            | Per-app (parallel)                                   | Per-app promotion                         | Argo CD syncs each Application                  |

## Current State

Image promotion is operational on hello-app. CI pushes an image, the Warehouse discovers it through the TLS registry proxy, and the Freight moves dev → qa → stage → prod → prod-1 and prod-2. qa, stage, and prod are manual. prod deploys nothing. prod-1 and prod-2 are automatic. Each deploying promotion waits until the Application reports the freight tag. hello-app is still a Deployment. Argo Rollouts, the config Warehouse, and the proposal tree are not built yet. Until they are, a merge under `clusters/` or `apps/hello-app` is applied by Argo CD directly.

## Acceptance Criteria

- [x] Image updates follow dev → qa → stage → prod → prod-1 and prod-2.
- [ ] Image updates run automated analysis at each stage.
- [ ] `hello-app-config` watches `gitops/apps/hello-app` and does not watch `clusters/`.
- [ ] Promotions render the proposal into `clusters/<cluster>/<namespace>/hello-app` and Argo CD syncs only that rendered directory.
- [ ] Environment-scoped and behavior-affecting config changes travel that chain instead of syncing on merge.
- [ ] CI rejects pull requests that edit the rendered live directories.
- [ ] Multi-app commits trigger independent per-app rollouts and analysis.
- [ ] Coupled applications are deployed with explicit ordering via sync waves.
- [ ] Every change that triggers a new ReplicaSet runs Argo Rollouts analysis before promotion.
