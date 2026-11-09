variable "name" {
  description = "Repository name."
  type        = string
}

variable "username" {
  description = "Owner of the repository."
  type        = string
}

variable "auto_init" {
  description = "Whether to auto-initialize the repository. Leave false so the first subtree push can create main."
  type        = bool
  default     = false
}

variable "default_branch" {
  description = "Default branch name."
  type        = string
  default     = "main"
}

variable "private" {
  description = "Whether the repository is private."
  type        = bool
  default     = false
}
