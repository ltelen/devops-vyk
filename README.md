# devops-vyk

A fully local GitOps platform running on k3d. Terraform provisions a three-node Kubernetes cluster and installs Argo CD via Helm; Argo CD then manages all workloads — a MySQL database with automated backups and a two-tier application stack — using sync-wave-ordered manifests pulled from this repository.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  Local machine                                                      │
│                                                                     │
│  make all                                                           │
│    │                                                                │
│    ├─► k3d cluster create (k3d-config.yaml)                        │
│    │     1 control-plane + 2 agents                                 │
│    │     k3s v1.29.4, traefik disabled, port 8080→80               │
│    │                                                                │
│    └─► terraform apply                                              │
│          │                                                          │
│          ├─► helm_release "argocd"          (namespace: argocd)    │
│          │     Argo CD 6.7.18                                       │
│          │     wait=true — blocks until pods Ready                  │
│          │                                                          │
│          ├─► kubectl_manifest "infrastructure"  sync-wave: 0       │
│          │     source: infrastructure/infra-chart/                 │
│          │     destination namespace: infrastructure                │
│          │                                                          │
│          └─► kubectl_manifest "applications"    sync-wave: 1       │
│                source: applications/stack-chart/                   │
│                destination namespace: applications                  │
│                depends_on: infrastructure App                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

Argo CD — infrastructure App
  wave 0: mysql-credentials Secret, mysql-data PVC, mysql-backups PVC
  wave 1: MySQL Deployment + Service
  wave 2: mysql-backup CronJob

Argo CD — applications App (stack-chart Helm)
  wave 0: backend Deployment + Service
  wave 1: frontend Deployment + Service
```

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| [k3d](https://k3d.io/) | v5.6 | Manages k3s clusters in Docker |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.29 | Must match the k3s version |
| [Terraform](https://www.terraform.io/downloads) | v1.6 | Required by `terraform/providers.tf` |
| [Helm](https://helm.sh/docs/intro/install/) | v3.14 | Used by the Terraform Helm provider |
| Docker | 24+ | Required by k3d |
| make | any | Runs the Makefile targets |

All tools must be on `PATH`.

---

## Quickstart

```bash
# 1. Clone the repository
git clone https://github.com/ltelen/devops-vyk.git
cd devops-vyk

# 2. Create the cluster and deploy everything
make all
```

`make all` runs two targets in sequence:

1. **`make cluster`** — calls `k3d cluster create --config k3d-config.yaml`, which spins up a one-control-plane, two-agent k3s cluster named `devops-vyk`, then merges its kubeconfig entry into `~/.kube/config`.
2. **`make deploy`** — runs `terraform -chdir=terraform init -upgrade` followed by `terraform -chdir=terraform apply -auto-approve`. Terraform installs Argo CD via Helm (blocking until all pods are Ready), then registers the two Argo CD Application resources. Argo CD immediately reconciles both Applications from Git.

Total cold-start time is roughly 3–5 minutes depending on image pull speeds.

### Access the Argo CD UI

```bash
# Port-forward the Argo CD server
kubectl port-forward svc/argocd-server -n argocd 8443:80

# Open in browser
open http://localhost:8443
```

### Retrieve the initial admin password

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Log in with username `admin` and the password printed above.

---

## Directory structure

```
devops-vyk/
├── k3d-config.yaml                  # Declarative k3d cluster definition
├── Makefile                         # Developer ergonomics (see targets table)
│
├── terraform/
│   ├── providers.tf                 # Helm, Kubernetes, kubectl provider config
│   ├── argocd.tf                    # Argo CD Helm release + PVC health-check override
│   └── gitops-apps.tf               # Argo CD Application CRs for both Apps
│
├── infrastructure/
│   └── infra-chart/                 # Helm chart — reconciled by infrastructure App
│       ├── Chart.yaml
│       ├── values.yaml              # Sync waves, MySQL config, PVC sizes, backup schedule
│       └── templates/
│           ├── _helpers.tpl
│           ├── mysql-secret.yaml    # Opaque Secret with DB credentials (wave 0)
│           ├── pvcs.yaml            # mysql-data (5 Gi) + mysql-backups (10 Gi) PVCs (wave 0)
│           ├── mysql.yaml           # MySQL 8.0 Deployment + ClusterIP Service (wave 1)
│           └── backup-cronjob.yaml  # mysqldump CronJob running every 5 min (wave 2)
│
└── applications/
    └── stack-chart/                 # Helm chart — reconciled by applications App
        ├── Chart.yaml
        ├── values.yaml              # services list: name, image, port, syncWave, resources
        └── templates/
            ├── _helpers.tpl
            ├── deployment.yaml      # loops over .Values.services → one Deployment each
            └── service.yaml         # loops over .Values.services → one ClusterIP Service each
```

---

## Sync wave ordering

### Two-layer model

Ordering is enforced at two levels:

1. **Terraform `depends_on`** (coarse): the `applications` Application resource depends on the `infrastructure` Application resource, so Terraform always creates infrastructure first.
2. **`argocd.argoproj.io/sync-wave` annotations** (fine): within each Argo CD Application, resources are applied in ascending wave order. Argo CD waits for all resources in wave N to reach a Healthy status before applying wave N+1.

### infrastructure App (infra-chart)

Wave numbers are set in `infrastructure/infra-chart/values.yaml` under `syncWaves` and injected into each template via the `argocd.argoproj.io/sync-wave` annotation.

| Wave | `values.yaml` key | Resources | Why this order |
|---|---|---|---|
| 0 | `syncWaves.base` | `mysql-credentials` Secret, `mysql-data` PVC, `mysql-backups` PVC | No dependencies; must exist before MySQL starts |
| 1 | `syncWaves.mysql` | MySQL Deployment, MySQL Service | Requires the Secret (env vars) and PVC (volume) from wave 0 |
| 2 | `syncWaves.backup` | `mysql-backup` CronJob | Requires MySQL to be running and reachable on `mysql:3306` |

### applications App (stack-chart)

Wave numbers are set per-service in `applications/stack-chart/values.yaml` under `services[].syncWave` and injected by the generic `deployment.yaml` and `service.yaml` loop templates.

| Wave | `values.yaml` field | Resources | Why this order |
|---|---|---|---|
| 0 | `services[name=backend].syncWave` | backend Deployment, backend Service | No dependencies within this App |
| 1 | `services[name=frontend].syncWave` | frontend Deployment, frontend Service | Logically depends on backend being healthy first |

### PVC health-check override

k3d's `local-path` StorageClass uses `WaitForFirstConsumer` volume binding. PVCs remain in `Pending` until a Pod referencing them is scheduled. Without intervention Argo CD marks `Pending` PVCs as `Progressing`, which stalls wave advancement indefinitely.

`terraform/argocd.tf` installs a Lua custom health check that treats `Pending` PVCs as `Healthy`, allowing wave 0 to complete and wave 1 (MySQL) to proceed:

```yaml
configs:
  cm:
    resource.customizations.health.PersistentVolumeClaim: |
      hs = {}
      if obj.status.phase == "Pending" then
        hs.status = "Healthy"
        hs.message = "Waiting for first consumer (WaitForFirstConsumer binding mode)"
      ...
      return hs
```

---

## Configuration reference

All values that are likely to change between forks are in `terraform/gitops-apps.tf` locals:

```hcl
locals {
  repo_url         = "https://github.com/ltelen/devops-vyk.git"
  target_revision  = "feature/initial-task"
  argocd_namespace = kubernetes_namespace.argocd.metadata[0].name
}
```

| Variable | Current value | Description |
|---|---|---|
| `repo_url` | `https://github.com/ltelen/devops-vyk.git` | Git remote Argo CD polls for changes |
| `target_revision` | `feature/initial-task` | Branch or tag to track |
| `argocd_namespace` | `argocd` | Namespace where Application CRs are created |

To point Argo CD at a different fork or branch, update these two locals and run `make deploy`.

**Infrastructure chart** — `infrastructure/infra-chart/values.yaml` controls MySQL credentials, PVC sizes, backup schedule, and sync wave numbers.

**Application chart** — `applications/stack-chart/values.yaml` defines each service as an entry in the `services` list. Add, remove, or reconfigure services there; the generic loop templates render the corresponding Deployments and Services automatically.

---

## Makefile targets

| Target | Description |
|---|---|
| `make all` | Default target — runs `cluster` then `deploy` |
| `make cluster` | Creates the k3d cluster from `k3d-config.yaml` and merges kubeconfig |
| `make deploy` | Runs `terraform init -upgrade` + `terraform apply -auto-approve` |
| `make verify` | Finds the most recent backup pod and tails its logs |
| `make destroy` | Destroys Terraform resources then deletes the k3d cluster |
| `make clean` | Removes the local `.terraform/` cache and lock file |

---

## Operational runbook

### Access the Argo CD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8443:80
# Visit http://localhost:8443
# Username: admin
```

### Retrieve the admin password

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Verify the last backup ran

```bash
make verify
```

This finds the most recently created pod with a `job-name` label in the `infrastructure` namespace and prints its logs. A successful run ends with a line like:

```
==> Backup complete: 4.0K  /backups/dump-20260316-120500.sql.gz
```

### Manually trigger an immediate backup

```bash
kubectl create job --from=cronjob/mysql-backup manual-backup-$(date +%s) \
  -n infrastructure
```

Then tail the pod logs:

```bash
kubectl logs -n infrastructure -l job-name=manual-backup-<suffix> -f
```

### Inspect a backup file

```bash
# Open a shell in a debug pod that mounts the backup PVC
kubectl run backup-inspector \
  --image=mysql:8.0 \
  --restart=Never \
  --rm -it \
  --overrides='{
    "spec": {
      "volumes": [{"name":"bk","persistentVolumeClaim":{"claimName":"mysql-backups"}}],
      "containers": [{"name":"backup-inspector","image":"mysql:8.0",
        "command":["bash"],"volumeMounts":[{"name":"bk","mountPath":"/backups"}]}]
    }
  }' \
  -n infrastructure

# Inside the pod:
ls -lh /backups/
zcat /backups/dump-<timestamp>.sql.gz | head -40
```

### Check Argo CD sync status

```bash
# List all Applications
kubectl get applications -n argocd

# Describe a specific App
kubectl describe application infrastructure -n argocd
kubectl describe application applications -n argocd
```

---

## Known limitations / production hardening notes

| Area | Current state | Production recommendation |
|---|---|---|
| **Secrets in Git** | `infrastructure/infra-chart/values.yaml` contains plaintext credentials committed to the repository; the template base64-encodes them at render time | Replace with [External Secrets Operator](https://external-secrets.io/) backed by Vault, AWS Secrets Manager, or equivalent |
| **Single-replica MySQL** | `replicas: 1` with `Recreate` rollout strategy — any restart causes downtime | Use MySQL Operator, Galera cluster, or managed RDS |
| **No TLS on Argo CD** | Server runs in `--insecure` mode; traffic is plaintext | Add a TLS-terminating ingress or re-enable TLS with a valid certificate |
| **No ingress for workloads** | Frontend and backend are ClusterIP only; unreachable from host | Add an Ingress controller (nginx, traefik) and Ingress resources |
| **Backup retention** | Old dump files accumulate on the PVC with no pruning | Add a housekeeping CronJob or lifecycle policy to delete files older than N days |
| **No RBAC hardening** | Argo CD uses the `default` project with broad cluster access | Create dedicated Argo CD Projects with namespace-scoped permissions |
| **Single node for data** | PVCs bind to whichever node schedules the Pod | Use a distributed storage class (Longhorn, Rook-Ceph) for multi-node resilience |

---

## Troubleshooting

| Error | Root cause | Fix |
|---|---|---|
| `no matches for kind Application in group argoproj.io` during `terraform plan` | `kubernetes_manifest` validates CRD schema at plan time by querying the live API. When Argo CD does not yet exist the CRD is absent, so the plan fails. `depends_on` only controls apply order — it cannot fix plan-time validation. | Use `kubectl_manifest` from the `alekc/kubectl` provider instead. This provider defers schema validation to apply time. Already applied in `gitops-apps.tf`. |
| PVC stays `Pending`; Argo CD sync hangs at wave 0 | k3d's `local-path` StorageClass uses `WaitForFirstConsumer` binding mode. PVCs only bind after a consuming Pod is scheduled. Argo CD's default health check marks `Pending` PVCs as `Progressing`, blocking wave advancement. | Install the Lua PVC health-check override in `argocd.tf` that promotes `Pending` to `Healthy`. Already present in this repository. |
| `mysqldump: Error 1227: Access denied; you need the PROCESS privilege` | MySQL 8.0 `mysqldump` reads InnoDB tablespace metadata by default, which requires the `PROCESS` privilege. The `appuser` account only has database-level grants. | Pass `--no-tablespaces` to `mysqldump`. Tablespace metadata is not required for a logical restore. Already applied in `backup-cronjob.yaml`. |
| `terraform apply` fails with provider authentication errors | The kubeconfig context `k3d-devops-vyk` does not exist — the cluster was not created or `k3d kubeconfig merge` was not run. | Run `make cluster` before `make deploy`, or run `k3d kubeconfig merge devops-vyk --kubeconfig-merge-default` manually. |
| Argo CD Application stuck `OutOfSync` after `make deploy` | Argo CD has not yet completed its first Git poll (default interval: 3 minutes). | Wait for the sync cycle or trigger a manual sync from the UI or with `kubectl patch`. |
