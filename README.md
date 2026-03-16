# devops-vyk

`make all` creates a local Kubernetes cluster, installs Argo CD with Terraform, and lets Argo CD sync two Helm charts from this repo:

- `infrastructure/infra-chart` (MySQL + backup job)
- `applications/stack-chart` (frontend/backend app services)

## What gets deployed

### Infrastructure chart

- `mysql-credentials` secret
- `mysql-data` PVC
- `mysql-backups` PVC
- `mysql` Deployment + Service
- `mysql-backup` CronJob (mysqldump every 5 minutes)

Sync order is controlled by `syncWaves` in `infrastructure/infra-chart/values.yaml`:

- `base` -> secret + PVCs
- `mysql` -> deployment + service
- `backup` -> cronjob

### Application chart

`applications/stack-chart` uses a single looped template for Deployments and a single looped template for Services. Everything comes from `services` in `applications/stack-chart/values.yaml`.

Each service entry supports:

- image, replicas, ports, resources
- sync wave
- optional probes (`liveness`, `readiness`, `startup`)
- optional args

If probes are omitted, they are simply not rendered.

## Prerequisites

- k3d
- kubectl
- Terraform >= 1.6
- Helm >= 3.14
- Docker
- make

All tools must be available in your shell `PATH`.

## Quickstart

```bash
git clone https://github.com/ltelen/devops-vyk.git
cd devops-vyk
make all
```

This runs:

1. `make cluster` -> creates the k3d cluster from `k3d-config.yaml`
2. `make deploy` -> `terraform init -upgrade` + `terraform apply -auto-approve`

## Argo CD access

```bash
kubectl port-forward svc/argocd-server -n argocd 8443:80
open http://localhost:8443
```

Get initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

## Important repo config

Argo CD source repo and revision are in `terraform/gitops-apps.tf`:

- `repo_url = "https://github.com/ltelen/devops-vyk.git"`
- `target_revision = "main"`

If you work from a fork or another branch, update those values and run `make deploy` again.

## Day-to-day commands

```bash
# deploy everything
make all

# only create cluster
make cluster

# only apply terraform/argocd changes
make deploy

# show logs of latest backup job pod
make verify

# teardown
make destroy
```

Manual backup trigger:

```bash
kubectl create job --from=cronjob/mysql-backup manual-backup-$(date +%s) -n infrastructure
kubectl logs -n infrastructure -l job-name=manual-backup-<suffix> -f
```

## Notes and limitations

- Credentials are stored in git (good enough for local dev only).
- MySQL is single replica (`Recreate` strategy), so restarts cause downtime.
- Argo CD is configured insecure for local use.
- App services are ClusterIP only (no ingress by default).

## Troubleshooting

- `terraform plan` complaining about Argo CD `Application` CRD:
  this repo uses `kubectl_manifest` to avoid plan-time CRD validation issues.

- Argo CD stuck on PVC health:
  `terraform/argocd.tf` includes a PVC health override for `WaitForFirstConsumer`.

- `mysqldump` PROCESS privilege error:
  backup job already uses `--no-tablespaces`.
