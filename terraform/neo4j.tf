resource "kubernetes_namespace" "neo4j" {
  metadata {
    name = var.neo4j_namespace
  }

  depends_on = [azurerm_kubernetes_cluster.this]
}

# Chart default: "If password is not set or empty a random password will be
# generated during installation" -- generating it here instead so Terraform
# can output it, rather than reading it back out of the pod logs.
resource "random_password" "neo4j" {
  length  = 24
  special = false
}

# Official Neo4j chart (neo4j/helm-charts, repo https://helm.neo4j.com/neo4j,
# chart name "neo4j" -- confirmed against the chart's own values.yaml, not
# the older/deprecated neo4j-contrib/neo4j-helm chart).
resource "helm_release" "neo4j" {
  name       = var.neo4j_release_name
  namespace  = kubernetes_namespace.neo4j.metadata[0].name
  repository = "https://helm.neo4j.com/neo4j"
  chart      = "neo4j"

  # neo4j.name is mandatory: it ties together members of the same logical
  # Neo4j deployment; installation fails without it.
  set {
    name  = "neo4j.name"
    value = var.neo4j_release_name
  }

  set {
    name  = "neo4j.edition"
    value = var.neo4j_edition
  }

  set {
    name  = "neo4j.acceptLicenseAgreement"
    value = var.neo4j_accept_license_agreement
  }

  set_sensitive {
    name  = "neo4j.password"
    value = random_password.neo4j.result
  }

  set {
    name  = "neo4j.resources.cpu"
    value = var.neo4j_cpu
  }

  set {
    name  = "neo4j.resources.memory"
    value = var.neo4j_memory
  }

  # volumes.data.mode has no default in the chart and must be set explicitly.
  # "dynamic" provisions a PVC against an explicitly named StorageClass,
  # which is more predictable across AKS versions than relying on whichever
  # StorageClass happens to be cluster-default.
  set {
    name  = "volumes.data.mode"
    value = "dynamic"
  }

  set {
    name  = "volumes.data.dynamic.storageClassName"
    value = var.neo4j_storage_class
  }

  set {
    name  = "volumes.data.dynamic.requests.storage"
    value = "${var.neo4j_data_disk_size_gb}Gi"
  }

  # Exposes Neo4j Browser/HTTP/Bolt outside the cluster via an Azure Load
  # Balancer public IP. Set to ClusterIP instead if you'll only ever reach
  # Neo4j from inside the cluster or through your own ingress.
  set {
    name  = "services.neo4j.spec.type"
    value = "LoadBalancer"
  }
}
