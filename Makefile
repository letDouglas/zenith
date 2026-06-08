include .env
export

# ── versions ────────────────────────────────────────────────────────────────
K3S_VERSION      = v1.27.4+k3s1
CILIUM_VERSION   = 1.14.3
LONGHORN_VERSION = 1.5.1
TRAEFIK_VERSION  = 26.0.0
ARGOCD_VERSION   = 5.46.7
VAULT_VERSION    = 0.28.0
ESO_VERSION      = 0.9.11
CNPG_VERSION     = 0.22.0

# ── configuration ────────────────────────────────────────────────────────────
MGMT_NODE        = zenith-mgmt-1
WORKLOAD_NODES   = zenith-1 zenith-2 zenith-3

KUBECONFIG_MGMT     = $(HOME)/.kube/clusters/zenith-mgmt
KUBECONFIG_WORKLOAD = $(HOME)/.kube/clusters/zenith

GITHUB_TOKEN ?= $(error Set GITHUB_TOKEN in .env)
GITHUB_USER  ?= $(error Set GITHUB_USER in .env)
GITHUB_REPO  ?= $(error Set GITHUB_REPO in .env)

.PHONY: bootstrap-mgmt bootstrap-workload destroy-mgmt destroy-workload destroy

# ── management cluster ───────────────────────────────────────────────────────
bootstrap-mgmt: mgmt-vm-create mgmt-k3s-install mgmt-vault-install mgmt-argocd-install mgmt-done

mgmt-vm-create:
	multipass launch --name $(MGMT_NODE) --cpus 2 --memory 4G --disk 20G

mgmt-k3s-install:
	$(eval MGMT_IP := $(shell multipass info $(MGMT_NODE) --format json | jq -r '.info["$(MGMT_NODE)"].ipv4[0]'))
	multipass exec $(MGMT_NODE) -- bash -c "\
		curl -sfL https://get.k3s.io | \
		INSTALL_K3S_VERSION=$(K3S_VERSION) sh -s - \
		--disable=traefik \
		--disable=servicelb"
	multipass exec $(MGMT_NODE) -- sudo cat /etc/rancher/k3s/k3s.yaml \
		| sed 's/127.0.0.1/$(MGMT_IP)/g' > $(KUBECONFIG_MGMT)
	KUBECONFIG=$(KUBECONFIG_MGMT) kubectl config rename-context default zenith-mgmt

mgmt-vault-install:
	helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
	helm repo update hashicorp
	KUBECONFIG=$(KUBECONFIG_MGMT) helm upgrade --install vault hashicorp/vault \
		--version $(VAULT_VERSION) \
		--namespace vault \
		--create-namespace \
		--values platform/management/helm/vault-values.yaml \
		--wait --timeout=120s

mgmt-argocd-install:
	helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
	helm repo update argo
	KUBECONFIG=$(KUBECONFIG_MGMT) helm upgrade --install argocd argo/argo-cd \
		--version $(ARGOCD_VERSION) \
		--namespace argocd \
		--create-namespace \
		--values platform/management/helm/argocd-values.yaml \
		--wait --timeout=120s
	brew install argocd 2>/dev/null || true

mgmt-done:
	@echo ""
	@echo "════════════════════════════════════════════════════════"
	@echo " ✅ Management cluster ready."
	@echo "════════════════════════════════════════════════════════"
	@echo ""
	@echo " Completa questi step prima di eseguire make bootstrap-workload:"
	@echo ""
	@echo " 1. Init Vault (salva output in un password manager):"
	@echo "    KUBECONFIG=$(KUBECONFIG_MGMT) kubectl exec -n vault vault-0 -- vault operator init"
	@echo ""
	@echo " 2. Unseal Vault (ripeti 3 volte con 3 chiavi diverse):"
	@echo "    KUBECONFIG=$(KUBECONFIG_MGMT) kubectl exec -n vault vault-0 -- vault operator unseal"
	@echo ""
	@echo " 3. Crea il secret con il root token:"
	@echo "    KUBECONFIG=$(KUBECONFIG_MGMT) kubectl create secret generic vault-root-token -n vault --from-literal=token=<root-token>"
	@echo ""
	@echo " 4. Abilita kv-v2 e metti la password del database in Vault:"
	@echo "    ROOT_TOKEN=<root-token>"
	@echo "    KUBECONFIG=$(KUBECONFIG_MGMT) kubectl exec -n vault vault-0 -- env VAULT_TOKEN=\$$ROOT_TOKEN vault secrets enable -path=secret kv-v2"
	@echo "    KUBECONFIG=$(KUBECONFIG_MGMT) kubectl exec -n vault vault-0 -- env VAULT_TOKEN=\$$ROOT_TOKEN vault kv put secret/postgres-credentials password=<password>"
	@echo ""
	@echo " Poi esegui: make bootstrap-workload"
	@echo ""

destroy-mgmt:
	multipass delete $(MGMT_NODE) --purge || true
	rm -f $(KUBECONFIG_MGMT)

# ── workload cluster ─────────────────────────────────────────────────────────
bootstrap-workload: workload-vms-create workload-k3s-install workload-longhorn-prereq \
	workload-cilium-install workload-cilium-config workload-cluster-wait \
	workload-longhorn-install workload-traefik-install \
	workload-vault-auth-config workload-argocd-bootstrap

workload-vms-create:
	multipass launch --name zenith-1 --cpus 2 --memory 3G --disk 20G
	multipass launch --name zenith-2 --cpus 2 --memory 3G --disk 20G
	multipass launch --name zenith-3 --cpus 2 --memory 3G --disk 20G

workload-k3s-install:
	$(eval SERVER_IP := $(shell multipass info zenith-1 --format json | jq -r '.info["zenith-1"].ipv4[0]'))
	multipass exec zenith-1 -- bash -c "\
		curl -sfL https://get.k3s.io | \
		INSTALL_K3S_VERSION=$(K3S_VERSION) sh -s - \
		--flannel-backend=none \
		--disable-network-policy \
		--disable=traefik \
		--disable=servicelb \
		--cluster-init"
	@until multipass exec zenith-1 -- sudo test -f /var/lib/rancher/k3s/server/node-token; do sleep 2; done
	@TOKEN=$$(multipass exec zenith-1 -- sudo cat /var/lib/rancher/k3s/server/node-token); \
		multipass exec zenith-2 -- bash -c \
			"curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$(K3S_VERSION) K3S_URL=https://$(SERVER_IP):6443 K3S_TOKEN=$$TOKEN sh -"; \
		multipass exec zenith-3 -- bash -c \
			"curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$(K3S_VERSION) K3S_URL=https://$(SERVER_IP):6443 K3S_TOKEN=$$TOKEN sh -"
	multipass exec zenith-1 -- sudo cat /etc/rancher/k3s/k3s.yaml \
		| sed 's/127.0.0.1/$(SERVER_IP)/g' > $(KUBECONFIG_WORKLOAD)
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl config rename-context default zenith
	rm -rf ~/.kube/cache

workload-longhorn-prereq:
	@for vm in zenith-1 zenith-2 zenith-3; do \
		multipass exec $$vm -- sudo apt-get install -y open-iscsi nfs-common && \
		multipass exec $$vm -- sudo systemctl enable --now iscsid; \
	done

workload-cilium-install:
	$(eval API_IP := $(shell multipass info zenith-1 --format json | jq -r '.info["zenith-1"].ipv4[0]'))
	helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) helm upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		--values platform/workload/helm/cilium-values.yaml \
		--set k8sServiceHost=$(API_IP) \
		--set k8sServicePort=6443 \
		--wait --timeout=120s

workload-cilium-config:
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl apply -f platform/workload/manifests/cilium/ipam.yaml

workload-cluster-wait:
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl wait node --all --for=condition=Ready --timeout=180s

workload-longhorn-install:
	helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
	helm repo update longhorn
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) helm upgrade --install longhorn longhorn/longhorn \
		--version $(LONGHORN_VERSION) \
		--namespace longhorn-system \
		--create-namespace \
		--values platform/workload/helm/longhorn-values.yaml \
		--wait --timeout=300s

workload-traefik-install:
	helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
	helm repo update traefik
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) helm upgrade --install traefik traefik/traefik \
		--version $(TRAEFIK_VERSION) \
		--namespace ingress-system \
		--create-namespace \
		--values platform/workload/helm/traefik-values.yaml \
		--wait --timeout=120s

# ── vault kubernetes auth for the workload cluster ──────────────────────────
workload-vault-auth-config:
	$(eval WORKLOAD_API_IP := $(shell multipass info zenith-1 --format json | jq -r '.info["zenith-1"].ipv4[0]'))
	$(eval ROOT_TOKEN := $(shell KUBECONFIG=$(KUBECONFIG_MGMT) kubectl get secret vault-root-token \
		-n vault -o jsonpath='{.data.token}' | base64 -d))
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl get configmap kube-root-ca.crt \
		-n kube-system -o jsonpath='{.data.ca\.crt}' > /tmp/workload-ca.crt
	KUBECONFIG=$(KUBECONFIG_MGMT) kubectl cp /tmp/workload-ca.crt vault/vault-0:/tmp/workload-ca.crt
	# Crea service account e clusterrolebinding per il token reviewer
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl create serviceaccount vault-token-reviewer \
		-n kube-system --dry-run=client -o yaml | KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl apply -f -
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl create clusterrolebinding vault-token-reviewer \
		--clusterrole=system:auth-delegator \
		--serviceaccount=kube-system:vault-token-reviewer \
		--dry-run=client -o yaml | KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl apply -f -
	# Crea secret long-lived (tipo kubernetes.io/service-account-token) per il token reviewer
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl apply -f platform/workload/manifests/vault/token-reviewer-secret.yaml
	# Aspetta che il token venga popolato nel secret
	sleep 8
	# Usa una shell unica per leggere il reviewer token e passarlo a Vault nella stessa invocazione
	# (evita il problema di $(eval ...) in recipe che può restituire stringa vuota)
	@REVIEWER_TOKEN=$$(KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl get secret vault-token-reviewer \
		-n kube-system -o jsonpath='{.data.token}' | base64 -d); \
	KUBECONFIG=$(KUBECONFIG_MGMT) kubectl exec -n vault vault-0 -- \
		env VAULT_TOKEN=$(ROOT_TOKEN) \
		vault auth enable -path=kubernetes-workload kubernetes || true; \
	KUBECONFIG=$(KUBECONFIG_MGMT) kubectl exec -n vault vault-0 -- \
		env VAULT_TOKEN=$(ROOT_TOKEN) \
		vault write auth/kubernetes-workload/config \
		kubernetes_host=https://$(WORKLOAD_API_IP):6443 \
		kubernetes_ca_cert=@/tmp/workload-ca.crt \
		token_reviewer_jwt="$$REVIEWER_TOKEN" \
		disable_local_ca_jwt=true; \
	KUBECONFIG=$(KUBECONFIG_MGMT) kubectl exec -n vault vault-0 -- \
		env VAULT_TOKEN=$(ROOT_TOKEN) \
		vault write auth/kubernetes-workload/role/database-role \
		bound_service_account_names=vault-auth-sa \
		bound_service_account_namespaces=database \
		policies=database-policy \
		ttl=1h


workload-argocd-bootstrap:
	$(eval MGMT_IP := $(shell multipass info $(MGMT_NODE) --format json | jq -r '.info["$(MGMT_NODE)"].ipv4[0]'))
	# Sostituisce qualsiasi server URL nel secret-store (IP e porta) con i valori corretti.
	# Il pattern matcha sia VAULT_SERVER_PLACEHOLDER che qualsiasi IP precedente.
	sed -i' ' 's|server: "http://[^"]*"|server: "http://$(MGMT_IP):30820"|g' \
		platform/workload/manifests/database/secret-store.yaml
	# Committa e pusha l'IP aggiornato prima che ArgoCD sincronizzi
	git add platform/workload/manifests/database/secret-store.yaml
	git commit -m "chore: update vault server IP for bootstrap [skip ci]" || true
	git push origin dev || true
	# Registra le credenziali GitHub in ArgoCD per accedere al repo
	KUBECONFIG=$(KUBECONFIG_MGMT) kubectl create secret generic github-creds \
		--namespace argocd \
		--from-literal=username=$(GITHUB_USER) \
		--from-literal=password=$(GITHUB_TOKEN) \
		--from-literal=url=$(GITHUB_REPO) \
		--dry-run=client -o yaml | KUBECONFIG=$(KUBECONFIG_MGMT) kubectl apply -f -
	KUBECONFIG=$(KUBECONFIG_MGMT) kubectl label secret github-creds -n argocd \
		argocd.argoproj.io/secret-type=repository --overwrite
	# Esporta il kubeconfig del workload cluster per registrarlo in ArgoCD
	KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl config view --raw > /tmp/workload-kubeconfig.yaml
	# Login ArgoCD via port-forward
	KUBECONFIG=$(KUBECONFIG_MGMT) argocd login \
		--port-forward --port-forward-namespace argocd --plaintext --insecure \
		--username admin \
		--password $$(KUBECONFIG=$(KUBECONFIG_MGMT) kubectl get secret argocd-initial-admin-secret \
			-n argocd -o jsonpath='{.data.password}' | base64 -d)
	# Registra il workload cluster in ArgoCD con il nome zenith-workload
	KUBECONFIG=$(KUBECONFIG_MGMT) argocd cluster add zenith \
		--kubeconfig /tmp/workload-kubeconfig.yaml \
		--name zenith-workload \
		--port-forward \
		--port-forward-namespace argocd \
		--yes
	# Applica la root-app: da qui ArgoCD gestisce tutto il resto in autonomia
	KUBECONFIG=$(KUBECONFIG_MGMT) kubectl apply -f platform/workload/argocd-apps/root-app.yaml -n argocd
	@echo ""
	@echo "════════════════════════════════════════════════════════"
	@echo " ✅ Bootstrap completo. ArgoCD sta deployando il workload cluster."
	@echo " Monitora con: KUBECONFIG=$(KUBECONFIG_WORKLOAD) kubectl get pods -A -w"
	@echo "════════════════════════════════════════════════════════"
	@echo ""

destroy-workload:
	multipass delete zenith-1 zenith-2 zenith-3 --purge || true
	rm -f $(KUBECONFIG_WORKLOAD)

destroy: destroy-mgmt destroy-workload