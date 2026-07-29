variable "azure_subscription_id" {
  type        = string
  description = "Azure subscription ID. Leave null to use ARM_SUBSCRIPTION_ID or the active `az account` subscription."
  default     = null
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
  description = "Number of nodes in the default node pool."
  default     = 3
}

variable "node_vm_size" {
  type        = string
  description = "VM size for the default node pool."
  default     = "Standard_D4s_v5"
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
  description = "Neo4j edition: community or enterprise. Enterprise requires neo4j_accept_license_agreement to be \"yes\" or \"eval\"."
  default     = "community"

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
