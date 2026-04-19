variable "name" {
  description = "Name of the Kind cluster."
  type        = string
}

variable "api_server_port" {
  description = "Host port for the Kubernetes API server."
  type        = number
}

variable "http_host_port" {
  description = "Host port mapped to container port 80."
  type        = number
}

variable "https_host_port" {
  description = "Host port mapped to container port 443."
  type        = number
}

variable "node_labels" {
  description = "Extra labels applied to the control-plane node."
  type        = map(string)
  default     = { "ingress-ready" = "true" }
}

variable "registry" {
  description = "Local Docker registry configuration."
  type = object({
    name          = string
    host_port     = number
    internal_port = number
  })
}
