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
