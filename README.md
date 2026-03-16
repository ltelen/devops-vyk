# devops-vyk

`make all` creates a local Kubernetes cluster, installs Argo CD with Terraform, and deploys two Helm charts in dependency order:

1. `infrastructure/infra-chart` (MySQL + backup job) — deployed first
2. `applications/stack-chart` (frontend/backend) — deployed only after infrastructure is healthy

Terraform creates both Argo CD Application resources directly. A `null_resource` between them runs `kubectl wait` to block until the infrastructure Application reaches `Healthy` before the applications Application is created — ensuring MySQL is running before the backend starts.

## What gets deployed

### Infrastructure chart

- `mysql-credentials` Secret (credentials)
- `mysql-config` ConfigMap (server config mounted at `/etc/mysql/conf.d`)
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
- optional ConfigMap (`configmap.enabled: true`, `configmap.data`)
- optional Secret (`secret.enabled: true`, `secret.data`) — values are base64-encoded at render time

Resources that are disabled or omitted are not rendered.

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

`terraform/gitops-apps.tf` contains two locals that control where Argo CD pulls from:

- `repo_url` — your Git remote
- `target_revision` — branch or tag to track

If you fork the repo or work from a different branch, update those two values and run `make deploy` again.

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

Verify backup files are written to the PVC:

```bash
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
zcat /backups/dump-<timestamp>.sql.gz | head -20
```

## Access frontend and backend

The services are ClusterIP. Use port-forward to reach them locally:

```bash
# Frontend (nginx)
kubectl port-forward svc/applications-frontend -n applications 8080:80
curl http://localhost:8080

# Backend (http-echo)
kubectl port-forward svc/applications-backend -n applications 5678:5678
curl http://localhost:5678
# returns: Hello from backend
```

Service names follow the pattern `<argo-app-name>-<service-name>`. The Argo CD app is named `applications`, so the services are `applications-frontend` and `applications-backend`.

## Verify data persistence

This confirms that MySQL data survives a pod restart (data lives on the PVC, not inside the container):

```bash
# Connect to MySQL
kubectl exec -it deploy/mysql -n infrastructure -- \
  mysql -u appuser -papppassword appdb

# Create a table and insert a row
CREATE TABLE IF NOT EXISTS test (id INT PRIMARY KEY, val VARCHAR(50));
INSERT INTO test VALUES (1, 'persisted');
exit

# Delete the MySQL pod — Recreate strategy brings it back automatically
kubectl delete pod -l app.kubernetes.io/name=mysql -n infrastructure

# Wait for the pod to become ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=mysql \
  -n infrastructure --timeout=60s

# Verify the row survived
kubectl exec -it deploy/mysql -n infrastructure -- \
  mysql -u appuser -papppassword appdb -e "SELECT * FROM test;"
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
