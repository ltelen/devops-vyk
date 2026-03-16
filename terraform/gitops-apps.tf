# terraform/gitops-apps.tf
# ---------------------------------------------------------------------------
# GitOps Application registrations
#
# Root cause of the original kubernetes_manifest error:
#   kubernetes_manifest validates the CRD GroupVersionKind at PLAN time by
#   querying the live cluster API.  depends_on only controls apply order —
#   it has no effect on plan-time validation.  When Argo CD doesn't exist yet,
#   the plan fails with "no matches for kind Application in group argoproj.io".
#
# Fix: kubectl_manifest (alekc/kubectl provider) uses kubectl-apply semantics
#   and skips plan-time schema validation, resolving the chicken-and-egg issue.
#
# Ordering model (two layers):
#   Coarse — Terraform depends_on:  infrastructure App created before applications App
#   Fine   — sync-wave annotations: within each App, Secret/PVC → MySQL → CronJob
# ---------------------------------------------------------------------------

locals {
  repo_url         = "https://github.com/ltelen/devops-vyk.git"
  target_revision  = "feature/initial-task"
  argocd_namespace = kubernetes_namespace.argocd.metadata[0].name
}

# ---------------------------------------------------------------------------
# Infrastructure Application  (wave 0)
# Reconciles everything under infrastructure/
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "argocd_app_infrastructure" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: infrastructure
      namespace: ${local.argocd_namespace}
      annotations:
        argocd.argoproj.io/sync-wave: "0"
    spec:
      project: default
      source:
        repoURL: ${local.repo_url}
        targetRevision: ${local.target_revision}
        path: infrastructure
      destination:
        server: https://kubernetes.default.svc
        namespace: infrastructure
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  YAML

  depends_on = [helm_release.argocd]
}

# ---------------------------------------------------------------------------
# Applications Application  (wave 1)
# Reconciles the unified Helm chart under applications/stack-chart/
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "argocd_app_applications" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: applications
      namespace: ${local.argocd_namespace}
      annotations:
        argocd.argoproj.io/sync-wave: "1"
    spec:
      project: default
      source:
        repoURL: ${local.repo_url}
        targetRevision: ${local.target_revision}
        path: applications/stack-chart
      destination:
        server: https://kubernetes.default.svc
        namespace: applications
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
  YAML

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.argocd_app_infrastructure,
  ]
}
