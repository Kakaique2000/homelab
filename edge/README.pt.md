# Edge — Proxy Reverso com WireGuard

Gerencia um VPS que serve como ponto de entrada público para o cluster Kubernetes local. Resolve o problema de CGNAT e IPs rotativos criando um túnel WireGuard entre o VPS e os nós do cluster, com nginx fazendo o proxy do tráfego.

> Este diretório é independente de `../ansible/`. O cluster funciona sem o edge. O edge pode ser configurado ou removido sem alterar nada no cluster.

---

## Arquitetura

```
Internet
    │
    │  HTTP :80/:443
    │  TCP qualquer porta (Minecraft, etc)
    ▼
┌─────────────────────────┐
│         VPS             │   IP público fixo
│  nginx  (proxy HTTP)    │
│  nginx  (proxy TCP/UDP) │
│  WireGuard :51820       │
│  wg0: 10.8.0.1          │
└──────────┬──────────────┘
           │  Túnel WireGuard (10.8.0.0/24)
           │  PersistentKeepalive — sobrevive CGNAT
    ┌──────┴──────┐
    │             │
    ▼             ▼
10.8.0.2      10.8.0.3  ...
k8s-master   k8s-worker1
  nginx         nginx
 ingress       ingress
```

**Fluxo HTTP:**
`cliente → VPS:80 → nginx upstream → 10.8.0.X:80 → ingress-nginx → pod`

**Fluxo TCP (ex: Minecraft):**
`cliente → VPS:25565 → nginx stream → 10.8.0.X:25565 → NodePort K8s → pod`

**WireGuard — topologia hub-and-spoke:**
- VPS é o hub (`10.8.0.1`)
- Cada nó K8s é um spoke (`10.8.0.2`, `.3`, ...)
- Nós fazem `PersistentKeepalive = 25s` para manter o túnel vivo mesmo com CGNAT
- Split-tunnel: só `10.8.0.0/24` passa pelo túnel, o resto vai direto pela rede do nó

---

## Pré-requisitos

- VPS com Ubuntu (testado em 22.04/24.04)
- Acesso SSH ao VPS com senha (para a primeira cópia de chave)
- Cluster K8s configurado via `../ansible/` com ingress-nginx ativo
- SSH key gerada em `../ansible/.ssh/id_ed25519`

---

## Setup inicial do VPS (uma vez)

```bash
cd homelab/edge/

export VPS_IP=1.2.3.4
export VPS_USER=ubuntu    # padrão: ubuntu

./setup-vps.sh
```

O script:
1. Copia a chave SSH do ansible para o VPS (pede senha uma vez)
2. Instala `wireguard-tools` e `nginx`
3. Gera keypair WireGuard no VPS e configura `wg0` (`10.8.0.1/24`)
4. Configura nginx com proxy HTTP e suporte a stream TCP/UDP
5. Instala o script `/usr/local/sbin/regen-nginx-upstream.sh` no VPS
6. Salva localmente `.vps-ip`, `.vps-user` e `.vps-wg-public.key` (gitignored)

---

## Registrar um nó no edge

Rode após `../ansible/install-k8s.sh` (master) ou `../ansible/add-worker.sh` (worker):

```bash
# Master (WG IP atribuído automaticamente: 10.8.0.2)
./register-node.sh k8s-master 192.168.15.13

# Worker (WG IP atribuído automaticamente: 10.8.0.3, .4, ...)
./register-node.sh k8s-worker1 192.168.15.20

# Com WG IP explícito
./register-node.sh k8s-master 192.168.15.13 10.8.0.2
```

O script:
1. Instala WireGuard no nó
2. Gera keypair no nó
3. Configura o túnel no nó (aponta para o VPS)
4. Registra o nó como peer no VPS (`wg addconf` — sem restart)
5. Regenera upstreams do nginx (HTTP + todas as portas TCP/UDP)
6. Verifica conectividade com `ping`

---

## Expor porta TCP/UDP extra

Para serviços que não são HTTP (Minecraft, servidores de jogo, etc):

```bash
./add-port.sh 25565 tcp   # Minecraft Java
./add-port.sh 19132 udp   # Minecraft Bedrock
./add-port.sh 27015 udp   # Steam
```

O tráfego é balanceado entre todos os nós registrados. Certifique-se de que o serviço K8s usa `NodePort` na mesma porta.

---

## Remover um nó

```bash
# Remove do VPS apenas
./remove-node.sh k8s-worker1

# Remove do VPS e também limpa o nó
./remove-node.sh k8s-worker1 192.168.15.20
```

---

## Workflow completo

```
1. Setup VPS (uma vez)
   export VPS_IP=1.2.3.4 && ./setup-vps.sh

2. Instalar cluster K8s
   cd ../ansible/ && ./install-k8s.sh

3. Registrar master no edge
   cd ../edge/ && ./register-node.sh k8s-master 192.168.15.13

4. (Opcional) Adicionar worker
   cd ../ansible/ && ./add-worker.sh k8s-worker1 192.168.15.20
   cd ../edge/   && ./register-node.sh k8s-worker1 192.168.15.20

5. (Opcional) Expor portas extras
   ./add-port.sh 25565 tcp
```

---

## Arquivos

| Arquivo | Descrição |
|---|---|
| `setup-vps.sh` | Provisionamento inicial do VPS |
| `register-node.sh` | Registra nó no WireGuard e nginx |
| `remove-node.sh` | Remove nó do WireGuard e nginx |
| `add-port.sh` | Expõe porta TCP/UDP no VPS |
| `.vps-ip` | IP do VPS (gerado, gitignored) |
| `.vps-user` | Usuário SSH do VPS (gerado, gitignored) |
| `.vps-wg-public.key` | Chave pública WireGuard do VPS (gerado, gitignored) |

---

## Como o nginx é atualizado automaticamente

O VPS tem um script `/usr/local/sbin/regen-nginx-upstream.sh` que:
- Lê todos os arquivos em `/etc/wireguard/peers/*.conf`
- Extrai os IPs WireGuard de cada nó
- Regenera `/etc/nginx/conf.d/k8s-upstream.conf` (upstream HTTP)
- Regenera todos os arquivos em `/etc/nginx/stream.conf.d/ports/` (upstreams TCP/UDP)
- Faz `nginx reload`

É chamado automaticamente por `register-node.sh` e `remove-node.sh`. Nunca precisa ser rodado manualmente.

---

## Verificação

```bash
# Testar proxy HTTP
curl -H "Host: meuapp.com" http://<VPS_IP>/

# Testar porta TCP
nc -zv <VPS_IP> 25565

# Ver estado do WireGuard no VPS
ssh ubuntu@<VPS_IP> "sudo wg show"

# Ver nós registrados
ssh ubuntu@<VPS_IP> "ls /etc/wireguard/peers/"

# Ver upstreams nginx
ssh ubuntu@<VPS_IP> "cat /etc/nginx/conf.d/k8s-upstream.conf"
```
