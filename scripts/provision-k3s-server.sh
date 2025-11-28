#!/bin/bash
set -e

# K3s Server Provisioning Script
# Run as: sudo ./provision-k3s-server.sh <username> [--init|--join <server-ip>]
#
# First server:  sudo ./provision-k3s-server.sh jasen --init
# Second server: sudo ./provision-k3s-server.sh jasen --join <first-server-tailscale-ip>

USERNAME=${1:-jasen}
MODE=${2:---init}
JOIN_IP=${3:-}
SSH_PORT=22879

echo "=== K3s Server Provisioning for user: $USERNAME ==="

# ============================================
# 1. System Update
# ============================================
echo "=== Updating system ==="
apt update && apt upgrade -y

# ============================================
# 2. Base Packages
# ============================================
echo "=== Installing base packages ==="
apt install -y \
  btop \
  build-essential \
  curl \
  dkms \
  git \
  grep \
  gzip \
  lshw \
  openssh-server \
  pipx \
  python-is-python3 \
  python3-pip \
  wget \
  zsh

# ============================================
# 3. GitHub CLI
# ============================================
echo "=== Installing GitHub CLI ==="
if ! command -v gh &> /dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  apt update && apt install -y gh
fi

# ============================================
# 4. Tailscale
# ============================================
echo "=== Installing Tailscale ==="
if ! command -v tailscale &> /dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# ============================================
# 5. SSH Hardening
# ============================================
echo "=== Hardening SSH ==="
SSH_CONFIG="/etc/ssh/sshd_config"
cp "$SSH_CONFIG" "${SSH_CONFIG}.backup-$(date +%Y%m%d)"

sed -i "s/^#*Port.*/Port $SSH_PORT/" "$SSH_CONFIG"
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSH_CONFIG"
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' "$SSH_CONFIG"
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' "$SSH_CONFIG"
sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' "$SSH_CONFIG"
sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/' "$SSH_CONFIG"

systemctl restart ssh

# ============================================
# 6. UFW Firewall
# ============================================
echo "=== Configuring UFW ==="
apt install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow $SSH_PORT/tcp comment 'SSH'

# K3s ports
ufw allow 6443/tcp comment 'K3s API'
ufw allow 10250/tcp comment 'Kubelet'
ufw allow 8472/udp comment 'Flannel VXLAN'
ufw allow 51820/udp comment 'Flannel Wireguard'
ufw allow 51821/udp comment 'Flannel Wireguard IPv6'
ufw allow 2379:2380/tcp comment 'etcd'

# Allow all traffic from Tailscale
ufw allow in on tailscale0

ufw --force enable

# ============================================
# 7. Oh My Zsh + Dracula Theme
# ============================================
echo "=== Installing Oh My Zsh for $USERNAME ==="
USER_HOME=$(eval echo ~$USERNAME)

if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
  sudo -u $USERNAME sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

DRACULA_DIR="$USER_HOME/.oh-my-zsh/custom/themes/dracula"
if [ ! -d "$DRACULA_DIR" ]; then
  sudo -u $USERNAME git clone https://github.com/dracula/zsh.git "$DRACULA_DIR"
  sudo -u $USERNAME ln -sf "$DRACULA_DIR/dracula.zsh-theme" "$USER_HOME/.oh-my-zsh/custom/themes/dracula.zsh-theme"
fi

cat > "$USER_HOME/.zshrc" << 'ZSHRC'
# Path to Oh My Zsh installation
export ZSH="$HOME/.oh-my-zsh"

# Dracula theme with hostname display
ZSH_THEME="dracula"
DRACULA_DISPLAY_CONTEXT=1

# Plugins
plugins=(git kubectl)

source $ZSH/oh-my-zsh.sh

# pipx path
export PATH="$PATH:$HOME/.local/bin"

# Kubectl alias
alias k='kubectl'

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
ZSHRC

chown $USERNAME:$USERNAME "$USER_HOME/.zshrc"
chsh -s $(which zsh) $USERNAME

# ============================================
# 8. Realtek R8125 Driver (for NUC NICs)
# ============================================
echo "=== Installing Realtek R8125 driver ==="
if ! dpkg -l | grep -q realtek-r8125-dkms; then
  apt install -y realtek-r8125-dkms 2>/dev/null || {
    echo "R8125 dkms package not in repos - may need manual install"
  }
fi

# ============================================
# 9. K3s Installation
# ============================================
echo "=== Installing K3s ==="

# Get Tailscale IP for node communication
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

if [ -z "$TAILSCALE_IP" ]; then
  echo "ERROR: Tailscale not connected. Run 'sudo tailscale up' first, then re-run this script."
  exit 1
fi

K3S_ARGS="--node-ip=$TAILSCALE_IP --advertise-address=$TAILSCALE_IP --flannel-iface=tailscale0"

if [ "$MODE" == "--init" ]; then
  echo "=== Initializing first K3s server node ==="
  curl -sfL https://get.k3s.io | sh -s - server \
    --cluster-init \
    $K3S_ARGS
  
  # Wait for K3s to be ready
  sleep 10
  
  # Get join token
  echo ""
  echo "=== K3s Server Initialized ==="
  echo "Join token for additional servers:"
  cat /var/lib/rancher/k3s/server/node-token
  echo ""
  echo "Join command for next server:"
  echo "sudo ./provision-k3s-server.sh <username> --join $TAILSCALE_IP"
  
elif [ "$MODE" == "--join" ]; then
  if [ -z "$JOIN_IP" ]; then
    echo "ERROR: Must provide server IP to join"
    echo "Usage: sudo ./provision-k3s-server.sh <username> --join <server-tailscale-ip>"
    exit 1
  fi
  
  echo "=== Joining K3s cluster at $JOIN_IP ==="
  echo "Enter the join token from the first server:"
  read -r K3S_TOKEN
  
  curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
    --server https://$JOIN_IP:6443 \
    $K3S_ARGS
fi

# Setup kubectl for user
mkdir -p $USER_HOME/.kube
cp /etc/rancher/k3s/k3s.yaml $USER_HOME/.kube/config
sed -i "s/127.0.0.1/$TAILSCALE_IP/g" $USER_HOME/.kube/config
chown -R $USERNAME:$USERNAME $USER_HOME/.kube

echo ""
echo "=== Provisioning Complete ==="
echo ""
echo "SSH Port: $SSH_PORT"
echo "Shell: zsh with Dracula theme"
echo "Tailscale IP: $TAILSCALE_IP"
echo "K3s: installed and running"
echo ""
echo "Test with: kubectl get nodes"
echo ""
echo "NOTE: SSH is now on port $SSH_PORT"
echo "      Reconnect with: ssh -p $SSH_PORT $USERNAME@$TAILSCALE_IP"
