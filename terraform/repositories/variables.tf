variable "gitea_url" {
  description = "Base URL of the Forgejo instance (e.g. http://localhost:3000)."
  type        = string
}

variable "gitea_username" {
  description = "Forgejo admin username."
  type        = string
}

variable "gitea_password" {
  description = "Forgejo admin password."
  type        = string
  sensitive   = true
}

variable "repositories" {
  description = "List of repository names to create."
  type        = list(string)
  default     = ["gitops", "actions", "hello-app"]
}
