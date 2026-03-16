locals {
  repo_url         = "https://github.com/ltelen/devops-vyk.git"
  target_revision  = "feature/initial-task"
  argocd_namespace = kubernetes_namespace.argocd.metadata[0].name
}

resource "kubectl_manifest" "argocd_app_infrastructure" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: infrastructure
      namespace: ${local.argocd_namespace}
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

# Block until the infrastructure Application is fully synced and healthy before
# creating the applications App. This ensures MySQL is running before the
# backend attempts to connect.
resource "null_resource" "wait_for_infrastructure" {
  provisioner "local-exec" {
    command = <<-EOT
      kubectl wait application/infrastructure \
        -n ${local.argocd_namespace} \
        --for=jsonpath='{.status.health.status}'=Healthy \
        --timeout=300s
    EOT
  }

  depends_on = [kubectl_manifest.argocd_app_infrastructure]
}

resource "kubectl_manifest" "argocd_app_applications" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: applications
      namespace: ${local.argocd_namespace}
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
    null_resource.wait_for_infrastructure,
  ]
}
