terraform {
  required_providers {
    gitea = {
      source  = "go-gitea/gitea"
      version = "~> 0.6"
    }
  }
}

# The provider base_url must be a plain localhost URL (no subdomain)
# because the go-gitea/gitea provider rejects URLs that match both
# "localhost" and "." (RFC 2606 validation). Use kubectl port-forward
# to expose Gitea on a local port before running terraform apply.
provider "gitea" {
  base_url = var.gitea_url
  username = var.gitea_username
  password = var.gitea_password
}

module "repo" {
  source   = "../modules/gitea-repository"
  for_each = toset(var.repositories)

  name     = each.value
  username = var.gitea_username
}
