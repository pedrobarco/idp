variable "clusters" {
  description = "Map of cluster name to its configuration."
  type = map(object({
    api_server_port = number
    http_host_port  = number
    https_host_port = number
  }))
  default = {
    dev = {
      api_server_port = 6443
      http_host_port  = 80
      https_host_port = 443
    }
    staging = {
      api_server_port = 6444
      http_host_port  = 8080
      https_host_port = 8443
    }
    prod-1 = {
      api_server_port = 6445
      http_host_port  = 8081
      https_host_port = 8444
    }
    prod-2 = {
      api_server_port = 6446
      http_host_port  = 8082
      https_host_port = 8445
    }
  }
}

variable "registry" {
  description = "Local Docker registry configuration."
  type = object({
    name          = string
    host_port     = number
    internal_port = number
  })
  default = {
    name          = "kind-registry"
    host_port     = 5001
    internal_port = 5000
  }
}
