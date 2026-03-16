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
  version    = "6.7.18"

  namespace = kubernetes_namespace.argocd.metadata[0].name

  # Block until all pods are Ready before kubectl_manifest resources in gitops-apps.tf run.
  wait    = true
  timeout = 600

  set {
    name  = "global.domain"
    value = "argocd.localhost"
  }

  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  set {
    name  = "dex.enabled"
    value = "false"
  }

  # k3d local-path StorageClass uses WaitForFirstConsumer: PVCs stay Pending until
  # a consumer Pod is scheduled. Without this override Argo CD marks Pending PVCs
  # as Progressing and never advances past wave 0.
  values = [<<-YAML
    configs:
      cm:
        resource.customizations.health.PersistentVolumeClaim: |
          hs = {}
          if obj.status ~= nil then
            if obj.status.phase == "Bound" then
              hs.status = "Healthy"
              hs.message = obj.status.phase
            elseif obj.status.phase == "Pending" then
              hs.status = "Healthy"
              hs.message = "Waiting for first consumer (WaitForFirstConsumer binding mode)"
            else
              hs.status = "Degraded"
              hs.message = obj.status.phase
            end
          end
          return hs
  YAML
  ]

  depends_on = [kubernetes_namespace.argocd]
}
