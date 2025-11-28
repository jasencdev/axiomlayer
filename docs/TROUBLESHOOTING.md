# Troubleshooting Guide

Comprehensive troubleshooting guide for common issues in the homelab cluster.

## Table of Contents

- [Quick Diagnostics](#quick-diagnostics)
- [Certificate Issues](#certificate-issues)
- [ArgoCD Issues](#argocd-issues)
- [Storage Issues](#storage-issues)
- [Network Issues](#network-issues)
- [Application Issues](#application-issues)
- [Node Issues](#node-issues)
- [Authentication Issues](#authentication-issues)
- [Database Issues](#database-issues)

---

## Quick Diagnostics

### Cluster Health Check

```bash
# Node status
kubectl get nodes -o wide

# All pods status
kubectl get pods -A | grep -v Running | grep -v Completed

# Recent events
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# Resource usage
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20
```

### Component Health

```bash
# ArgoCD applications
kubectl get applications -n argocd

# Certificates
kubectl get certificates -A

# Sealed secrets
kubectl get sealedsecrets -A

# Persistent volumes
kubectl get pv

# Ingresses
kubectl get ingress -A
```

---

## Certificate Issues

### Certificate Stuck in "Pending"

**Symptoms:**
- Certificate shows `Ready: False`
- Challenge not completing

**Diagnosis:**

```bash
# Check certificate status
kubectl describe certificate {name} -n {namespace}

# Check certificate request
kubectl get certificaterequests -n {namespace}
kubectl describe certificaterequest {name} -n {namespace}

# Check challenges
kubectl get challenges -n {namespace}
kubectl describe challenge {name} -n {namespace}

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager --tail=100 | grep {domain}
```

**Common Causes & Solutions:**

1. **DNS record not created**
   ```bash
   # Check if TXT record exists
   dig @1.1.1.1 _acme-challenge.{app}.lab.axiomlayer.com TXT

   # If missing, delete challenge and let cert-manager retry
   kubectl delete challenge -n {namespace} --all
   ```

2. **Cloudflare API token invalid**
   ```bash
   # Check token is correct
   kubectl get secret cloudflare-api-token -n cert-manager -o jsonpath='{.data.api-token}' | base64 -d

   # Reseal with correct token if needed
   ```

3. **DNS propagation delay**
   ```bash
   # Wait 7+ minutes (Cloudflare negative cache TTL)
   # Then delete and recreate certificate
   kubectl delete certificate {name} -n {namespace}
   ```

4. **Rate limiting (Let's Encrypt)**
   ```bash
   # Check cert-manager logs for rate limit errors
   # Wait 1 hour and retry
   ```

### Certificate Expired

**Quick Fix:**

```bash
# Delete certificate to trigger renewal
kubectl delete certificate {name} -n {namespace}

# ArgoCD will recreate it
# Watch for new certificate
kubectl get certificates -n {namespace} -w
```

### Traefik Not Using New Certificate

```bash
# Restart Traefik to pick up new TLS secret
kubectl rollout restart deployment/traefik -n kube-system

# Or delete the pod
kubectl delete pod -n kube-system -l app.kubernetes.io/name=traefik
```

---

## ArgoCD Issues

### Application OutOfSync

**Diagnosis:**

```bash
# Check sync status
kubectl get application {name} -n argocd -o jsonpath='{.status.sync.status}'

# Get detailed diff
kubectl get application {name} -n argocd -o yaml | grep -A50 "status:"
```

**Common Causes & Solutions:**

1. **Immutable resource changed (Jobs)**
   ```bash
   # Delete the job, ArgoCD will recreate
   kubectl delete job {name} -n {namespace}
   ```

2. **Resource modified outside GitOps**
   ```bash
   # Force sync to restore Git state
   kubectl patch application {name} -n argocd --type merge \
     -p '{"operation":{"sync":{"force":true}}}'
   ```

3. **Finalizer blocking deletion**
   ```bash
   # Remove finalizer
   kubectl patch {resource} {name} -n {namespace} --type merge \
     -p '{"metadata":{"finalizers":null}}'
   ```

### Application Stuck in "Progressing"

```bash
# Check application status
kubectl describe application {name} -n argocd

# Check target resources
kubectl get all -n {target-namespace}

# Check for pods not starting
kubectl get pods -n {target-namespace} -o wide
kubectl describe pod {pod} -n {target-namespace}
```

### ArgoCD UI Not Accessible

```bash
# Check ArgoCD server
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

# Check ingress
kubectl describe ingress argocd-server -n argocd

# Check certificate
kubectl get certificate argocd-tls -n argocd

# Restart server
kubectl rollout restart deployment/argocd-server -n argocd
```

### Force Hard Refresh

```bash
# Refresh from Git (hard refresh)
kubectl patch application {name} -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

---

## Storage Issues

### Longhorn Volume Degraded

**Symptoms:**
- Volume shows "Degraded" in UI
- Less than expected replicas

**Diagnosis:**

```bash
# Check volume status
kubectl get volumes -n longhorn-system
kubectl describe volume {pvc-name} -n longhorn-system

# Check replicas
kubectl get replicas -n longhorn-system | grep {pvc-name}

# Check node storage
kubectl get nodes.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,SCHEDULABLE:.spec.allowScheduling,STORAGE:.status.conditions
```

**Solutions:**

1. **Node disk full**
   ```bash
   # Check disk usage on nodes
   ssh {node} df -h

   # Extend LVM if needed
   sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
   sudo resize2fs /dev/ubuntu-vg/ubuntu-lv

   # Restart Longhorn manager to detect new space
   kubectl delete pod -n longhorn-system -l app=longhorn-manager
   ```

2. **Node not schedulable**
   ```bash
   # Check Longhorn UI or
   kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep allowScheduling
   ```

### Volume Stuck in Attaching

```bash
# Check volume attachment
kubectl describe volumeattachment | grep {pvc-name}

# Force detach (careful!)
kubectl delete volumeattachment {attachment-name}

# Delete and recreate pod using the volume
kubectl delete pod {pod-name} -n {namespace}
```

### PVC Stuck in Pending

```bash
# Check PVC events
kubectl describe pvc {name} -n {namespace}

# Check storage class exists
kubectl get storageclass

# Check Longhorn CSI
kubectl get pods -n longhorn-system | grep csi
```

---

## Network Issues

### Pod Cannot Reach External Services

**Diagnosis:**

```bash
# Test from pod
kubectl run -it --rm debug --image=busybox -- sh
# Inside pod:
wget -qO- https://google.com
nslookup google.com
```

**Common Causes:**

1. **Network policy blocking egress**
   ```bash
   kubectl get networkpolicies -n {namespace}
   kubectl describe networkpolicy {name} -n {namespace}
   ```

2. **CoreDNS not working**
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   kubectl logs -n kube-system -l k8s-app=kube-dns
   ```

### Service Not Reachable

```bash
# Check service exists
kubectl get svc -n {namespace}

# Check endpoints
kubectl get endpoints {service} -n {namespace}

# Test connectivity
kubectl run -it --rm debug --image=busybox -- wget -qO- http://{service}.{namespace}.svc:port
```

### Ingress Not Working

```bash
# Check ingress
kubectl describe ingress {name} -n {namespace}

# Check Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik | grep {domain}

# Test with curl
curl -vk https://{domain}
```

### Tailscale Connection Issues

```bash
# Check Tailscale status
tailscale status

# Check connectivity between nodes
tailscale ping {other-node}

# Restart Tailscale
sudo systemctl restart tailscaled
sudo tailscale up
```

---

## Application Issues

### Pod CrashLooping

**Diagnosis:**

```bash
# Check pod status
kubectl get pods -n {namespace}
kubectl describe pod {pod} -n {namespace}

# Check logs
kubectl logs {pod} -n {namespace}
kubectl logs {pod} -n {namespace} --previous  # Previous crash
```

**Common Causes:**

1. **Configuration error**
   ```bash
   # Check ConfigMap/Secret mounted correctly
   kubectl get pod {pod} -n {namespace} -o yaml | grep -A20 "volumes:"
   ```

2. **Resource limits too low**
   ```bash
   # Check if OOMKilled
   kubectl describe pod {pod} -n {namespace} | grep -A5 "State:"

   # Increase limits in deployment
   ```

3. **Liveness probe failing**
   ```bash
   # Check probe configuration
   kubectl get deployment {name} -n {namespace} -o yaml | grep -A10 "livenessProbe:"
   ```

### Pod Stuck in Pending

```bash
# Check events
kubectl describe pod {pod} -n {namespace}

# Common causes:
# - No nodes with enough resources
# - Node selector/affinity not matching
# - PVC not bound
# - Image pull error
```

### Pod Stuck in Terminating

```bash
# Force delete
kubectl delete pod {pod} -n {namespace} --grace-period=0 --force

# If still stuck, check finalizers
kubectl get pod {pod} -n {namespace} -o yaml | grep finalizers
```

### Image Pull Error

```bash
# Check image name and tag
kubectl describe pod {pod} -n {namespace} | grep Image

# Check pull secret
kubectl get pod {pod} -n {namespace} -o yaml | grep imagePullSecrets

# Verify secret exists
kubectl get secret {pull-secret} -n {namespace}
```

---

## Node Issues

### Node NotReady

**Diagnosis:**

```bash
# Check node status
kubectl describe node {node}

# Check kubelet logs
ssh {node} journalctl -u k3s -n 100

# Check disk space
ssh {node} df -h

# Check memory
ssh {node} free -h
```

**Solutions:**

1. **Disk pressure**
   ```bash
   # Clean up
   ssh {node} sudo docker system prune -af  # if using docker
   ssh {node} sudo crictl rmi --prune       # for containerd

   # Extend disk
   sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
   sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
   ```

2. **K3s service crashed**
   ```bash
   ssh {node} sudo systemctl restart k3s
   # or for agent
   ssh {node} sudo systemctl restart k3s-agent
   ```

3. **Tailscale disconnected**
   ```bash
   ssh {node} tailscale status
   ssh {node} sudo tailscale up
   ```

### High CPU/Memory Usage

```bash
# Find resource hogs
kubectl top pods -A --sort-by=cpu | head -10
kubectl top pods -A --sort-by=memory | head -10

# Check node resource usage
kubectl top nodes
```

---

## Authentication Issues

### SSO Login Failing

**Diagnosis:**

```bash
# Check Authentik server
kubectl get pods -n authentik
kubectl logs -n authentik -l app.kubernetes.io/name=authentik-server

# Check outpost
kubectl get pods -n authentik | grep outpost
kubectl logs -n authentik -l app.kubernetes.io/name=ak-outpost-forward-auth-outpost
```

**Common Causes:**

1. **Outpost not running**
   ```bash
   kubectl rollout restart deployment/ak-outpost-forward-auth-outpost -n authentik
   ```

2. **Wrong redirect URL in provider**
   - Check Authentik admin → Providers → Application
   - Verify redirect URIs match

3. **Middleware not applied**
   ```bash
   kubectl describe ingress {name} -n {namespace} | grep middlewares
   ```

### Authentik UI Not Loading

```bash
# Check all Authentik components
kubectl get pods -n authentik

# Check database
kubectl logs -n authentik authentik-postgresql-0

# Check Redis
kubectl logs -n authentik authentik-redis-master-0

# Restart Authentik
kubectl rollout restart deployment/authentik-server -n authentik
```

---

## Database Issues

### CloudNativePG Cluster Unhealthy

```bash
# Check cluster status
kubectl get clusters -A
kubectl describe cluster {name} -n {namespace}

# Check pods
kubectl get pods -n {namespace} -l cnpg.io/cluster={name}

# Check primary
kubectl get pods -n {namespace} -l cnpg.io/cluster={name},role=primary
```

### PostgreSQL Connection Refused

```bash
# Test connection
kubectl run -it --rm psql --image=postgres:15 -- \
  psql -h {cluster}-rw.{namespace}.svc -U {user} -d {database}

# Check service
kubectl get svc -n {namespace} | grep {cluster}

# Check endpoints
kubectl get endpoints {cluster}-rw -n {namespace}
```

### Database Full

```bash
# Check PVC usage
kubectl exec -it {cluster}-1 -n {namespace} -- df -h /var/lib/postgresql/data

# Expand PVC (Longhorn supports expansion)
kubectl patch pvc {pvc-name} -n {namespace} --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

---

## Quick Reference Commands

### Logs

```bash
# Application logs
kubectl logs -n {namespace} -l app.kubernetes.io/name={app} -f

# Previous container logs
kubectl logs -n {namespace} {pod} --previous

# All containers in pod
kubectl logs -n {namespace} {pod} --all-containers

# Logs with timestamps
kubectl logs -n {namespace} {pod} --timestamps
```

### Debugging

```bash
# Interactive shell in pod
kubectl exec -it {pod} -n {namespace} -- /bin/sh

# Run debug container
kubectl run -it --rm debug --image=busybox -- sh

# Network debugging
kubectl run -it --rm debug --image=nicolaka/netshoot -- bash
```

### Resource Management

```bash
# Force delete stuck resources
kubectl delete {resource} {name} -n {namespace} --grace-period=0 --force

# Remove finalizers
kubectl patch {resource} {name} -n {namespace} --type merge \
  -p '{"metadata":{"finalizers":null}}'

# Restart deployment
kubectl rollout restart deployment/{name} -n {namespace}
```

### Events

```bash
# All events
kubectl get events -A --sort-by='.lastTimestamp'

# Namespace events
kubectl get events -n {namespace} --sort-by='.lastTimestamp'

# Watch events
kubectl get events -A -w
```
