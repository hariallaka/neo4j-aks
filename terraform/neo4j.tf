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

  # One Helm values map shared by every cluster member: Neo4j clustering
  # ties members together by `neo4j.name` (identical across all of them),
  # not by Helm release name (which is unique per member -- see
  # helm_release.neo4j below). Every member also needs the same
  # minimumClusterSize so each one waits for the others to appear before
  # reporting ready.
  neo4j_helm_values = {
    # neo4j.name is mandatory: it ties together members of the same logical
    # Neo4j deployment; installation fails without it.
    neo4j = {
      name                   = var.neo4j_release_name
      edition                = var.neo4j_edition
      acceptLicenseAgreement = var.neo4j_accept_license_agreement
      minimumClusterSize     = var.neo4j_cluster_size
      resources = {
        cpu    = var.neo4j_cpu
        memory = var.neo4j_memory
      }
      # podSpec.podAntiAffinity defaults to true in the chart, which already
      # prevents two members sharing `neo4j.name` from landing on the same
      # AKS node -- see the node pool capacity check below for why the
      # target node pool still needs at least neo4j_cluster_size nodes.
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

  # One Helm release per cluster member (neo4j_cluster_size = 1 keeps the
  # original single-release name, unchanged from before HA support existed).
  # The chart's `services.neo4j` LoadBalancer Service is keyed off
  # `neo4j.name`, not the release name, and carries a `helm.sh/resource-
  # policy: keep` annotation -- so it's shared/reconciled across all members
  # as one Service rather than one-per-pod.
  neo4j_release_names = {
    for i in range(var.neo4j_cluster_size) :
    tostring(i) => var.neo4j_cluster_size > 1 ? "${var.neo4j_release_name}-${i}" : var.neo4j_release_name
  }
}

# Official Neo4j chart (neo4j/helm-charts, repo https://helm.neo4j.com/neo4j,
# chart name "neo4j" -- confirmed against the chart's own values.yaml, not
# the older/deprecated neo4j-contrib/neo4j-helm chart).
resource "helm_release" "neo4j" {
  for_each = local.neo4j_release_names

  name       = each.value
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

# Cluster-wide PodDisruptionBudget spanning all members (the chart's own
# per-release podDisruptionBudget only covers that one release's single
# pod -- see the comment above `podDisruptionBudget` in the chart's
# values.yaml). Selects on the label every member shares regardless of its
# individual release name. maxUnavailable is the same F as in the
# fault-tolerance formula M = 2F+1, so a rolling AKS node drain can't ever
# take down more members than the cluster can already tolerate losing.
resource "kubernetes_pod_disruption_budget_v1" "neo4j_cluster" {
  count = var.neo4j_cluster_size >= 3 ? 1 : 0

  metadata {
    name      = "${var.neo4j_release_name}-cluster"
    namespace = kubernetes_namespace.neo4j.metadata[0].name
  }

  spec {
    max_unavailable = tostring(floor((var.neo4j_cluster_size - 1) / 2))

    selector {
      match_labels = {
        "helm.neo4j.com/neo4j.name" = var.neo4j_release_name
      }
    }
  }
}

# Non-blocking sanity checks, surfaced as warnings on `plan`/`apply`.
check "neo4j_cluster_requirements" {
  assert {
    condition     = var.neo4j_cluster_size == 1 || (var.neo4j_edition == "enterprise" && contains(["yes", "eval"], var.neo4j_accept_license_agreement))
    error_message = "neo4j_cluster_size > 1 enables Neo4j clustering, which requires Enterprise Edition (neo4j_edition = \"enterprise\") and a license (neo4j_accept_license_agreement = \"yes\" or \"eval\"). Community Edition and unlicensed Enterprise Edition can't cluster."
  }
}

check "neo4j_node_pool_capacity" {
  assert {
    condition     = var.neo4j_cluster_size <= (var.neo4j_node_pool_tier == "small" ? var.small_pool_node_count : var.large_pool_node_count)
    error_message = "neo4j_cluster_size exceeds the node count of the target node pool (neo4j_node_pool_tier). The chart's default podAntiAffinity keeps two members off the same node, so the pool needs at least neo4j_cluster_size nodes or some member pods will stay Pending."
  }
}
