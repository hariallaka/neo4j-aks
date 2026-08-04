terraform {
  required_version = ">= 1.5.0"

  required_providers {
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
    # Applies the Istio Gateway/VirtualService CRDs -- see main.tf's
    # comment on kubectl_manifest.neo4j_gateway for why (no generic CRD
    # resource in the mainline kubernetes provider, and Istio isn't
    # installed by this example either).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
