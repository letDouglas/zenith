# zenith

A professional bare-metal Kubernetes environment.


---

## stack

| component | version |
|---|---|
| k3s | v1.27.4 |
| Cilium | 1.14.3 |
| Longhorn | 1.5.1 |
| Vault | TBD |
| CNPG | TBD |

---

## prerequisites

```bash
brew install --cask multipass
brew install kubernetes-cli helm jq
```

Optional but recommended:

```bash
brew install danielfoehrkn/switch/switch   # context switcher
brew install kubecolor
brew install derailed/k9s/k9s
```

### why multipass

Longhorn needs `open-iscsi` on the actual node host — not inside a container. This rules out every tool that uses Docker containers as nodes:

| tool | problem |
|---|---|
| k3d | Alpine nodes — no working package manager for iscsi, `nsenter` fails |
| kind | same as k3d |
| minikube (qemu2) | Buildroot ISO — no `apt-get`, open-iscsi not installable |
| minikube + socket_vmnet | fixes multi-node networking but same iscsi problem |

Multipass creates real Ubuntu VMs → `apt-get install open-iscsi` works → Longhorn runs.

---

## kubeconfig setup

Bootstrap writes kubeconfig to `~/.kube/clusters/zenith`. Create the dir and add to your shell:

```bash
mkdir -p ~/.kube/clusters
```

```bash
# .zshrc
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
make bootstrap   # create VMs, install k3s + Cilium + Longhorn
make destroy     # delete everything
```

After bootstrap:

```bash
switch zenith
```

Bootstrap steps in order:

1. `vms-create` — 3 Ubuntu VMs via multipass (2 CPU, 4G RAM, 20G disk each)
2. `k3s-install` — k3s on all VMs; server on `zenith-1`, agents on `zenith-2/3`; flannel, traefik, servicelb disabled
3. `longhorn-prereq` — install `open-iscsi` + `nfs-common` on each node via `multipass exec`
4. `cilium-install` — Cilium with `kubeProxyReplacement: strict`
5. `cluster-wait` — wait for all nodes `Ready`
6. `longhorn-install` — Longhorn distributed storage

---

## notes

**Cilium without kube-proxy** — `--disable-kube-proxy` doesn't exist in k3s v1.27 (added in v1.28+). Setting `kubeProxyReplacement: strict` in Cilium's Helm values is enough — Cilium takes over service routing without needing to explicitly kill kube-proxy at the k3s level.

**ArgoCD** — tried for bootstrapping, dropped. Longhorn's `pre-upgrade` Helm hook runs as an ArgoCD `PreSync` hook before the ServiceAccount exists, causing an infinite loop. The fix (`helmPreUpgradeCheckerJob.enabled: false`) works but ArgoCD goes into backoff after failed retries and won't recover without manual intervention. Plain Helm in the Makefile for bootstrap; ArgoCD can come back later for managing stable apps.

---

## roadmap

- [ ] Vault
- [ ] CNPG
- [ ] Ingress (Nginx or Cilium Gateway API)
- [ ] ArgoCD