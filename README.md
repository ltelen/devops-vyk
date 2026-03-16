# devops-vyk

Local GitOps platform on k3d. Terraform sets up the cluster tooling (Argo CD), and Argo CD takes it from there — syncing a MySQL infrastructure chart and a frontend/backend application chart from this repo.

Infrastructure is always deployed before applications. Terraform waits for the infrastructure Argo CD Application to reach Healthy before creating the applications one, so MySQL is guaranteed to be up when the backend starts.

## Prerequisites

k3d, kubectl, Terraform >= 1.6, Helm >= 3.14, Docker, make — all on `PATH`.

## Quickstart

```bash
git clone https://github.com/ltelen/devops-vyk.git
cd devops-vyk
make all
```

This creates the k3d cluster and runs `terraform apply`. Terraform installs Argo CD, waits for the infrastructure app to be healthy (MySQL ready, backups configured), then registers the applications app. The whole thing takes 3–5 minutes on a decent connection.

## Argo CD

```bash
kubectl port-forward svc/argocd-server -n argocd 8443:80
```

Open http://localhost:8443, username `admin`, password:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d && echo
```

## Configuration

Repo URL and branch are set as locals in `terraform/gitops-apps.tf`. If you fork or switch branches, update those and re-run `make deploy`.

MySQL credentials, PVC sizes, backup schedule, and server config live in `infrastructure/infra-chart/values.yaml`. Application images and replicas are in `applications/stack-chart/values.yaml`.

The application chart supports optional ConfigMaps and Secrets per service — add `configmap.enabled: true` / `secret.enabled: true` with a `data` block to any service entry in values and the templates handle the rest.

## Commands

```bash
make all      # cluster + terraform apply
make cluster  # cluster only
make deploy   # terraform apply only
make verify   # logs from the latest backup pod
make destroy  # tear everything down
make clean    # remove .terraform cache
```

## Verifications

### Argo CD sync status

```bash
kubectl get applications -n argocd
```

Both `infrastructure` and `applications` should show `Synced` and `Healthy`.

### Backup running

```bash
make verify
```

Or trigger one manually and follow the logs:

```bash
kubectl create job --from=cronjob/mysql-backup manual-backup-$(date +%s) -n infrastructure
kubectl logs -n infrastructure -l job-name=manual-backup-<suffix> -f
```

Exec into a pod to inspect the actual files on the PVC:

```bash
kubectl run backup-inspector \
  --image=mysql:8.0 --restart=Never --rm -it \
  --overrides='{
    "spec": {
      "volumes": [{"name":"bk","persistentVolumeClaim":{"claimName":"mysql-backups"}}],
      "containers": [{"name":"backup-inspector","image":"mysql:8.0",
        "command":["bash"],"volumeMounts":[{"name":"bk","mountPath":"/backups"}]}]
    }
  }' -n infrastructure

# inside the pod
ls -lh /backups/
zcat /backups/dump-<timestamp>.sql.gz | head -20
```

### Frontend and backend

```bash
# frontend (nginx)
kubectl port-forward svc/applications-frontend -n applications 8080:80
curl http://localhost:8080

# backend (http-echo)
kubectl port-forward svc/applications-backend -n applications 5678:5678
curl http://localhost:5678
# Hello from backend
```

### Data persistence

Write something to MySQL, restart the pod, and verify it's still there:

```bash
kubectl exec -it deploy/mysql -n infrastructure -- \
  mysql -u appuser -papppassword appdb

CREATE TABLE IF NOT EXISTS test (id INT PRIMARY KEY, val VARCHAR(50));
INSERT INTO test VALUES (1, 'persisted');
exit

kubectl delete pod -l app.kubernetes.io/name=mysql -n infrastructure

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=mysql -n infrastructure --timeout=60s

kubectl exec -it deploy/mysql -n infrastructure -- \
  mysql -u appuser -papppassword appdb -e "SELECT * FROM test;"
```

## Known issues

- Credentials are in Git — fine for local dev, not for production
- MySQL runs as a single replica with `Recreate` strategy, so restarts cause a brief outage
- Argo CD is running without TLS (`--insecure`)
- No ingress — services are ClusterIP, use port-forward to access them

## Troubleshooting

**`terraform plan` fails with `no matches for kind Application`** — the `kubernetes_manifest` provider validates CRDs at plan time and Argo CD doesn't exist yet. This repo uses `kubectl_manifest` (alekc/kubectl provider) which skips plan-time validation.

**Argo CD sync stuck on PVC health** — k3d's `local-path` StorageClass uses `WaitForFirstConsumer`, so PVCs stay Pending until a consumer pod is scheduled. There's a Lua health override in `argocd.tf` that treats Pending PVCs as Healthy to unblock wave progression.

**`mysqldump` PROCESS privilege error** — MySQL 8.0 needs the `PROCESS` privilege to dump tablespace metadata. The backup job uses `--no-tablespaces` to skip that.

**`make deploy` times out waiting for infrastructure** — check MySQL pod logs: `kubectl logs -n infrastructure -l app.kubernetes.io/name=mysql`
