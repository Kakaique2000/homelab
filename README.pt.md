# Homelab

Homelab Kubernetes self-hosted com provisionamento automatizado de cluster, edge público via WireGuard e gerenciamento de workloads GitOps com Flux.

---

## Visão Geral

```
homelab/
├── ansible/    # Provisionamento do cluster Kubernetes (Kubespray)
├── edge/       # Proxy reverso no VPS (WireGuard + nginx)
└── flux/       # Gerenciamento GitOps de workloads (Flux CD)
```

### Como as partes se conectam

```
Internet
    │
    ▼
┌──────────────────────────┐
│  VPS (edge/)             │  IP público fixo
│  nginx + WireGuard hub   │
└──────────┬───────────────┘
           │ Túnel WireGuard (10.8.0.0/24)
    ┌──────┴──────┐
    ▼             ▼
k8s-master    k8s-worker1    ← provisionados pelo ansible/
  ingress-nginx                ← workloads gerenciados pelo flux/
```

---

## ansible/ — Cluster Kubernetes

Instalação simples e automatizada de cluster Kubernetes usando Ansible e Kubespray.

### Pré-requisitos

- Máquina(s) Ubuntu/Debian para os nós (mínimo 2 GB RAM, 2 CPU)
- Máquina de controle com Bash (WSL, Linux ou Mac) e **Docker**
- Conectividade de rede entre as máquinas

### Instalação em 3 passos

```bash
# === Passo 1: No futuro nó K8s ===
./ansible/setup-node.sh
# Exibe: Machine IPs: 192.168.1.100

# === Passo 2: Na máquina de controle ===
export MASTER_IP=192.168.1.100
./ansible/setup-controller.sh
# Instala: Ansible, kubectl, k9s
# Configura: chaves SSH, Kubespray, inventory

# === Passo 3: Instalar Kubernetes ===
./ansible/install-k8s.sh
# Leva 15-30 minutos
# Baixa o kubeconfig para ansible/.kube/config

# === Usar o cluster ===
./kubectl.sh get nodes
./k9s.sh
```

### Scripts

| Script | Executar em | Função |
|---|---|---|
| `setup-node.sh` | Nó K8s | Instala SSH, Python, cria usuário `ansible-agent` |
| `setup-controller.sh` | Máquina de controle | Instala ferramentas, configura SSH, constrói imagem Kubespray |
| `install-k8s.sh` | Máquina de controle | Executa Kubespray, baixa kubeconfig |
| `add-worker.sh` | Máquina de controle | Adiciona nós workers ao cluster |

### Adicionando Workers

```bash
# 1. Na nova máquina
./ansible/setup-node.sh

# 2. Configurar SSH para o novo nó
export WORKER_IP=192.168.1.101
MASTER_IP=$WORKER_IP ./ansible/setup-controller.sh

# 3. Adicionar ao cluster
./ansible/add-worker.sh k8s-worker1 192.168.1.101
```

### O que é instalado

- Kubernetes v1.28.6
- Rede Calico (Pod: `10.233.64.0/18`, Service: `10.233.0.0/18`)
- CoreDNS, Containerd
- Kubernetes Dashboard, Metrics Server
- Ingress-NGINX Controller

### Configuração

Editar antes de rodar `install-k8s.sh`:

**`ansible/group_vars/k8s_cluster/k8s-cluster.yml`**
```yaml
kube_version: v1.28.6
kube_network_plugin: calico
dashboard_enabled: true
metrics_server_enabled: true
ingress_nginx_enabled: true
```

### Usando o cluster

```bash
./kubectl.sh get nodes
./kubectl.sh get pods -A
./k9s.sh
```

Ou exportar o kubeconfig:
```bash
export KUBECONFIG=$PWD/ansible/.kube/config
kubectl get nodes
```

### Resolução de problemas

```bash
# Testar SSH
ssh -i ansible/.ssh/id_ed25519 ansible-agent@$MASTER_IP

# Baixar kubeconfig novamente
scp -i ansible/.ssh/id_ed25519 ansible-agent@$MASTER_IP:~/.kube/config ansible/.kube/config

# Logs do nó
ssh -i ansible/.ssh/id_ed25519 ansible-agent@$MASTER_IP
sudo journalctl -u kubelet -f
```

---

## edge/ — Proxy Reverso WireGuard

Gerencia um VPS como ponto de entrada público para o cluster local. Resolve o problema de CGNAT e IP rotativo criando um túnel WireGuard entre o VPS e os nós do cluster, com nginx fazendo o proxy do tráfego.

> `edge/` é independente do `ansible/`. O cluster funciona sem o edge, e o edge pode ser configurado ou removido sem alterar nada no cluster.

### Arquitetura

```
Internet
    │  HTTP :80/:443
    │  TCP qualquer porta (Minecraft, servidores de jogo, etc)
    ▼
┌─────────────────────────┐
│  VPS                    │  IP público fixo
│  nginx (proxy HTTP)     │
│  nginx (stream TCP/UDP) │
│  WireGuard :51820       │
│  wg0: 10.8.0.1          │
└──────────┬──────────────┘
           │ Túnel WireGuard (10.8.0.0/24)
    ┌──────┴──────┐
    ▼             ▼
10.8.0.2      10.8.0.3
k8s-master   k8s-worker1
  ingress       ingress
```

- **HTTP:** `cliente → VPS:80 → nginx → 10.8.0.X:80 → ingress-nginx → pod`
- **TCP:** `cliente → VPS:25565 → nginx stream → 10.8.0.X:25565 → NodePort → pod`
- **Topologia:** hub-and-spoke — VPS é o hub, cada nó é um spoke com `PersistentKeepalive = 25s`

### Pré-requisitos

- VPS com Ubuntu 22.04/24.04
- Acesso SSH ao VPS com senha (para a cópia inicial da chave)
- Cluster K8s provisionado via `ansible/` com ingress-nginx ativo

### Workflow completo

```bash
# 1. Configurar o VPS (uma vez)
export VPS_IP=1.2.3.4
export VPS_USER=ubuntu   # padrão: ubuntu
./edge/setup-vps.sh

# 2. Instalar o cluster K8s
./ansible/install-k8s.sh

# 3. Registrar o master no edge
./edge/register-node.sh k8s-master 192.168.15.13

# 4. (Opcional) Adicionar worker
./ansible/add-worker.sh k8s-worker1 192.168.15.20
./edge/register-node.sh k8s-worker1 192.168.15.20

# 5. (Opcional) Expor portas TCP/UDP extras
./edge/add-port.sh 25565 tcp   # Minecraft Java
./edge/add-port.sh 19132 udp   # Minecraft Bedrock
```

### Scripts

| Script | Função |
|---|---|
| `setup-vps.sh` | Provisionamento inicial do VPS |
| `register-node.sh` | Registra nó no WireGuard e upstreams nginx |
| `remove-node.sh` | Remove nó do WireGuard e nginx |
| `add-port.sh` | Expõe porta TCP/UDP no VPS |

### Verificação

```bash
# Testar proxy HTTP
curl -H "Host: meuapp.com" http://<VPS_IP>/

# Testar porta TCP
nc -zv <VPS_IP> 25565

# Ver estado do WireGuard
ssh ubuntu@<VPS_IP> "sudo wg show"

# Listar nós registrados
ssh ubuntu@<VPS_IP> "ls /etc/wireguard/peers/"
```

---

## flux/ — Workloads GitOps

Gerencia todos os workloads Kubernetes via Flux CD. O cluster reconcilia automaticamente a partir deste repositório.

### Bootstrap

```bash
./flux/bootstrap.sh
```

### Estrutura

```
flux/
├── bootstrap.sh
├── clusters/       # Entrypoints do Flux por cluster
├── infrastructure/ # Infraestrutura base (cert-manager, ingress, etc)
└── apps/           # Workloads de aplicações
```

---

## Scripts utilitários (raiz)

| Script | Função |
|---|---|
| `kubectl.sh` | Wrapper do `kubectl` usando o kubeconfig local |
| `k9s.sh` | Wrapper do `k9s` usando o kubeconfig local |
| `flux.sh` | Wrapper da CLI `flux` |

---

## Referências

- [Documentação Kubespray](https://kubespray.io/)
- [Documentação Kubernetes](https://kubernetes.io/docs/)
- [Documentação Flux CD](https://fluxcd.io/docs/)
- [Documentação WireGuard](https://www.wireguard.com/)
- [Documentação k9s](https://k9scli.io/)
