# Homelab

Self-hosted Kubernetes homelab with automated cluster provisioning, a WireGuard-based public edge, and GitOps workload management via Flux.

---

## Overview

```
homelab/
├── ansible/    # Kubernetes cluster provisioning (Kubespray)
├── edge/       # VPS reverse proxy (WireGuard + nginx)
└── flux/       # GitOps workload management (Flux CD)
```

### How the pieces fit together

```
Internet
    │
    ▼
┌──────────────────────────┐
│  VPS (edge/)             │  fixed public IP
│  nginx + WireGuard hub   │
└──────────┬───────────────┘
           │ WireGuard tunnel (10.8.0.0/24)
    ┌──────┴──────┐
    ▼             ▼
k8s-master    k8s-worker1    ← provisioned by ansible/
  ingress-nginx                ← workloads managed by flux/
```

---

## ansible/ — Kubernetes Cluster

Simple, automated Kubernetes cluster setup using Ansible and Kubespray.

### Prerequisites

- Ubuntu/Debian machine(s) for nodes (2 GB RAM, 2 CPU minimum)
- Control machine with Bash (WSL, Linux, or Mac) and **Docker**
- Network connectivity between machines

### 3-Step Installation

```bash
# === Step 1: On the future K8s node ===
./ansible/setup-node.sh
# Output shows: Machine IPs: 192.168.1.100

# === Step 2: On your control machine ===
export MASTER_IP=192.168.1.100
./ansible/setup-controller.sh
# Installs: Ansible, kubectl, k9s
# Configures: SSH keys, Kubespray, inventory

# === Step 3: Install Kubernetes ===
./ansible/install-k8s.sh
# Takes 15-30 minutes
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

- Kubernetes v1.28.6
- Calico networking (Pod: `10.233.64.0/18`, Service: `10.233.0.0/18`)
- CoreDNS, Containerd
- Kubernetes Dashboard, Metrics Server
- Ingress-NGINX Controller

### Configuration

Edit before running `install-k8s.sh`:

**`ansible/group_vars/k8s_cluster/k8s-cluster.yml`**
```yaml
kube_version: v1.28.6
kube_network_plugin: calico
dashboard_enabled: true
metrics_server_enabled: true
ingress_nginx_enabled: true
```

### Using the Cluster

```bash
./kubectl.sh get nodes
./kubectl.sh get pods -A
./k9s.sh
```

Or export the kubeconfig:
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

## edge/ — WireGuard Reverse Proxy

Manages a VPS as a public entrypoint for the local cluster. Solves CGNAT / rotating IP by creating a WireGuard tunnel between the VPS and the cluster nodes, with nginx proxying incoming traffic.

> `edge/` is independent of `ansible/`. The cluster works without the edge, and the edge can be set up or removed without touching the cluster.

### Architecture

```
Internet
    │  HTTP :80/:443
    │  TCP any port (Minecraft, game servers, etc)
    ▼
┌─────────────────────────┐
│  VPS                    │  fixed public IP
│  nginx (HTTP proxy)     │
│  nginx (TCP/UDP stream) │
│  WireGuard :51820       │
│  wg0: 10.8.0.1          │
└──────────┬──────────────┘
           │ WireGuard tunnel (10.8.0.0/24)
    ┌──────┴──────┐
    ▼             ▼
10.8.0.2      10.8.0.3
k8s-master   k8s-worker1
  ingress       ingress
```

- **HTTP:** `client → VPS:80 → nginx → 10.8.0.X:80 → ingress-nginx → pod`
- **TCP:** `client → VPS:25565 → nginx stream → 10.8.0.X:25565 → NodePort → pod`
- **Topology:** hub-and-spoke — VPS is the hub, each node is a spoke with `PersistentKeepalive = 25s`

### Prerequisites

- VPS running Ubuntu 22.04/24.04
- SSH access to the VPS (password, for the initial key copy)
- K8s cluster provisioned via `ansible/` with ingress-nginx enabled

### Full Workflow

```bash
# 1. Set up the VPS (once)
export VPS_IP=1.2.3.4
export VPS_USER=ubuntu   # default: ubuntu
./edge/setup-vps.sh

# 2. Install the K8s cluster
./ansible/install-k8s.sh

# 3. Register master on the edge
./edge/register-node.sh k8s-master 192.168.15.13

# 4. (Optional) Add a worker
./ansible/add-worker.sh k8s-worker1 192.168.15.20
./edge/register-node.sh k8s-worker1 192.168.15.20

# 5. (Optional) Expose extra TCP/UDP ports
./edge/add-port.sh 25565 tcp   # Minecraft Java
./edge/add-port.sh 19132 udp   # Minecraft Bedrock
```

### Scripts

| Script | Purpose |
|---|---|
| `setup-vps.sh` | One-time VPS provisioning |
| `register-node.sh` | Add a node to WireGuard and nginx upstreams |
| `remove-node.sh` | Remove a node from WireGuard and nginx |
| `add-port.sh` | Expose a TCP/UDP port on the VPS |

### Verification

```bash
# Test HTTP proxy
curl -H "Host: myapp.com" http://<VPS_IP>/

# Test TCP port
nc -zv <VPS_IP> 25565

# Check WireGuard status
ssh ubuntu@<VPS_IP> "sudo wg show"

# List registered nodes
ssh ubuntu@<VPS_IP> "ls /etc/wireguard/peers/"
```

---

## flux/ — GitOps Workloads

Manages all Kubernetes workloads via Flux CD. The cluster reconciles automatically from this repository.

### Bootstrap

```bash
./flux/bootstrap.sh
```

### Structure

```
flux/
├── bootstrap.sh
├── clusters/       # Cluster-level Flux entrypoints
├── infrastructure/ # Base infrastructure (cert-manager, ingress, etc)
└── apps/           # Application workloads
```

---

## Utility Scripts (root)

| Script | Purpose |
|---|---|
| `kubectl.sh` | `kubectl` wrapper using the local kubeconfig |
| `k9s.sh` | `k9s` wrapper using the local kubeconfig |
| `flux.sh` | `flux` CLI wrapper |

---

## Resources

- [Kubespray Documentation](https://kubespray.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Flux CD Documentation](https://fluxcd.io/docs/)
- [WireGuard Documentation](https://www.wireguard.com/)
- [k9s Documentation](https://k9scli.io/)
