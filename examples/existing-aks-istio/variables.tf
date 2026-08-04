variable "kube_config_path" {
  type        = string
  description = "Path to a kubeconfig file with credentials for your existing AKS cluster (e.g. what `az aks get-credentials` writes)."
  default     = "~/.kube/config"
}

variable "kube_context" {
  type        = string
  description = "kubeconfig context to use. Leave empty to use the file's current-context."
  default     = ""
}

variable "neo4j_namespace" {
  type        = string
  description = "Kubernetes namespace to deploy Neo4j into."
  default     = "neo4j"
}

variable "neo4j_release_name" {
  type        = string
  description = "Helm release name prefix; also used as neo4j.name in the chart (mandatory, ties cluster members together)."
  default     = "neo4j"
}

variable "neo4j_edition" {
  type        = string
  description = "Neo4j edition: community or enterprise. Enterprise is required for clustering (neo4j_cluster_size > 1) and needs neo4j_accept_license_agreement set."
  default     = "enterprise"

  validation {
    condition     = contains(["community", "enterprise"], var.neo4j_edition)
    error_message = "neo4j_edition must be either \"community\" or \"enterprise\"."
  }
}

variable "neo4j_accept_license_agreement" {
  type        = string
  description = "Required for enterprise edition: \"yes\" (licensed) or \"eval\" (evaluation). Ignored for community edition. See https://neo4j.com/licensing/."
  default     = "no"

  validation {
    condition     = contains(["no", "yes", "eval"], var.neo4j_accept_license_agreement)
    error_message = "neo4j_accept_license_agreement must be \"no\", \"yes\", or \"eval\"."
  }
}

variable "neo4j_cluster_size" {
  type        = number
  description = "Number of Neo4j cluster members to deploy, each as its own Helm release/pod. 1 = standalone. 3+ enables Neo4j causal clustering for HA (fault tolerance M = 2F+1: 3 members tolerate 1 failure). Requires enterprise edition + a license."
  default     = 3

  validation {
    condition     = var.neo4j_cluster_size >= 1
    error_message = "neo4j_cluster_size must be at least 1."
  }

  validation {
    condition     = var.neo4j_cluster_size == 1 || var.neo4j_cluster_size % 2 == 1
    error_message = "neo4j_cluster_size must be 1 (standalone) or an odd number (3, 5, ...) -- Neo4j clustering uses Raft consensus, which needs an odd number of members to form a majority."
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

variable "neo4j_node_selector" {
  type        = map(string)
  description = "Optional nodeSelector for the Neo4j pods, if your existing cluster has dedicated/tainted node pools (see the main terraform/ stack's small/large pools for that pattern). Leave empty to schedule on any node."
  default     = {}
}

variable "neo4j_tolerations" {
  type = list(object({
    key      = string
    operator = string
    value    = optional(string)
    effect   = string
  }))
  description = "Optional pod tolerations matching neo4j_node_selector's target node pool's taint, if any."
  default     = []
}

variable "neo4j_helm_repo_url" {
  type        = string
  description = "Helm chart repository URL for the neo4j chart. Point this at an internal proxy/mirror if helm.neo4j.com isn't reachable from your network -- see the main README's proxy-cache note for what such a mirror needs to serve."
  default     = "https://helm.neo4j.com/neo4j"
}

variable "neo4j_helm_chart_version" {
  type        = string
  description = "Pin the neo4j chart version (e.g. \"2026.6.0\"). Leave empty to install whatever version the configured repo currently resolves as latest."
  default     = ""
}

variable "istio_gateway_enabled" {
  type        = bool
  description = "Front Neo4j with the cluster's existing Istio ingress gateway: a Gateway + VirtualService doing plain TCP passthrough to Neo4j's Service (Bolt 7687 + Browser HTTP 7474). Assumes Istio is already installed in your cluster -- this only creates the routing objects, not Istio itself."
  default     = true
}

variable "istio_ingress_gateway_selector" {
  type        = map(string)
  description = "Pod label selector matching your existing Istio ingress gateway workload -- used as the Gateway resource's spec.selector. Default matches Istio's own default ingress gateway install; override if yours uses different labels."
  default = {
    istio = "ingressgateway"
  }
}
