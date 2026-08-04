terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    # Applies raw Kubernetes manifests -- used for the Istio Gateway/
    # VirtualService CRDs in ingress.tf, since the mainline kubernetes
    # provider has no generic resource for arbitrary CRDs (Istio isn't
    # installed by this stack -- see ingress.tf -- so there's no typed
    # Terraform resource for its CRDs to use instead).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
