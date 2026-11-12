# Progressive Delivery with Environment Promotion

## Context

The IDP builds container images in Forgejo Actions and pushes them to a local registry. Kargo promotes hello-app from dev through qa and stage, then through a manual prod gate, and prod-1 and prod-2 deploy that freight in parallel. Promotion succeeds only when the Application reports the freight image. Analysis and rollback are still the remaining work.

We need a deployment strategy where every new version is tested against the actual running environment before it goes live. Different environments require different types of verification:

| Environment | Verification                            |
| ----------- | --------------------------------------- |
| dev         | e2e tests                               |
| qa          | Performance testing + deep verification |
| stage       | e2e tests                               |
| prod-1      | e2e tests                               |
| prod-2      | e2e tests                               |

The e2e test suite is the same across environments, but each environment has different configuration (replicas, resource limits, external dependencies, etc). If verification fails, the deployment must automatically roll back with no manual intervention and no downtime.

## Solution

The CD pipeline is built on three tools with no overlap in responsibilities:

| Tool           | Responsibility                                                    |
| -------------- | ----------------------------------------------------------------- |
| Kargo          | Watches for new artifacts, orchestrates promotion between environments, schedules and gates promotions |
| ArgoCD         | Syncs desired state from git to each cluster                      |
| Argo Rollouts  | Executes blue-green or canary rollout strategy with analysis      |

### Architecture

Kargo Warehouses watch for new artifacts (container images, git commits, Helm charts). When a change is detected, Kargo creates a Freight — a bundle of artifact versions that flows through a pipeline of Stages. Each Stage represents an environment and defines its own promotion steps, schedule, and verification.

Kargo's built-in promotion steps handle the git workflow for each environment transition:

1. `git-clone` — check out the gitops repo on `main`
2. `kustomize-set-image` — set the image tag in the target overlay
3. `git-commit` + `git-push` — commit and push to Forgejo
4. `argocd-update` — start a sync of this Application
5. `argocd-wait` — wait until that Application is Healthy and Synced
6. `http` — succeed only when `status.summary.images` contains the freight tag

prod has a single `compose-output` step. It records the tag and writes no manifest.

Argo CD auto-sync remains enabled. Kargo pushes to git, Argo CD detects the change and syncs. `argocd-wait` does not compare the sync revision, because every stage tracks `HEAD`. The `http` step is what proves this promotion's image is the one running.

### Deployment flow

1. CI builds and pushes a new image to the registry.
2. The `hello-app` Warehouse detects the new tag and creates a Freight.
3. dev promotes it immediately and commits the tag into the dev overlay.
4. Argo CD syncs that Application. The promotion succeeds when the running image is the freight tag.
5. qa, then stage, then prod, each wait for a Promote click. prod writes nothing.
6. prod-1 and prod-2 promote that Freight automatically and deploy in parallel.

AnalysisRuns are not part of this loop yet. A failed `http` check fails the Promotion, and the next stage does not see the Freight as verified.

### Promotion strategy

| Transition        | Trigger                                              |
| ----------------- | ---------------------------------------------------- |
| New image → dev   | Immediate, when the Warehouse creates the Freight    |
| dev → qa          | Manual Promote                                       |
| qa → stage        | Manual Promote                                       |
| stage → prod      | Manual Promote. prod deploys nothing                 |
| prod → prod-1     | Immediate, after prod verifies the Freight           |
| prod → prod-2     | Immediate, in parallel with prod-1                   |

Scheduled windows (qa and stage daily, production weekly) remain future policy. The running policy is the table above. An admin can approve one production stage directly, which lets that stage promote without waiting for prod. Approving prod itself does not skip the fan-out.

### Config trigger

Image promotion subscribes only to the registry. A merged manifest is applied by Argo CD because every Application renders `HEAD`, and the overlays point at `gitops/apps/hello-app`.

Config that must soak uses a second Warehouse and a tree Argo CD does not sync:

- People merge into `gitops/apps/hello-app`, including `envs/<stage>` for the patches that today live in the overlays.
- `hello-app-config` subscribes to `apps/hello-app` and not to `clusters/`.
- Each deploying stage requests both Freights. A promotion renders that stage's env at the config commit, sets the image Freight's tag, and commits plain manifests under `clusters/<cluster>/<namespace>/hello-app`.
- prod stays a gate with no render. prod-1 and prod-2 render their own env directories after the click.

The two Warehouses keep their own cadence. One Warehouse with both subscriptions would ship the newest image and the newest commit as a single Freight. This config path is the plan; the image path above is what is running.

### CI workflows

CI remains in Forgejo Actions. Kargo handles all of CD.

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `actions/.forgejo/workflows/build-and-push.yaml` | `workflow_call` (from project CI) | Builds and pushes a container image via `actions/build.sh` |
| `projects/<app>/.forgejo/workflows/ci.yaml` | Push to main | Calls the actions repo workflow for the project |

### Rollout strategy

Non-prod and prod environments use different Argo Rollouts strategies. No traffic router is required in any environment.

**Non-prod (dev, qa, staging) — Blue-green.** The rollout creates a separate preview ReplicaSet and points a preview Service at it. No real traffic reaches the new version during analysis. The analysis Job targets the preview Service directly. On success, the active Service switches to the new version. On failure, the preview is scaled down and the active version continues serving.

For dev and staging, `previewReplicaCount` is 1 — a single preview pod is sufficient for e2e testing. For QA, `previewReplicaCount` is N — multiple pods are needed for performance testing. QA runs at 0 replicas in steady state (`spec.replicas: 0`). The preview temporarily scales to N for testing and returns to 0 on both success and failure. Both the steady-state replica count and the preview replica count are defined in the same Rollout manifest in git. No extra commits are needed to manage the replica lifecycle.

**Prod (prod1, prod2) — Canary.** The rollout scales 1 canary replica, which receives a small fraction of real traffic proportional to its share of the total pod count (e.g. 1 canary among 10 stable pods ≈ 9% traffic). Analysis runs at that scale. On success, traffic gradually increases (10% → 25% → 50% → 100%) with pauses between steps. On failure, the canary is killed and the stable version keeps serving.

The version has already passed e2e in dev, performance tests in QA, and e2e in staging before reaching prod. The small initial traffic exposure during prod analysis is acceptable given this prior verification.

| Environment | Strategy   | Preview/Canary replicas | Analysis | After analysis passes          |
| ----------- | ---------- | ----------------------- | -------- | ------------------------------ |
| dev         | blue-green | 1 (preview)             | e2e      | Full switch                    |
| qa          | blue-green | N (preview, from 0)     | perf     | Scale to 0                     |
| staging     | blue-green | 1 (preview)             | e2e      | Full switch                    |
| prod1       | canary     | 1 (canary)              | e2e      | 10% → 25% → 50% → 100%       |
| prod2       | canary     | 1 (canary)              | e2e      | 10% → 25% → 50% → 100%       |

### Verification

Each environment defines its own AnalysisTemplate that launches a Kubernetes Job to test the live deployment. The Job runs a test container image against the actual service endpoint in that environment.

The same e2e test image is reused across dev, staging, prod1, and prod2 with environment-specific arguments (target URL, thresholds, timeouts). QA uses a separate test image or configuration for performance and deep verification. The test images are built and pushed through the same CI pipeline as application images.

An AnalysisRun succeeds when the test Job exits 0 and fails on any non-zero exit. On failure, Argo Rollouts aborts the rollout automatically.

### Why Job metrics over CI-triggered tests

Argo Rollouts supports multiple analysis providers. Two were considered for running verification tests:

**Job metric (chosen):** The AnalysisRun spins up a Kubernetes Job directly in the cluster. The Job runs the test container against the live service. The AnalysisRun watches the Job natively — exit 0 means pass, non-zero means fail. No external orchestration, no polling, no race conditions.

**Web metric (Forgejo Actions trigger):** The AnalysisRun calls the Forgejo API to dispatch a workflow (`POST /api/v1/repos/{owner}/{repo}/actions/dispatches`) and then polls for the result. This requires two metrics (trigger + poll), correlation of the dispatched run with the poll response, and handling of race conditions if multiple runs overlap.

The Job metric is the better fit because:

- Tests run inside the cluster against cluster-internal services — no external CI features are needed.
- The AnalysisRun has native lifecycle control over the Job (timeout, retry, cleanup).
- There is no dependency on Forgejo availability during the analysis phase.
- The feedback loop is faster — no HTTP polling interval overhead.

The Forgejo webhook approach is reserved for notifications (e.g. alerting on rollback) rather than driving the analysis itself.

### Failure handling

When analysis fails, Argo Rollouts automatically aborts the rollout — the old stable version keeps serving traffic and users see no disruption. The Rollout enters a degraded state. A notification is sent to alert the team.

The git repository still contains the commit with the failed image tag. This creates a temporary drift between what git declares and what the cluster is running. This drift is intentional and self-healing: when a developer pushes a fix, CI builds a new image, Kargo creates a new Freight and promotes it to the same Stage. Argo Rollouts sees the new desired version, abandons the failed state, and starts a fresh rollout from the current stable version.

No automated git revert is needed. The natural flow of a new version superseding the failed one resolves the drift without additional automation. The promotion chain is already blocked — Kargo will not promote a Freight that failed verification to the next Stage.

Example: v1 is stable, v2 fails analysis, v3 is pushed as a fix.

1. v2 arrives. Rollouts deploys the new version. Analysis fails. Rollouts aborts. v1 keeps serving.
2. Kargo marks the v2 Freight as failed. It is not promoted to the next Stage.
3. Developer pushes a fix. CI builds v3. Kargo creates new Freight and promotes to the same Stage.
4. Rollouts sees v3 as the new desired version, starts a fresh rollout from v1.
5. v3 passes analysis. Kargo verification confirms health. Freight proceeds to the next Stage.

At no point does v2 reach any subsequent environment. The degraded state is temporary and clears automatically when the next Freight arrives.

## Acceptance Criteria

### Infrastructure
- [x] Kargo is deployed to the hub cluster.
- [ ] Argo Rollouts controller is deployed to every cluster.
- [ ] No traffic router is required in any environment.

### Promotion
- [x] Kargo Warehouse detects new container images via the TLS registry proxy.
- [ ] `hello-app-config` detects commits under `gitops/apps/hello-app`.
- [ ] Kargo Warehouse detects Helm chart versions.
- [x] Stages exist for dev, qa, stage, prod, prod-1, and prod-2.
- [x] Dev promotions trigger immediately when new image Freight is available.
- [x] qa, stage, and prod wait for Promote. prod deploys nothing.
- [x] prod-1 and prod-2 promote immediately after prod verifies the Freight.
- [ ] QA and stage promotions are scheduled (daily at 2am).
- [ ] The prod gate is scheduled (weekly) instead of manual.
- [ ] Intermediate Freight versions are skipped when multiple arrive between scheduled windows.
- [ ] Failed verification blocks the Freight from reaching subsequent Stages.
- [ ] A new Freight supersedes a failed one and starts a fresh rollout from the stable version.

### Rollout
- [ ] Application workloads use Rollout resources instead of Deployments.
- [ ] Non-prod environments (dev, qa, staging) use blue-green with prePromotionAnalysis against the preview Service.
- [ ] Production environments (prod1, prod2) use canary with gradual traffic increase (10% → 25% → 50% → 100%).
- [ ] QA scales from 0 to N preview replicas for testing and converges back to 0 on both success and failure.
- [ ] Failed analysis aborts the Rollout and keeps the old stable version serving traffic.
- [ ] Failed analysis sends a notification to alert the team.

### Verification
- [ ] Every deployment to every environment triggers an AnalysisRun before promotion.
- [ ] Verification runs as a Kubernetes Job via the Argo Rollouts Job metric provider.
- [ ] QA runs performance and deep verification tests.
- [ ] The e2e test suite is a container image built and pushed through the same CI pipeline.
- [ ] Environment-specific test configuration is defined per cluster overlay.

### End-to-end
- [x] The image promotion chain (dev → qa → stage → prod → prod-1 and prod-2) is operational.
- [ ] The config promotion chain renders `apps/hello-app` into the live directories.
- [x] CI remains in Forgejo Actions. Kargo handles all of CD.
