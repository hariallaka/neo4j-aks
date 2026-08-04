# Fronts Neo4j through the cluster's existing Istio ingress gateway
# (installed/managed outside this stack -- see var.neo4j_reverse_proxy_enabled)
# for end users who can only reach a raw HTTP(S) port (443), not a raw TCP
# port like Bolt's 7687. Only created when var.neo4j_reverse_proxy_enabled.
# A plain Kubernetes Ingress/Istio VirtualService can't carry Bolt itself
# (HTTP(S) only) -- neo4j-reverse-proxy is what actually tunnels Bolt over
# WebSocket; the Gateway/VirtualService below just get that pod's traffic
# routed to it through Istio, the same way any other HTTP(S) backend would
# be. Istio/Envoy handles the WebSocket upgrade automatically for HTTP
# routes, no extra VirtualService config needed for that part.
#
# If your actual goal is just "one shared front door" rather than
# "80/443-only egress", routing Neo4j's own LoadBalancer Service
# (services.neo4j in neo4j.tf) through a plain TCP Istio Gateway (protocol
# TCP/TLS passthrough on 7687, not HTTP) is simpler and doesn't need
# neo4j-reverse-proxy at all -- not what's set up here, since this solves
# the narrower 80/443-only problem instead.
#
# The neo4j-reverse-proxy pod and the Istio ingress gateway both run on
# the dedicated "ingress" node pool (node_pools.tf), not the small/large
# tenant pools Neo4j itself uses, and not the tainted AKS "system" pool
# (aks.tf, reserved for cluster add-ons only). Creating this pool here
# doesn't by itself move the *existing* Istio ingress gateway Deployment
# onto it -- that Deployment is managed outside this repo, so it needs a
# matching nodeSelector/toleration added on its own side:
#
#   nodeSelector:
#     workload: ingress
#   tolerations:
#     - key: workload
#       operator: Equal
#       value: ingress
#       effect: NoSchedule
#
# hand those to whoever manages the Istio install if you want the gateway
# pods to actually land here.

locals {
  ingress_pool_node_selector = {
    workload = "ingress"
  }
  ingress_pool_toleration = [
    {
      key      = "workload"
      operator = "Equal"
      value    = "ingress"
      effect   = "NoSchedule"
    }
  ]

  # Matches the neo4j-reverse-proxy chart's own naming template
  # (neo4j.reverseProxy.fullname -> "<release name>", then
  # "-reverseproxy-service"/"-reverseproxy-ingress" suffixes -- confirmed
  # against templates/ingress.yaml and templates/_helpers.tpl in
  # neo4j/helm-charts). reverseProxy.ingress stays disabled below (Istio
  # does the routing instead of a chart-managed Ingress object), but the
  # Service is still created unconditionally by the chart.
  neo4j_reverse_proxy_release_name = "${var.neo4j_release_name}-reverse-proxy"
  neo4j_reverse_proxy_service_name = "${local.neo4j_reverse_proxy_release_name}-reverseproxy-service"
  neo4j_reverse_proxy_port         = var.neo4j_reverse_proxy_tls_secret_name != "" ? 443 : 80
}

# Neo4j's own reverse-proxy chart, from the same repo/version line as the
# neo4j chart -- reuses neo4j_helm_repo_url/neo4j_helm_chart_version so
# switching to an internal mirror (see README's proxy-cache note) covers
# this chart too, not just neo4j itself.
resource "helm_release" "neo4j_reverse_proxy" {
  count = var.neo4j_reverse_proxy_enabled ? 1 : 0

  name       = local.neo4j_reverse_proxy_release_name
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

      nodeSelector = local.ingress_pool_node_selector
      tolerations  = local.ingress_pool_toleration

      # No chart-managed Ingress object -- Istio routes to this pod's
      # Service directly via the VirtualService below instead.
      ingress = {
        enabled = false
      }
    }
  })]

  depends_on = [
    helm_release.neo4j,
    null_resource.neo4j_helm_cli,
    azurerm_kubernetes_cluster_node_pool.ingress,
  ]
}

# Binds to the cluster's existing Istio ingress gateway workload (matched
# by var.istio_ingress_gateway_selector) rather than provisioning a new
# one -- Istio itself isn't installed by this stack.
resource "kubectl_manifest" "neo4j_reverse_proxy_gateway" {
  count = var.neo4j_reverse_proxy_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1beta1"
    kind       = "Gateway"
    metadata = {
      name      = "${local.neo4j_reverse_proxy_release_name}-gateway"
      namespace = kubernetes_namespace.neo4j.metadata[0].name
    }
    spec = {
      selector = var.istio_ingress_gateway_selector
      servers = var.neo4j_reverse_proxy_tls_secret_name != "" ? [
        {
          port = {
            number   = 443
            name     = "https-neo4j"
            protocol = "HTTPS"
          }
          tls = {
            mode           = "SIMPLE"
            credentialName = var.neo4j_reverse_proxy_tls_secret_name
          }
          hosts = [var.neo4j_reverse_proxy_host]
        }
        ] : [
        {
          port = {
            number   = 80
            name     = "http-neo4j"
            protocol = "HTTP"
          }
          hosts = [var.neo4j_reverse_proxy_host]
        }
      ]
    }
  })

  depends_on = [helm_release.neo4j_reverse_proxy]
}

resource "kubectl_manifest" "neo4j_reverse_proxy_virtualservice" {
  count = var.neo4j_reverse_proxy_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1beta1"
    kind       = "VirtualService"
    metadata = {
      name      = "${local.neo4j_reverse_proxy_release_name}-vs"
      namespace = kubernetes_namespace.neo4j.metadata[0].name
    }
    spec = {
      hosts    = [var.neo4j_reverse_proxy_host]
      gateways = ["${local.neo4j_reverse_proxy_release_name}-gateway"]
      http = [
        {
          route = [
            {
              destination = {
                host = "${local.neo4j_reverse_proxy_service_name}.${kubernetes_namespace.neo4j.metadata[0].name}.svc.cluster.local"
                port = {
                  number = local.neo4j_reverse_proxy_port
                }
              }
            }
          ]
        }
      ]
    }
  })

  depends_on = [kubectl_manifest.neo4j_reverse_proxy_gateway]
}

check "neo4j_reverse_proxy_requirements" {
  assert {
    condition     = !var.neo4j_reverse_proxy_enabled || var.neo4j_reverse_proxy_host != ""
    error_message = "neo4j_reverse_proxy_host is required (used as the Gateway/VirtualService host) when neo4j_reverse_proxy_enabled = true."
  }
}
