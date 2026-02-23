# Homelab

Self-hosted Kubernetes homelab with automated cluster provisioning, a WireGuard-based public edge, and GitOps workload management via Flux CD.

---

## Overview

```
homelab/
├── ansible/    # Kubernetes cluster provisioning (Kubespray)
├── edge/       # VPS public entrypoint (WireGuard + iptables DNAT)
└── flux/       # GitOps workload management (Flux CD)
```

### How the pieces fit together

```
Internet
    │
    ▼
┌──────────────────────────────┐
│  VPS (edge/)                 │  fixed public IP
│  iptables DNAT               │  :80, :443, :25565 → k8s nodes
│  WireGuard hub (10.8.0.1)   │
└──────────────┬───────────────┘
               │ WireGuard tunnel (10.8.0.0/24)
               ▼
          k8s-master (10.8.0.2)   ← provisioned by ansible/
            ingress-nginx          ← workloads managed by flux/
```

Traffic flow: `Internet → VPS (iptables DNAT) → WireGuard tunnel → K8s NodePort → ingress-nginx → pod`

---

## ansible/ — Kubernetes Cluster

Automated Kubernetes cluster setup using Ansible and Kubespray.

### Prerequisites

- Ubuntu/Debian machine(s) for nodes (2 GB RAM, 2 CPU minimum)
- Control machine with Bash (WSL, Linux, or Mac) and **Docker**
- Network connectivity between machines

### Installation

```bash
# === Step 1: On the future K8s node ===
./ansible/setup-node.sh
# Output shows the node IP: 192.168.1.100

# === Step 2: On your control machine ===
export MASTER_IP=192.168.1.100
./ansible/setup-controller.sh
# Installs: Ansible, kubectl, k9s
# Configures: SSH keys, Kubespray, inventory

# === Step 3: Install Kubernetes ===
./ansible/install-k8s.sh
# Downloads kubeconfig to ansible/.kube/config

# === Use your cluster ===
./kubectl.sh get nodes
./k9s.sh
```

### Scripts

| Script | Run on | Purpose |
|---|---|---|
| `setup-node.sh` | K8s node | Install SSH, Python, create `ansible-agent` user |
| `setup-controller.sh` | Control machine | Install tools, configure SSH, build Kubespray image |
| `install-k8s.sh` | Control machine | Run Kubespray, download kubeconfig |
| `add-worker.sh` | Control machine | Scale the cluster with additional nodes |

### Adding Worker Nodes

```bash
# 1. On the new machine
./ansible/setup-node.sh

# 2. Configure SSH for the new node
export WORKER_IP=192.168.1.101
MASTER_IP=$WORKER_IP ./ansible/setup-controller.sh

# 3. Add to the cluster
./ansible/add-worker.sh k8s-worker1 192.168.1.101
```

### What Gets Installed

- Kubernetes (latest stable via Kubespray)
- Calico networking (Pod: `10.233.64.0/18`, Service: `10.233.0.0/18`)
- CoreDNS, Containerd
- Ingress-NGINX Controller

### Using the Cluster

```bash
./kubectl.sh get nodes
./kubectl.sh get pods -A
./k9s.sh
```

Or export the kubeconfig directly:
```bash
export KUBECONFIG=$PWD/ansible/.kube/config
kubectl get nodes
```

### Troubleshooting

```bash
# Test SSH
ssh -i ansible/.ssh/id_ed25519 ansible-agent@$MASTER_IP

# Re-download kubeconfig
scp -i ansible/.ssh/id_ed25519 ansible-agent@$MASTER_IP:~/.kube/config ansible/.kube/config

# Node logs
ssh -i ansible/.ssh/id_ed25519 ansible-agent@$MASTER_IP
sudo journalctl -u kubelet -f
```

---

## edge/ — WireGuard + iptables Edge

Manages a VPS as a public entrypoint for the local cluster. Solves CGNAT / rotating IP by creating a WireGuard tunnel between the VPS and the cluster nodes. Incoming traffic is forwarded via **iptables DNAT** to the appropriate K8s NodePort.

> `edge/` is independent of `ansible/`. The cluster works without the edge, and the edge can be set up or removed without touching the cluster.

### Architecture

```
Internet
    │  :80, :443, :25565, ...
    ▼
┌─────────────────────────────┐
│  VPS                        │  fixed public IP
│  iptables DNAT + MASQUERADE │
│  WireGuard :51820           │
│  wg0: 10.8.0.1              │
└──────────────┬──────────────┘
               │ WireGuard tunnel (10.8.0.0/24)
               ▼
          10.8.0.2 (k8s-master)
            NodePort → ingress-nginx → pod
```

- **All protocols:** `client → VPS:port → iptables DNAT → node_wg_ip:node_port → K8s NodePort`
- **Return path:** MASQUERADE ensures return traffic flows back through the VPS
- **Topology:** hub-and-spoke — VPS is the hub, each node is a spoke with `PersistentKeepalive = 25s`
- **Routing on nodes:** `AllowedIPs = 10.8.0.1/32` (only VPS traffic through the tunnel)

### Prerequisites

- VPS running Ubuntu 22.04/24.04
- SSH access to the VPS
- K8s cluster provisioned via `ansible/`

### Workflow

```bash
# 1. Set up WireGuard hub on VPS (once)
export VPS_IP=1.2.3.4
./edge/setup-edge.sh

# 2. Register a K8s node into the WireGuard tunnel
./edge/register-node.sh k8s-master 192.168.15.13 10.8.0.2

# 3. Edit edge.conf to declare the node and exposed ports
#    NODES=("k8s-master:10.8.0.2")
#    PORTS=("443:443:tcp" "80:80:tcp" "25565:30565:tcp")

# 4. Apply iptables rules to the VPS
./edge/deploy.sh
```

### Configuration (`edge/edge.conf`)

```bash
WG_VPS_IP=10.8.0.1      # VPS WireGuard IP
WG_PORT=51820            # WireGuard listen port

NODES=(
  "k8s-master:10.8.0.2" # name:wg_ip
)

PORTS=(
  "443:443:tcp"          # vps_port:node_port:proto
  "80:80:tcp"
  "25565:30565:tcp"      # Minecraft Java
)
```

### Scripts

| Script | Purpose |
|---|---|
| `setup-edge.sh` | One-time VPS provisioning: installs WireGuard, enables IP forwarding, generates keys, runs `deploy.sh` |
| `register-node.sh` | Installs WireGuard on a K8s node, generates keypair, creates tunnel, registers as VPS peer |
| `deploy.sh` | Idempotent: syncs `edge.conf` to VPS and applies iptables DNAT rules |
| `show-rules.sh` | Shows current iptables rules managed by the edge |

### Verification

```bash
# Check WireGuard peers on VPS
ssh root@<VPS_IP> "sudo wg show"

# Check iptables DNAT rules
./edge/show-rules.sh

# Test port
nc -zv <VPS_IP> 25565
```

---

## flux/ — GitOps Workloads

Manages all Kubernetes workloads via Flux CD. The cluster reconciles automatically from this repository.

### Structure

```
flux/
├── clusters/homelab/             # Flux Kustomization entrypoints
│   ├── kustomization.yaml        # Kustomize root (picked up by flux-system)
│   ├── infrastructure.yaml       # Kustomization: infra layer
│   ├── cert-manager-issuer.yaml  # Kustomization: TLS issuers (SOPS-encrypted secret)
│   └── apps.yaml                 # Kustomization: applications
├── infrastructure/               # Base infrastructure HelmReleases
│   ├── cert-manager.yaml
│   ├── goldilocks.yaml
│   ├── local-path-provisioner.yaml
│   ├── ingress-nginx-lease-rbac.yaml
│   └── cert-manager-issuer/
│       ├── issuer.yaml
│       └── route53-creds.secret.yaml  # SOPS-encrypted
└── apps/
    ├── whoami.yaml
    └── minecraft.yaml
```

### Dependency chain

```
infrastructure → cert-manager-issuer → apps
```

### Secrets (SOPS + Age)

Sensitive files (e.g. `route53-creds.secret.yaml`) are encrypted with [SOPS](https://github.com/getsops/sops) using an Age key. Flux decrypts them automatically via the `sops-age` secret in `flux-system`.

To set up the Age key in the cluster:
```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=<path-to-age-key>
```

### Bootstrap

Flux was bootstrapped with:
```bash
flux bootstrap github \
  --owner=<github-user> \
  --repository=homelab \
  --branch=main \
  --path=flux/clusters/homelab
```

After bootstrap, all subsequent changes are applied automatically via GitOps. To force a reconciliation:
```bash
./flux.sh reconcile source git flux-system
./flux.sh reconcile kustomization infrastructure cert-manager-issuer apps
```

### Infrastructure components

| Component | Purpose |
|---|---|
| cert-manager | Automatic TLS certificate management |
| ingress-nginx | HTTP/HTTPS ingress controller |
| local-path-provisioner | Dynamic PVC provisioning on single-node |
| goldilocks | Resource request/limit recommendations |

### Applications

| App | Description |
|---|---|
| whoami | Simple HTTP echo service for ingress testing |
| minecraft | Minecraft Java server (NodePort 30565) |

---

## Utility Scripts

| Script | Purpose |
|---|---|
| `kubectl.sh` | `kubectl` wrapper using `ansible/.kube/config` |
| `k9s.sh` | `k9s` wrapper using `ansible/.kube/config` |
| `flux.sh` | `flux` CLI wrapper (auto-installs flux if missing) |

---

## Resources

- [Kubespray Documentation](https://kubespray.io/)
- [Flux CD Documentation](https://fluxcd.io/docs/)
- [SOPS Documentation](https://github.com/getsops/sops)
- [WireGuard Documentation](https://www.wireguard.com/)
- [k9s Documentation](https://k9scli.io/)
