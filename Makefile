.PHONY: run clean sync status stop start help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

run: ## Create clusters, install infra, and activate GitOps
	@./scripts/run.sh

clean: ## Destroy all clusters and clean up
	@./scripts/clean.sh

stop: ## Stop clusters without losing state
	@./scripts/stop.sh

start: ## Start previously stopped clusters
	@./scripts/start.sh

sync: ## Sync repos to Gitea
	@./scripts/sync-projects.sh

status: ## Show platform status (applications, URLs, credentials)
	@./scripts/status.sh
