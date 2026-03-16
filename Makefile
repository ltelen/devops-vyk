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
