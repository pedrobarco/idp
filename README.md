# IDP — Internal Developer Platform

A local multi-cluster GitOps platform running on [kind](https://kind.sigs.k8s.io/), managed by [ArgoCD](https://argo-cd.readthedocs.io/).

## Quick Start

```bash
make run      # create clusters, install infra, activate GitOps
make status   # show platform status
make clean    # tear everything down
```

## Architecture

Four kind clusters simulate a real multi-cluster environment:

| Cluster   | Role                           | Port    |
| --------- | ------------------------------ | ------- |
| `dev`     | Hub — runs ArgoCD + Gitea      | `:80`   |
| `staging` | Remote — stage + qa namespaces | `:8080` |
| `prod-1`  | Remote — prod namespace        | `:8081` |
| `prod-2`  | Remote — prod namespace        | `:8082` |

ArgoCD on the dev cluster manages all clusters. Gitea hosts the git repos that ArgoCD watches.

## Repository Structure

```
.
├── scripts/                # Operational scripts
│   ├── run.sh              # Full setup (clusters → bootstrap → GitOps)
│   ├── clean.sh            # Full teardown
│   ├── status.sh           # Platform status
│   ├── sync-projects.sh    # Push repos to Gitea
│   └── utils.sh            # Shared config and helpers
│
├── infrastructure/         # Shared infra definitions (never applied directly)
│   ├── argocd/             # ArgoCD Helm chart
│   ├── gitea/              # Gitea Helm chart
│   ├── ingress-nginx/      # Ingress controller
│   ├── argocd-manager/     # Remote cluster SA + RBAC
│   └── registry/           # Local registry ConfigMap
│
├── bootstrap/              # One-shot infra per cluster (applied by run.sh)
│   ├── dev/                # ArgoCD + Gitea + ingress-nginx + registry + cluster secrets
│   ├── staging/            # argocd-manager + ingress-nginx + registry
│   ├── prod-1/             # argocd-manager + ingress-nginx + registry
│   └── prod-2/             # argocd-manager + ingress-nginx + registry
│
├── applicationsets/        # ArgoCD ApplicationSet declarations
│   ├── applicationsets.yaml  # Root Application (tracks this directory)
│   └── hello-app.yaml       # Git directory generator for hello-app
│
├── apps/                   # App base manifests (never applied directly)
│   └── hello-app/          # Deployment, Service, Ingress
│
├── clusters/               # Per-target overlays (ArgoCD's source of truth)
│   ├── dev/dev/hello-app/
│   ├── staging/stage/hello-app/
│   ├── staging/qa/hello-app/
│   ├── prod-1/prod/hello-app/
│   └── prod-2/prod/hello-app/
│
├── projects/               # Application source code
│   └── hello-app/          # Go app + Dockerfile + CI script
│
├── kind/                   # Kind cluster configs
└── Makefile
```

## How It Works

### Setup Flow (`make run`)

1. **Create clusters** — 4 kind clusters in parallel
2. **Bootstrap** — build images + apply `bootstrap/<cluster>` in parallel
3. **Wait** — ArgoCD, Gitea, ingress-nginx rollouts
4. **Credentials** — generate SA tokens, patch cluster secrets
5. **Sync** — push IDP repo + projects to Gitea
6. **Activate** — apply root Application that tracks `applicationsets/`

### GitOps Loop

The `applicationsets/` directory contains ApplicationSet declarations. Each one uses a **git directory generator** that scans `clusters/*/*/<app>`. The directory path encodes the target:

```
clusters/<cluster>/<namespace>/<app>/kustomization.yaml
```

Each matching directory becomes an ArgoCD Application. The kustomization references a base from `apps/<app>/` and applies per-target patches (replicas, env vars, image tags, ingress hosts).

### Adding a New App

1. Create the base manifests in `apps/<name>/`
2. Create overlays in `clusters/<cluster>/<namespace>/<name>/`
3. Create an ApplicationSet in `applicationsets/<name>.yaml`
4. Run `make sync` to push changes to Gitea

### Adding a New Cluster Target

1. Create `clusters/<cluster>/<namespace>/<app>/kustomization.yaml`
2. Run `make sync` — ArgoCD auto-discovers the new directory

## Commands

| Command       | Description                         |
| ------------- | ----------------------------------- |
| `make run`    | Create clusters and activate GitOps |
| `make clean`  | Destroy all clusters                |
| `make sync`   | Push repos to Gitea                 |
| `make status` | Show platform status                |
| `make help`   | List all targets                    |

## Prerequisites

- [docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/)
- [helm](https://helm.sh/docs/intro/install/)
- curl, git
