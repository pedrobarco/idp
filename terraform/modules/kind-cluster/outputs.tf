output "endpoint" {
  description = "Cluster API server endpoint."
  value       = kind_cluster.this.endpoint
}

output "kubeconfig" {
  description = "Raw kubeconfig for the cluster."
  value       = kind_cluster.this.kubeconfig
  sensitive   = true
}

output "context_name" {
  description = "kubectl context name for this cluster."
  value       = "kind-${var.name}"
}
