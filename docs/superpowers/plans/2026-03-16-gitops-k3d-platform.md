# GitOps k3d Platform Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap a fully GitOps-managed application platform on k3d using Terraform to provision Argo CD, which then self-manages all infrastructure and application workloads via Sync Waves.

**Architecture:** k3d provides the local Kubernetes cluster with a LoadBalancer port-mapping. Terraform (Helm provider) installs Argo CD, then declares two `Application` CRDs — one for the `infrastructure/` path (MySQL + Backup) and one for `applications/stack-chart/` (Frontend + Backend). Argo CD reconciles both continuously. Sync Waves enforce database-before-app ordering.

**Tech Stack:** k3d, Terraform ≥1.6, Helm provider, Kubernetes provider, Argo CD 6.x (Helm chart), Helm (stack chart), kubectl, Make, MySQL 8.0.

---

## File Map

| Path | Responsibility |
|---|---|
| `k3d-config.yaml` | Declarative k3d cluster spec (1 CP, 2 workers, LB port 80→8080) |
| `Makefile` | Developer ergonomics: `cluster`, `deploy`, `destroy`, `verify` |
| `.gitignore` | Terraform state, Neovim swap/undo, uv cache |
| `terraform/providers.tf` | Helm + Kubernetes provider wiring to k3d kubeconfig |
| `terraform/argocd.tf` | Argo CD Helm release, namespace, wait logic |
| `terraform/gitops-apps.tf` | Two Argo CD `Application` CRDs via `kubernetes_manifest` |
| `applications/stack-chart/Chart.yaml` | Umbrella chart metadata |
| `applications/stack-chart/values.yaml` | Default values for frontend + backend |
| `applications/stack-chart/templates/_helpers.tpl` | Named templates: `fullname`, `labels`, `selectorLabels` |
| `applications/stack-chart/templates/frontend-deployment.yaml` | Frontend Deployment using helpers |
| `applications/stack-chart/templates/frontend-service.yaml` | Frontend ClusterIP Service |
| `applications/stack-chart/templates/backend-deployment.yaml` | Backend Deployment using helpers |
| `applications/stack-chart/templates/backend-service.yaml` | Backend ClusterIP Service |
| `infrastructure/mysql-secret.yaml` | Opaque Secret for MySQL root + app credentials |
| `infrastructure/mysql-pvc.yaml` | PersistentVolumeClaim for MySQL data |
| `infrastructure/mysql-deployment.yaml` | MySQL 8 Deployment + ClusterIP Service |
| `infrastructure/backup-pvc.yaml` | PVC for mysqldump output |
| `infrastructure/backup-cronjob.yaml` | CronJob (every 5 min) running mysqldump |

---

## Sync Wave Logic (read this before implementing `gitops-apps.tf`)

Argo CD processes resources in ascending wave order within a single Application sync. Waves are set via the annotation:

```yaml
annotations:
  argocd.argoproj.io/sync-wave: "N"
```

**Wave assignment for the `infrastructure` Application:**

| Resource | Wave | Reason |
|---|---|---|
| `mysql-secret.yaml` | `"0"` | Credentials must exist before any consumer starts |
| `mysql-pvc.yaml` | `"0"` | Storage must be bound before the pod can schedule |
| `backup-pvc.yaml` | `"0"` | Provisioned early — no dependency blocker |
| `mysql-deployment.yaml` | `"1"` | Depends on Secret + PVC from wave 0 |
| `backup-cronjob.yaml` | `"2"` | Needs MySQL running; wave 2 guarantees MySQL pod is healthy before the first job fires |

Argo CD waits for all resources in wave N to reach a Healthy/Synced status before advancing to wave N+1. This prevents the backup CronJob from ever running against a MySQL instance that hasn't finished its readiness probe.

**Wave assignment for the `applications` Application:**

The entire `applications` Argo CD Application has `syncPolicy.syncOptions: [CreateNamespace=true]` and is itself deployed via Terraform *after* the `infrastructure` Application resource — this is the coarse-grained ordering (Terraform `depends_on`). Fine-grained wave annotations inside the chart are optional but included for forward compatibility:

| Resource | Wave |
|---|---|
| Backend Deployment + Service | `"0"` |
| Frontend Deployment + Service | `"1"` (frontend may call backend) |

---

## Chunk 1: Repo Scaffolding & Cluster Config

### Task 1: `.gitignore`

**Files:**
- Create: `.gitignore`

- [ ] Create `.gitignore` covering Terraform state/lock/cache, Neovim swap/undo files, and uv virtualenv artifacts:

```gitignore
# Terraform
**/.terraform/
*.tfstate
*.tfstate.*
*.tfstate.backup
.terraform.lock.hcl
crash.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Terraform sensitive vars (never commit)
*.tfvars
*.tfvars.json
!terraform.tfvars.example

# Neovim swap and undo
*.swp
*.swo
*.swn
.*.swp
.*.swo
.netrwhist
[._]*.un~
.undodir/

# uv
.venv/
.python-version
uv.lock
__pycache__/
*.py[cod]

# OS
.DS_Store
Thumbs.db
```

- [ ] Commit:

```bash
git add .gitignore
git commit -m "chore: add .gitignore for Terraform, Neovim, uv"
```

---

### Task 2: k3d cluster config

**Files:**
- Create: `k3d-config.yaml`

- [ ] Create `k3d-config.yaml`:

```yaml
# k3d-config.yaml
# Declarative cluster definition for k3d v5+
# Doc: https://k3d.io/v5.x/usage/configfile/
apiVersion: k3d.io/v1alpha5
kind: Simple

metadata:
  name: devops-vyk

# 1 control-plane + 2 worker nodes
servers: 1
agents: 2

# Map host port 8080 → LB port 80 so curl http://localhost:8080 reaches ingress
ports:
  - port: 8080:80
    nodeFilters:
      - loadbalancer

# Disable default traefik; we'll rely on the k3d built-in LB and ArgoCD's ingress
options:
  k3s:
    extraArgs:
      - arg: --disable=traefik
        nodeFilters:
          - server:*

image: rancher/k3s:v1.29.4-k3s1
```

- [ ] Commit:

```bash
git add k3d-config.yaml
git commit -m "feat: add k3d declarative cluster config (1 CP, 2 workers, LB:8080)"
```

---

### Task 3: Makefile

**Files:**
- Create: `Makefile`

- [ ] Create `Makefile`:

```makefile
# Makefile — developer ergonomics for the devops-vyk platform
# Requires: k3d, kubectl, terraform, helm

CLUSTER_NAME  := devops-vyk
KUBECONFIG    := $(HOME)/.kube/config
TF_DIR        := terraform
BACKUP_NS     := infrastructure
CRONJOB_NAME  := mysql-backup

.PHONY: all cluster deploy destroy verify clean

## Default target
all: cluster deploy

## Create the k3d cluster from the declarative config
cluster:
	@echo "==> Creating k3d cluster '$(CLUSTER_NAME)' ..."
	k3d cluster create --config k3d-config.yaml
	@echo "==> Merging kubeconfig ..."
	k3d kubeconfig merge $(CLUSTER_NAME) --kubeconfig-merge-default
	@echo "==> Cluster ready. Current context:"
	kubectl config current-context

## Run Terraform init + apply to deploy Argo CD and register GitOps Apps
deploy:
	@echo "==> Initialising Terraform ..."
	terraform -chdir=$(TF_DIR) init -upgrade
	@echo "==> Applying Terraform plan ..."
	terraform -chdir=$(TF_DIR) apply -auto-approve

## Tail logs from the most recent mysql-backup CronJob pod
verify:
	@echo "==> Finding latest mysql-backup job pod ..."
	$(eval POD := $(shell kubectl get pods -n $(BACKUP_NS) \
	  -l job-name \
	  --sort-by=.metadata.creationTimestamp \
	  -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null))
	@if [ -z "$(POD)" ]; then \
	  echo "No backup pods found yet. Wait for the CronJob to fire (every 5 min)."; \
	  exit 1; \
	fi
	@echo "==> Logs for pod: $(POD)"
	kubectl logs -n $(BACKUP_NS) $(POD)

## Tear down Terraform resources then delete the cluster
destroy:
	@echo "==> Destroying Terraform resources ..."
	-terraform -chdir=$(TF_DIR) destroy -auto-approve
	@echo "==> Deleting k3d cluster ..."
	k3d cluster delete $(CLUSTER_NAME)

## Remove local Terraform cache
clean:
	rm -rf $(TF_DIR)/.terraform $(TF_DIR)/.terraform.lock.hcl
```

- [ ] Commit:

```bash
git add Makefile
git commit -m "feat: add Makefile with cluster/deploy/verify/destroy targets"
```

---

## Chunk 2: Terraform

### Task 4: `terraform/providers.tf`

**Files:**
- Create: `terraform/providers.tf`

- [ ] Create `terraform/providers.tf`:

```hcl
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
```

- [ ] Commit:

```bash
git add terraform/providers.tf
git commit -m "feat(terraform): add Helm + Kubernetes provider config targeting k3d"
```

---

### Task 5: `terraform/argocd.tf`

**Files:**
- Create: `terraform/argocd.tf`

- [ ] Create `terraform/argocd.tf`:

```hcl
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
#   - Server is exposed as a ClusterIP (default).  Access via port-forward or
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
```

- [ ] Commit:

```bash
git add terraform/argocd.tf
git commit -m "feat(terraform): deploy Argo CD via Helm, wait for readiness"
```

---

### Task 6: `terraform/gitops-apps.tf`

**Files:**
- Create: `terraform/gitops-apps.tf`

- [ ] Create `terraform/gitops-apps.tf`:

```hcl
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
  repo_url        = "https://github.com/YOUR_ORG/devops-vyk.git" # <-- update before apply
  target_revision = "HEAD"
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
```

- [ ] Commit:

```bash
git add terraform/gitops-apps.tf
git commit -m "feat(terraform): register infrastructure + applications Argo CD Apps with sync waves"
```

---

## Chunk 3: Helm Chart (applications/stack-chart)

### Task 7: Chart metadata and values

**Files:**
- Create: `applications/stack-chart/Chart.yaml`
- Create: `applications/stack-chart/values.yaml`

- [ ] Create `applications/stack-chart/Chart.yaml`:

```yaml
# applications/stack-chart/Chart.yaml
apiVersion: v2
name: stack-chart
description: |
  Unified Helm chart for the application stack.
  Deploys a Frontend (nginx) and a Backend (generic HTTP service)
  as separate Deployments sharing common label helpers.
type: application
version: 0.1.0
appVersion: "1.0.0"
```

- [ ] Create `applications/stack-chart/values.yaml`:

```yaml
# applications/stack-chart/values.yaml
# ---------------------------------------------------------------------------
# Top-level keys match component names.  Templates reference .Values.frontend
# and .Values.backend respectively, keeping concerns clearly separated.
# ---------------------------------------------------------------------------

frontend:
  name: frontend
  replicaCount: 2
  image:
    repository: nginx
    tag: "1.25-alpine"
    pullPolicy: IfNotPresent
  port: 80
  resources:
    requests:
      cpu: "50m"
      memory: "64Mi"
    limits:
      cpu: "200m"
      memory: "128Mi"

backend:
  name: backend
  replicaCount: 2
  image:
    repository: hashicorp/http-echo
    tag: "latest"
    pullPolicy: IfNotPresent
  port: 5678
  args:
    - "-text=Hello from backend"
  resources:
    requests:
      cpu: "50m"
      memory: "64Mi"
    limits:
      cpu: "200m"
      memory: "128Mi"
```

- [ ] Commit:

```bash
git add applications/stack-chart/Chart.yaml applications/stack-chart/values.yaml
git commit -m "feat(chart): add stack-chart Chart.yaml and values"
```

---

### Task 8: `_helpers.tpl`

**Files:**
- Create: `applications/stack-chart/templates/_helpers.tpl`

- [ ] Create `applications/stack-chart/templates/_helpers.tpl`:

```gotmpl
{{/*
applications/stack-chart/templates/_helpers.tpl

Named templates used across all chart resources.
Convention: prefix every template with the chart name to avoid collisions
when this chart is used as a subchart.
*/}}

{{/*
Expand the chart name.
*/}}
{{- define "stack-chart.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully-qualified name: <release-name>-<component>.
Truncated to 63 chars (Kubernetes label/name limit).
Usage: include "stack-chart.fullname" (dict "Release" .Release "Chart" .Chart "component" "frontend")
*/}}
{{- define "stack-chart.fullname" -}}
{{- $component := .component -}}
{{- printf "%s-%s" .Release.Name $component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
Includes recommended Kubernetes labels for observability and tooling.
Usage: include "stack-chart.labels" (dict "Release" .Release "Chart" .Chart "component" "frontend")
*/}}
{{- define "stack-chart.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — the minimal stable set used by Services and Deployments.
These must NOT change after initial deployment (they are immutable on Deployments).
Usage: include "stack-chart.selectorLabels" (dict "Release" .Release "Chart" .Chart "component" "frontend")
*/}}
{{- define "stack-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
```

- [ ] Commit:

```bash
git add applications/stack-chart/templates/_helpers.tpl
git commit -m "feat(chart): add _helpers.tpl with fullname, labels, selectorLabels templates"
```

---

### Task 9: Frontend templates

**Files:**
- Create: `applications/stack-chart/templates/frontend-deployment.yaml`
- Create: `applications/stack-chart/templates/frontend-service.yaml`

- [ ] Create `applications/stack-chart/templates/frontend-deployment.yaml`:

```yaml
# applications/stack-chart/templates/frontend-deployment.yaml
{{- $ctx := dict "Release" .Release "Chart" .Chart "component" .Values.frontend.name -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "stack-chart.fullname" $ctx }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "stack-chart.labels" $ctx | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  replicas: {{ .Values.frontend.replicaCount }}
  selector:
    matchLabels:
      {{- include "stack-chart.selectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "stack-chart.selectorLabels" $ctx | nindent 8 }}
    spec:
      containers:
        - name: {{ .Values.frontend.name }}
          image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
          imagePullPolicy: {{ .Values.frontend.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.frontend.port }}
          resources:
            {{- toYaml .Values.frontend.resources | nindent 12 }}
```

- [ ] Create `applications/stack-chart/templates/frontend-service.yaml`:

```yaml
# applications/stack-chart/templates/frontend-service.yaml
{{- $ctx := dict "Release" .Release "Chart" .Chart "component" .Values.frontend.name -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "stack-chart.fullname" $ctx }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "stack-chart.labels" $ctx | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  type: ClusterIP
  ports:
    - port: {{ .Values.frontend.port }}
      targetPort: {{ .Values.frontend.port }}
      protocol: TCP
      name: http
  selector:
    {{- include "stack-chart.selectorLabels" $ctx | nindent 4 }}
```

- [ ] Commit:

```bash
git add applications/stack-chart/templates/frontend-deployment.yaml \
        applications/stack-chart/templates/frontend-service.yaml
git commit -m "feat(chart): add frontend Deployment and Service templates"
```

---

### Task 10: Backend templates

**Files:**
- Create: `applications/stack-chart/templates/backend-deployment.yaml`
- Create: `applications/stack-chart/templates/backend-service.yaml`

- [ ] Create `applications/stack-chart/templates/backend-deployment.yaml`:

```yaml
# applications/stack-chart/templates/backend-deployment.yaml
{{- $ctx := dict "Release" .Release "Chart" .Chart "component" .Values.backend.name -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "stack-chart.fullname" $ctx }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "stack-chart.labels" $ctx | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  replicas: {{ .Values.backend.replicaCount }}
  selector:
    matchLabels:
      {{- include "stack-chart.selectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "stack-chart.selectorLabels" $ctx | nindent 8 }}
    spec:
      containers:
        - name: {{ .Values.backend.name }}
          image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}"
          imagePullPolicy: {{ .Values.backend.image.pullPolicy }}
          args:
            {{- toYaml .Values.backend.args | nindent 12 }}
          ports:
            - containerPort: {{ .Values.backend.port }}
          resources:
            {{- toYaml .Values.backend.resources | nindent 12 }}
```

- [ ] Create `applications/stack-chart/templates/backend-service.yaml`:

```yaml
# applications/stack-chart/templates/backend-service.yaml
{{- $ctx := dict "Release" .Release "Chart" .Chart "component" .Values.backend.name -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "stack-chart.fullname" $ctx }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "stack-chart.labels" $ctx | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  type: ClusterIP
  ports:
    - port: {{ .Values.backend.port }}
      targetPort: {{ .Values.backend.port }}
      protocol: TCP
      name: http
  selector:
    {{- include "stack-chart.selectorLabels" $ctx | nindent 4 }}
```

- [ ] Commit:

```bash
git add applications/stack-chart/templates/backend-deployment.yaml \
        applications/stack-chart/templates/backend-service.yaml
git commit -m "feat(chart): add backend Deployment and Service templates"
```

---

## Chunk 4: Infrastructure Manifests

### Task 11: MySQL Secret and PVC

**Files:**
- Create: `infrastructure/mysql-secret.yaml`
- Create: `infrastructure/mysql-pvc.yaml`

- [ ] Create `infrastructure/mysql-secret.yaml`:

```yaml
# infrastructure/mysql-secret.yaml
# ---------------------------------------------------------------------------
# WARNING: Storing base64-encoded credentials in Git is only acceptable for
# local development.  In production, replace this with an ExternalSecret
# (External Secrets Operator) or a Vault-backed SecretStore.
#
# Values below are base64(echo -n "..."):
#   rootpassword → cm9vdHBhc3N3b3Jk
#   appuser      → YXBwdXNlcg==
#   apppassword  → YXBwcGFzc3dvcmQ=
#   appdb        → YXBwZGI=
# ---------------------------------------------------------------------------
apiVersion: v1
kind: Secret
metadata:
  name: mysql-credentials
  namespace: infrastructure
  annotations:
    argocd.argoproj.io/sync-wave: "0"
type: Opaque
data:
  root-password: cm9vdHBhc3N3b3Jk   # rootpassword
  username: YXBwdXNlcg==             # appuser
  password: YXBwcGFzc3dvcmQ=         # apppassword
  database: YXBwZGI=                 # appdb
```

- [ ] Create `infrastructure/mysql-pvc.yaml`:

```yaml
# infrastructure/mysql-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-data
  namespace: infrastructure
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
```

- [ ] Commit:

```bash
git add infrastructure/mysql-secret.yaml infrastructure/mysql-pvc.yaml
git commit -m "feat(infra): add MySQL Secret (wave 0) and data PVC (wave 0)"
```

---

### Task 12: MySQL Deployment + Service

**Files:**
- Create: `infrastructure/mysql-deployment.yaml`

- [ ] Create `infrastructure/mysql-deployment.yaml`:

```yaml
# infrastructure/mysql-deployment.yaml
# ---------------------------------------------------------------------------
# MySQL 8 Deployment.  Credentials are consumed from the mysql-credentials
# Secret provisioned in wave 0; this Deployment is wave 1 so Argo CD
# guarantees the Secret exists and the PVC is Bound before scheduling.
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: infrastructure
  labels:
    app.kubernetes.io/name: mysql
    app.kubernetes.io/component: database
    app.kubernetes.io/managed-by: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: mysql
      app.kubernetes.io/component: database
  strategy:
    type: Recreate   # required for single-replica stateful workloads using RWO PVC
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mysql
        app.kubernetes.io/component: database
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          ports:
            - containerPort: 3306
              name: mysql
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: root-password
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: username
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: password
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: database
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql
          readinessProbe:
            exec:
              command:
                - mysqladmin
                - ping
                - -h
                - localhost
                - -u
                - root
                - -p$(MYSQL_ROOT_PASSWORD)
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "500m"
              memory: "1Gi"
      volumes:
        - name: mysql-data
          persistentVolumeClaim:
            claimName: mysql-data
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: infrastructure
  labels:
    app.kubernetes.io/name: mysql
    app.kubernetes.io/component: database
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  type: ClusterIP
  ports:
    - port: 3306
      targetPort: 3306
      name: mysql
  selector:
    app.kubernetes.io/name: mysql
    app.kubernetes.io/component: database
```

- [ ] Commit:

```bash
git add infrastructure/mysql-deployment.yaml
git commit -m "feat(infra): add MySQL Deployment + Service (wave 1, Recreate strategy)"
```

---

### Task 13: Backup PVC + CronJob

**Files:**
- Create: `infrastructure/backup-pvc.yaml`
- Create: `infrastructure/backup-cronjob.yaml`

- [ ] Create `infrastructure/backup-pvc.yaml`:

```yaml
# infrastructure/backup-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-backups
  namespace: infrastructure
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

- [ ] Create `infrastructure/backup-cronjob.yaml`:

```yaml
# infrastructure/backup-cronjob.yaml
# ---------------------------------------------------------------------------
# MySQL backup CronJob — wave 2.
#
# Sync Wave 2 ensures:
#   - Wave 0: mysql-credentials Secret + both PVCs are Bound
#   - Wave 1: MySQL Deployment is Healthy (readiness probe passed)
#   - Wave 2: THIS CronJob is created only after MySQL is confirmed running
#
# The job runs mysqldump and writes compressed output to the backup PVC.
# Filename includes the pod's hostname (unique per job run) + timestamp.
# ---------------------------------------------------------------------------
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mysql-backup
  namespace: infrastructure
  labels:
    app.kubernetes.io/name: mysql-backup
    app.kubernetes.io/component: backup
    app.kubernetes.io/managed-by: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  schedule: "*/5 * * * *"      # every 5 minutes
  concurrencyPolicy: Forbid    # never run two backup jobs simultaneously
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata:
          labels:
            app.kubernetes.io/name: mysql-backup
            app.kubernetes.io/component: backup
        spec:
          restartPolicy: OnFailure
          containers:
            - name: mysqldump
              image: mysql:8.0
              command:
                - /bin/sh
                - -c
                - |
                  set -euo pipefail
                  BACKUP_FILE="/backups/dump-$(date +%Y%m%d-%H%M%S).sql.gz"
                  echo "==> Starting backup to ${BACKUP_FILE}"
                  mysqldump \
                    --host=mysql \
                    --user="${MYSQL_USER}" \
                    --password="${MYSQL_PASSWORD}" \
                    --databases "${MYSQL_DATABASE}" \
                    --single-transaction \
                    --quick \
                    | gzip > "${BACKUP_FILE}"
                  echo "==> Backup complete: $(du -sh ${BACKUP_FILE})"
                  echo "==> Backup directory contents:"
                  ls -lh /backups/
              env:
                - name: MYSQL_USER
                  valueFrom:
                    secretKeyRef:
                      name: mysql-credentials
                      key: username
                - name: MYSQL_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: mysql-credentials
                      key: password
                - name: MYSQL_DATABASE
                  valueFrom:
                    secretKeyRef:
                      name: mysql-credentials
                      key: database
              volumeMounts:
                - name: backup-storage
                  mountPath: /backups
              resources:
                requests:
                  cpu: "100m"
                  memory: "128Mi"
                limits:
                  cpu: "500m"
                  memory: "256Mi"
          volumes:
            - name: backup-storage
              persistentVolumeClaim:
                claimName: mysql-backups
```

- [ ] Commit:

```bash
git add infrastructure/backup-pvc.yaml infrastructure/backup-cronjob.yaml
git commit -m "feat(infra): add backup PVC + mysqldump CronJob (wave 2, every 5 min)"
```

---

## Final Commit

- [ ] Final verification commit:

```bash
git add .
git status   # should be clean
git log --oneline
```

Expected log:
```
feat(infra): add backup PVC + mysqldump CronJob (wave 2, every 5 min)
feat(infra): add MySQL Deployment + Service (wave 1, Recreate strategy)
feat(infra): add MySQL Secret (wave 0) and data PVC (wave 0)
feat(chart): add backend Deployment and Service templates
feat(chart): add frontend Deployment and Service templates
feat(chart): add _helpers.tpl with fullname, labels, selectorLabels templates
feat(chart): add stack-chart Chart.yaml and values
feat(terraform): register infrastructure + applications Argo CD Apps with sync waves
feat(terraform): deploy Argo CD via Helm, wait for readiness
feat(terraform): add Helm + Kubernetes provider config targeting k3d
feat: add Makefile with cluster/deploy/verify/destroy targets
feat: add k3d declarative cluster config (1 CP, 2 workers, LB:8080)
chore: add .gitignore for Terraform, Neovim, uv
```
