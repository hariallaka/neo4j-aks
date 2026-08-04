# Two size-tiered user node pools shared across tenants (rather than one
# dedicated pool per tenant). Isolation between tenants is at the Neo4j
# database/role level (see onboarding/), not the node level -- these pools
# just separate workload sizing tiers from each other and from the system
# pool. Each Neo4j Helm release picks a tier via nodeSelector + a matching
# toleration (see neo4j.tf / var.neo4j_node_pool_tier).
resource "azurerm_kubernetes_cluster_node_pool" "small" {
  name                  = "small"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"
  vm_size               = var.small_pool_vm_size
  node_count            = var.small_pool_node_count

  node_labels = {
    workloadsize = "small"
  }

  node_taints = [
    "workloadsize=small:NoSchedule",
  ]
}

resource "azurerm_kubernetes_cluster_node_pool" "large" {
  name                  = "large"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"
  vm_size               = var.large_pool_vm_size
  node_count            = var.large_pool_node_count

  node_labels = {
    workloadsize = "large"
  }

  node_taints = [
    "workloadsize=large:NoSchedule",
  ]
}

# Dedicated pool for ingress/edge workloads -- the Istio ingress gateway
# and the neo4j-reverse-proxy pod (see ingress.tf) -- kept off both the
# tenant small/large pools above and the AKS system pool (aks.tf), which
# is tainted CriticalAddonsOnly=true:NoSchedule for cluster add-ons only.
# Only created when var.neo4j_reverse_proxy_enabled.
#
# This pool creating the toleration/label pair doesn't by itself move an
# already-installed Istio ingress gateway onto it -- that gateway's own
# Deployment (managed outside this repo) needs a matching nodeSelector/
# toleration added on its side too. See the README's reverse-proxy section
# for the exact values to hand to whoever manages that install.
resource "azurerm_kubernetes_cluster_node_pool" "ingress" {
  count = var.neo4j_reverse_proxy_enabled ? 1 : 0

  name                  = "ingress"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"
  vm_size               = var.ingress_pool_vm_size
  node_count            = var.ingress_pool_node_count

  node_labels = {
    workload = "ingress"
  }

  node_taints = [
    "workload=ingress:NoSchedule",
  ]
}
