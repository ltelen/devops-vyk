# terraform/argocd.tf
# ---------------------------------------------------------------------------
# Argo CD — installed via the official Helm chart.
#
# Design decisions:
#   - Dedicated namespace `argocd` (created by the kubernetes_namespace resource
#     so Terraform owns its lifecycle).
#   - `wait = true` on the Helm release makes `terraform apply` block until all
#     Argo CD pods report Ready.  This ensures the subsequent kubectl_manifest
#     resources in gitops-apps.tf can successfully POST to the Argo CD CRDs.
#   - Server is exposed as ClusterIP (default).  Access via port-forward or
#     an Ingress added later.
#   - Custom PVC health check: k3d's default StorageClass (local-path) uses
#     WaitForFirstConsumer binding mode, so PVCs stay Pending until a Pod
#     referencing them is scheduled.  Argo CD's built-in health check marks
#     Pending PVCs as Progressing, which blocks sync wave advancement.
#     The Lua override below treats Pending as Healthy so wave 0 (Secret +
#     PVCs) completes and wave 1 (MySQL Deployment) can proceed.
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

  # Custom PVC health check — treats Pending as Healthy.
  # Required for k3d local-path StorageClass (WaitForFirstConsumer):
  # PVCs only bind after a consuming Pod is scheduled, so without this
  # override Argo CD never advances past wave 0.
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
