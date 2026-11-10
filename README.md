<p align="center">
  <img src="docs/assets/logo.png" alt="IDP Logo" width="420">
  <br><br>
  <strong style="font-size:1.5em;">IDP — Internal Developer Platform</strong>
  <br>
  <em>A local multi-cluster GitOps platform running on <a href="https://kind.sigs.k8s.io/">kind</a>, managed by <a href="https://argo-cd.readthedocs.io/">ArgoCD</a>.</em>
</p>

## Quick Start

```bash
make run      # create clusters, install infra, activate GitOps
make status   # show platform status
make stop     # stop clusters without losing state
make start    # resume previously stopped clusters
make clean    # tear everything down
```

## Architecture

```mermaid
graph TB
    subgraph docker["Docker Network (kind)"]

        subgraph dev["dev cluster :80"]
            ArgoCD
            Gitea
            Kargo
            runner[Gitea Actions Runner]
            tls_proxy[Registry TLS Proxy]
            nginx_dev[ingress-nginx]
            rollouts_dev[Argo Rollouts]
            app_dev[hello-app<br/><i>dev/dev</i>]
        end

        subgraph staging["staging cluster :8080"]
            nginx_stg[ingress-nginx]
            rollouts_stg[Argo Rollouts]
            app_qa[hello-app<br/><i>staging/qa</i>]
            app_stage[hello-app<br/><i>staging/stage</i>]
        end

        subgraph prod1["prod-1 cluster :8081"]
            nginx_p1[ingress-nginx]
            rollouts_p1[Argo Rollouts]
            app_p1[hello-app<br/><i>prod-1/prod</i>]
        end

        subgraph prod2["prod-2 cluster :8082"]
            nginx_p2[ingress-nginx]
            rollouts_p2[Argo Rollouts]
            app_p2[hello-app<br/><i>prod-2/prod</i>]
        end

        registry["kind-registry :5001"]
    end

    Gitea -- "repo sync" --> ArgoCD
    Gitea -- "triggers" --> runner
    runner -- "build & push" --> registry
    tls_proxy -- "HTTPS proxy" --> registry
    Kargo -- "discovers images" --> tls_proxy
    Kargo -- "promotes freight" --> Gitea
    ArgoCD -- "manages" --> dev
    ArgoCD -- "manages" --> staging
    ArgoCD -- "manages" --> prod1
    ArgoCD -- "manages" --> prod2
```

Four kind clusters simulate a real multi-cluster environment:

| Cluster   | Role                                      | Port    |
| --------- | ----------------------------------------- | ------- |
| `dev`     | Hub — runs ArgoCD, Gitea, Kargo + Actions runner | `:80`   |
| `staging` | Remote — stage + qa namespaces            | `:8080` |
| `prod-1`  | Remote — prod namespace                   | `:8081` |
| `prod-2`  | Remote — prod namespace                   | `:8082` |

ArgoCD on the dev cluster manages all clusters. Gitea hosts the git repos that ArgoCD watches.

Argo CD, Gitea, and Kargo set memory requests and limits. Dex, notifications, the Kargo external webhook receiver, and Kargo API TLS are off. Give Docker about **8 GiB**. Image builds still spike above that because the Actions runner uses Docker-in-Docker.

## Repository Structure

```
.
├── scripts/                  # Playground scripts (run, clean, sync, status, stop, start)
├── terraform/                # Infrastructure as code (clusters, repositories, modules)
├── bootstrap/                # One-shot infra per cluster (applied by run.sh)
│   └── <cluster>/            # Kustomization referencing gitops/infrastructure/ bases
├── docs/                     # Platform and delivery specs
│
├── actions/                  # Shared CI, published as the actions repo
│   ├── build.sh
│   └── .gitea/workflows/build-and-push.yaml
│
├── gitops/                   # Desired state, published as the gitops repo
│   ├── infrastructure/       # Shared infra bases (Kustomize / Helm)
│   │   └── <component>/      # e.g. argocd, ingress-nginx, argo-rollouts, gitea, …
│   ├── applicationsets/      # ArgoCD ApplicationSet declarations
│   │   └── <component>.yaml  # Git directory generator → clusters/*/*/<component>
│   ├── apps/                 # App base manifests (Deployment, Service, Ingress, …)
│   │   └── <app>/
│   └── clusters/             # Per-target overlays (ArgoCD's source of truth)
│       └── <cluster>/
│           ├── <component>/  # Infra overlay (e.g. ingress-nginx, argo-rollouts, registry)
│           ├── <namespace>/
│           │   └── <app>/    # App overlay with per-env patches
│           └── <app>/
│               └── kargo-pipeline/  # Kargo promotion pipeline (project, warehouse, stages)
│
├── projects/                 # Application source code + CI workflows
│   └── <app>/
│
└── Makefile
```

## How It Works

### Setup Flow (`make run`)

0. **Terraform** — provision Docker network, registry, and 4 Kind clusters
1. **Secrets** — generate placeholder `.env` files for cluster credentials and a runner registration token for Gitea Actions
2. **Bootstrap** — build images + apply `bootstrap/<cluster>` in parallel
3. **Wait** — ArgoCD + Gitea rollouts
4. **Credentials** — generate real SA tokens, re-apply cluster secrets
5. **Repos** — provision Gitea repositories via Terraform
6. **Sync** — publish `gitops/`, `actions/`, and each `projects/*` to its own Gitea repo
7. **Activate** — apply root Application that tracks `gitops/applicationsets/`

### CI Pipeline

Each project in `projects/` includes a Gitea Actions workflow (`.gitea/workflows/ci.yaml`) that runs on push to `main`. The workflow calls the shared build-and-push workflow in the `actions` repo (`actions/.gitea/workflows/build-and-push.yaml`), which runs `actions/build.sh` and pushes the image to the local registry (`kind-registry:5000`).

The Gitea Actions runner is deployed as a pod with a DinD (Docker-in-Docker) sidecar on the dev cluster, managed by ArgoCD via the `gitea-actions` ApplicationSet. Runner configuration and DinD daemon config are generated by Kustomize `configMapGenerator` from plain files (`config.yaml`, `daemon.json`). The runner registration token is a shared secret generated at setup time and consumed by both Gitea and the runner via `secretGenerator` in the Gitea kustomization.

> **Note:** Cross-repo checkout in Gitea Actions requires `ref: main` to work around a missing API endpoint ([go-gitea/gitea#29654](https://github.com/go-gitea/gitea/issues/29654)).

### CD Pipeline

Kargo handles continuous delivery. A **Warehouse** watches the container registry for new image tags. When a new tag is detected, Kargo creates a **Freight** and promotes it through a pipeline of **Stages** (one per environment). Each Stage runs promotion steps: `git-clone` → `kustomize-set-image` → `git-commit` → `git-push` → `argocd-update`.

Since the Kind registry is HTTP-only, an nginx-based **TLS reverse proxy** (`registry-tls-proxy`) on the dev cluster provides HTTPS for Kargo image discovery. The proxy generates its own certificate when the pod starts. Kargo's admission webhooks use the chart default and ask cert-manager for a certificate. The API itself is HTTP behind the ingress, and the external webhook receiver is off.

See [progressive-delivery.md](docs/progressive-delivery.md) for the full promotion strategy and rollout specification.

### GitOps Loop

The `gitops/applicationsets/` directory contains ApplicationSet declarations. Each one uses a **git directory generator** that scans `clusters/*/*/<app>`. The directory path encodes the target inside the GitOps repo:

```
clusters/<cluster>/<namespace>/<app>/kustomization.yaml
```

Each matching directory becomes an ArgoCD Application. The kustomization references a base from `apps/<app>/` and applies per-target patches (replicas, env vars, image tags, ingress hosts).

### Adding a New App

1. Create the base manifests in `gitops/apps/<name>/`
2. Create overlays in `gitops/clusters/<cluster>/<namespace>/<name>/`
3. Create an ApplicationSet in `gitops/applicationsets/<name>.yaml`
4. Run `make sync` to push changes to Gitea

### Adding a New Cluster Target

1. Create `gitops/clusters/<cluster>/<namespace>/<app>/kustomization.yaml`
2. Run `make sync` — ArgoCD auto-discovers the new directory

### Platform Status (`make status`)

```
  NAME                                     STATUS             URL                                        CREDENTIALS
  ──────────────────────────────────────── ────────────────── ────────────────────────────────────────── ────────────────────
  argocd                                   Healthy            http://argocd.idp.localhost                admin / ••••••••
  gitea                                    Healthy            http://gitea.idp.localhost                 admin / ••••••••

  argo-rollouts
  argo-rollouts-argo-rollouts-dev          Synced/Healthy     -                                          -
  argo-rollouts-argo-rollouts-prod-1       Synced/Healthy     -                                          -
  argo-rollouts-argo-rollouts-prod-2       Synced/Healthy     -                                          -
  argo-rollouts-argo-rollouts-staging      Synced/Healthy     -                                          -

  gitea-actions
  gitea-actions-gitea-dev                  Synced/Healthy     -                                          -

  hello-app
  hello-app-dev-dev                        Synced/Healthy     http://hello-app.dev.idp.localhost         -
  hello-app-prod-prod-1                    Synced/Healthy     http://hello-app.prod.idp.localhost:8081   -
  hello-app-prod-prod-2                    Synced/Healthy     http://hello-app.prod.idp.localhost:8082   -
  hello-app-qa-staging                     Synced/Healthy     http://hello-app.qa.idp.localhost:8080     -
  hello-app-stage-staging                  Synced/Healthy     http://hello-app.stage.idp.localhost:8080  -

  ingress-nginx
  ingress-nginx-ingress-nginx-dev          Synced/Healthy     -                                          -
  ingress-nginx-ingress-nginx-prod-1       Synced/Healthy     -                                          -
  ingress-nginx-ingress-nginx-prod-2       Synced/Healthy     -                                          -
  ingress-nginx-ingress-nginx-staging      Synced/Healthy     -                                          -

  kargo
  kargo-kargo-dev                          Synced/Healthy     http://kargo.idp.localhost                 admin / ••••••••

  kargo-pipeline
  kargo-pipeline-hello-app-dev             Synced/Healthy     -                                          -

  registry
  registry-registry-dev                    Synced/Healthy     -                                          -
```

## Commands

| Command       | Description                                           |
| ------------- | ----------------------------------------------------- |
| `make run`    | Provision infrastructure and activate GitOps          |
| `make stop`   | Stop clusters without losing state (docker stop)      |
| `make start`  | Resume previously stopped clusters (docker start)     |
| `make clean`  | Destroy all infrastructure (terraform destroy)        |
| `make sync`   | Publish gitops, actions, and project folders to Gitea |
| `make status` | Show platform status                                  |
| `make help`   | List all targets                                      |

## Prerequisites

- [docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/)
- [helm](https://helm.sh/docs/intro/install/)
- [terraform](https://developer.hashicorp.com/terraform/install)
- curl, git
