# Kubernetes Homelab with Ansible + Kubespray

Simple, automated Kubernetes cluster setup for your homelab using Ansible and Kubespray.

## Features

✅ **Simple workflow**: Just 3 scripts to get from zero to Kubernetes
✅ **Isolated kubeconfig**: Doesn't interfere with your existing kubectl setup
✅ **Automatic SSH setup**: Key generation and configuration handled for you
✅ **Single-node or multi-node**: Start with one machine, add workers later
✅ **Production-ready**: Uses Kubespray (official Kubernetes tooling)

## Quick Start

### Prerequisites

- Ubuntu/Debian machine(s) for Kubernetes nodes (2GB RAM, 2 CPU minimum)
- Control machine with bash (WSL, Linux, or Mac)
- **Docker** installed on control machine (for running Kubespray)
- Network connectivity between machines

### 3-Step Installation

```bash
# === Step 1: On the Ubuntu machine (future K8s node) ===
./setup-node.sh
# Output shows: Machine IPs: 192.168.1.100

# === Step 2: On your control machine (WSL/laptop) ===
export MASTER_IP=192.168.1.100  # Use IP from step 1

./setup-controller.sh
# Installs: Ansible, kubectl, k9s
# Configures: SSH keys, Kubespray, inventory

# === Step 3: Install Kubernetes ===
./install-k8s.sh
# Takes 15-30 minutes
# Automatically downloads kubeconfig to ./.kube/config

# === Use your cluster ===
./kubectl.sh get nodes
./k9s.sh
```

That's it! You now have a working Kubernetes cluster.

## What Each Script Does

### `setup-node.sh`
**Run on**: Target Ubuntu machine
**Does**:
- Installs OpenSSH, Python3
- Creates `ansible-agent` user with sudo access
- Configures firewall for SSH
- Shows available IP addresses

### `setup-controller.sh`
**Run on**: Control machine (requires `export MASTER_IP=<ip>` and Docker)
**Does**:
- Verifies Docker is installed
- Installs kubectl and k9s
- Generates SSH keys and copies them to nodes
- Downloads Kubespray and builds Docker image (contains Ansible + all dependencies)
- Creates Ansible inventory automatically

**Note**: Kubespray runs in Docker, eliminating Python dependency issues!

### `install-k8s.sh`
**Run on**: Control machine
**Does**:
- Verifies prerequisites
- Copies custom configuration to Kubespray
- Runs Kubespray playbooks (15-30 min)
- Downloads kubeconfig to `./.kube/config`

### `add-worker.sh`
**Run on**: Control machine
**Usage**: `./add-worker.sh <node-name> <node-ip>`
**Does**:
- Adds additional worker nodes to existing cluster
- Guides you through inventory update
- Runs Kubespray scale playbook

## Directory Structure

```
ansible/
├── setup-node.sh          # 1. Run on K8s node
├── setup-controller.sh    # 2. Run on control machine
├── install-k8s.sh         # 3. Install Kubernetes
├── add-worker.sh          # Add workers later
├── kubectl.sh             # kubectl wrapper (uses local kubeconfig)
├── k9s.sh                 # k9s wrapper (uses local kubeconfig)
├── inventory.ini          # Auto-generated (gitignored)
├── ansible.cfg            # Ansible configuration
├── .gitignore             # Protects secrets
├── .ssh/                  # SSH keys (gitignored)
├── .kube/                 # Kubeconfig (gitignored)
└── group_vars/            # Kubernetes configuration
    ├── all/all.yml        # Global settings
    └── k8s_cluster/k8s-cluster.yml  # K8s settings
```

## Configuration

### Customize Kubernetes Installation

Edit before running `install-k8s.sh`:

**`group_vars/k8s_cluster/k8s-cluster.yml`**:
```yaml
kube_version: v1.28.6           # Kubernetes version
kube_network_plugin: calico     # Network plugin
dashboard_enabled: true         # Enable dashboard
metrics_server_enabled: true    # Enable metrics
ingress_nginx_enabled: true     # Enable ingress
```

**`group_vars/all/all.yml`**:
```yaml
upstream_dns_servers:           # DNS servers
  - 8.8.8.8
  - 1.1.1.1
```

### Environment Variables

- **`MASTER_IP`** (required): IP of master node
- **`SSH_PORT`** (optional): SSH port if not 22
- **`VERBOSE`** (optional): Set to `true` for debug output

## Using Your Cluster

### Option 1: Wrapper Scripts (Recommended)

```bash
# Use kubectl
./kubectl.sh get nodes
./kubectl.sh get pods -A
./kubectl.sh apply -f deployment.yaml

# Use k9s (interactive terminal UI)
./k9s.sh
```

### Option 2: Export KUBECONFIG

```bash
export KUBECONFIG=$PWD/.kube/config
kubectl get nodes
k9s
```

### Option 3: Create Aliases

Add to `~/.bashrc`:
```bash
export MASTER_IP=192.168.1.100
alias k='cd ~/homelab/ansible && ./kubectl.sh'
alias k9s='cd ~/homelab/ansible && ./k9s.sh'
```

Then use:
```bash
k get nodes
k9s
```

## Adding Worker Nodes

When your homelab grows:

```bash
# 1. On new machine
./setup-node.sh
# Note the IP address

# 2. On control machine - configure SSH for new node
export WORKER_IP=192.168.1.101
MASTER_IP=$WORKER_IP ./setup-controller.sh

# 3. Edit inventory.ini manually
# Add under [all]:
#   k8s-worker1 ansible_host=192.168.1.101 ansible_user=ansible-agent ansible_ssh_private_key_file=./.ssh/id_ed25519
# Add under [kube_node]:
#   k8s-worker1

# 4. Add to cluster
./add-worker.sh k8s-worker1 192.168.1.101

# 5. Verify
./kubectl.sh get nodes
```

## Common Tasks

### View Cluster Info
```bash
./kubectl.sh cluster-info
./kubectl.sh get nodes -o wide
./kubectl.sh get pods -A
```

### Access Kubernetes Dashboard
```bash
./kubectl.sh proxy
# Visit: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
```

### Check Node Resources
```bash
./kubectl.sh top nodes
./kubectl.sh top pods -A
```

### Drain Node for Maintenance
```bash
./kubectl.sh drain <node-name> --ignore-daemonsets
# Do maintenance...
./kubectl.sh uncordon <node-name>
```

### Remove a Worker Node
```bash
./kubectl.sh drain <node-name> --ignore-daemonsets --delete-emptydir-data --force
./kubectl.sh delete node <node-name>
# Edit inventory.ini to remove the node
```

## Troubleshooting

### Check Environment Variable
```bash
echo $MASTER_IP
# If empty: export MASTER_IP=192.168.1.100
```

### Test SSH Connectivity
```bash
ssh -i .ssh/id_ed25519 ansible-agent@$MASTER_IP
```

### Test Ansible Connectivity
```bash
ansible all -i inventory.ini -m ping
```

### Re-download Kubeconfig
```bash
mkdir -p .kube
scp -i .ssh/id_ed25519 ansible-agent@$MASTER_IP:~/.kube/config .kube/config
```

### View Logs on Node
```bash
ssh -i .ssh/id_ed25519 ansible-agent@$MASTER_IP

# Check kubelet
sudo journalctl -u kubelet -f

# Check containerd
sudo journalctl -u containerd -f

# Check pods
sudo crictl pods
sudo crictl ps
```

### Reset Everything
**WARNING: Destroys the cluster!**
```bash
cd ~/kubespray
ansible-playbook -i inventory/mycluster/inventory.ini reset.yml
```

## Upgrading Kubernetes

1. Edit `group_vars/k8s_cluster/k8s-cluster.yml`
2. Change `kube_version` to desired version
3. Run:
```bash
cd ~/kubespray
ansible-playbook -i inventory/mycluster/inventory.ini upgrade-cluster.yml
```

## Network Configuration

Default settings (configured in `group_vars/`):
- **Pod network**: 10.233.64.0/18
- **Service network**: 10.233.0.0/18
- **Network plugin**: Calico

**Important**: Ensure these don't conflict with your home network!

## Security

✅ SSH keys isolated in `.ssh/` directory
✅ Password auth disabled for `ansible-agent` user
✅ Kubeconfig separate from system config
✅ All secrets gitignored

### Additional Hardening

For production use:
- Enable firewall between nodes
- Use network policies
- Enable RBAC
- Regular updates
- Secrets management (sealed-secrets, external-secrets)
- Audit logging
- TLS for ingress (cert-manager)

## Tips & Tricks

### Persistent Environment Variable

Add to `~/.bashrc` or `~/.zshrc`:
```bash
export MASTER_IP=192.168.1.100
```

### Verbose Mode

Debug any script:
```bash
./setup-controller.sh -v
./install-k8s.sh --verbose
```

### Watch Resources
```bash
./kubectl.sh get pods -A --watch
watch ./kubectl.sh get nodes
```

### Port Forward to Service
```bash
./kubectl.sh port-forward svc/my-service 8080:80
```

### Get Shell in Pod
```bash
./kubectl.sh exec -it <pod-name> -- /bin/bash
```

## What's Installed

After `install-k8s.sh` completes:

- ✅ Kubernetes v1.28.6
- ✅ Calico networking
- ✅ CoreDNS
- ✅ Containerd runtime
- ✅ Kubernetes Dashboard
- ✅ Metrics Server
- ✅ Ingress-NGINX Controller
- ✅ Helm (optional)

## Resources

- [Kubespray Documentation](https://kubespray.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- [k9s Documentation](https://k9scli.io/)

## FAQ

**Q: Can I use this for production?**
A: It uses production-grade tools (Kubespray), but additional hardening is recommended. See Security section.

**Q: How much disk space needed?**
A: ~20GB per node (OS + Kubernetes + images)

**Q: Can I mix Ubuntu versions?**
A: Yes, but all should be LTS versions (20.04, 22.04, 24.04)

**Q: How to backup the cluster?**
A: Use Velero or similar backup tool. etcd backup also recommended.

**Q: Can I change the network plugin later?**
A: Not easily. Choose carefully before installation.

**Q: Does this work on Raspberry Pi?**
A: Yes, but ARM architecture requires different container images. Modify Kubespray config accordingly.

## License

MIT

---

**Need help?** Check the [troubleshooting section](#troubleshooting) or open an issue.
