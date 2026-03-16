locals {
  repo_url         = "https://github.com/ltelen/devops-vyk.git"
  target_revision  = "main"
  argocd_namespace = kubernetes_namespace.argocd.metadata[0].name
}

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
        path: infrastructure/infra-chart
        helm:
          valueFiles:
            - values.yaml
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
