output "clone_urls" {
  description = "Map of repository name to clone URL."
  value       = { for k, v in module.repo : k => v.clone_url }
}
