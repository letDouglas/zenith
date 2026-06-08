# zenith

A professional bare-metal Kubernetes homelab environment, designed to mirror enterprise GitOps patterns.

Two-cluster architecture: a **management cluster** running ArgoCD and Vault, and a **workload cluster** running the actual applications.

---

## stack

| component | version | cluster |
|---|---|---|
| k3s | v1.27.4 | both |
| Cilium | 1.14.3 | workload |
| Longhorn | 1.5.1 | workload |
| Traefik | 26.0.0 | workload |
| ArgoCD | 5.46.7 | management |
| Vault | 0.28.0 (chart) | management |
| External Secrets Operator | 0.9.11 | workload |
| CloudNativePG | 0.22.0 (chart) | workload |

---

## architecture

```
┌─────────────────────────────┐     ┌─────────────────────────────────────┐
│   management cluster        │     │   workload cluster                  │
│   zenith-mgmt-1 (4GB)       │     │   zenith-1/2/3 (3GB each)           │
│                             │     │                                     │
│   ArgoCD ──────────────────────────► deploys everything below           │
│   Vault  ◄──────────────────────────  ESO reads secrets                 │
│                             │     │   CNPG + Postgres                   │
│                             │     │   Longhorn + Cilium + Traefik       │
└─────────────────────────────┘     └─────────────────────────────────────┘
```

Secrets flow:
```
Human puts password in Vault (once)
  └── ESO syncs it as postgres-db-secret in namespace database
        └── CNPG uses it to initialize app_db with app_user
```

---

## prerequisites

```bash
brew install --cask multipass
brew install kubernetes-cli helm jq argocd
```

Optional but recommended:

```bash
brew install danielfoehrkn/switch/switch
brew install kubecolor
brew install derailed/k9s/k9s
```

---

## kubeconfig setup

```bash
mkdir -p ~/.kube/clusters
```

Add to `~/.zshrc`:

```bash
export KUBECONFIG=~/.kube/config:~/.kube/clusters/zenith-mgmt:~/.kube/clusters/zenith
```

If you use kube-switch, add to `~/.kube/kube-switch.yaml`:

```yaml
- kind: filesystem
  id: local
  paths:
    - ~/.kube/clusters/zenith-mgmt
    - ~/.kube/clusters/zenith
```

---

## usage

### step 1 — management cluster

```bash
make bootstrap-mgmt
```

This creates the management VM, installs k3s, Vault, and ArgoCD.

When done, complete these **one-time manual steps**:

**Init and unseal Vault:**
```bash
kubectl exec -n vault vault-0 -- vault operator init
# Save the 5 unseal keys and root token somewhere safe (password manager)

kubectl exec -n vault vault-0 -- vault operator unseal
# Repeat 3x with 3 different keys
```

**Create the root token secret:**
```bash
kubectl create secret generic vault-root-token \
  -n vault --from-literal=token=<root-token>
```

**Enable kv-v2 and put the database password in Vault:**
```bash
ROOT_TOKEN=<root-token>

kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$ROOT_TOKEN vault secrets enable -path=secret kv-v2

kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$ROOT_TOKEN vault policy write database-policy - <<EOF
path "secret/data/postgres-credentials" { capabilities = ["read"] }
EOF

kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$ROOT_TOKEN vault kv put secret/postgres-credentials password=<your-password>
```

### step 2 — workload cluster

```bash
make bootstrap-workload
```

This creates 3 workload VMs, installs k3s + Cilium + Longhorn + Traefik, registers the workload cluster in ArgoCD, and applies the root-app.

ArgoCD then automatically deploys ESO, CNPG, and Postgres. No further manual steps.

---

## verify

Check everything is running:

```bash
switch zenith
kubectl get pods -A
kubectl get pods -n database -w   # wait for all 3 postgres pods Running
```

Retrieve the database password:

```bash
kubectl get secret postgres-db-secret -n database \
  -o jsonpath='{.data.password}' | base64 -d
```

Connect to the database:

```bash
kubectl exec -it zenith-postgres-1 -n database -- \
  psql -U app_user -d app_db -h localhost
```

---

## teardown

```bash
make destroy-workload   # destroy workload cluster only
make destroy-mgmt       # destroy management cluster only
make destroy            # destroy everything
```

---

## notes

**Why two clusters** — Vault lives on the management cluster which is never destroyed. The workload cluster can be destroyed and rebuilt at any time without touching secrets. No race conditions, no bootstrap jobs, no sync waves needed.

**Why multipass** — Longhorn requires `open-iscsi` on the actual node host. Docker-based tools (k3d, kind, minikube) can't provide this. Multipass creates real Ubuntu VMs where `apt-get install open-iscsi` works.

**Cilium without kube-proxy** — `--disable-kube-proxy` doesn't exist in k3s v1.27. Setting `kubeProxyReplacement: strict` in Cilium's Helm values is enough.

**Vault token for ESO** — `make bootstrap-workload` automatically creates a scoped Vault token for ESO and stores it as a Kubernetes secret in the workload cluster. You never touch it manually.

---

## roadmap

- [x] Cilium CNI
- [x] Longhorn storage
- [x] Traefik ingress
- [x] ArgoCD GitOps
- [x] Vault secrets management (management cluster)
- [x] External Secrets Operator
- [x] CloudNativePG
- [ ] Gitea (Git server using the Postgres cluster)
- [ ] Ingress routes (ArgoCD UI, Longhorn UI, Vault UI)
- [ ] Monitoring (?)
- [ ] Backup (CNPG backups to S3/MinIO)