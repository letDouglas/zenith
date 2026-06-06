# zenith

A professional bare-metal Kubernetes homelab environment, designed to mirror enterprise GitOps patterns.

---

## stack

| component | version | role |
|---|---|---|
| k3s | v1.27.4 | Kubernetes distribution |
| Cilium | 1.14.3 | CNI + kube-proxy replacement + L2 LB |
| Longhorn | 1.5.1 | Distributed block storage |
| Traefik | 26.0.0 | Ingress controller |
| ArgoCD | 5.46.7 | GitOps engine |
| Vault | 0.28.0 (chart) | Secrets management |
| External Secrets Operator | 0.9.11 | Vault → Kubernetes secret sync |
| CloudNativePG | 0.22.0 (chart) | PostgreSQL operator |

---

## prerequisites

```bash
brew install --cask multipass
brew install kubernetes-cli helm jq
```

Optional but recommended:

```bash
brew install danielfoehrkn/switch/switch   # kubeconfig context switcher
brew install kubecolor
brew install derailed/k9s/k9s
```

### why multipass

Longhorn requires `open-iscsi` on the actual node host — not inside a container. This rules out every tool that uses Docker containers as nodes:

| tool | problem |
|---|---|
| k3d | Alpine nodes — no working package manager for iscsi |
| kind | same as k3d |
| minikube (qemu2) | Buildroot ISO — no `apt-get`, open-iscsi not installable |

Multipass creates real Ubuntu VMs → `apt-get install open-iscsi` works → Longhorn runs.

---

## architecture

```
GitHub (dev branch)
    └── ArgoCD (root-app, App of Apps pattern)
            ├── wave 1 — Vault + External Secrets Operator
            ├── wave 2 — vault-config (bootstrap job: auth, policy, kv-v2)
            └── wave 3 — CNPG operator + postgres-database
                              └── ExternalSecret reads from Vault
                              └── postgres-db-secret created in k8s
                              └── CNPG cluster bootstraps with that secret
```

Secrets flow:

```
Human puts password in Vault (one-time, manual)
    └── ESO syncs it as postgres-db-secret in namespace database
            └── CNPG uses it to initialize app_db with app_user
```

---

## kubeconfig setup

Bootstrap writes kubeconfig to `~/.kube/clusters/zenith`. Create the dir first:

```bash
mkdir -p ~/.kube/clusters
```

Add to your shell (`~/.zshrc`):

```bash
export KUBECONFIG=~/.kube/config:~/.kube/clusters/zenith
```

If you use kube-switch, add to `~/.kube/kube-switch.yaml`:

```yaml
- kind: filesystem
  id: local
  paths:
    - ~/.kube/clusters/zenith
```

---

## usage

```bash
make bootstrap   # create VMs, install k3s + Cilium + Longhorn + ArgoCD
make destroy     # delete everything
```

After bootstrap:

```bash
switch zenith
```

---

## bootstrap sequence

`make bootstrap` automates the infrastructure layer:

1. `vms-create` — 3 Ubuntu VMs via multipass (2 CPU, 4G RAM, 20G disk each)
2. `k3s-install` — k3s on all nodes; server on `zenith-1`, agents on `zenith-2/3`; flannel, traefik, servicelb disabled
3. `longhorn-prereq` — install `open-iscsi` + `nfs-common` on each node
4. `cilium-install` — Cilium with `kubeProxyReplacement: strict`
5. `cilium-config` — L2 IP pool + announcement policy
6. `cluster-wait` — wait for all nodes Ready
7. `longhorn-install` — distributed storage
8. `traefik-install` — ingress controller (LoadBalancer IP: `192.168.64.241`)
9. `argocd-install` — GitOps engine
10. `argocd-bootstrap` — GitHub credentials + root-app applied

ArgoCD then takes over and deploys everything else via sync waves.

---

## manual steps after bootstrap

After `make bootstrap`, ArgoCD deploys wave 1 (Vault + ESO) and wave 2 (vault-config job). Before wave 3 (postgres) can proceed, **two manual steps are required** — this is intentional and mirrors real production workflows.

### 1. initialize and unseal Vault

Vault starts sealed. Initialize it and unseal it:

```bash
kubectl exec -n vault vault-0 -- vault operator init
```

Save the unseal keys and root token somewhere safe (password manager). Then unseal:

```bash
kubectl exec -n vault vault-0 -- vault operator unseal  # repeat 3 times with different keys
```

### 2. create the vault-root-token secret

The vault-config bootstrap job needs the root token to configure Vault:

```bash
kubectl create secret generic vault-root-token \
  --namespace vault \
  --from-literal=token=<your-root-token>
```

The bootstrap job will now run and configure:
- Kubernetes auth method
- KV-V2 secrets engine at `secret/`
- Policy and role for ESO

### 3. put the database password in Vault

This is the only secret you will ever manage manually:

```bash
ROOT_TOKEN=$(kubectl get secret vault-root-token -n vault -o jsonpath='{.data.token}' | base64 -d)

kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$ROOT_TOKEN \
  vault kv put secret/postgres-credentials password=<your-password>
```

Once this is done, ESO syncs the secret into Kubernetes and CNPG bootstraps the database automatically.

### retrieve the database password later

```bash
kubectl get secret postgres-db-secret -n database \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## notes

**Cilium without kube-proxy** — `--disable-kube-proxy` doesn't exist in k3s v1.27 (added in v1.28+). Setting `kubeProxyReplacement: strict` in Cilium's Helm values is enough — Cilium takes over service routing without needing to explicitly disable kube-proxy at the k3s level.

**Vault in-cluster** — Vault runs inside the cluster in the `vault` namespace. While in production Vault typically lives on dedicated infrastructure outside the cluster, the behavior from the perspective of ESO and CNPG is identical — ESO makes HTTP calls to `http://vault.vault.svc.cluster.local:8200` regardless of where Vault physically runs. This setup faithfully mirrors the enterprise pattern.

**Sync waves** — ArgoCD deploys apps in wave order and waits for each wave to be healthy before proceeding. This guarantees that Vault is ready before the bootstrap job runs, and the bootstrap job completes before CNPG attempts to read the database secret.

**vault-root-token** — The bootstrap job uses `BeforeHookCreation` delete policy, meaning it re-runs on every ArgoCD sync. It is idempotent (`|| true` on already-enabled engines). The `vault-root-token` secret must exist in the `vault` namespace for the job to succeed.

---

## roadmap

- [x] Cilium CNI
- [x] Longhorn storage
- [x] Traefik ingress
- [x] ArgoCD GitOps
- [x] Vault secrets management
- [x] External Secrets Operator
- [x] CloudNativePG
- [ ] Ingress routes (ArgoCD, Longhorn UI, Vault UI)
- [ ] Monitoring (Prometheus + Grafana)
- [ ] Backup (Longhorn snapshots + CNPG backups to S3)