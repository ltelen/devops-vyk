# terraform/providers.tf
# ---------------------------------------------------------------------------
# Provider configuration
#
# Both the Helm and Kubernetes providers are pointed at the k3d cluster via
# the local kubeconfig that `k3d kubeconfig merge` writes.  We use the
# config_path + context approach so the workspace is fully portable — no
# hard-coded IP addresses or inline certificates.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

# ---------------------------------------------------------------------------
# Local values — centralise the cluster name so it's easy to change.
# ---------------------------------------------------------------------------
locals {
  cluster_name    = "k3d-devops-vyk"
  kubeconfig_path = pathexpand("~/.kube/config")
}

# ---------------------------------------------------------------------------
# Kubernetes provider
#
# config_context targets the specific k3d context so this workspace won't
# accidentally modify a different cluster if the user has many contexts.
# ---------------------------------------------------------------------------
provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = local.cluster_name
}

# ---------------------------------------------------------------------------
# Helm provider
#
# Shares the same kubeconfig / context as the Kubernetes provider.
# ---------------------------------------------------------------------------
provider "helm" {
  kubernetes {
    config_path    = local.kubeconfig_path
    config_context = local.cluster_name
  }
}
