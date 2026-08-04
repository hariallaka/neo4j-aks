# ingress-nginx + Neo4j's own "neo4j-reverse-proxy" chart, fronting Neo4j
# for end users who can only reach a raw HTTP(S) port (443), not a raw TCP
# port like Bolt's 7687. Only created when var.neo4j_reverse_proxy_enabled.
# A plain Kubernetes Ingress can't carry Bolt itself (Ingress is HTTP(S)
# only) -- neo4j-reverse-proxy is what actually tunnels Bolt over
# WebSocket; ingress-nginx just does normal host-based HTTP(S) routing to
# that proxy pod. If your real constraint is "consolidate everything
# behind one shared front door" rather than "80/443-only egress", a plain
# ingress-nginx `tcp-services` ConfigMap doing L4 passthrough straight to
# Neo4j's own LoadBalancer Service (services.neo4j in neo4j.tf) is simpler
# and isn't what this file sets up.
#
# Both the ingress-nginx controller and the reverse-proxy pod run on the
# "system" node pool (aks.tf's default_node_pool), not the small/large
# tenant pools Neo4j itself uses. That pool is tainted
# CriticalAddonsOnly=true:NoSchedule specifically to keep general
# workloads off it (see aks.tf's comments) -- scheduling these here is a
# deliberate, explicit exception via a toleration, not a loosening of that
# taint for anything else. It was sized/intended for cluster add-ons only,
# so if you're adding real traffic through it, revisit node_count/
# node_vm_size accordingly. AKS labels nodes in a System-mode pool
# `kubernetes.azure.com/mode: system` automatically -- used below as the
# nodeSelector, no extra labeling needed.
locals {
  system_pool_toleration = [
    {
      key      = "CriticalAddonsOnly"
      operator = "Equal"
      value    = "true"
      effect   = "NoSchedule"
    }
  ]
  system_pool_node_selector = {
    "kubernetes.azure.com/mode" = "system"
  }
}

resource "kubernetes_namespace" "ingress_nginx" {
  count = var.neo4j_reverse_proxy_enabled ? 1 : 0

  metadata {
    name = "ingress-nginx"
  }

  depends_on = [azurerm_kubernetes_cluster.this]
}

# Community ingress-nginx chart (kubernetes/ingress-nginx, repo
# https://kubernetes.github.io/ingress-nginx by default) -- not a Neo4j
# chart, so it's a separate repo/version line from neo4j_helm_repo_url.
resource "helm_release" "ingress_nginx" {
  count = var.neo4j_reverse_proxy_enabled ? 1 : 0

  name       = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress_nginx[0].metadata[0].name
  repository = var.ingress_nginx_helm_repo_url
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version != "" ? var.ingress_nginx_chart_version : null

  values = [yamlencode({
    controller = {
      tolerations  = local.system_pool_toleration
      nodeSelector = local.system_pool_node_selector
      service = {
        type = "LoadBalancer"
      }
    }
  })]

  depends_on = [azurerm_kubernetes_cluster.this]
}

# Neo4j's own reverse-proxy chart, from the same repo/version line as the
# neo4j chart -- reuses neo4j_helm_repo_url/neo4j_helm_chart_version so
# switching to an internal mirror (see README's proxy-cache note) covers
# this chart too, not just neo4j itself.
resource "helm_release" "neo4j_reverse_proxy" {
  count = var.neo4j_reverse_proxy_enabled ? 1 : 0

  name       = "${var.neo4j_release_name}-reverse-proxy"
  namespace  = kubernetes_namespace.neo4j.metadata[0].name
  repository = var.neo4j_helm_repo_url
  chart      = "neo4j-reverse-proxy"
  version    = var.neo4j_helm_chart_version != "" ? var.neo4j_helm_chart_version : null

  values = [yamlencode({
    reverseProxy = {
      # The neo4j chart's own external Service is shared across every
      # cluster member (see neo4j.tf/README's HA section) and named
      # "<neo4j.name>-lb-neo4j" regardless of which member's release
      # created it -- confirmed against Neo4j's own "Access the Neo4j
      # cluster from outside Kubernetes" operations-manual page.
      serviceName = "${var.neo4j_release_name}-lb-neo4j"
      namespace   = kubernetes_namespace.neo4j.metadata[0].name

      # Same tenant pool Neo4j itself schedules onto (neo4j.tf) -- the
      # reverse-proxy pod is Neo4j-adjacent, not a platform/ingress
      # component, so it doesn't need the system-pool toleration above.
      nodeSelector = {
        workloadsize = var.neo4j_node_pool_tier
      }
      tolerations = [
        {
          key      = "workloadsize"
          operator = "Equal"
          value    = var.neo4j_node_pool_tier
          effect   = "NoSchedule"
        }
      ]

      ingress = {
        enabled   = true
        className = "nginx"
        host      = var.neo4j_reverse_proxy_host
        tls = {
          enabled = var.neo4j_reverse_proxy_tls_secret_name != ""
          config = var.neo4j_reverse_proxy_tls_secret_name != "" ? [
            {
              secretName = var.neo4j_reverse_proxy_tls_secret_name
              hosts      = [var.neo4j_reverse_proxy_host]
            }
          ] : []
        }
      }
    }
  })]

  depends_on = [
    helm_release.ingress_nginx,
    helm_release.neo4j,
    null_resource.neo4j_helm_cli,
  ]
}

check "neo4j_reverse_proxy_requirements" {
  assert {
    condition     = !var.neo4j_reverse_proxy_enabled || var.neo4j_reverse_proxy_host != ""
    error_message = "neo4j_reverse_proxy_host is required (used as the Ingress host) when neo4j_reverse_proxy_enabled = true."
  }
}
