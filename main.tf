locals {
  # The chart names its resources after the release when the release name
  # contains the chart name ("tempo"), else <release>-tempo.
  tempo_service   = strcontains(var.release_name, "tempo") ? var.release_name : "${var.release_name}-tempo"
  tempo_http      = "http://${local.tempo_service}.${var.namespace}.svc.cluster.local:3200"
  tempo_otlp_http = "http://${local.tempo_service}.${var.namespace}.svc.cluster.local:4318"

  gateway_service = "${var.release_name}-gateway"
  gateway_labels  = { "app.kubernetes.io/name" = local.gateway_service, "app.kubernetes.io/part-of" = var.release_name }
  internal_url    = "http://${local.gateway_service}.${var.namespace}.svc.cluster.local"
  external_url    = var.httproute != null ? "https://${var.httproute.hostname}" : null

  # Per-tenant public hostnames: <prefix>-<tenant>-<random suffix>.<domain>.
  # "_" is valid in a tenant ID but not in a hostname.
  per_tenant_hostnames = var.httproute != null && try(var.httproute.tenant_hostnames, null) != null
  tenant_hostname = local.per_tenant_hostnames ? {
    for t in keys(var.tenants) :
    t => "${var.httproute.tenant_hostnames.prefix}-${replace(t, "_", "-")}-${random_string.tenant_suffix[t].result}.${var.httproute.tenant_hostnames.domain}"
  } : {}
  tenant_external_url = {
    for t in keys(var.tenants) : t => local.per_tenant_hostnames ? "https://${local.tenant_hostname[t]}" : local.external_url
  }

  # Hostnames the gateway serves for any authenticated tenant: the in-cluster
  # service names (Grafana, in-cluster collectors) and local port-forwards.
  # They are not reachable through the public Gateway, whose routes only carry
  # the public hostnames.
  internal_hostnames = [
    local.gateway_service,
    "${local.gateway_service}.${var.namespace}",
    "${local.gateway_service}.${var.namespace}.svc",
    "${local.gateway_service}.${var.namespace}.svc.cluster.local",
    "localhost",
    "127.0.0.1",
  ]
  nginx_host_map = join("\n", concat(
    [for h in local.internal_hostnames : "    ${h} \"*\";"],
    [for t in sort(keys(local.tenant_hostname)) : "    ${local.tenant_hostname[t]} \"${t}\";"],
  ))

  # Per-tenant limits for Tempo's runtime overrides. Each tenant gets every
  # limit explicitly, so changing default_limits applies to all of them.
  tenant_overrides = {
    for t, cfg in var.tenants : t => {
      ingestion = {
        rate_limit_bytes    = coalesce(cfg.ingestion_rate_limit_bytes, var.default_limits.ingestion_rate_limit_bytes)
        burst_size_bytes    = coalesce(cfg.ingestion_burst_size_bytes, var.default_limits.ingestion_burst_size_bytes)
        max_traces_per_user = coalesce(cfg.max_traces_per_user, var.default_limits.max_traces_per_user)
      }
      compaction = {
        block_retention = coalesce(cfg.retention, var.default_limits.retention)
      }
    }
  }

  htpasswd = join("\n", [
    for t in sort(keys(var.tenants)) : "${t}:${random_password.tenant[t].bcrypt_hash}"
  ])

  # The monolithic chart has no gateway, so the module runs its own nginx in
  # front of Tempo: basic auth per tenant, and a tenant check that rejects
  # (403) any request whose X-Scope-OrgID differs from the authenticated user.
  # "/" (the health path) stays open. The check runs in the rewrite phase,
  # before auth_basic: a right header with a wrong password still gets 401
  # afterwards. Every proxied request also gets X-Scope-OrgID rewritten to the
  # authenticated user, so Tempo never sees another tenant's ID.
  #
  # With per-tenant hostnames the Host must also belong to that tenant
  # ($tenant_host = tenant), or be an in-cluster name ($tenant_host = "*").
  # Any other Host, the shared public hostname included, only serves "/".
  nginx_tenant_maps = local.per_tenant_hostnames ? local.nginx_tenant_maps_per_tenant : local.nginx_tenant_maps_shared

  nginx_tenant_maps_per_tenant = <<-EOT
    map $uri $tenant_check_public {
      "/"      1;
      default  0;
    }
    map $host $tenant_host {
      hostnames;
      default "";
    ${local.nginx_host_map}
    }
    map "$tenant_check_public:$tenant_host:$remote_user:$http_x_scope_orgid" $tenant_check_ok {
      "~^1:"                      1;
      "~^0:\*:([^:|]+):\1$"       1;
      "~^0:([^:|*]+):\1:\1$"      1;
      default                     0;
    }
  EOT

  nginx_tenant_maps_shared = <<-EOT
    map $uri $tenant_check_public {
      "/"      1;
      default  0;
    }
    map "$tenant_check_public:$remote_user:$http_x_scope_orgid" $tenant_check_ok {
      "~^1:"                1;
      "~^0:([^:|]+):\1$"    1;
      default               0;
    }
  EOT

  nginx_conf = <<-EOT
    worker_processes  2;
    error_log         /dev/stderr warn;
    pid               /tmp/nginx.pid;
    events {
      worker_connections 1024;
    }
    http {
      client_body_temp_path /tmp/client_temp;
      proxy_temp_path       /tmp/proxy_temp;
      fastcgi_temp_path     /tmp/fastcgi_temp;
      uwsgi_temp_path       /tmp/uwsgi_temp;
      scgi_temp_path        /tmp/scgi_temp;
      client_max_body_size  ${var.gateway_max_body_size};
      proxy_read_timeout    300;
      proxy_send_timeout    300;
      proxy_http_version    1.1;
      default_type          application/octet-stream;
      log_format main '$remote_addr - $remote_user [$time_local] $status "$request" $body_bytes_sent "$http_user_agent"';
      access_log /dev/stderr main;

    ${local.nginx_tenant_maps}
      server {
        listen 8080;
        listen [::]:8080;
        auth_basic           "Tempo";
        auth_basic_user_file /etc/nginx/secrets/.htpasswd;

        if ($tenant_check_ok = 0) {
          return 403 "use your tenant's hostname with its basic auth and X-Scope-OrgID equal to the user\n";
        }

        location = / {
          auth_basic off;
          return 200 'OK';
        }
        # OTLP/HTTP ingest (both paths clients commonly use).
        location = /v1/traces {
          proxy_set_header X-Scope-OrgID $remote_user;
          proxy_pass ${local.tempo_otlp_http}/v1/traces;
        }
        location = /otlp/v1/traces {
          proxy_set_header X-Scope-OrgID $remote_user;
          proxy_pass ${local.tempo_otlp_http}/v1/traces;
        }
        # Query API (Grafana): /api/echo, /api/search, /api/traces/<id>, /api/v2/...
        # No URI part and no variables in proxy_pass: nginx then forwards the
        # request URI as is and resolves the upstream at startup (no resolver).
        location ^~ /api {
          proxy_set_header X-Scope-OrgID $remote_user;
          proxy_pass ${local.tempo_http};
        }
      }
    }
  EOT

  module_values = {
    replicas = 1

    tempo = {
      multitenancyEnabled = true
      reportingEnabled    = false
      # Global block retention (backend scheduler); tenants override it.
      retention = var.default_limits.retention

      # Tenants not listed in var.tenants cannot authenticate, but keep the
      # global defaults equal to default_limits anyway.
      overrides = {
        defaults = {
          ingestion = {
            rate_limit_bytes    = var.default_limits.ingestion_rate_limit_bytes
            burst_size_bytes    = var.default_limits.ingestion_burst_size_bytes
            max_traces_per_user = var.default_limits.max_traces_per_user
          }
          compaction = {
            block_retention = var.default_limits.retention
          }
        }
        per_tenant_override_config = "/conf/overrides.yaml"
      }
      per_tenant_overrides = local.tenant_overrides

      storage = {
        trace = {
          backend = "s3"
          s3 = {
            bucket         = var.s3.bucket
            endpoint       = var.s3.endpoint
            region         = var.s3.region
            access_key     = var.s3.access_key_id
            secret_key     = var.s3.secret_access_key
            insecure       = var.s3.insecure
            forcepathstyle = var.s3.force_path_style
          }
        }
      }

      # OTLP only on the public side (the gateway proxies /v1/traces to 4318);
      # the chart keeps its Jaeger receivers on the in-cluster Service.
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      }
    }

    persistence = merge(
      { enabled = true, size = var.storage_size },
      var.storage_class != null ? { storageClassName = var.storage_class } : {},
    )
  }
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
  }
}

resource "random_password" "tenant" {
  for_each = var.tenants

  length  = 48
  special = false
}

# Random part of each tenant's public hostname. Rotate it with
# terraform apply -replace='module.<name>.random_string.tenant_suffix["<tenant>"]'.
resource "random_string" "tenant_suffix" {
  for_each = local.per_tenant_hostnames ? var.tenants : {}

  length  = var.httproute.tenant_hostnames.suffix_length
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "helm_release" "tempo" {
  name       = var.release_name
  repository = var.chart_repository
  chart      = "tempo"
  version    = var.chart_version
  namespace  = kubernetes_namespace.this.metadata[0].name
  timeout    = 900
  wait       = true

  values = [
    yamlencode(local.module_values),
    yamlencode(var.values),
  ]
}

# ---------------------------------------------------------------------------
# Gateway: nginx with basic auth and the tenant check, in front of Tempo.
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "htpasswd" {
  metadata {
    name      = "${local.gateway_service}-htpasswd"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    ".htpasswd" = local.htpasswd
  }
}

resource "kubernetes_config_map" "gateway" {
  metadata {
    name      = local.gateway_service
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    "nginx.conf" = local.nginx_conf
  }
}

resource "kubernetes_deployment" "gateway" {
  metadata {
    name      = local.gateway_service
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.gateway_labels
  }

  spec {
    replicas = var.gateway_replicas

    selector {
      match_labels = { "app.kubernetes.io/name" = local.gateway_service }
    }

    template {
      metadata {
        labels = local.gateway_labels
        annotations = {
          "checksum/nginx-conf" = sha256(local.nginx_conf)
          "checksum/htpasswd"   = sha256(local.htpasswd)
        }
      }

      spec {
        container {
          name              = "nginx"
          image             = var.gateway_image
          image_pull_policy = "Always"

          port {
            name           = "http"
            container_port = 8080
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }
          volume_mount {
            name       = "htpasswd"
            mount_path = "/etc/nginx/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          # Empty dir over the image's entrypoint scripts: they edit
          # /etc/nginx/conf.d, which does not exist with our nginx.conf.
          volume_mount {
            name       = "entrypoint"
            mount_path = "/docker-entrypoint.d"
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 3
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 10
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "500m", memory = "128Mi" }
          }

          security_context {
            run_as_non_root            = true
            read_only_root_filesystem  = true
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.gateway.metadata[0].name
          }
        }
        volume {
          name = "htpasswd"
          secret {
            secret_name = kubernetes_secret.htpasswd.metadata[0].name
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
        volume {
          name = "entrypoint"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [helm_release.tempo]
}

resource "kubernetes_service" "gateway" {
  metadata {
    name      = local.gateway_service
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.gateway_labels
  }
  spec {
    selector = { "app.kubernetes.io/name" = local.gateway_service }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

resource "kubectl_manifest" "httproute" {
  count = var.httproute != null ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = local.gateway_service
      namespace = var.namespace
    }
    spec = {
      parentRefs = [{
        name        = var.httproute.gateway_name
        namespace   = var.httproute.gateway_namespace
        sectionName = var.httproute.section_name
      }]
      hostnames = concat([var.httproute.hostname], [for t in sort(keys(local.tenant_hostname)) : local.tenant_hostname[t]])
      rules = [{
        matches     = [{ path = { type = "PathPrefix", value = "/" } }]
        backendRefs = [{ name = local.gateway_service, port = 80 }]
      }]
    }
  })

  depends_on = [kubernetes_service.gateway]
}
