terraform {
  required_providers {
    kind = {
      source = "tehcyx/kind"
    }
  }
}


resource "kind_cluster" "this" {
  name           = var.name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      api_server_port = var.api_server_port
    }

    containerd_config_patches = [
      <<-TOML
      [plugins."io.containerd.grpc.v1.cri".registry]
        config_path = "/etc/containerd/certs.d"
      TOML
    ]

    node {
      role = "control-plane"

      kubeadm_config_patches = [
        yamlencode({
          kind = "InitConfiguration"
          nodeRegistration = {
            kubeletExtraArgs = {
              "node-labels" = join(",", [for k, v in var.node_labels : "${k}=${v}"])
            }
          }
        })
      ]

      extra_port_mappings {
        container_port = 80
        host_port      = var.http_host_port
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = var.https_host_port
        protocol       = "TCP"
      }
    }
  }
}

# Configure containerd on every node to use the local registry.
# triggers_replace ensures this re-runs whenever the cluster is recreated.
resource "terraform_data" "containerd_registry" {
  triggers_replace = kind_cluster.this.id

  provisioner "local-exec" {
    command = <<-BASH
      for node in $(kind get nodes --name "${var.name}" 2>/dev/null); do
        docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${var.registry.host_port}"
        echo '[host."http://${var.registry.name}:${var.registry.internal_port}"]' | \
          docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:${var.registry.host_port}/hosts.toml"
      done
    BASH
  }
}
