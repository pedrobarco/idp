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

| Transition      | Trigger                                  |
| --------------- | ---------------------------------------- |
| New image → dev | Automatic (Image Updater)                |
| dev → qa        | Automatic on successful dev verification |
| qa → staging    | Manual approval or PR-based              |
| staging → prod1 | Manual approval or PR-based              |
| prod1 → prod2   | Manual approval or PR-based              |

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

## Acceptance Criteria

- [ ] Argo Rollouts controller is deployed to every cluster.
- [ ] Application workloads use Rollout resources instead of Deployments.
- [ ] Every deployment to every environment triggers an AnalysisRun before promotion.
- [ ] Failed analysis causes automatic rollback with zero downtime.
- [ ] Dev deployments are triggered automatically when a new image appears in the registry.
- [ ] QA deployments run performance and deep verification tests.
- [ ] Staging and production deployments require manual approval before starting.
- [ ] The e2e test suite is a container image built and pushed through the same CI pipeline.
- [ ] Verification runs as a Kubernetes Job via the Argo Rollouts Job metric provider.
- [ ] Environment-specific test configuration is defined per cluster overlay.
- [ ] The full promotion chain (dev → qa → staging → prod1 → prod2) is operational.
