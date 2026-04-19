# Progressive Delivery with Environment Promotion

## Context

The IDP currently has a CI pipeline that builds container images and pushes them to a local registry. ArgoCD deploys applications across four clusters (dev, staging, prod1, prod2) from git-defined manifests. However, there is no automated deployment pipeline — image tags in cluster manifests are updated manually, and there is no mechanism to verify a deployment before it receives production traffic.

We need a deployment strategy where every new version is tested against the actual running environment before it goes live. Different environments require different types of verification:

| Environment | Verification                            |
| ----------- | --------------------------------------- |
| dev         | e2e tests                               |
| qa          | Performance testing + deep verification |
| staging     | e2e tests                               |
| prod1       | e2e tests                               |
| prod2       | e2e tests                               |

The e2e test suite is the same across environments, but each environment has different configuration (replicas, resource limits, external dependencies, etc). If verification fails, the deployment must automatically roll back with no manual intervention and no downtime.

## Solution

Adopt Argo Rollouts as the deployment mechanism for all application workloads. Rollouts replace standard Kubernetes Deployments and introduce progressive delivery: a new version is deployed alongside the old one, verified via an AnalysisRun, and promoted or rolled back based on the test outcome.

Argo CD Image Updater watches the container registry for new image tags and commits the updated tag to git, triggering the rollout pipeline through ArgoCD.

### Deployment flow

1. CI builds and pushes a new image to the registry.
2. Image Updater detects the new tag and commits it to the dev cluster manifest.
3. ArgoCD syncs the change. Argo Rollouts deploys the new version as a canary.
4. An AnalysisRun executes the verification suite against the live deployment.
5. On success, the rollout promotes the new version to full traffic.
6. On failure, the rollout automatically reverts. The old version continues serving.
7. Promotion to the next environment follows the same deploy-verify-promote cycle.

### Promotion strategy

All promotions are fully automatic. On successful analysis, Argo Rollouts Notifications sends a webhook to Gitea that dispatches the `promote.yaml` workflow. The workflow copies the image tag from the source overlay to the target overlay, commits, and pushes. ArgoCD syncs the target environment and the cycle repeats.

| Transition      | Trigger                                   |
| --------------- | ----------------------------------------- |
| New image → dev | Automatic (Image Updater)                 |
| dev → qa        | Automatic (promote workflow on success)    |
| qa → staging    | Automatic (promote workflow on success)    |
| staging → prod1 | Automatic (promote workflow on success)    |
| prod1 → prod2   | Automatic (promote workflow on success)   |

Failure at any stage aborts the rollout and stops the chain. The bad version never reaches subsequent environments. The next image push restarts the chain from dev.

### Promotion workflow

A single reusable Gitea Actions workflow (`promote.yaml`) handles all environment transitions. It is agnostic to application names, environments, and registries. It takes two inputs:

| Input | Description                                                |
| ----- | ---------------------------------------------------------- |
| from  | Source cluster overlay path (e.g. clusters/dev/default/hello-app)     |
| to    | Target cluster overlay path (e.g. clusters/qa/default/hello-app)     |

The workflow:

1. Checks out the IDP repo.
2. Reads the current image tag from the source kustomization.
3. Sets the same image tag in the target kustomization.
4. Commits and pushes.

ArgoCD detects the change in the target overlay and syncs. Argo Rollouts starts a new canary in the target environment with its own analysis.

### Workflows

The platform uses three workflows:

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `build-and-push.yaml` | `workflow_call` (from project CI) | Builds and pushes a container image via `scripts/build.sh` |
| `promote.yaml` | `workflow_dispatch` (from Rollouts notification) | Copies an image tag from one overlay to the next |
| `projects/<app>/.gitea/workflows/ci.yaml` | Push to main | Calls `build-and-push.yaml` for the project |

### Verification

Each environment defines its own AnalysisTemplate that launches a Kubernetes Job to test the live deployment. The Job runs a test container image against the actual service endpoint in that environment.

The same e2e test image is reused across dev, staging, prod1, and prod2 with environment-specific arguments (target URL, thresholds, timeouts). QA uses a separate test image or configuration for performance and deep verification. The test images are built and pushed through the same CI pipeline as application images.

An AnalysisRun succeeds when the test Job exits 0 and fails on any non-zero exit. On failure, Argo Rollouts reverts the canary automatically.

### Why Job metrics over CI-triggered tests

Argo Rollouts supports multiple analysis providers. Two were considered for running verification tests:

**Job metric (chosen):** The AnalysisRun spins up a Kubernetes Job directly in the cluster. The Job runs the test container against the live service. The AnalysisRun watches the Job natively — exit 0 means pass, non-zero means fail. No external orchestration, no polling, no race conditions.

**Web metric (Gitea Actions trigger):** The AnalysisRun calls the Gitea API to dispatch a workflow (`POST /api/v1/repos/{owner}/{repo}/actions/dispatches`) and then polls for the result. This requires two metrics (trigger + poll), correlation of the dispatched run with the poll response, and handling of race conditions if multiple runs overlap.

The Job metric is the better fit because:

- Tests run inside the cluster against cluster-internal services — no external CI features are needed.
- The AnalysisRun has native lifecycle control over the Job (timeout, retry, cleanup).
- There is no dependency on Gitea availability during the analysis phase.
- The feedback loop is faster — no HTTP polling interval overhead.

The Gitea webhook approach is reserved for notifications (e.g. alerting on rollback) rather than driving the analysis itself.

### Failure handling

When analysis fails, Argo Rollouts automatically aborts the canary — the old stable version keeps serving traffic and users see no disruption. The Rollout enters a degraded state. A notification is sent to alert the team.

The git repository still contains the commit with the failed image tag. This creates a temporary drift between what git declares and what the cluster is running. This drift is intentional and self-healing: when a developer pushes a fix, CI builds a new image, and Image Updater (or the promotion workflow) commits the new tag to the same overlay. Argo Rollouts sees the new desired version, abandons the failed state, and starts a fresh rollout from the current stable version.

No automated git revert is needed. The natural flow of a new version superseding the failed one resolves the drift without additional automation. The promotion chain is already blocked — a failed analysis prevents the image tag from being committed to the next environment, so the bad version cannot spread.

Example: v1 is stable, v2 fails analysis, v3 is pushed as a fix.

1. v2 arrives. Rollouts deploys canary. Analysis fails. Rollouts aborts. v1 keeps serving.
2. Promotion to the next environment does not happen (v2 never passed).
3. Developer pushes a fix. CI builds v3. The new tag is committed to the same overlay.
4. Rollouts sees v3 as the new desired version, starts a fresh rollout from v1.
5. v3 passes analysis. Promoted. Chain continues to the next environment.

At no point does v2 reach any subsequent environment. The degraded state is temporary and clears automatically when the next version arrives.

## Acceptance Criteria

- [ ] Argo Rollouts controller is deployed to every cluster.
- [ ] Application workloads use Rollout resources instead of Deployments.
- [ ] Every deployment to every environment triggers an AnalysisRun before promotion.
- [ ] Failed analysis aborts the Rollout and keeps the old stable version serving traffic.
- [ ] Failed analysis sends a notification to alert the team.
- [ ] Failed analysis in any environment prevents promotion to the next environment.
- [ ] A new image version supersedes a failed rollout and starts a fresh canary from the stable version.
- [ ] Dev deployments are triggered automatically when a new image appears in the registry.
- [ ] QA deployments run performance and deep verification tests.
- [ ] Successful analysis triggers the promote workflow to commit the tag to the next environment.
- [ ] The promote workflow is agnostic — it only requires a source and target overlay path.
- [ ] The full promotion chain (dev → qa → staging → prod1 → prod2) runs automatically end-to-end.
- [ ] The e2e test suite is a container image built and pushed through the same CI pipeline.
- [ ] Verification runs as a Kubernetes Job via the Argo Rollouts Job metric provider.
- [ ] Environment-specific test configuration is defined per cluster overlay.
