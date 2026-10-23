module "tempo" {
  source = "../.."

  tenants = {
    acme   = {}
    globex = { retention = "720h", max_traces_per_user = 50000 }
  }

  s3 = {
    endpoint          = var.s3_endpoint
    bucket            = var.s3_bucket
    region            = "garage"
    access_key_id     = var.s3_access_key_id
    secret_access_key = var.s3_secret_access_key
    insecure          = true
  }

  storage_class = "local-path"

  httproute = {
    hostname          = "tempo.example.com"
    gateway_name      = "public-gateway"
    gateway_namespace = "infrastructure"
    # acme -> tempo-acme-<8 random chars>.example.com; the listener must
    # terminate TLS with a certificate for *.example.com.
    tenant_hostnames = { domain = "example.com" }
  }
}

output "tenants" {
  value     = module.tempo.tenants
  sensitive = true
}
