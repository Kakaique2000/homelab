# Homelab

Homelab Kubernetes self-hosted com provisionamento automatizado de cluster, edge público via WireGuard e gerenciamento de workloads GitOps com Flux CD.

---

## Visão Geral

```
homelab/
├── ansible/    # Provisionamento do cluster Kubernetes (Kubespray)
├── edge/       # Ponto de entrada público no VPS (WireGuard + iptables DNAT)
└── flux/       # Gerenciamento GitOps de workloads (Flux CD)
```

### Como as partes se conectam

```
Internet
    │
    ▼
┌──────────────────────────────┐
│  VPS (edge/)                 │  IP público fixo
│  iptables DNAT               │  :80, :443, :25565 → nós k8s
│  WireGuard hub (10.8.0.1)   │
└──────────────┬───────────────┘
               │ Túnel WireGuard (10.8.0.0/24)
               ▼
          k8s-master (10.8.0.2)   ← provisionado pelo ansible/
            ingress-nginx          ← workloads gerenciados pelo flux/
```

Fluxo de tráfego: `Internet → VPS (iptables DNAT) → túnel WireGuard → K8s NodePort → ingress-nginx → pod`

---

## ansible/ — Cluster Kubernetes

Instalação automatizada de cluster Kubernetes usando Ansible e Kubespray.

### Pré-requisitos

- Máquina(s) Ubuntu/Debian para os nós (mínimo 2 GB RAM, 2 CPU)
- Máquina de controle com Bash (WSL, Linux ou Mac) e **Docker**
- Conectividade de rede entre as máquinas

### Instalação

```bash
# === Passo 1: No futuro nó K8s ===
./ansible/setup-node.sh
# Exibe o IP do nó: 192.168.1.100

# === Passo 2: Na máquina de controle ===
export MASTER_IP=192.168.1.100
./ansible/setup-controller.sh
# Instala: Ansible, kubectl, k9s
# Configura: chaves SSH, Kubespray, inventory

# === Passo 3: Instalar Kubernetes ===
./ansible/install-k8s.sh
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

- Kubernetes (versão estável mais recente via Kubespray)
- Rede Calico (Pod: `10.233.64.0/18`, Service: `10.233.0.0/18`)
- CoreDNS, Containerd
- Ingress-NGINX Controller

### Usando o cluster

```bash
./kubectl.sh get nodes
./kubectl.sh get pods -A
./k9s.sh
```

Ou exportar o kubeconfig diretamente:
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

## edge/ — WireGuard + iptables Edge

Gerencia um VPS como ponto de entrada público para o cluster local. Resolve o problema de CGNAT e IP rotativo criando um túnel WireGuard entre o VPS e os nós do cluster. O tráfego é encaminhado via **iptables DNAT** para o NodePort apropriado no K8s.

> `edge/` é independente do `ansible/`. O cluster funciona sem o edge, e o edge pode ser configurado ou removido sem alterar nada no cluster.

### Arquitetura

```
Internet
    │  :80, :443, :25565, ...
    ▼
┌─────────────────────────────┐
│  VPS                        │  IP público fixo
│  iptables DNAT + MASQUERADE │
│  WireGuard :51820           │
│  wg0: 10.8.0.1              │
└──────────────┬──────────────┘
               │ Túnel WireGuard (10.8.0.0/24)
               ▼
          10.8.0.2 (k8s-master)
            NodePort → ingress-nginx → pod
```

- **Todos os protocolos:** `cliente → VPS:porta → iptables DNAT → node_wg_ip:node_port → K8s NodePort`
- **Caminho de retorno:** MASQUERADE garante que o tráfego de volta passe pelo VPS
- **Topologia:** hub-and-spoke — VPS é o hub, cada nó é um spoke com `PersistentKeepalive = 25s`
- **Roteamento nos nós:** `AllowedIPs = 10.8.0.1/32` (apenas tráfego do VPS pelo túnel)

### Pré-requisitos

- VPS com Ubuntu 22.04/24.04
- Acesso SSH ao VPS
- Cluster K8s provisionado via `ansible/`

### Workflow

```bash
# 1. Configurar o hub WireGuard no VPS (uma vez)
export VPS_IP=1.2.3.4
./edge/setup-edge.sh

# 2. Registrar um nó K8s no túnel WireGuard
./edge/register-node.sh k8s-master 192.168.15.13 10.8.0.2

# 3. Editar edge.conf com o nó e as portas expostas
#    NODES=("k8s-master:10.8.0.2")
#    PORTS=("443:443:tcp" "80:80:tcp" "25565:30565:tcp")

# 4. Aplicar as regras iptables no VPS
./edge/deploy.sh
```

### Configuração (`edge/edge.conf`)

```bash
WG_VPS_IP=10.8.0.1      # IP WireGuard do VPS
WG_PORT=51820            # Porta de escuta WireGuard

NODES=(
  "k8s-master:10.8.0.2" # nome:wg_ip
)

PORTS=(
  "443:443:tcp"          # vps_port:node_port:proto
  "80:80:tcp"
  "25565:30565:tcp"      # Minecraft Java
)
```

### Scripts

| Script | Função |
|---|---|
| `setup-edge.sh` | Provisionamento inicial do VPS: instala WireGuard, ativa IP forwarding, gera chaves, executa `deploy.sh` |
| `register-node.sh` | Instala WireGuard no nó K8s, gera keypair, cria o túnel, registra como peer no VPS |
| `deploy.sh` | Idempotente: sincroniza `edge.conf` no VPS e aplica as regras iptables DNAT |
| `show-rules.sh` | Exibe as regras iptables gerenciadas pelo edge |

### Verificação

```bash
# Ver peers WireGuard no VPS
ssh root@<VPS_IP> "sudo wg show"

# Ver regras iptables DNAT
./edge/show-rules.sh

# Testar porta
nc -zv <VPS_IP> 25565
```

---

## flux/ — Workloads GitOps

Gerencia todos os workloads Kubernetes via Flux CD. O cluster reconcilia automaticamente a partir deste repositório.

### Estrutura

```
flux/
├── clusters/homelab/             # Entrypoints do Flux (Kustomizations)
│   ├── kustomization.yaml        # Raiz kustomize (lida pelo flux-system)
│   ├── infrastructure.yaml       # Kustomization: camada de infraestrutura
│   ├── cert-manager-issuer.yaml  # Kustomization: issuers TLS (secret criptografado com SOPS)
│   └── apps.yaml                 # Kustomization: aplicações
├── infrastructure/               # HelmReleases de infraestrutura base
│   ├── cert-manager.yaml
│   ├── goldilocks.yaml
│   ├── local-path-provisioner.yaml
│   ├── ingress-nginx-lease-rbac.yaml
│   └── cert-manager-issuer/
│       ├── issuer.yaml
│       └── route53-creds.secret.yaml  # Criptografado com SOPS
└── apps/
    ├── whoami.yaml
    └── minecraft.yaml
```

### Cadeia de dependências

```
infrastructure → cert-manager-issuer → apps
```

### Secrets (SOPS + Age)

Arquivos sensíveis (ex: `route53-creds.secret.yaml`) são criptografados com [SOPS](https://github.com/getsops/sops) usando uma chave Age. O Flux os descriptografa automaticamente via o secret `sops-age` no namespace `flux-system`.

Para configurar a chave Age no cluster:
```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=<caminho-para-chave-age>
```

### Bootstrap

O Flux é inicializado via Flux Operator (Helm), não pelo comando `flux bootstrap`. O operator gerencia o ciclo de vida do Flux através de um CRD `FluxInstance` — sem arquivos `gotk-*.yaml` commitados no repositório.

```bash
export GITHUB_REPO=https://github.com/seu-usuario/homelab
./flux/bootstrap.sh
```

O script:
1. Instala o Flux Operator via Helm
2. Aplica um `FluxInstance` apontando para este repositório
3. Aguarda o Flux ficar pronto

Após o bootstrap, todas as mudanças são aplicadas automaticamente via GitOps. Para forçar uma reconciliação:
```bash
./flux.sh reconcile source git flux-system
./flux.sh reconcile kustomization infrastructure cert-manager-issuer apps
```

### Componentes de infraestrutura

| Componente | Função |
|---|---|
| cert-manager | Gerenciamento automático de certificados TLS |
| ingress-nginx | Controller de ingress HTTP/HTTPS |
| local-path-provisioner | Provisionamento dinâmico de PVCs em nó único |
| goldilocks | Recomendações de resource requests/limits |

### Aplicações

| App | Descrição |
|---|---|
| whoami | Serviço HTTP echo simples para testar ingress |
| minecraft | Servidor Minecraft Java (NodePort 30565) |

---

## Scripts utilitários

| Script | Função |
|---|---|
| `kubectl.sh` | Wrapper do `kubectl` usando `ansible/.kube/config` |
| `k9s.sh` | Wrapper do `k9s` usando `ansible/.kube/config` |
| `flux.sh` | Wrapper da CLI `flux` (instala o flux automaticamente se necessário) |

---

## Referências

- [Documentação Kubespray](https://kubespray.io/)
- [Documentação Flux CD](https://fluxcd.io/docs/)
- [Documentação SOPS](https://github.com/getsops/sops)
- [Documentação WireGuard](https://www.wireguard.com/)
- [Documentação k9s](https://k9scli.io/)
