output "namespace" {
  description = "Namespace where Tempo runs."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "internal_url" {
  description = "In-cluster base URL of the Tempo gateway (basic auth required)."
  value       = local.internal_url
}

output "external_url" {
  description = "Shared public base URL of the Tempo gateway when httproute is set, else null. With tenant_hostnames it only answers the health path."
  value       = local.external_url
}

output "tenants" {
  description = <<-EOT
    Credentials and endpoints per tenant. Send basic auth with username/password
    and the header X-Scope-OrgID equal to the username. *_url_internal work
    inside the cluster; hostname, otlp_http_url and query_url are the public
    ones (null without httproute; the tenant's own hostname with
    tenant_hostnames, else the shared one). query_url is the base URL a Grafana
    Tempo datasource takes; otlp_http_url is the full OTLP/HTTP traces endpoint.
  EOT
  sensitive   = true
  value = {
    for t in keys(var.tenants) : t => {
      username               = t
      password               = random_password.tenant[t].result
      hostname               = local.per_tenant_hostnames ? local.tenant_hostname[t] : try(var.httproute.hostname, null)
      otlp_http_url          = local.tenant_external_url[t] != null ? "${local.tenant_external_url[t]}/v1/traces" : null
      query_url              = local.tenant_external_url[t]
      otlp_http_url_internal = "${local.internal_url}/v1/traces"
      query_url_internal     = local.internal_url
    }
  }
}
