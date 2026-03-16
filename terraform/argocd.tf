# terraform/argocd.tf
# ---------------------------------------------------------------------------
# Argo CD — installed via the official Helm chart.
#
# Design decisions:
#   - Dedicated namespace `argocd` (created by the kubernetes_namespace resource
#     so Terraform owns its lifecycle).
#   - `wait = true` on the Helm release makes `terraform apply` block until all
#     Argo CD pods report Ready.  This ensures the subsequent `kubernetes_manifest`
#     resources in gitops-apps.tf can successfully POST to the Argo CD CRDs.
#   - Server is exposed as ClusterIP (default).  Access via port-forward or
#     an Ingress added later.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "managed-by" = "terraform"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.18" # pin for reproducibility; bump deliberately

  namespace = kubernetes_namespace.argocd.metadata[0].name

  # Block until all Argo CD pods are Ready — required before CRD-dependent
  # resources in gitops-apps.tf are applied.
  wait    = true
  timeout = 600 # seconds

  # Minimal production-safe overrides
  set {
    name  = "global.domain"
    value = "argocd.localhost"
  }

  # Run in non-TLS mode for local development (avoids self-signed cert noise)
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  # Disable the bundled Dex (OIDC) for simplicity
  set {
    name  = "dex.enabled"
    value = "false"
  }

  depends_on = [kubernetes_namespace.argocd]
}
