resource "kubernetes_namespace" "neo4j" {
  metadata {
    name = var.neo4j_namespace
  }

  depends_on = [azurerm_kubernetes_cluster.this]
}

# Chart default: "If password is not set or empty a random password will be
# generated during installation" -- generating it here instead so Terraform
# can output it (and store a copy in Key Vault, see keyvault.tf) rather than
# reading it back out of pod logs. This remains the native-auth admin
# credential used by the onboarding pipeline even after OIDC is configured
# below (see README for why `native` stays enabled alongside OIDC).
resource "random_password" "neo4j" {
  length  = 24
  special = false
}

# OIDC/Entra ID config, added to neo4j.conf via the chart's `config` map,
# only once var.neo4j_oidc_client_id is set (i.e. after the one-time Entra
# app registration described in README.md exists). Until then the stack is
# still fully apply-able with native auth only.
#
# authorization_providers is "native", not "oidc-azure": identities
# authenticate via their Entra-issued token (oidc-azure), but which Neo4j
# roles they hold is still decided natively via GRANT ROLE, per the
# per-identity CREATE USER ... SET AUTH 'oidc-azure' {...} pattern in
# onboarding/cypher/onboard-tenant.cypher.tpl -- not by mapping Entra
# groups/app-roles directly to Neo4j roles.
locals {
  neo4j_oidc_config = var.neo4j_oidc_client_id != "" ? {
    "dbms.security.authentication_providers" = "oidc-azure,native"
    "dbms.security.authorization_providers"  = "native"
    "dbms.security.require_local_user"       = "true"

    "dbms.security.oidc.azure.display_name"             = "Azure"
    "dbms.security.oidc.azure.auth_flow"                = "pkce"
    "dbms.security.oidc.azure.audience"                 = var.neo4j_oidc_client_id
    "dbms.security.oidc.azure.issuer"                   = "https://login.microsoftonline.com/${var.entra_tenant_id}/v2.0"
    "dbms.security.oidc.azure.token_endpoint"           = "https://login.microsoftonline.com/${var.entra_tenant_id}/oauth2/v2.0/token"
    "dbms.security.oidc.azure.well_known_discovery_uri" = "https://login.microsoftonline.com/${var.entra_tenant_id}/v2.0/.well-known/openid-configuration"
    # sub is the only claim guaranteed stable/unique per Neo4j's own docs;
    # confirm it's actually populated for your app-only/client-credentials
    # tokens before onboarding identities against it (see README).
    "dbms.security.oidc.azure.claims.username" = "sub"
    "dbms.security.oidc.azure.config"          = "principal=sub;code_challenge_method=S256;token_type_principal=access_token;token_type_authentication=access_token"
    "dbms.security.oidc.azure.params"          = "client_id=${var.neo4j_oidc_client_id};response_type=code;scope=openid profile email api://${var.neo4j_oidc_client_id}/access-token"
  } : {}

  neo4j_helm_values = {
    # neo4j.name is mandatory: it ties together members of the same logical
    # Neo4j deployment; installation fails without it.
    neo4j = {
      name                   = var.neo4j_release_name
      edition                = var.neo4j_edition
      acceptLicenseAgreement = var.neo4j_accept_license_agreement
      resources = {
        cpu    = var.neo4j_cpu
        memory = var.neo4j_memory
      }
    }

    # volumes.data.mode has no default in the chart and must be set
    # explicitly. "dynamic" provisions a PVC against an explicitly named
    # StorageClass, which is more predictable across AKS versions than
    # relying on whichever StorageClass happens to be cluster-default.
    volumes = {
      data = {
        mode = "dynamic"
        dynamic = {
          storageClassName = var.neo4j_storage_class
          accessModes      = ["ReadWriteOnce"]
          requests = {
            storage = "${var.neo4j_data_disk_size_gb}Gi"
          }
        }
      }
    }

    # Exposes Neo4j Browser/HTTP/Bolt outside the cluster via an Azure Load
    # Balancer public IP. Set to ClusterIP instead if you'll only ever reach
    # Neo4j from inside the cluster or through your own ingress.
    services = {
      neo4j = {
        enabled = true
        spec = {
          type = "LoadBalancer"
        }
      }
    }

    # Schedules onto the matching tier's tainted node pool (node_pools.tf).
    nodeSelector = {
      workloadsize = var.neo4j_node_pool_tier
    }

    podSpec = {
      tolerations = [
        {
          key      = "workloadsize"
          operator = "Equal"
          value    = var.neo4j_node_pool_tier
          effect   = "NoSchedule"
        }
      ]
    }

    config = local.neo4j_oidc_config
  }
}

# Official Neo4j chart (neo4j/helm-charts, repo https://helm.neo4j.com/neo4j,
# chart name "neo4j" -- confirmed against the chart's own values.yaml, not
# the older/deprecated neo4j-contrib/neo4j-helm chart).
resource "helm_release" "neo4j" {
  name       = var.neo4j_release_name
  namespace  = kubernetes_namespace.neo4j.metadata[0].name
  repository = "https://helm.neo4j.com/neo4j"
  chart      = "neo4j"

  values = [yamlencode(local.neo4j_helm_values)]

  set_sensitive {
    name  = "neo4j.password"
    value = random_password.neo4j.result
  }

  depends_on = [
    azurerm_kubernetes_cluster_node_pool.small,
    azurerm_kubernetes_cluster_node_pool.large,
  ]
}
