# Unlike terraform/providers.tf in the main stack (which derives its
# kubeconfig from the azurerm_kubernetes_cluster resource it creates in
# the same apply), this example targets a cluster Terraform doesn't
# manage -- so these providers just point at a kubeconfig file/context,
# same as `kubectl`/`helm` CLI would. Defaults to the standard
# ~/.kube/config and its current-context; override with
# kube_config_path/kube_context if yours differs (e.g. after
# `az aks get-credentials`).
provider "kubernetes" {
  config_path    = var.kube_config_path
  config_context = var.kube_context != "" ? var.kube_context : null
}

provider "helm" {
  kubernetes {
    config_path    = var.kube_config_path
    config_context = var.kube_context != "" ? var.kube_context : null
  }
}

provider "kubectl" {
  config_path      = var.kube_config_path
  config_context   = var.kube_context != "" ? var.kube_context : null
  load_config_file = true
}
