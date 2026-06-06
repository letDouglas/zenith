-include .env
export

CLUSTER_NAME     = zenith
K3S_VERSION      = v1.27.4+k3s1
CILIUM_VERSION   = 1.14.3
LONGHORN_VERSION = 1.5.1
TRAEFIK_VERSION  = 26.0.0
KUBECONFIG_ZENITH = $(HOME)/.kube/clusters/zenith
ARGOCD_VERSION   = 5.46.7

GITHUB_TOKEN ?= $(error Imposta GITHUB_TOKEN in .env)
GITHUB_USER  ?= $(error Imposta GITHUB_USER in .env)
GITHUB_REPO  ?= $(error Imposta GITHUB_REPO in .env)

.PHONY: bootstrap destroy

destroy:
	multipass delete zenith-1 zenith-2 zenith-3 --purge || true

bootstrap: vms-create k3s-install longhorn-prereq cilium-install cilium-config cluster-wait longhorn-install traefik-install argocd-install argocd-bootstrap
	@echo ""
	@echo "✅ Bootstrap completo — esegui: switch zenith"


vms-create:
	multipass launch --name zenith-1 --cpus 2 --memory 4G --disk 20G
	multipass launch --name zenith-2 --cpus 2 --memory 4G --disk 20G
	multipass launch --name zenith-3 --cpus 2 --memory 4G --disk 20G

k3s-install:
	$(eval SERVER_IP := $(shell multipass info zenith-1 --format json | jq -r '.info["zenith-1"].ipv4[0]'))
	multipass exec zenith-1 -- bash -c "\
		curl -sfL https://get.k3s.io | \
		INSTALL_K3S_VERSION=$(K3S_VERSION) sh -s - \
		--flannel-backend=none \
		--disable-network-policy \
		--disable=traefik \
		--disable=servicelb \
		--cluster-init"
	@echo "==> Attendo token..."
	@until multipass exec zenith-1 -- sudo test -f /var/lib/rancher/k3s/server/node-token; \
		do sleep 2; done
	@TOKEN=$$(multipass exec zenith-1 -- sudo cat /var/lib/rancher/k3s/server/node-token); \
		multipass exec zenith-2 -- bash -c \
			"curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$(K3S_VERSION) K3S_URL=https://$(SERVER_IP):6443 K3S_TOKEN=$$TOKEN sh -"; \
		multipass exec zenith-3 -- bash -c \
			"curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$(K3S_VERSION) K3S_URL=https://$(SERVER_IP):6443 K3S_TOKEN=$$TOKEN sh -"
	multipass exec zenith-1 -- sudo cat /etc/rancher/k3s/k3s.yaml \
		| sed 's/127.0.0.1/$(SERVER_IP)/g' > $(KUBECONFIG_ZENITH)
	KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl config rename-context default zenith
	rm -rf ~/.kube/cache

longhorn-prereq:
	@for vm in zenith-1 zenith-2 zenith-3; do \
		multipass exec $$vm -- sudo apt-get install -y open-iscsi nfs-common && \
		multipass exec $$vm -- sudo systemctl enable --now iscsid; \
	done

cilium-install:
	$(eval API_IP := $(shell multipass info zenith-1 --format json | jq -r '.info["zenith-1"].ipv4[0]'))
	helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
	KUBECONFIG=$(KUBECONFIG_ZENITH) helm upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		--values platform/helm/cilium-values.yaml \
		--set k8sServiceHost=$(API_IP) \
		--set k8sServicePort=6443 \
		--wait --timeout=120s

cilium-config:
	KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl apply -f platform/manifests/cilium-ipam.yaml

cluster-wait:
	KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl wait node --all --for=condition=Ready --timeout=180s

longhorn-install:
	helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
	helm repo update longhorn
	KUBECONFIG=$(KUBECONFIG_ZENITH) helm upgrade --install longhorn longhorn/longhorn \
		--version $(LONGHORN_VERSION) \
		--namespace longhorn-system \
		--create-namespace \
		--values platform/helm/longhorn-values.yaml \
		--wait --timeout=300s

traefik-install:
	helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
	helm repo update traefik
	KUBECONFIG=$(KUBECONFIG_ZENITH) helm upgrade --install traefik traefik/traefik \
	  --version $(TRAEFIK_VERSION) \
	  --namespace ingress-system \
	  --create-namespace \
	  --values platform/helm/traefik-values.yaml \
	  --wait --timeout=120s

argocd-install:
	helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
	helm repo update argo
	KUBECONFIG=$(KUBECONFIG_ZENITH) helm upgrade --install argocd argo/argo-cd \
	  --version $(ARGOCD_VERSION) \
	  --namespace argocd \
	  --create-namespace \
	  --values platform/helm/argocd-values.yaml \
	  --wait --timeout=120s

argocd-bootstrap:
	KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl create namespace cnpg-system --dry-run=client -o yaml | KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl apply -f -
	KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl create secret generic github-creds \
		--namespace argocd \
		--from-literal=username=$(GITHUB_USER) \
		--from-literal=password=$(GITHUB_TOKEN) \
		--from-literal=url=$(GITHUB_REPO) \
		--dry-run=client -o yaml | KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl apply -f -
	KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl label secret github-creds -n argocd \
		argocd.argoproj.io/secret-type=repository --overwrite
	KUBECONFIG=$(KUBECONFIG_ZENITH) kubectl apply -f platform/argocd-apps/root-app.yaml -n argocd
	@echo ""
	@echo "✅ Bootstrap completed. ArgoCD is deploying wave 1 (Vault + ESO)."
	@echo ""
	@echo "⚠️  MANUAL STEPS REQUIRED:"
	@echo ""
	@echo "  1. Wait for Vault to be Running:"
	@echo "     kubectl get pod -n vault -w"
	@echo ""
	@echo "  2. Initialize and unseal Vault:"
	@echo "     kubectl exec -n vault vault-0 -- vault operator init"
	@echo "     kubectl exec -n vault vault-0 -- vault operator unseal  # x3"
	@echo ""
	@echo "  3. Create the secret containing the root token:"
	@echo "     kubectl create secret generic vault-root-token --namespace vault --from-literal=token=<root-token>"
	@echo ""
	@echo "  4. Store the database password in Vault:"
	@echo "     ROOT_TOKEN=\$$(kubectl get secret vault-root-token -n vault -o jsonpath='{.data.token}' | base64 -d)"
	@echo "     kubectl exec -n vault vault-0 -- env VAULT_TOKEN=\$$ROOT_TOKEN vault kv put secret/postgres-credentials password=<password>"
	@echo ""
	@echo "  Done. ArgoCD will automatically complete the deployment."
	@echo ""