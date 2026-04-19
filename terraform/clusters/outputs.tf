output "cluster_endpoints" {
  description = "Map of cluster name to API server endpoint."
  value       = { for k, v in module.cluster : k => v.endpoint }
}

output "cluster_contexts" {
  description = "Map of cluster name to kubectl context name."
  value       = { for k, v in module.cluster : k => v.context_name }
}

output "registry_name" {
  description = "Name of the Docker registry container."
  value       = docker_container.registry.name
}
