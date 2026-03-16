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
    # kubectl defers CRD schema validation to apply time rather than plan time,
    # avoiding the chicken-and-egg failure when argoproj.io/Application doesn't exist yet.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
}

locals {
  cluster_name    = "k3d-devops-vyk"
  kubeconfig_path = pathexpand("~/.kube/config")
}

provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = local.cluster_name
}

provider "helm" {
  kubernetes {
    config_path    = local.kubeconfig_path
    config_context = local.cluster_name
  }
}

provider "kubectl" {
  config_path      = local.kubeconfig_path
  config_context   = local.cluster_name
  load_config_file = true
}
