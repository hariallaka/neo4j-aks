# Deploys a Neo4j Enterprise cluster onto an EXISTING AKS cluster that
# already has Istio installed -- see README.md for the assumptions this
# makes and what it deliberately doesn't do (create the AKS cluster or
# node pools, install Istio, multi-tenant onboarding, OIDC/Entra auth).
# It's a trimmed-down illustration of the same patterns used in the main
# ../../terraform stack (neo4j.tf/ingress.tf), not a replacement for it.

resource "kubernetes_namespace" "neo4j" {
  metadata {
    name = var.neo4j_namespace
  }
}

# Chart default: "If password is not set or empty a random password will
# be generated during installation" -- generating it here instead so
# Terraform can output it rather than reading it back out of pod logs.
resource "random_password" "neo4j" {
  length  = 24
  special = false
}

locals {
  # One Helm values map shared by every cluster member: Neo4j clustering
  # ties members together by `neo4j.name` (identical across all of them),
  # not by Helm release name (unique per member, see helm_release.neo4j
  # below) -- same pattern as ../../terraform/neo4j.tf.
  neo4j_helm_values = {
    neo4j = {
      name                   = var.neo4j_release_name
      edition                = var.neo4j_edition
      acceptLicenseAgreement = var.neo4j_accept_license_agreement
      minimumClusterSize     = var.neo4j_cluster_size
      resources = {
        cpu    = var.neo4j_cpu
        memory = var.neo4j_memory
      }
    }

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

    # LoadBalancer stays enabled even with Istio fronting things too --
    # it's a small extra cost (or none, on an internal-only setup) for a
    # direct fallback path that doesn't depend on Istio being healthy.
    # Switch to ClusterIP if you'd rather Istio be the only way in.
    services = {
      neo4j = {
        enabled = true
        spec = {
          type = "LoadBalancer"
        }
      }
    }

    nodeSelector = var.neo4j_node_selector

    podSpec = {
      tolerations = var.neo4j_tolerations
    }
  }

  # neo4j_cluster_size = 1 keeps a single, unsuffixed release name.
  neo4j_release_names = {
    for i in range(var.neo4j_cluster_size) :
    tostring(i) => var.neo4j_cluster_size > 1 ? "${var.neo4j_release_name}-${i}" : var.neo4j_release_name
  }
}

# Official Neo4j chart (neo4j/helm-charts, repo https://helm.neo4j.com/neo4j
# by default -- see README's proxy-cache note if that's not reachable from
# your network).
resource "helm_release" "neo4j" {
  for_each = local.neo4j_release_names

  name       = each.value
  namespace  = kubernetes_namespace.neo4j.metadata[0].name
  repository = var.neo4j_helm_repo_url
  chart      = "neo4j"
  version    = var.neo4j_helm_chart_version != "" ? var.neo4j_helm_chart_version : null

  values = [yamlencode(local.neo4j_helm_values)]

  set_sensitive {
    name  = "neo4j.password"
    value = random_password.neo4j.result
  }
}

# Cluster-wide PodDisruptionBudget spanning all members (each member is a
# separate Helm release/single-pod StatefulSet, so the chart's own
# per-release PDB support would only cover one pod at a time -- see the
# comment above `podDisruptionBudget` in the chart's own values.yaml).
# maxUnavailable follows the same fault-tolerance formula (M = 2F+1) as
# neo4j_cluster_size's own validation.
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

# Plain TCP passthrough to Neo4j's own shared external Service
# ("<neo4j.name>-lb-neo4j", created by the chart regardless of its
# `services.neo4j.spec.type`) through the cluster's EXISTING Istio ingress
# gateway -- confirmed against Istio's own TCP routing sample
# (istio/istio's samples/tcp-echo), not guessed. No HTTP/WebSocket
# tunneling here -- see the main README's Istio section for why, and what
# to add (Neo4j's own neo4j-reverse-proxy chart) if you need Bolt reachable
# over 80/443 only.
resource "kubectl_manifest" "neo4j_gateway" {
  count = var.istio_gateway_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1beta1"
    kind       = "Gateway"
    metadata = {
      name      = "${var.neo4j_release_name}-gateway"
      namespace = kubernetes_namespace.neo4j.metadata[0].name
    }
    spec = {
      selector = var.istio_ingress_gateway_selector
      servers = [
        {
          port = {
            number   = 7687
            name     = "tcp-bolt"
            protocol = "TCP"
          }
          hosts = ["*"]
        },
        {
          port = {
            number   = 7474
            name     = "tcp-http"
            protocol = "TCP"
          }
          hosts = ["*"]
        }
      ]
    }
  })
}

resource "kubectl_manifest" "neo4j_virtualservice" {
  count = var.istio_gateway_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1beta1"
    kind       = "VirtualService"
    metadata = {
      name      = "${var.neo4j_release_name}-vs"
      namespace = kubernetes_namespace.neo4j.metadata[0].name
    }
    spec = {
      hosts    = ["*"]
      gateways = ["${var.neo4j_release_name}-gateway"]
      tcp = [
        {
          match = [{ port = 7687 }]
          route = [{
            destination = {
              host = "${var.neo4j_release_name}-lb-neo4j.${kubernetes_namespace.neo4j.metadata[0].name}.svc.cluster.local"
              port = { number = 7687 }
            }
          }]
        },
        {
          match = [{ port = 7474 }]
          route = [{
            destination = {
              host = "${var.neo4j_release_name}-lb-neo4j.${kubernetes_namespace.neo4j.metadata[0].name}.svc.cluster.local"
              port = { number = 7474 }
            }
          }]
        }
      ]
    }
  })

  depends_on = [
    kubectl_manifest.neo4j_gateway,
    helm_release.neo4j,
  ]
}
