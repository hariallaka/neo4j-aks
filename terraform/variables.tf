variable "azure_subscription_id" {
  type        = string
  description = "Azure subscription ID. Leave null to use ARM_SUBSCRIPTION_ID or the active `az account` subscription."
  default     = null
}

variable "entra_tenant_id" {
  type        = string
  description = "Entra ID (Azure AD) tenant ID. Used for both AKS's Azure AD RBAC integration and the Neo4j OIDC provider config."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to create for the AKS cluster."
  default     = "rg-neo4j-aks"
}

variable "location" {
  type        = string
  description = "Azure region for the resource group and AKS cluster."
  default     = "eastus"
}

variable "cluster_name" {
  type        = string
  description = "Name of the AKS cluster."
  default     = "neo4j-aks"
}

variable "dns_prefix" {
  type        = string
  description = "DNS prefix for the AKS cluster's API server."
  default     = "neo4j-aks"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the cluster. Leave null to use AKS's current default."
  default     = null
}

variable "node_count" {
  type        = number
  description = "Number of nodes in the system node pool (critical add-ons only -- see node_pools.tf for tenant workload pools)."
  default     = 3
}

variable "node_vm_size" {
  type        = string
  description = "VM size for the system node pool."
  default     = "Standard_D4s_v5"
}

variable "local_account_disabled" {
  type        = bool
  description = "Disable AKS local admin/user kubeconfig accounts, forcing all cluster access through Azure AD RBAC. Leave false unless you've also switched the kubernetes/helm providers in providers.tf to a kubelogin exec plugin -- local kube_config is what they currently authenticate with."
  default     = false
}

variable "aks_admin_group_object_ids" {
  type        = list(string)
  description = "Entra ID group Object IDs granted cluster-admin via Azure AD RBAC. Strongly recommended to set at least one in production."
  default     = []
}

variable "aks_authorized_ip_ranges" {
  type        = list(string)
  description = "CIDR ranges allowed to reach the AKS API server. Empty means unrestricted (default AKS behavior)."
  default     = []
}

variable "enable_microsoft_defender" {
  type        = bool
  description = "Enable Microsoft Defender for Containers (creates a Log Analytics Workspace for its audit logs)."
  default     = true
}

variable "small_pool_vm_size" {
  type        = string
  description = "VM size for the \"small\" tenant workload node pool."
  default     = "Standard_D4s_v5"
}

variable "small_pool_node_count" {
  type        = number
  description = "Node count for the \"small\" tenant workload node pool."
  default     = 2
}

variable "large_pool_vm_size" {
  type        = string
  description = "VM size for the \"large\" tenant workload node pool."
  default     = "Standard_D8s_v5"
}

variable "large_pool_node_count" {
  type        = number
  description = "Node count for the \"large\" tenant workload node pool."
  default     = 2
}

variable "key_vault_name" {
  type        = string
  description = "Name of the Key Vault created for Neo4j secrets (globally unique)."
  default     = "kv-neo4j-aks"
}

variable "key_vault_admin_object_id" {
  type        = string
  description = "Object ID granted \"Key Vault Secrets Officer\" (read/write secrets). Leave null to use the object ID of whoever/whatever runs terraform apply."
  default     = null
}

variable "neo4j_namespace" {
  type        = string
  description = "Kubernetes namespace to deploy Neo4j into."
  default     = "neo4j"
}

variable "neo4j_release_name" {
  type        = string
  description = "Helm release name; also used as neo4j.name in the chart (mandatory, ties cluster members together)."
  default     = "neo4j-aks"
}

variable "neo4j_edition" {
  type        = string
  description = "Neo4j edition: community or enterprise. Enterprise requires neo4j_accept_license_agreement to be \"yes\" or \"eval\", and is required for multi-database (multi-tenant) and OIDC/SSO support used here."
  default     = "enterprise"

  validation {
    condition     = contains(["community", "enterprise"], var.neo4j_edition)
    error_message = "neo4j_edition must be either \"community\" or \"enterprise\"."
  }
}

variable "neo4j_accept_license_agreement" {
  type        = string
  description = "Required for enterprise edition: \"yes\" (licensed) or \"eval\" (evaluation). Ignored for community edition."
  default     = "no"

  validation {
    condition     = contains(["no", "yes", "eval"], var.neo4j_accept_license_agreement)
    error_message = "neo4j_accept_license_agreement must be \"no\", \"yes\", or \"eval\"."
  }
}

variable "neo4j_cluster_size" {
  type        = number
  description = "Number of Neo4j cluster members to deploy, each as its own Helm release/pod (see neo4j.tf). 1 = standalone, no clustering (default -- matches a single-instance license). 3+ enables Neo4j causal clustering for HA: fault tolerance follows M = 2F+1, so 3 members tolerate 1 failure and keep write availability, 5 tolerate 2, etc. Clustering requires neo4j_edition = \"enterprise\" and a valid license (neo4j_accept_license_agreement = \"yes\" or \"eval\") -- see the README's HA section for the licensing caveat before raising this above 1."
  default     = 1

  validation {
    condition     = var.neo4j_cluster_size >= 1
    error_message = "neo4j_cluster_size must be at least 1."
  }

  validation {
    condition     = var.neo4j_cluster_size == 1 || var.neo4j_cluster_size % 2 == 1
    error_message = "neo4j_cluster_size must be 1 (standalone) or an odd number (3, 5, ...) -- Neo4j clustering uses Raft consensus, which needs an odd number of members to form a majority; an even size adds a member without adding fault tolerance."
  }
}

variable "neo4j_cpu" {
  type        = string
  description = "CPU request/limit for the Neo4j container (chart minimum is 0.5)."
  default     = "1000m"
}

variable "neo4j_memory" {
  type        = string
  description = "Memory request/limit for the Neo4j container (chart minimum is 2Gi)."
  default     = "2Gi"
}

variable "neo4j_storage_class" {
  type        = string
  description = "Kubernetes StorageClass for the Neo4j data volume. AKS ships \"default\" and \"managed-csi\" out of the box."
  default     = "managed-csi"
}

variable "neo4j_data_disk_size_gb" {
  type        = number
  description = "Size in GiB of the persistent volume used for Neo4j data."
  default     = 50
}

variable "neo4j_node_pool_tier" {
  type        = string
  description = "Which tenant workload node pool (node_pools.tf) this Neo4j release schedules onto."
  default     = "small"

  validation {
    condition     = contains(["small", "large"], var.neo4j_node_pool_tier)
    error_message = "neo4j_node_pool_tier must be either \"small\" or \"large\"."
  }
}

variable "neo4j_deployment_method" {
  type        = string
  description = "How to install the Neo4j Helm release(s). \"helm_release\" (default) uses Terraform's native helm_release resource. \"helm_cli\" instead shells out to a locally-installed `helm` binary via null_resource/local-exec -- useful when the machine running `terraform apply` reaches the chart repo (or an internal mirror) only through a locally-configured proxy/helm setup that the Terraform helm provider can't be pointed at the same way. Only one method's resources are created per apply; see the README's HA section for how to switch between them on an existing deployment."
  default     = "helm_release"

  validation {
    condition     = contains(["helm_release", "helm_cli"], var.neo4j_deployment_method)
    error_message = "neo4j_deployment_method must be \"helm_release\" or \"helm_cli\"."
  }
}

variable "neo4j_helm_repo_url" {
  type        = string
  description = "Helm chart repository URL for the neo4j chart (what `helm repo add`/the Terraform helm provider's `repository` argument points at). Defaults to Neo4j's own repo (helm.neo4j.com/neo4j); point this at an internal proxy/mirror (Artifactory, Nexus, Harbor, etc.) if that's not directly reachable from your network -- see the README's proxy-cache note for exactly what such a mirror needs to serve."
  default     = "https://helm.neo4j.com/neo4j"
}

variable "neo4j_helm_chart_version" {
  type        = string
  description = "Pin the neo4j chart version (e.g. \"2026.6.0\"). Leave empty to install whatever version the configured repo currently resolves as latest."
  default     = ""
}

variable "neo4j_oidc_client_id" {
  type        = string
  description = "Application (client) ID of the Entra app registration used for Neo4j SSO/OIDC (see README's one-time Entra setup section). Leave empty to run with native auth only -- OIDC config is omitted entirely until this is set."
  default     = ""
}
