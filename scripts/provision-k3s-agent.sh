#!/bin/bash
set -e

# K3s Agent Provisioning Script (Raspberry Pi)
# Run as: sudo ./provision-k3s-agent.sh <username> <server-tailscale-ip>

USERNAME=${1:-jasen}
SERVER_IP=${2:-}
SSH_PORT=22879

if [ -z "$SERVER_IP" ]; then
  echo "ERROR: Must provide K3s server Tailscale IP"
  echo "Usage: sudo ./provision-k3s-agent.sh <username> <server-tailscale-ip>"
  exit 1
fi

echo "=== K3s Agent Provisioning for user: $USERNAME ==="

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
# 3. Tailscale
# ============================================
echo "=== Installing Tailscale ==="
if ! command -v tailscale &> /dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# ============================================
# 4. SSH Hardening
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
# 5. UFW Firewall
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

# Allow all traffic from Tailscale
ufw allow in on tailscale0

ufw --force enable

# ============================================
# 6. Oh My Zsh + Dracula Theme
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
# 7. Raspberry Pi Specific (cgroups)
# ============================================
echo "=== Enabling cgroups for K3s ==="
if ! grep -q "cgroup_memory=1" /boot/firmware/cmdline.txt 2>/dev/null; then
  if [ -f /boot/firmware/cmdline.txt ]; then
    sed -i 's/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
    echo "Cgroups enabled - REBOOT REQUIRED before K3s install"
    NEEDS_REBOOT=1
  fi
fi

# ============================================
# 8. K3s Agent Installation
# ============================================
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

if [ -z "$TAILSCALE_IP" ]; then
  echo "ERROR: Tailscale not connected. Run 'sudo tailscale up' first."
  exit 1
fi

if [ "${NEEDS_REBOOT:-0}" == "1" ]; then
  echo ""
  echo "=== REBOOT REQUIRED ==="
  echo "Cgroups were enabled. After reboot, run:"
  echo "  sudo ./provision-k3s-agent.sh $USERNAME $SERVER_IP --post-reboot"
  exit 0
fi

if [ "$3" == "--post-reboot" ] || [ "${NEEDS_REBOOT:-0}" != "1" ]; then
  echo "=== Installing K3s Agent ==="
  echo "Enter the join token from the K3s server:"
  read -r K3S_TOKEN

  curl -sfL https://get.k3s.io | K3S_URL="https://$SERVER_IP:6443" K3S_TOKEN="$K3S_TOKEN" sh -s - agent \
    --node-ip=$TAILSCALE_IP \
    --flannel-iface=tailscale0
fi

echo ""
echo "=== Provisioning Complete ==="
echo ""
echo "SSH Port: $SSH_PORT"
echo "Tailscale IP: $TAILSCALE_IP"
echo "K3s Agent: connected to $SERVER_IP"
echo ""
echo "Verify on server with: kubectl get nodes"
