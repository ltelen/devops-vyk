# terraform/gitops-apps.tf
# ---------------------------------------------------------------------------
# GitOps Application registrations
#
# Two Argo CD Application CRDs are declared here:
#
#   1. argocd-app-infrastructure  (wave 0 — coarse ordering via depends_on)
#      Watches: infrastructure/
#      Manages: MySQL Secret, PVCs, Deployment, Backup CronJob
#      Sync Waves inside the app enforce Secret/PVC → MySQL → CronJob order.
#
#   2. argocd-app-applications    (wave 1 — depends on infrastructure app)
#      Watches: applications/stack-chart/
#      Manages: Frontend + Backend Helm chart
#
# Terraform `depends_on` provides the coarse-grained guarantee: Argo CD won't
# even begin reconciling `argocd-app-applications` until `argocd-app-infrastructure`
# has been created (and by extension, until MySQL is healthy via sync waves).
#
# Fine-grained ordering *within* each Application is handled by the
# `argocd.argoproj.io/sync-wave` annotations on the manifests themselves.
# See the Sync Wave Logic section in the implementation plan for the full
# rationale and wave table.
# ---------------------------------------------------------------------------

locals {
  repo_url         = "https://github.com/YOUR_ORG/devops-vyk.git" # <-- update before apply
  target_revision  = "HEAD"
  argocd_namespace = kubernetes_namespace.argocd.metadata[0].name
}

# ---------------------------------------------------------------------------
# Infrastructure Application
# Reconciles everything under infrastructure/
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "argocd_app_infrastructure" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "infrastructure"
      namespace = local.argocd_namespace
      annotations = {
        # Wave 0: infrastructure syncs before applications
        "argocd.argoproj.io/sync-wave" = "0"
      }
    }

    spec = {
      project = "default"

      source = {
        repoURL        = local.repo_url
        targetRevision = local.target_revision
        path           = "infrastructure"
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "infrastructure"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]
}

# ---------------------------------------------------------------------------
# Applications Application
# Reconciles the unified Helm chart under applications/stack-chart/
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "argocd_app_applications" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "applications"
      namespace = local.argocd_namespace
      annotations = {
        # Wave 1: only starts after the infrastructure Application is Healthy
        "argocd.argoproj.io/sync-wave" = "1"
      }
    }

    spec = {
      project = "default"

      source = {
        repoURL        = local.repo_url
        targetRevision = local.target_revision
        path           = "applications/stack-chart"
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "applications"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
        ]
      }
    }
  }

  # Coarse-grained ordering: applications only registered after infrastructure CRD exists
  depends_on = [
    helm_release.argocd,
    kubernetes_manifest.argocd_app_infrastructure,
  ]
}
