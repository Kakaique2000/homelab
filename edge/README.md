# Edge — WireGuard Reverse Proxy

Manages a VPS that serves as a public entrypoint for a local Kubernetes cluster. Solves the CGNAT / rotating IP problem by creating a WireGuard tunnel between the VPS and the cluster nodes, with nginx proxying incoming traffic.

> This directory is independent of `../ansible/`. The cluster works without the edge. The edge can be set up or removed without changing anything in the cluster.

---

## Architecture

```
Internet
    │
    │  HTTP :80/:443
    │  TCP any port (Minecraft, game servers, etc)
    ▼
┌─────────────────────────┐
│         VPS             │   fixed public IP
│  nginx  (HTTP proxy)    │
│  nginx  (TCP/UDP stream)│
│  WireGuard :51820       │
│  wg0: 10.8.0.1          │
└──────────┬──────────────┘
           │  WireGuard tunnel (10.8.0.0/24)
           │  PersistentKeepalive — survives CGNAT
    ┌──────┴──────┐
    │             │
    ▼             ▼
10.8.0.2      10.8.0.3  ...
k8s-master   k8s-worker1
  nginx         nginx
 ingress       ingress
```

**HTTP flow:**
`client → VPS:80 → nginx upstream → 10.8.0.X:80 → ingress-nginx → pod`

**TCP flow (e.g. Minecraft):**
`client → VPS:25565 → nginx stream → 10.8.0.X:25565 → K8s NodePort → pod`

**WireGuard — hub-and-spoke topology:**
- VPS is the hub (`10.8.0.1`)
- Each K8s node is a spoke (`10.8.0.2`, `.3`, ...)
- Nodes use `PersistentKeepalive = 25s` to keep the tunnel alive through CGNAT
- Split-tunnel: only `10.8.0.0/24` goes through the tunnel, all other traffic uses the node's normal interface

---

## Prerequisites

- VPS running Ubuntu (tested on 22.04/24.04)
- SSH access to the VPS with a password (for the initial key copy)
- K8s cluster set up via `../ansible/` with ingress-nginx enabled
- SSH key generated at `../ansible/.ssh/id_ed25519`

---

## Initial VPS setup (once)

```bash
cd homelab/edge/

export VPS_IP=1.2.3.4
export VPS_USER=ubuntu    # default: ubuntu

./setup-vps.sh
```

The script:
1. Copies the ansible SSH key to the VPS (prompts for password once)
2. Installs `wireguard-tools` and `nginx`
3. Generates a WireGuard keypair on the VPS and configures `wg0` (`10.8.0.1/24`)
4. Configures nginx with HTTP proxy and TCP/UDP stream support
5. Installs `/usr/local/sbin/regen-nginx-upstream.sh` on the VPS
6. Saves `.vps-ip`, `.vps-user`, and `.vps-wg-public.key` locally (gitignored)

---

## Registering a node

Run after `../ansible/install-k8s.sh` (master) or `../ansible/add-worker.sh` (worker):

```bash
# Master (WG IP auto-assigned: 10.8.0.2)
./register-node.sh k8s-master 192.168.15.13

# Worker (WG IP auto-assigned: 10.8.0.3, .4, ...)
./register-node.sh k8s-worker1 192.168.15.20

# With explicit WG IP
./register-node.sh k8s-master 192.168.15.13 10.8.0.2
```

The script:
1. Installs WireGuard on the node
2. Generates a keypair on the node
3. Configures the tunnel on the node (pointing to the VPS)
4. Registers the node as a peer on the VPS (`wg addconf` — no restart needed)
5. Regenerates nginx upstreams (HTTP + all TCP/UDP ports)
6. Verifies connectivity with `ping`

---

## Exposing extra TCP/UDP ports

For non-HTTP services (Minecraft, game servers, etc):

```bash
./add-port.sh 25565 tcp   # Minecraft Java
./add-port.sh 19132 udp   # Minecraft Bedrock
./add-port.sh 27015 udp   # Steam
```

Traffic is load-balanced across all registered nodes. Make sure your K8s service uses `NodePort` on the same port.

---

## Removing a node

```bash
# Remove from VPS only
./remove-node.sh k8s-worker1

# Remove from VPS and clean up the node
./remove-node.sh k8s-worker1 192.168.15.20
```

---

## Full workflow

```
1. Set up the VPS (once)
   export VPS_IP=1.2.3.4 && ./setup-vps.sh

2. Install the K8s cluster
   cd ../ansible/ && ./install-k8s.sh

3. Register master on the edge
   cd ../edge/ && ./register-node.sh k8s-master 192.168.15.13

4. (Optional) Add a worker
   cd ../ansible/ && ./add-worker.sh k8s-worker1 192.168.15.20
   cd ../edge/   && ./register-node.sh k8s-worker1 192.168.15.20

5. (Optional) Expose extra ports
   ./add-port.sh 25565 tcp
```

---

## Files

| File | Description |
|---|---|
| `setup-vps.sh` | One-time VPS provisioning |
| `register-node.sh` | Registers a node in WireGuard and nginx |
| `remove-node.sh` | Removes a node from WireGuard and nginx |
| `add-port.sh` | Exposes a TCP/UDP port on the VPS |
| `.vps-ip` | VPS IP address (generated, gitignored) |
| `.vps-user` | VPS SSH user (generated, gitignored) |
| `.vps-wg-public.key` | VPS WireGuard public key (generated, gitignored) |

---

## How nginx is updated automatically

The VPS has a script at `/usr/local/sbin/regen-nginx-upstream.sh` that:
- Reads all files in `/etc/wireguard/peers/*.conf`
- Extracts the WireGuard IP of each node
- Regenerates `/etc/nginx/conf.d/k8s-upstream.conf` (HTTP upstream)
- Regenerates all files in `/etc/nginx/stream.conf.d/ports/` (TCP/UDP upstreams)
- Runs `nginx reload`

It is called automatically by `register-node.sh` and `remove-node.sh`. You never need to run it manually.

---

## Verification

```bash
# Test HTTP proxy
curl -H "Host: myapp.com" http://<VPS_IP>/

# Test TCP port
nc -zv <VPS_IP> 25565

# Check WireGuard status on VPS
ssh ubuntu@<VPS_IP> "sudo wg show"

# List registered nodes
ssh ubuntu@<VPS_IP> "ls /etc/wireguard/peers/"

# Check nginx upstreams
ssh ubuntu@<VPS_IP> "cat /etc/nginx/conf.d/k8s-upstream.conf"
```
