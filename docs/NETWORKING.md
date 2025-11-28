# Networking Guide

Comprehensive documentation for networking configuration in the homelab cluster.

## Table of Contents

- [Network Overview](#network-overview)
- [Tailscale Mesh](#tailscale-mesh)
- [Kubernetes Networking](#kubernetes-networking)
- [DNS Configuration](#dns-configuration)
- [TLS/SSL Configuration](#tlsssl-configuration)
- [Ingress Configuration](#ingress-configuration)
- [Network Policies](#network-policies)
- [Load Balancing](#load-balancing)
- [Firewall Rules](#firewall-rules)

---

## Network Overview

### Network Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Internet                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Cloudflare                                         │
│                                                                              │
│   DNS: *.lab.axiomlayer.com → 100.67.134.110, 100.106.35.14, 100.121.67.60 │
│   (Tailscale IPs - accessible only via Tailscale network)                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Tailscale Network                                    │
│                                                                              │
│   ┌───────────────┐   ┌───────────────┐   ┌───────────────┐                │
│   │     neko      │   │     neko2     │   │    bobcat     │                │
│   │ 100.67.134.110│◄─▶│ 100.106.35.14 │◄─▶│ 100.121.67.60 │                │
│   │ 192.168.1.167 │   │ 192.168.1.103 │   │ 192.168.1.49  │                │
│   └───────────────┘   └───────────────┘   └───────────────┘                │
│           │                   │                   │                         │
│           └───────────────────┼───────────────────┘                         │
│                               │                                              │
│                       ┌───────▼───────┐                                     │
│                       │   siberian    │                                     │
│                       │  (Tailscale)  │                                     │
│                       │  Ollama GPU   │                                     │
│                       └───────────────┘                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Local Network (192.168.1.0/24)                       │
│                                                                              │
│   Router: 192.168.1.1                                                       │
│   UniFi NAS: 192.168.1.234                                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### IP Address Allocation

| Node | Tailscale IP | Local IP | Role |
|------|--------------|----------|------|
| neko | 100.67.134.110 | 192.168.1.167 | K3s control-plane |
| neko2 | 100.106.35.14 | 192.168.1.103 | K3s control-plane |
| bobcat | 100.121.67.60 | 192.168.1.49 | K3s agent |
| siberian | (Tailscale) | 192.168.1.x | GPU workstation |
| UniFi NAS | N/A | 192.168.1.234 | Backup storage |

### Kubernetes Network CIDRs

| Network | CIDR | Purpose |
|---------|------|---------|
| Pod Network | 10.42.0.0/16 | Pod IP addresses |
| Service Network | 10.43.0.0/16 | ClusterIP services |
| Node Network | 100.x.x.x/32 | Tailscale node IPs |

---

## Tailscale Mesh

### Overview

All cluster communication happens over Tailscale WireGuard mesh:

- **Encryption**: All traffic encrypted via WireGuard
- **NAT Traversal**: Works across networks without port forwarding
- **ACLs**: Can be managed via Tailscale admin console
- **MagicDNS**: Optional hostname resolution

### K3s Configuration

K3s is configured to use Tailscale interface:

```bash
# Server installation
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san=neko \
  --flannel-iface=tailscale0

# Agent installation
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://100.67.134.110:6443 \
  --flannel-iface=tailscale0
```

### Flannel over Tailscale

The CNI (Flannel) is configured to use the `tailscale0` interface:

```yaml
# Flannel configuration
Backend:
  Type: vxlan
Interface: tailscale0
```

This means:
- Pod-to-pod traffic goes over Tailscale
- All inter-node traffic is encrypted
- No additional VPN configuration needed

### Tailscale Commands

```bash
# Check Tailscale status
tailscale status

# Check Tailscale IP
tailscale ip -4

# View network map
tailscale netcheck

# Connect to Tailscale
sudo tailscale up

# Disconnect
sudo tailscale down
```

---

## Kubernetes Networking

### Service Types

| Type | Use Case | Example |
|------|----------|---------|
| ClusterIP | Internal services | PostgreSQL, Redis |
| LoadBalancer | External access | Traefik, Telnet |
| NodePort | (Not used) | - |
| ExternalName | External services | - |

### DNS Resolution

CoreDNS provides in-cluster DNS:

```
# Service DNS format
{service}.{namespace}.svc.cluster.local

# Examples
postgres-rw.outline.svc.cluster.local
authentik-server.authentik.svc.cluster.local
nfs-proxy.nfs-proxy.svc.cluster.local
```

### Pod-to-Pod Communication

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Pod Communication                                 │
│                                                                              │
│   ┌─────────────┐                              ┌─────────────┐              │
│   │ Pod A       │                              │ Pod B       │              │
│   │ 10.42.0.15  │                              │ 10.42.1.20  │              │
│   │ (neko)      │                              │ (neko2)     │              │
│   └──────┬──────┘                              └──────┬──────┘              │
│          │                                            │                      │
│          │  ┌─────────────────────────────────────┐  │                      │
│          └──│         Flannel VXLAN               │──┘                      │
│             │    (over tailscale0 interface)      │                         │
│             └─────────────────────────────────────┘                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## DNS Configuration

### External DNS (Cloudflare)

External-DNS automatically manages Cloudflare DNS records:

| Record | Type | Value | TTL |
|--------|------|-------|-----|
| *.lab.axiomlayer.com | A | 100.67.134.110 | Auto |
| *.lab.axiomlayer.com | A | 100.106.35.14 | Auto |
| *.lab.axiomlayer.com | A | 100.121.67.60 | Auto |

### DNS Records Created

| Subdomain | Target | Purpose |
|-----------|--------|---------|
| alerts | Tailscale IPs | Alertmanager |
| argocd | Tailscale IPs | ArgoCD |
| auth | Tailscale IPs | Authentik |
| ai | Tailscale IPs | Open WebUI |
| chat | Tailscale IPs | Campfire |
| db | Tailscale IPs | Dashboard |
| docs | Tailscale IPs | Outline |
| grafana | Tailscale IPs | Grafana |
| longhorn | Tailscale IPs | Longhorn UI |
| autom8 | Tailscale IPs | n8n |
| plane | Tailscale IPs | Plane |
| telnet | Tailscale IPs | Telnet Server |

### ACME Challenge Records

cert-manager creates temporary TXT records for Let's Encrypt:

```
_acme-challenge.{app}.lab.axiomlayer.com TXT "{challenge-token}"
```

These are automatically created and cleaned up during certificate issuance.

### DNS Propagation

**Important**: Cloudflare caches negative DNS responses for ~7 minutes.

If a record was missing and you're retrying:
1. Wait at least 7 minutes
2. Or delete the certificate and let cert-manager recreate it

### Checking DNS

```bash
# Check A records
dig @1.1.1.1 app.lab.axiomlayer.com A

# Check ACME challenge
dig @1.1.1.1 _acme-challenge.app.lab.axiomlayer.com TXT

# Check from Cloudflare nameserver directly
dig @aurora.ns.cloudflare.com app.lab.axiomlayer.com A +norecurse
```

---

## TLS/SSL Configuration

### Certificate Hierarchy

```
Let's Encrypt (ACME)
        │
        ▼
ClusterIssuer (letsencrypt-prod)
        │
        ▼
Certificate (per application)
        │
        ▼
Secret (TLS cert + key)
        │
        ▼
Ingress (uses secret for TLS)
```

### Certificate Template

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {app}-tls
  namespace: {app}
spec:
  secretName: {app}-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - {app}.lab.axiomlayer.com
```

### Certificate Status

| App | Secret | Expires | Status |
|-----|--------|---------|--------|
| alertmanager | alertmanager-tls | ~90 days | Auto-renew |
| argocd | argocd-tls | ~90 days | Auto-renew |
| authentik | authentik-tls | ~90 days | Auto-renew |
| campfire | campfire-tls | ~90 days | Auto-renew |
| dashboard | dashboard-tls | ~90 days | Auto-renew |
| grafana | grafana-tls | ~90 days | Auto-renew |
| longhorn | longhorn-tls | ~90 days | Auto-renew |
| n8n | autom8-tls | ~90 days | Auto-renew |
| open-webui | open-webui-tls | ~90 days | Auto-renew |
| outline | outline-tls | ~90 days | Auto-renew |
| plane | plane-tls | ~90 days | Auto-renew |
| telnet-server | telnet-metrics-tls | ~90 days | Auto-renew |

### Checking Certificates

```bash
# List all certificates
kubectl get certificates -A

# Check certificate details
kubectl describe certificate {name} -n {namespace}

# Check expiration
kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.notAfter}{"\n"}{end}'

# View certificate content
kubectl get secret {name}-tls -n {namespace} -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

---

## Ingress Configuration

### Standard Ingress Template

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {app}
  namespace: {app}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    # Enable SSO:
    traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - {app}.lab.axiomlayer.com
      secretName: {app}-tls
  rules:
    - host: {app}.lab.axiomlayer.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {app}
                port:
                  number: {port}
```

### Bypassing SSO for Specific Paths

Some paths need to bypass SSO (webhooks, APIs, static assets):

```yaml
# Create a separate ingress without middleware
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {app}-public
  namespace: {app}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    # NO middleware annotation = no SSO
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - {app}.lab.axiomlayer.com
      secretName: {app}-tls
  rules:
    - host: {app}.lab.axiomlayer.com
      http:
        paths:
          - path: /webhook
            pathType: Prefix
            backend:
              service:
                name: {app}
                port:
                  number: {port}
```

### WebSocket Support

For WebSocket endpoints, create a separate ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {app}-ws
  annotations:
    # WebSocket-specific annotations if needed
spec:
  rules:
    - host: {app}.lab.axiomlayer.com
      http:
        paths:
          - path: /ws
            pathType: Prefix
          - path: /cable
            pathType: Prefix
```

---

## Network Policies

### Default Deny Pattern

All namespaces use a default-deny approach:

```yaml
# 1. Default deny all
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {app}-default-deny
  namespace: {app}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

# 2. Allow specific ingress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {app}-allow-ingress
  namespace: {app}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: {app}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
      ports:
        - port: {port}

# 3. Allow specific egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {app}-allow-egress
  namespace: {app}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: {app}
  policyTypes:
    - Egress
  egress:
    # DNS
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    # Add more as needed
```

### Current Network Policies

| Namespace | Policies |
|-----------|----------|
| alertmanager | default-deny, allow-ingress, allow-egress |
| campfire | default-deny, allow-ingress, allow-egress |
| dashboard | default-deny, allow-ingress, allow-egress |
| external-dns | default-deny, allow-egress |
| n8n | default-deny, allow-ingress, allow-egress, db-allow |
| nfs-proxy | default-deny, allow-ingress, allow-egress |
| open-webui | default-deny, allow-ingress, allow-egress, db-allow |
| outline | default-deny, allow-ingress, allow-egress, db-allow, redis-allow |
| telnet-server | default-deny, allow-ingress, allow-egress |

---

## Load Balancing

### K3s ServiceLB

K3s includes ServiceLB (formerly Klipper) for LoadBalancer services:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          ServiceLB                                           │
│                                                                              │
│   LoadBalancer Service                                                       │
│        │                                                                     │
│        ▼                                                                     │
│   ┌─────────┐   ┌─────────┐   ┌─────────┐                                  │
│   │  svclb  │   │  svclb  │   │  svclb  │   (DaemonSet pods)               │
│   │  neko   │   │  neko2  │   │ bobcat  │                                  │
│   └────┬────┘   └────┬────┘   └────┬────┘                                  │
│        │             │             │                                         │
│        └─────────────┼─────────────┘                                         │
│                      │                                                       │
│                      ▼                                                       │
│              Target Pods                                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### LoadBalancer Services

| Service | Namespace | External IPs | Port |
|---------|-----------|--------------|------|
| traefik | kube-system | All Tailscale IPs | 80, 443 |
| telnet-server | telnet-server | All Tailscale IPs | 2323 |

### How Traffic Reaches Services

1. Client connects to any Tailscale IP
2. ServiceLB pod on that node receives traffic
3. ServiceLB forwards to appropriate pod (any node)
4. Response returns via same path

---

## Firewall Rules

### Node Firewall (UFW)

Recommended firewall rules for cluster nodes:

```bash
# Allow SSH
ufw allow 22/tcp

# Allow Tailscale
ufw allow in on tailscale0

# Allow K3s API (from Tailscale only)
ufw allow from 100.64.0.0/10 to any port 6443

# Allow Kubelet
ufw allow from 100.64.0.0/10 to any port 10250

# Allow Flannel VXLAN
ufw allow from 100.64.0.0/10 to any port 8472 proto udp

# Allow NodePort range (if used)
ufw allow from 100.64.0.0/10 to any port 30000:32767 proto tcp

# Enable firewall
ufw enable
```

### Tailscale ACLs

Optional Tailscale ACLs for additional security:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:k3s-node"],
      "dst": ["tag:k3s-node:*"]
    },
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:k3s-node:80,443"]
    }
  ],
  "tagOwners": {
    "tag:k3s-node": ["autogroup:admin"]
  }
}
```

---

## Troubleshooting

### DNS Issues

```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test DNS resolution from a pod
kubectl run -it --rm debug --image=busybox -- nslookup kubernetes.default.svc.cluster.local

# Check external DNS logs
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns
```

### Connectivity Issues

```bash
# Check Tailscale status
tailscale status

# Ping between nodes
tailscale ping neko2

# Check pod networking
kubectl run -it --rm debug --image=busybox -- wget -qO- http://service.namespace.svc:port

# Check network policies
kubectl get networkpolicies -n {namespace}
kubectl describe networkpolicy {name} -n {namespace}
```

### Certificate Issues

```bash
# Check certificate status
kubectl get certificates -A
kubectl describe certificate {name} -n {namespace}

# Check challenges
kubectl get challenges -A
kubectl describe challenge -n {namespace}

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager
```

### Ingress Issues

```bash
# Check ingress configuration
kubectl get ingress -A
kubectl describe ingress {name} -n {namespace}

# Check Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik

# Test with curl
curl -v https://app.lab.axiomlayer.com
```
