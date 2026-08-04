# Fronts Neo4j through the cluster's existing Istio ingress gateway
# (installed/managed outside this stack -- see var.neo4j_istio_gateway_enabled)
# as a single shared front door, using plain TCP passthrough straight to
# Neo4j's own Service (services.neo4j in neo4j.tf) -- no separate backend
# pod, no HTTP/WebSocket tunneling. Only created when
# var.neo4j_istio_gateway_enabled.
#
# This deliberately does NOT tunnel Bolt over HTTP/WebSocket for
# 80/443-only egress -- that would need a WebSocket-aware backend in front
# of Neo4j (Neo4j's own neo4j-reverse-proxy chart does this), which this
# stack doesn't deploy. If end users can only reach 80/443, not a raw TCP
# port, this setup doesn't help them; the trade-off was deliberately made
# for simplicity (two kubectl_manifest resources, no extra pod/chart to
# operate) since that wasn't a requirement here.
#
# Binds to the cluster's existing Istio ingress gateway workload (matched
# by var.istio_ingress_gateway_selector) rather than provisioning a new
# one -- Istio itself isn't installed by this stack. Confirmed against
# Istio's own TCP routing sample (istio/istio's samples/tcp-echo, not
# guessed): a Gateway server with protocol "TCP" and a VirtualService's
# `tcp[].match[].port` (matching the Gateway's listening port) routing to
# a Service host/port.
resource "kubectl_manifest" "neo4j_gateway" {
  count = var.neo4j_istio_gateway_enabled ? 1 : 0

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

# The neo4j chart's own external Service is shared across every cluster
# member (see neo4j.tf/README's HA section) and named "<neo4j.name>-lb-neo4j"
# regardless of which member's release created it -- confirmed against
# Neo4j's own "Access the Neo4j cluster from outside Kubernetes"
# operations-manual page. Routed to here by its in-cluster ClusterIP/DNS
# name, independent of whatever external type (LoadBalancer by default)
# that Service itself also has.
resource "kubectl_manifest" "neo4j_virtualservice" {
  count = var.neo4j_istio_gateway_enabled ? 1 : 0

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
    null_resource.neo4j_helm_cli,
  ]
}
