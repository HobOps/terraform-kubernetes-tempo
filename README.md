# terraform-kubernetes-tempo

Terraform module that installs a **multi-tenant Grafana Tempo** (chart
`grafana-community/tempo`, monolithic mode, Tempo 3) for a central traces
cluster: one tenant per customer, basic auth per tenant, per-tenant limits and
retention, S3 object storage, an nginx gateway that binds the tenant to the
authenticated user, and an optional Gateway API route for remote clients
(OTLP/HTTP from Grafana Alloy, the OpenTelemetry SDKs or collectors).

It is the traces twin of
[`terraform-kubernetes-mimir`](https://github.com/HobOps/terraform-kubernetes-mimir)
and [`terraform-kubernetes-loki`](https://github.com/HobOps/terraform-kubernetes-loki):
same inputs, same tenant binding, same outputs, so a tenant that exists in the
three gets the same username and the same kind of hostname.

Providers (`helm`, `kubernetes`, `kubectl`, `random`) are configured by the
**caller**. Where the tenant credentials end up (Vault, SOPS, a Grafana
datasource) is also the caller's choice: the module only outputs them.

## What it deploys

| Piece | Choice |
|---|---|
| Tempo | **Monolithic** (one StatefulSet, one replica): Tempo 3's in-process ingest path, no Kafka. The microservices chart (`tempo-distributed` 3.x) needs Kafka; this module targets labs and a handful of customers |
| Storage | One S3 bucket for trace blocks (Tempo keys them by tenant); a volume on `storage_class` for the WAL |
| Gateway | The module's own nginx (`gateway_image`, unprivileged) with basic auth; one random password per tenant |
| Tenant binding | `X-Scope-OrgID` **must equal the authenticated user**, or the gateway answers 403; every proxied request also gets the header rewritten to the user |
| Per-tenant hostnames | Optional: `<prefix>-<tenant>-<random suffix>.<domain>` per tenant; a tenant's credentials only work on its own hostname |
| Limits | Per-tenant runtime overrides (ingestion rate/burst in bytes/s, live traces, block retention) |
| Public paths | `/v1/traces` and `/otlp/v1/traces` (OTLP/HTTP ingest), `/api/...` (queries, what a Grafana Tempo datasource uses), `/` (health, no auth) |

Not exposed through the gateway: OTLP/gRPC, Jaeger and Zipkin receivers (they
stay on the in-cluster Tempo Service), and Grafana's gRPC streaming (disable
`streamingEnabled` in the datasource).

### Why the tenant binding

Tempo takes the tenant from the `X-Scope-OrgID` header. Behind plain basic
auth a client with valid credentials could write to or read from any tenant.
The gateway rejects requests whose header differs from the basic-auth user and
sets the header to the user on every proxied request. Tenant federation is
therefore not possible through the gateway.

### Per-tenant hostnames

With `httproute.tenant_hostnames`, every tenant gets its own public hostname,
`<prefix>-<tenant>-<random suffix>.<domain>` (suffix: lowercase letters and
digits, `suffix_length` long), all on the same HTTPRoute. The gateway maps the
`Host` to a tenant and requires it to match the authenticated user too, so a
tenant's credentials are useless on another tenant's hostname and on the shared
hostname (which then only answers `/`). The in-cluster service names
(`<release>-gateway.<namespace>.svc...`) keep serving every tenant, for Grafana
and collectors inside the cluster.

The `domain` must be covered by the listener's certificate. A wildcard
certificate (`*.<domain>`) keeps the tenant hostnames out of Certificate
Transparency logs; external-dns still publishes one record per hostname.

## Usage

```hcl
module "tempo" {
  source = "git::https://github.com/HobOps/terraform-kubernetes-tempo.git?ref=v0.0.1"

  tenants = {
    acme   = {}
    globex = { retention = "720h", max_traces_per_user = 50000 }
  }

  s3 = {
    endpoint          = "s3.example.internal:3900"
    bucket            = "tempo"
    region            = "garage"
    access_key_id     = var.s3_access_key_id
    secret_access_key = var.s3_secret_access_key
    insecure          = true # plain HTTP
  }

  storage_class = "local-path"

  httproute = {
    hostname          = "tempo.example.com"
    gateway_name      = "public-gateway"
    gateway_namespace = "infrastructure"
    # Optional: one hostname per tenant under a wildcard certificate.
    tenant_hostnames = { domain = "example.com" }
  }
}
```

A client sends OTLP/HTTP with basic auth `acme:<password>` and the header
`X-Scope-OrgID: acme` to `https://tempo-acme-<suffix>.example.com/v1/traces`
(`https://tempo.example.com/v1/traces` without `tenant_hostnames`); a Grafana
Tempo datasource takes the same base URL (`query_url`) with the same basic
auth and header. The exact URLs are in the `tenants` output.

See [`examples/complete`](examples/complete).

## Inputs

| Name | Description | Default |
|---|---|---|
| `tenants` | Map of tenant ID → optional `retention`, `ingestion_rate_limit_bytes`, `ingestion_burst_size_bytes`, `max_traces_per_user` | `{}` |
| `default_limits` | Limits for every tenant unless overridden | 168h, 15 MB/s, burst 20 MB, 10000 traces |
| `s3` | `endpoint`, `bucket`, `region`, `access_key_id`, `secret_access_key`, `insecure`, `force_path_style` | required |
| `namespace` | Namespace (created) | `tempo` |
| `release_name` | Helm release name; the gateway Service is `<release>-gateway` | `tempo` |
| `chart_repository` / `chart_version` | `grafana-community/tempo` chart | `https://grafana-community.github.io/helm-charts` / `3.2.1` |
| `storage_class` / `storage_size` | Volume of the Tempo pod | cluster default / `10Gi` |
| `gateway_image` / `gateway_replicas` / `gateway_max_body_size` | nginx gateway | `nginx-unprivileged:1.29-alpine@sha256:…` / `1` / `32m` |
| `httproute` | `hostname`, `gateway_name`, `gateway_namespace`, `section_name`, optional `tenant_hostnames` (`domain`, `prefix` = `tempo`, `suffix_length` = 8) | `null` |
| `values` | Extra chart values, merged after the module's | `{}` |

## Outputs

| Name | Description |
|---|---|
| `namespace` | Namespace |
| `internal_url` | In-cluster gateway URL |
| `external_url` | Shared public URL (with `httproute`); health path only when `tenant_hostnames` is set |
| `tenants` | Sensitive: per tenant `username`, `password`, `hostname`, `otlp_http_url`, `query_url`, `otlp_http_url_internal`, `query_url_internal` |

## Notes

- Tenant IDs: lowercase letters, digits, `-` and `_`.
- `retention` values are Go durations ("168h", "720h").
- One replica: a Tempo restart loses nothing durable (WAL on the volume,
  blocks in S3) but pauses ingest for a few seconds. Scaling out means the
  microservices chart with Kafka.
- Removing a tenant removes its password (it can no longer push or query); its
  blocks stay in the bucket until retention deletes them.
- Rotating a tenant's password:
  `terraform apply -replace='module.<name>.random_password.tenant["<tenant>"]'`.
  Rotating its hostname suffix:
  `terraform apply -replace='module.<name>.random_string.tenant_suffix["<tenant>"]'`.
  Then hand the client the new values from the `tenants` output.
- Upgrading the chart: re-check `tempo.overrides`, `tempo.per_tenant_overrides`
  and `tempo.storage.trace.s3` keep their shape, and that the Service still
  exposes 3200 and 4318.
