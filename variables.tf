variable "namespace" {
  description = "Namespace for Tempo (created by the module)."
  type        = string
  default     = "tempo"
}

variable "release_name" {
  description = "Helm release name. The gateway Service is <release>-gateway."
  type        = string
  default     = "tempo"
}

variable "chart_repository" {
  description = "Helm repository of the grafana-community/tempo chart (monolithic Tempo)."
  type        = string
  default     = "https://grafana-community.github.io/helm-charts"
}

variable "chart_version" {
  description = "Version of the tempo chart."
  type        = string
  default     = "3.2.1"
}

variable "s3" {
  description = <<-EOT
    S3-compatible object storage for trace blocks (one bucket; Tempo keys
    objects by tenant). `endpoint` is host:port without scheme;
    `insecure = true` means plain HTTP. Path-style addressing suits Garage and
    MinIO.
  EOT
  type = object({
    endpoint          = string
    bucket            = string
    region            = optional(string, "us-east-1")
    access_key_id     = string
    secret_access_key = string
    insecure          = optional(bool, false)
    force_path_style  = optional(bool, true)
  })
  sensitive = true
}

variable "tenants" {
  description = <<-EOT
    Tenants, keyed by tenant ID (also the basic-auth username). One per
    customer: hosts and services go in resource attributes, not in tenants.
    Every field is optional and falls back to `default_limits`; values use
    Tempo's names and units (retention like "168h"; rates in bytes/s).
  EOT
  type = map(object({
    retention                  = optional(string)
    ingestion_rate_limit_bytes = optional(number)
    ingestion_burst_size_bytes = optional(number)
    max_traces_per_user        = optional(number)
  }))
  default = {}

  validation {
    condition     = alltrue([for t in keys(var.tenants) : can(regex("^[a-z0-9][a-z0-9_-]{0,149}$", t))])
    error_message = "Tenant IDs must be lowercase letters, digits, '-' or '_' (no ':' or '|')."
  }
}

variable "default_limits" {
  description = "Limits applied to every tenant unless the tenant overrides them (Tempo's defaults: 15 MB/s, burst 20 MB, 10000 live traces)."
  type = object({
    retention                  = optional(string, "168h")
    ingestion_rate_limit_bytes = optional(number, 15000000)
    ingestion_burst_size_bytes = optional(number, 20000000)
    max_traces_per_user        = optional(number, 10000)
  })
  default = {}
}

variable "storage_class" {
  description = "StorageClass for the Tempo volume (WAL and local blocks before upload). null = cluster default. Durable data lives in S3."
  type        = string
  default     = null
}

variable "storage_size" {
  description = "Volume size of the Tempo pod."
  type        = string
  default     = "10Gi"
}

variable "gateway_image" {
  description = "nginx image of the gateway (unprivileged, listens on 8080)."
  type        = string
  default     = "docker.io/nginxinc/nginx-unprivileged:1.29-alpine"
}

variable "gateway_replicas" {
  description = "Replicas of the nginx gateway."
  type        = number
  default     = 1
}

variable "gateway_max_body_size" {
  description = "nginx client_max_body_size for OTLP batches."
  type        = string
  default     = "32m"
}

variable "httproute" {
  description = <<-EOT
    Optional Gateway API HTTPRoute to the gateway (OTLP/HTTP ingest and
    queries for remote clients). null = no route.

    `hostname` is the shared public hostname. With `tenant_hostnames` set, every
    tenant also gets its own hostname `<prefix>-<tenant>-<random suffix>.<domain>`
    and the gateway accepts a tenant's credentials only on that hostname (or on
    the in-cluster service names); the shared hostname then answers only the
    health path. `domain` must be covered by the listener's certificate: a
    wildcard keeps the tenant names out of Certificate Transparency.
  EOT
  type = object({
    hostname          = string
    gateway_name      = string
    gateway_namespace = string
    section_name      = optional(string, "https")
    tenant_hostnames = optional(object({
      domain        = string
      prefix        = optional(string, "tempo")
      suffix_length = optional(number, 8)
    }))
  })
  default = null
}

variable "values" {
  description = "Extra values for the tempo chart, applied after the module's (Helm deep-merges maps; lists replace)."
  type        = any
  default     = {}
}
