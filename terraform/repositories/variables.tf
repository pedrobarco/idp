variable "gitea_url" {
  description = "Base URL of the Gitea instance (e.g. http://gitea.dev.localhost)."
  type        = string
}

variable "gitea_username" {
  description = "Gitea admin username."
  type        = string
}

variable "gitea_password" {
  description = "Gitea admin password."
  type        = string
  sensitive   = true
}

variable "repositories" {
  description = "List of repository names to create."
  type        = list(string)
  default     = ["idp", "hello-app"]
}
