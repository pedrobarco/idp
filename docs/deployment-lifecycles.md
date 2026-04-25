# Deployment Lifecycles

## Context

Not every change to the platform follows the same path to production. A new application image, a configuration change, and a multi-environment commit each carry different levels of risk and require different promotion strategies.

The platform must support distinct lifecycles depending on what changed, while ensuring that every change to a production environment is verified before it receives traffic.

## Change Types

### 1. Application image update

A new version of application code is built and pushed to the container registry.

**Path:** dev → qa → staging → prod1 + prod2 (sequential)

**Trigger:** Kargo Warehouse detects a new tag in the registry and creates a Freight. Kargo promotes the Freight through each Stage (environment), where Argo Rollouts verifies the deployment before Kargo promotes to the next. See [progressive-delivery.md](progressive-delivery.md) for the full specification.

### 2. Environment-scoped configuration

Operational changes that apply to a single environment: replica count, resource limits, annotations, HPA settings. These do not affect application behavior — they tune the deployment for a specific environment.

**Path:** Direct commit to the target environment overlay.

**Trigger:** A PR is opened against the target cluster overlay. On merge, ArgoCD syncs the change. If the change triggers a new ReplicaSet (e.g. resource limits), Argo Rollouts runs analysis. If it does not (e.g. HPA config), it is a plain sync with no rollout.

No promotion chain is needed. The change is specific to one environment and has no meaning in other environments.

### 3. Behavior-affecting configuration

Changes to environment variables, secrets, feature flags, or ingress rules that alter how the application behaves at runtime. These carry similar risk to a code change.

**Path:** dev → qa → staging → prod1 + prod2 (same as image updates)

**Trigger:** The change is committed to the dev cluster overlay first. Kargo Warehouse detects the git commit and creates a Freight. The Freight follows the same promotion chain as an image update — Argo Rollouts runs analysis at each stage. Promotion to the next environment happens only after Kargo verification passes.

This ensures that a bad config change is caught in dev before it reaches production, just like a bad code change would be.

### 4. Multi-environment commit

A single commit that touches overlays for multiple environments. Examples: updating a shared label across all clusters, changing a resource limit everywhere.

**Path:** Depends on the environments involved.

For non-production environments (dev, qa), multi-environment commits are acceptable. ArgoCD syncs each Application independently. Each environment's Rollout runs its own analysis.

For production environments (staging, prod1, prod2), multi-environment commits must be avoided. A commit that touches prod1 and prod2 simultaneously would deploy to both at once with no sequential gate between them. Instead:

- Split the change into per-environment commits, each promoted through the chain, or
- Use Kargo Stages to apply the change to one environment at a time.

This can be enforced through CI checks that reject PRs touching multiple production overlays.

### 5. Multi-app commit

A single commit that touches multiple applications within the same environment.

**Path:** Each application syncs and rolls out independently, in parallel.

ArgoCD treats each Application as an independent unit. A commit that changes both `hello-app` and `api-gateway` in the same environment triggers two separate syncs and two separate Rollout analyses. A failure in one does not affect the other.

The exception is coupled applications that must be deployed together (e.g. an API and a worker that share a database migration). These require explicit ordering via ArgoCD sync waves or an app-of-apps pattern to ensure the migration runs before the dependents roll out.

## Summary

| Change type                 | Promotion chain         | Gate                   | Automation                 |
| --------------------------- | ----------------------- | ---------------------- | -------------------------- |
| New image                   | Full (dev → prod)       | Analysis at each stage | Kargo Warehouse triggers dev |
| Env-scoped config           | None (direct to target) | PR review              | ArgoCD sync                  |
| Behavior-affecting config   | Full (dev → prod)       | Analysis at each stage | Kargo Warehouse detects git commit |
| Multi-env commit (non-prod) | Per-env (parallel)      | Per-env analysis       | ArgoCD sync                |
| Multi-env commit (prod)     | Rejected — must split   | PR policy              | CI enforcement             |
| Multi-app commit            | Per-app (parallel)      | Per-app analysis       | ArgoCD sync                |

## Current State

The dev stage of the image update lifecycle is operational: CI builds and pushes images → Kargo Warehouse discovers them via the TLS registry proxy → Kargo auto-promotes to dev → ArgoCD syncs. The remaining stages (qa, staging, prod1, prod2) and Argo Rollouts analysis integration are not yet implemented.

## Acceptance Criteria

- [ ] Image updates follow the full sequential promotion chain with automated analysis.
- [ ] Environment-scoped config changes can be applied directly to a target environment via PR.
- [ ] Behavior-affecting config changes follow the same promotion chain as image updates.
- [ ] Multi-environment commits to production overlays are rejected by CI.
- [ ] Multi-app commits trigger independent per-app rollouts and analysis.
- [ ] Coupled applications are deployed with explicit ordering via sync waves.
- [ ] Every change that triggers a new ReplicaSet runs Argo Rollouts analysis before promotion.
