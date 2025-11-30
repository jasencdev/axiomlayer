#!/bin/bash
set -e

# K3s Agent + Ollama GPU Provisioning Script
# For Ubuntu 24.04 servers with NVIDIA GPU joining the K3s cluster
# Run as: sudo ./provision-k3s-ollama-agent.sh <username> <server-tailscale-ip>

USERNAME=${1:-jasen}
SERVER_IP=${2:-}
SSH_PORT=22879

if [ -z "$SERVER_IP" ]; then
  echo "ERROR: Must provide K3s server Tailscale IP"
  echo "Usage: sudo ./provision-k3s-ollama-agent.sh <username> <server-tailscale-ip>"
  exit 1
fi

echo "=== K3s Ollama Agent Provisioning for user: $USERNAME ==="
echo "Target: Ubuntu 24.04 with NVIDIA GPU"
echo ""

# ============================================
# 0. Remove Unnecessary Packages
# ============================================
echo "=== Removing unnecessary packages ==="
systemctl stop nginx postgresql certbot.timer 2>/dev/null || true
systemctl disable nginx postgresql certbot.timer 2>/dev/null || true

apt purge -y \
  avahi-daemon \
  byobu \
  certbot \
  cloud-init \
  cloud-guest-utils \
  cloud-initramfs-copymods \
  cloud-initramfs-dyn-netconf \
  ftp \
  lxd-installer \
  nginx \
  pemmican-server \
  postgresql \
  python3-certbot-nginx \
  screen \
  sosreport \
  speedtest-cli \
  ubuntu-pro-client \
  motd-news-config \
  overlayroot \
  pollinate \
  2>/dev/null || true

apt autoremove -y
apt autoclean -y

# Clean up leftover configs
rm -rf /etc/nginx /etc/postgresql /var/lib/postgresql 2>/dev/null || true

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
  curl \
  git \
  openssh-server \
  wget \
  zsh

# ============================================
# 3. NVIDIA Drivers
# ============================================
echo "=== Installing NVIDIA drivers ==="

# Remove any existing NVIDIA installations
apt remove --purge -y '^nvidia-.*' '^libnvidia-.*' 2>/dev/null || true
apt autoremove -y

# Install Ubuntu's recommended NVIDIA driver
apt install -y ubuntu-drivers-common
ubuntu-drivers install

# ============================================
# 4. CUDA Toolkit
# ============================================
echo "=== Installing CUDA toolkit ==="
apt install -y nvidia-cuda-toolkit

# ============================================
# 5. Tailscale
# ============================================
echo "=== Installing Tailscale ==="
if ! command -v tailscale &> /dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# ============================================
# 6. SSH Hardening
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

systemctl restart ssh

# ============================================
# 7. UFW Firewall
# ============================================
echo "=== Configuring UFW ==="
apt install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow $SSH_PORT/tcp comment 'SSH'
ufw allow 10250/tcp comment 'Kubelet'
ufw allow 8472/udp comment 'Flannel VXLAN'
ufw allow 51820/udp comment 'Flannel Wireguard'
ufw allow 11434/tcp comment 'Ollama API'

# Allow all traffic from Tailscale
ufw allow in on tailscale0

ufw --force enable

# ============================================
# 8. Oh My Zsh + Dracula Theme
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
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="dracula"
DRACULA_DISPLAY_CONTEXT=1
plugins=(git)
source $ZSH/oh-my-zsh.sh
export PATH="$PATH:$HOME/.local/bin"
alias ll='ls -alF'
ZSHRC

chown $USERNAME:$USERNAME "$USER_HOME/.zshrc"
chsh -s $(which zsh) $USERNAME

# ============================================
# 9. Ollama Installation
# ============================================
echo "=== Installing Ollama ==="
curl -fsSL https://ollama.com/install.sh | sh

# Configure Ollama for network access
mkdir -p /etc/systemd/system/ollama.service.d

cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_ORIGINS=*"
EOF

systemctl daemon-reload
systemctl enable ollama

# ============================================
# 10. K3s Agent Installation
# ============================================
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

if [ -z "$TAILSCALE_IP" ]; then
  echo ""
  echo "=== REBOOT REQUIRED ==="
  echo "NVIDIA drivers were installed. After reboot:"
  echo "  1. Connect Tailscale: sudo tailscale up"
  echo "  2. Re-run: sudo ./provision-k3s-ollama-agent.sh $USERNAME $SERVER_IP"
  exit 0
fi

echo "=== Installing K3s Agent ==="
echo "Enter the join token from the K3s server:"
read -r K3S_TOKEN

curl -sfL https://get.k3s.io | K3S_URL="https://$SERVER_IP:6443" K3S_TOKEN="$K3S_TOKEN" sh -s - agent \
  --node-ip=$TAILSCALE_IP \
  --flannel-iface=tailscale0

echo ""
echo "=== Provisioning Complete ==="
echo ""
echo "SSH Port: $SSH_PORT"
echo "Tailscale IP: $TAILSCALE_IP"
echo "K3s Agent: connected to $SERVER_IP"
echo "Ollama API: http://$TAILSCALE_IP:11434"
echo ""
echo "=== Verify Installation ==="
echo "  nvidia-smi                    # Check GPU"
echo "  ollama run llama3.2:3b        # Test Ollama"
echo "  kubectl get nodes             # Check on server"
echo ""
echo "=== Recommended Models ==="
echo "  ollama pull llama3.2:3b       # Fast, general (2GB)"
echo "  ollama pull llama3.1:8b       # Good balance (5GB)"
echo "  ollama pull codellama:13b     # Code assistance (8GB)"
echo "  ollama pull deepseek-r1:14b   # Reasoning (9GB)"
echo ""
