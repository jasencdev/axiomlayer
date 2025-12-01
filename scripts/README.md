# Scripts Documentation

This directory contains provisioning, maintenance, and automation scripts for the homelab cluster.

**Shell Compatibility**: All scripts use `#!/bin/bash` and are tested on Ubuntu 24.04 LTS with zsh 5.9.

## Table of Contents

- [Provisioning Scripts](#provisioning-scripts)
- [Maintenance Scripts](#maintenance-scripts)
- [Validation Scripts](#validation-scripts)
- [Documentation Sync Scripts](#documentation-sync-scripts)
- [Fix/Repair Scripts](#fixrepair-scripts)

---

## Provisioning Scripts

### provision-k3s-server.sh

Provisions a K3s control-plane (server) node with all required dependencies.

**Purpose**: Automates installation of K3s server with Tailscale networking, Docker, and development tools.

**Usage**:
```bash
# First control-plane node (neko)
sudo ./scripts/provision-k3s-server.sh <username> --init

# Additional control-plane nodes (neko2)
sudo ./scripts/provision-k3s-server.sh <username> --join <first-server-tailscale-ip>
```

**Parameters**:
- `<username>`: User to configure (default: `jasen`)
- `--init`: Initialize first control-plane node with cluster-init
- `--join <ip>`: Join existing cluster at given Tailscale IP

**What it installs**:
- System packages (btop, build-essential, curl, git, zsh, etc.)
- GitHub CLI
- Tailscale
- Docker
- kubectl
- kubeseal
- Helm
- K3s server

**Prerequisites**:
- Ubuntu 24.04 LTS
- Root access (run with `sudo`)
- Tailscale account

**Post-installation**:
- K3s kubeconfig at `/etc/rancher/k3s/k3s.yaml`
- Symlinked to `~/.kube/config` for user
- K3s runs on Tailscale interface (`tailscale0`)

**Example**:
```bash
# On neko (first server)
sudo ./scripts/provision-k3s-server.sh jasen --init

# On neko2 (second server)
sudo ./scripts/provision-k3s-server.sh jasen --join 100.67.134.110
```

---

### provision-k3s-agent.sh

Provisions a K3s worker node (agent).

**Purpose**: Automates installation of K3s agent to join existing cluster.

**Usage**:
```bash
sudo ./scripts/provision-k3s-agent.sh <username> <server-tailscale-ip>
```

**Parameters**:
- `<username>`: User to configure (default: `jasen`)
- `<server-tailscale-ip>`: Tailscale IP of K3s server to join

**What it installs**:
- System packages
- GitHub CLI
- Tailscale
- Docker (for CI/CD workloads)
- kubectl
- K3s agent

**Prerequisites**:
- Ubuntu 24.04 LTS
- Root access
- Tailscale connected
- K3s server already running
- K3s join token from server (at `/var/lib/rancher/k3s/server/node-token`)

**Example**:
```bash
# On panther or bobcat
sudo ./scripts/provision-k3s-agent.sh jasen 100.67.134.110
```

---

### provision-k3s-ollama-agent.sh

Provisions a lightweight K3s GPU agent for Ollama embeddings.

**Purpose**: Specialized provisioning for GPU nodes running Ollama for embeddings (not full generation workloads).

**Usage**:
```bash
sudo ./scripts/provision-k3s-ollama-agent.sh <username> <server-tailscale-ip>
```

**Parameters**:
- `<username>`: User to configure
- `<server-tailscale-ip>`: K3s server Tailscale IP

**Differences from standard agent**:
- Optimized for lightweight embedding tasks
- Assumes NVIDIA GPU present
- Configures Ollama for embedding models only

**Prerequisites**:
- NVIDIA GPU (e.g., RTX 3050 Ti on panther)
- NVIDIA drivers installed
- Same as `provision-k3s-agent.sh`

**Example**:
```bash
# On panther (RTX 3050 Ti node)
sudo ./scripts/provision-k3s-ollama-agent.sh jasen 100.67.134.110
```

---

### provision-siberian.sh

Provisions GPU workstation for Ollama LLM generation (external to K8s cluster).

**Purpose**: Sets up dedicated GPU workstation (siberian) with Ollama for LLM chat inference.

**Usage**:
```bash
sudo ./scripts/provision-siberian.sh <username>
```

**Parameters**:
- `<username>`: User to configure (default: `jasen`)

**What it installs**:
- System packages
- GitHub CLI
- Tailscale
- NVIDIA drivers (535 server)
- Docker
- Ollama

**GPU**: NVIDIA RTX 5070 Ti (16GB VRAM)

**Post-installation**:
1. Reboot to load NVIDIA drivers
2. Run `sudo tailscale up` to connect
3. Run `sudo systemctl start ollama`
4. Pull models: `ollama pull llama3.2:3b`

**Example**:
```bash
# On siberian workstation
sudo ./scripts/provision-siberian.sh jasen
# Reboot
sudo reboot
# After reboot
sudo tailscale up
sudo systemctl start ollama
ollama pull llama3.2:3b
ollama pull deepseek-r1:14b
```

**Recommended Models** (16GB VRAM):
- `llama3.2:3b` (2GB) - Fast, general purpose
- `llama3.1:8b` (5GB) - Balanced
- `deepseek-r1:14b` (9GB) - Reasoning
- `codellama:13b` (8GB) - Code assistance
- `qwen2.5:14b` (9GB) - Multilingual

---

### provision-ollama-workstation.sh

General-purpose Ollama workstation provisioning.

**Purpose**: Alternative provisioning script for Ollama workstations (similar to provision-siberian.sh but more generic).

**Usage**:
```bash
sudo ./scripts/provision-ollama-workstation.sh <username>
```

**Parameters**:
- `<username>`: User to configure

**Differences from provision-siberian.sh**:
- More generic, not specific to siberian hardware
- May have different NVIDIA driver version
- Can be used for any GPU workstation

---

### provision-neko.sh

Provisions the neko node (primary control-plane).

**Purpose**: Full provisioning of neko as primary K3s control-plane with all development tools.

**Usage**:
```bash
sudo ./scripts/provision-neko.sh <username>
```

**Parameters**:
- `<username>`: User to configure (default: `jasen`)

**What it installs**:
- All packages from `provision-k3s-server.sh`
- Additional development tools specific to neko
- K3s server with `--cluster-init`

**Special considerations**:
- This is the primary control-plane node
- etcd runs here
- NFS proxy runs here (for Longhorn backups)

---

### provision-neko2.sh

Provisions the neko2 node (secondary control-plane).

**Purpose**: Provisions neko2 as secondary K3s control-plane for HA.

**Usage**:
```bash
sudo ./scripts/provision-neko2.sh <username>
```

**Parameters**:
- `<username>`: User to configure

**What it does**:
- Joins existing K3s cluster as additional control-plane
- Configured to use Tailscale networking
- Participates in etcd quorum

**Prerequisites**:
- neko (primary control-plane) must be running
- K3s join token available

---

## Maintenance Scripts

### backup-homelab.sh

Creates local backup of critical homelab configuration and data.

**Purpose**: Manual backup script for operator-initiated backups before maintenance or risky operations.

**Usage**:
```bash
./scripts/backup-homelab.sh
```

**What it backs up**:
- `.env` file (secrets)
- Sealed Secrets controller public/private keys
- CNPG PostgreSQL databases (Authentik, Outline)
- Longhorn settings
- Git repository state

**Output location**: `./backups/backup-YYYYMMDD-HHMMSS/`

**Prerequisites**:
- kubectl access to cluster
- `.env` file exists
- Cluster is healthy

**Example**:
```bash
# Before cluster maintenance
./scripts/backup-homelab.sh

# Backup is created in backups/ directory
ls backups/
# backup-20251201-143022/
```

**Note**: This is different from automated CronJob backups (`infrastructure/backups/`) which run daily at 3 AM.

---

### bootstrap-argocd.sh

Bootstraps ArgoCD and GitOps deployment.

**Purpose**: Initial ArgoCD installation and configuration after cluster is provisioned.

**Usage**:
```bash
./scripts/bootstrap-argocd.sh
```

**What it does**:
1. Installs ArgoCD via kubectl apply
2. Waits for ArgoCD to be ready
3. Applies root Application (App of Apps)
4. Configures ArgoCD credentials
5. Creates initial admin password

**Prerequisites**:
- K3s cluster running
- kubectl access
- Sealed Secrets controller installed

**Post-bootstrap**:
- ArgoCD UI at https://argocd.lab.axiomlayer.com
- Root application begins syncing all child apps
- GitOps workflow is active

**Example**:
```bash
# After K3s cluster is running
./scripts/bootstrap-argocd.sh

# Check ArgoCD is running
kubectl get pods -n argocd

# Get admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

**Recovery**: If cluster is rebuilt, re-run this script to restore GitOps.

---

## Validation Scripts

### validate-kustomize.sh

Validates all Kustomize builds in the repository.

**Purpose**: Ensures all `kustomization.yaml` files are valid and can build successfully.

**Usage**:
```bash
./scripts/validate-kustomize.sh
```

**What it validates**:
- All directories with `kustomization.yaml` in `apps/`
- All directories with `kustomization.yaml` in `infrastructure/`
- Runs `kubectl kustomize` on each directory

**Exit codes**:
- `0`: All kustomizations valid
- `1`: At least one kustomization failed

**Example**:
```bash
# Validate all kustomizations
./scripts/validate-kustomize.sh

# Output:
# Validating apps/argocd
# Validating apps/campfire
# Validating apps/dashboard
# ...
```

**CI/CD**: This script is run in CI pipeline via `tests/validate-manifests.sh`.

---

### check-no-plaintext-secrets.sh

Validates that no plaintext Kubernetes Secrets are committed to Git.

**Purpose**: Security validation to ensure only SealedSecrets are used, never plaintext Secrets.

**Usage**:
```bash
./scripts/check-no-plaintext-secrets.sh
```

**What it checks**:
- Searches for `kind: Secret` (top-level, not indented) in all YAML files
- Ignores references in ArgoCD `ignoreDifferences` blocks

**Exit codes**:
- `0`: No plaintext secrets found ✅
- `1`: Plaintext secrets detected ❌

**Example**:
```bash
# Check for plaintext secrets
./scripts/check-no-plaintext-secrets.sh

# If secrets found:
# ERROR: Found plaintext Secret. Use SealedSecret instead.
# apps/myapp/secret.yaml:2:kind: Secret
```

**CI/CD**: Should be run in CI to prevent plaintext secrets from being merged.

**Fix**: Replace `kind: Secret` with `kind: SealedSecret` and seal using `kubeseal`.

---

## Documentation Sync Scripts

### sync-outline.sh

Syncs markdown documentation to Outline wiki.

**Purpose**: Publishes repository documentation to Outline at https://docs.lab.axiomlayer.com.

**Usage**:
```bash
# Set environment variables
export OUTLINE_API_TOKEN="your-outline-api-token"

# Sync documentation
./scripts/sync-outline.sh

# Force full sync (ignores state tracking)
FORCE_FULL_SYNC=true ./scripts/sync-outline.sh
```

**Environment variables**:
- `OUTLINE_API_TOKEN` or `OUTLINE_API_KEY`: API token from Outline (required)
- `FORCE_FULL_SYNC`: Set to `true` to re-sync all files

**Configuration**:
- `outline_sync/config.json`: Defines which files to sync and their titles
- `outline_sync/state.json`: Tracks document IDs (auto-generated)
- `.outline-sync-commit`: Tracks last synced git commit

**How it works**:
1. Checks git diff since last sync (from `.outline-sync-commit`)
2. For each changed file in `config.json`:
   - If not in Outline yet → create document
   - If already in Outline → update document
3. Updates `.outline-sync-commit` marker

**Prerequisites**:
- Outline API token with `documents.write` + `collections.write` scopes
- Git repository with commit history
- Outline collection already created

**Example**:
```bash
# First time setup - add API token to .env
echo 'export OUTLINE_API_TOKEN="your-token-here"' >> .env

# Sync docs (in zsh)
bash -c 'source .env && ./scripts/sync-outline.sh'

# Force re-sync all docs
bash -c 'source .env && FORCE_FULL_SYNC=true ./scripts/sync-outline.sh'
```

**CI/CD**: Runs automatically on push to `main` via GitHub Actions.

**Troubleshooting**:
- Check `outline_sync/state.json` for document IDs
- Delete `state.json` to force re-creation of all documents
- Check Outline API token scopes

---

### sync-rag.sh

Syncs repository files to Open WebUI RAG knowledge base.

**Purpose**: Uploads codebase to Open WebUI for AI-powered code search and chat.

**Usage**:
```bash
# Set environment variables
export OPEN_WEBUI_API_KEY="your-api-key"
export OPEN_WEBUI_KNOWLEDGE_ID="your-knowledge-base-id"

# Sync files
./scripts/sync-rag.sh

# Force full sync
FORCE_FULL_SYNC=true ./scripts/sync-rag.sh
```

**Environment variables** (required):
- `OPEN_WEBUI_API_KEY`: API key from Open WebUI
- `OPEN_WEBUI_KNOWLEDGE_ID`: Knowledge base UUID
- `FORCE_FULL_SYNC`: Set to `true` to re-upload all files

**What it syncs**:
- All `*.md` files
- `apps/**/*.yaml`
- `infrastructure/**/*.yaml`
- `.github/workflows/*.yaml`

**Exclusions**:
- `*sealed-secret*`
- `*.env*`
- `*AGENTS.md*`
- `node_modules/`
- `.git/`

**How it works**:
1. Checks git diff since last sync (from `.rag-sync-commit`)
2. For each changed file:
   - If not in knowledge base → upload
   - If in knowledge base and content changed → update
   - If unchanged → skip
3. Updates `.rag-sync-commit` marker

**Prerequisites**:
- Open WebUI running at https://ai.lab.axiomlayer.com
- API key created in Open WebUI
- Knowledge base created in Open WebUI

**Example**:
```bash
# First time setup
echo 'export OPEN_WEBUI_API_KEY="sk-xxxxx"' >> .env
echo 'export OPEN_WEBUI_KNOWLEDGE_ID="uuid-here"' >> .env

# Sync (in zsh)
bash -c 'source .env && ./scripts/sync-rag.sh'

# Force re-upload all files
bash -c 'source .env && FORCE_FULL_SYNC=true ./scripts/sync-rag.sh'
```

**CI/CD**: Runs automatically on push to `main` via GitHub Actions.

**Troubleshooting**:
- Verify API key is valid
- Check knowledge base ID in Open WebUI UI
- Delete `.rag-sync-commit` to force full re-sync
- Check Open WebUI logs if uploads fail

---

## Fix/Repair Scripts

### fix-etcd-ip.sh

Fixes etcd member IP address to use Tailscale IP.

**Purpose**: Corrects etcd member peer URL when node is using wrong IP address (typically after networking changes).

**Usage**:
```bash
# Run on control-plane node with etcd issue
sudo ./scripts/fix-etcd-ip.sh
```

**When to use**:
- etcd is using local IP instead of Tailscale IP
- K3s control-plane not reachable from other nodes
- etcd quorum issues after network changes

**What it does**:
1. Starts K3s if not running
2. Gets etcd member list via `etcdctl`
3. Identifies member ID
4. Updates peer URL to use Tailscale IP (100.67.134.110)
5. Restarts K3s
6. Verifies change

**Prerequisites**:
- Must run on neko (primary control-plane)
- Root access required
- Tailscale connected
- etcd certificates present

**Example**:
```bash
# On neko
sudo ./scripts/fix-etcd-ip.sh

# Output:
# === Fixing neko etcd member IP ===
# Starting k3s...
# Getting etcd member ID...
# Member ID: abc123def456
# Updating member peer URL to https://100.67.134.110:2380...
# Restarting k3s...
# === Done ===
```

**Manual fix** (if script fails):
```bash
ETCD_CERTS="--cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key"
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_CERTS member list
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_CERTS member update <ID> --peer-urls=https://100.67.134.110:2380
sudo systemctl restart k3s
```

---

### fix-flannel-agents.sh

Fixes Flannel networking on K3s worker nodes to use Tailscale interface.

**Purpose**: Reconfigures K3s agent to use Tailscale for pod networking.

**Usage**:
```bash
# Run on worker nodes (bobcat, panther)
sudo ./scripts/fix-flannel-agents.sh
```

**When to use**:
- Pods can't communicate across nodes
- Worker nodes using wrong network interface
- After changing network configuration

**What it does**:
1. Detects Tailscale IP
2. Backs up `/etc/systemd/system/k3s-agent.service`
3. Adds `--node-ip=<tailscale-ip>` and `--flannel-iface=tailscale0`
4. Reloads systemd and restarts k3s-agent

**Prerequisites**:
- Tailscale connected
- K3s agent installed
- Root access

**Example**:
```bash
# On bobcat or panther
sudo ./scripts/fix-flannel-agents.sh

# Output:
# Tailscale IP: 100.79.124.94
# Adding --node-ip and --flannel-iface to k3s-agent...
# Added --node-ip=100.79.124.94 --flannel-iface=tailscale0
# Reloading and restarting k3s-agent...
# Done. Checking status...
```

**Verification**:
```bash
# Check node is using correct IP
kubectl get nodes -o wide

# Check pod networking
kubectl run test-pod --image=busybox --rm -it -- ping <other-pod-ip>
```

---

### fix-flannel-neko2.sh

Fixes Flannel networking on neko2 control-plane to use Tailscale interface.

**Purpose**: Reconfigures K3s server on neko2 to use Tailscale for pod networking.

**Usage**:
```bash
# Run on neko2 (secondary control-plane)
sudo ./scripts/fix-flannel-neko2.sh
```

**When to use**:
- neko2 pods can't communicate with other nodes
- neko2 using wrong network interface
- After network changes on neko2

**What it does**:
1. Detects Tailscale IP
2. Backs up `/etc/systemd/system/k3s.service`
3. Adds `--node-ip=<tailscale-ip>`, `--advertise-address=<tailscale-ip>`, and `--flannel-iface=tailscale0`
4. Reloads systemd and restarts k3s

**Prerequisites**:
- Tailscale connected on neko2
- K3s server installed
- Root access

**Example**:
```bash
# On neko2
sudo ./scripts/fix-flannel-neko2.sh

# Output:
# Tailscale IP: 100.106.35.14
# Adding --node-ip, --advertise-address, and --flannel-iface to k3s server...
# Added flags
# Reloading and restarting k3s...
# Done. Checking status...
```

**Difference from fix-flannel-agents.sh**:
- This fixes K3s **server** (not agent)
- Includes `--advertise-address` for control-plane API
- Only for control-plane nodes (neko2)

---

## Script Conventions

### All Scripts Follow These Standards

1. **Shebang**: `#!/bin/bash`
2. **Error handling**: Most use `set -e` or `set -euo pipefail`
3. **Idempotency**: Can be run multiple times safely
4. **Logging**: Echo progress and status messages
5. **Prerequisites check**: Validate requirements before proceeding
6. **Backups**: Create backups before modifying system files

### Error Handling

- `set -e`: Exit on any command failure
- `set -u`: Exit on undefined variable
- `set -o pipefail`: Fail if any command in pipeline fails

### Testing Scripts

```bash
# Always test in non-production first
# Dry-run where possible
# Check prerequisites
# Review script before running with sudo
```

### Getting Help

- Check script header comments for usage
- Read this README for detailed documentation
- See `CLAUDE.md` for operational procedures
- See `CONTRIBUTING.md` for contribution guidelines

---

## Quick Reference

| Script | Purpose | Run On | Sudo? |
|--------|---------|--------|-------|
| provision-k3s-server.sh | Install K3s server | Control-plane nodes | ✅ Yes |
| provision-k3s-agent.sh | Install K3s agent | Worker nodes | ✅ Yes |
| provision-k3s-ollama-agent.sh | Install K3s GPU agent | GPU worker nodes | ✅ Yes |
| provision-siberian.sh | Install Ollama workstation | siberian | ✅ Yes |
| provision-neko.sh | Provision neko | neko | ✅ Yes |
| provision-neko2.sh | Provision neko2 | neko2 | ✅ Yes |
| backup-homelab.sh | Backup cluster config | Any with kubectl | ❌ No |
| bootstrap-argocd.sh | Install ArgoCD | Any with kubectl | ❌ No |
| validate-kustomize.sh | Validate manifests | Any | ❌ No |
| check-no-plaintext-secrets.sh | Security validation | Any | ❌ No |
| sync-outline.sh | Sync docs to Outline | Any | ❌ No |
| sync-rag.sh | Sync to RAG knowledge base | Any | ❌ No |
| fix-etcd-ip.sh | Fix etcd IP | neko | ✅ Yes |
| fix-flannel-agents.sh | Fix worker networking | Worker nodes | ✅ Yes |
| fix-flannel-neko2.sh | Fix neko2 networking | neko2 | ✅ Yes |

---

## See Also

- `tests/README.md` - Test suite documentation
- `CLAUDE.md` - Operator guide and procedures
- `CONTRIBUTING.md` - Contribution guidelines
- `README.md` - Project overview
