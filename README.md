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

**Why two clusters** — Vault lives on the management cluster which is never destroyed. The workload cluster can be destroyed and rebuilt at any time without touching secrets. No race conditions, no bootstrap jobs, no sync waves needed.

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

The Makefile writes cluster configs to `~/.kube/clusters/`. Create the directory and register the paths:

```bash
mkdir -p ~/.kube/clusters
```

Add to `~/.kube/kube-switch.yaml` (used by `switch`):

```yaml
- kind: filesystem
  id: local
  paths:
    - ~/.kube/clusters/zenith-mgmt
    - ~/.kube/clusters/zenith
```

Then switch between clusters with:

```bash
switch zenith-mgmt   # management cluster
switch zenith        # workload cluster
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
switch zenith-mgmt

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

**Enable kv-v2 and put the database credentials in Vault:**
```bash
ROOT_TOKEN=<root-token>

kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$ROOT_TOKEN vault secrets enable -path=secret kv-v2

kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$ROOT_TOKEN vault kv put secret/postgres-credentials \
  username=app_user \
  password=<your-password>
```

> Both `username` and `password` must be stored in Vault. The ExternalSecret maps both fields into the Kubernetes secret consumed by CloudNativePG.

### step 2 — workload cluster

```bash
make bootstrap-workload
```

This creates 3 workload VMs, installs k3s + Cilium + Longhorn + Traefik, configures Vault Kubernetes auth for the workload cluster, registers it in ArgoCD, and applies the root-app.

ArgoCD then automatically deploys ESO, CNPG, and Postgres. No further manual steps.

**What `bootstrap-workload` does automatically:**

- Creates a `vault-token-reviewer` ServiceAccount + long-lived token secret in the workload cluster
- Copies the workload cluster CA cert into Vault
- Enables the `kubernetes-workload` auth mount in Vault and writes the `database-policy`
- Creates the `database-role` binding the `vault-auth-sa` ServiceAccount to the policy
- Updates `secret-store.yaml` with the current management VM IP via `sed` and pushes to Git
- Registers GitHub credentials and the workload cluster into ArgoCD
- Deploys the root-app (App of Apps pattern)

---

## verify

Check everything is running:

```bash
switch zenith
kubectl get pods -A
kubectl get pods -n database -w   # wait for all 3 postgres pods Running
```

Retrieve the synced database credentials:

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

## troubleshooting

### ExternalSecrets `permission denied` (403)

Vault requires an explicit policy granting read access on the secret path. The policy is written automatically by `make bootstrap-workload`, but if you re-ran Vault init manually, check:

```bash
switch zenith-mgmt

kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=<root-token> vault policy read database-policy
```

If missing, re-apply:

```bash
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=<root-token> \
  sh -c 'echo "path \"secret/data/postgres-credentials\" { capabilities = [\"read\"] }" \
  | vault policy write database-policy -'
```

### Postgres pod stuck in Init

The CNPG cluster pod stays in `Init` if the `postgres-db-secret` is not yet synced. Check the ExternalSecret status first:

```bash
kubectl describe externalsecret postgres-password-sync -n database
```

If the secret exists but Postgres still won't start, the pod may be stuck in exponential backoff. Force a retry by deleting the pod:

```bash
kubectl delete pod -n database -l cnpg.io/cluster=zenith-postgres
```

### Vault IP changes after VM recreation

Multipass assigns a new IP each time a VM is created. `make bootstrap-workload` handles this automatically via `sed` — it rewrites the `server` field in `secret-store.yaml` and pushes the change to Git before ArgoCD syncs. If you run Vault-related steps manually, update the file yourself:

```bash
MGMT_IP=$(multipass info zenith-mgmt-1 --format json | jq -r '.info["zenith-mgmt-1"].ipv4[0]')
sed -i '' 's|server: "http://[^"]*"|server: "http://'"$MGMT_IP"':30820"|g' \
  platform/workload/manifests/database/secret-store.yaml
git add platform/workload/manifests/database/secret-store.yaml
git commit -m "chore: update vault server IP"
git push origin dev
```

### Makefile `missing separator` error

Make requires real TAB characters (not spaces) to indent recipe lines. Copy-pasting from a browser often converts tabs to spaces. Verify with:

```bash
cat -t Makefile | grep -n "^\^I"   # lines starting with a real tab show ^I
```

Fix in your editor by enabling "show invisibles" and replacing any leading spaces on recipe lines with tabs.

### CNPG password not reloading after Vault rotation

CNPG only reloads credentials from a Secret if the Secret carries the label `cnpg.io/reload: "true"`. This label is already present in the `ExternalSecret` template in `platform/workload/manifests/database/external-secret.yaml`. If you recreated the ExternalSecret manually and omitted the label, add it back and let ArgoCD reconcile.

---

## design notes

**Why multipass** — Longhorn requires `open-iscsi` on the actual node host. Docker-based tools (k3d, kind, minikube) can't provide this. Multipass creates real Ubuntu VMs where `apt-get install open-iscsi` works.

**Cilium without kube-proxy** — `--disable-kube-proxy` doesn't exist in k3s v1.27. Setting `kubeProxyReplacement: strict` in Cilium's Helm values is sufficient.

**Vault Kubernetes auth (cross-cluster)** — Vault on the management cluster validates workload Pod identities by calling the workload API server using a long-lived `vault-token-reviewer` token. This is necessary because Vault cannot use its own cluster's CA to verify tokens from a different cluster (`disable_local_ca_jwt=true`).

**Placeholder IP in Git** — `secret-store.yaml` stores a placeholder URL for the Vault server. The Makefile resolves the real IP at bootstrap time and commits the result before ArgoCD syncs. Never hardcode an IP directly in the repository; Multipass IPs change on every VM recreation.

**ExternalSecret field mapping** — CNPG requires a Secret with both a `username` and a `password` key. The ExternalSecret explicitly maps both properties from the single Vault KV entry at `secret/postgres-credentials`.

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