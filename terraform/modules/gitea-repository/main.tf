terraform {
  required_providers {
    gitea = {
      source = "go-gitea/gitea"
    }
  }
}

resource "gitea_repository" "this" {
  username       = var.username
  name           = var.name
  auto_init      = var.auto_init
  default_branch = var.default_branch
  private        = var.private
}
