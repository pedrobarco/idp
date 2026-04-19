terraform {
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.7"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "kind" {}
provider "docker" {}

# ---------- Docker network ----------------------------------------------------
# Create the network before Kind so that Kind reuses it instead of creating
# its own.  This lets us attach the registry declaratively.

resource "docker_network" "kind" {
  name = "kind"
}

# ---------- Docker registry ---------------------------------------------------

resource "docker_image" "registry" {
  name         = "registry:2"
  force_remove = true
}

resource "docker_container" "registry" {
  name    = var.registry.name
  image   = docker_image.registry.image_id
  restart = "always"

  ports {
    internal = var.registry.internal_port
    external = var.registry.host_port
    ip       = "127.0.0.1"
  }

  networks_advanced {
    name = docker_network.kind.name
  }
}

# ---------- Kind clusters -----------------------------------------------------

module "cluster" {
  source   = "../modules/kind-cluster"
  for_each = var.clusters

  name            = each.key
  api_server_port = each.value.api_server_port
  http_host_port  = each.value.http_host_port
  https_host_port = each.value.https_host_port

  registry = var.registry

  depends_on = [docker_container.registry]
}
