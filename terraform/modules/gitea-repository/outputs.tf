output "clone_url" {
  description = "HTTP clone URL of the repository."
  value       = gitea_repository.this.clone_url
}
