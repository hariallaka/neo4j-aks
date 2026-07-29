data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

# Only created when Defender is enabled -- Defender for Containers requires
# a Log Analytics Workspace to send its audit logs to.
resource "azurerm_log_analytics_workspace" "this" {
  count               = var.enable_microsoft_defender ? 1 : 0
  name                = "${var.cluster_name}-law"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = var.kubernetes_version

  # Uptime SLA tier -- required for production workloads, gives an SLA on
  # the control plane.
  sku_tier                  = "Standard"
  automatic_upgrade_channel = "stable"

  # Disables kubeconfig-based local admin/user accounts, forcing all
  # kubectl/Helm access through Azure AD RBAC below. Off by default because
  # it also breaks the kubernetes/helm Terraform providers' use of
  # kube_config in providers.tf (they'd need a kubelogin exec plugin
  # instead) -- flip once you've moved that wiring over.
  local_account_disabled = var.local_account_disabled

  # System pool: cluster-critical add-ons only (tainted with
  # CriticalAddonsOnly=true:NoSchedule). Tenant/Neo4j workloads run on the
  # "small"/"large" user pools in node_pools.tf instead, so a noisy or
  # misbehaving tenant workload can't starve system pods.
  default_node_pool {
    name                         = "system"
    node_count                   = var.node_count
    vm_size                      = var.node_vm_size
    only_critical_addons_enabled = true
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure AD (Entra ID) integration for Kubernetes RBAC: cluster access and
  # authorization is driven by Entra identities/groups rather than
  # AKS-local Kubernetes RBAC bindings alone.
  azure_active_directory_role_based_access_control {
    tenant_id              = var.entra_tenant_id
    admin_group_object_ids = var.aks_admin_group_object_ids
    azure_rbac_enabled     = true
  }

  # Azure CNI with Azure's network policy engine, so NetworkPolicy objects
  # can enforce pod-to-pod traffic rules between tenant namespaces.
  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  # CSI Secrets Store driver + managed identity, so Key Vault secrets can be
  # mounted into pods / synced to native K8s Secrets without hand-rolling
  # credential distribution.
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  dynamic "microsoft_defender" {
    for_each = var.enable_microsoft_defender ? [1] : []
    content {
      log_analytics_workspace_id = azurerm_log_analytics_workspace.this[0].id
    }
  }

  # Empty by default (no restriction). Set to your corporate/VPN egress
  # ranges to restrict who can reach the API server at all.
  dynamic "api_server_access_profile" {
    for_each = length(var.aks_authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.aks_authorized_ip_ranges
    }
  }
}
