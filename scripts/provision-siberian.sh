#!/bin/bash
set -e

# Siberian Provisioning Script (GPU Workstation)
# Ubuntu 24.04 with NVIDIA RTX 5070 Ti + Ollama
# Run as: sudo ./provision-siberian.sh <username>

USERNAME=${1:-jasen}
SSH_PORT=22879

echo "=== Provisioning Siberian (GPU Workstation) for user: $USERNAME ==="

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

sudo systemctl daemon-reload
sudo systemctl restart ssh

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

# Ollama API (only from Tailscale)
ufw allow in on tailscale0 to any port 11434 proto tcp comment 'Ollama API'

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
plugins=(git)

source $ZSH/oh-my-zsh.sh

# pipx path
export PATH="$PATH:$HOME/.local/bin"

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Ollama aliases
alias ollama-logs='journalctl -u ollama -f'
alias ollama-status='systemctl status ollama'
ZSHRC

chown $USERNAME:$USERNAME "$USER_HOME/.zshrc"
chsh -s $(which zsh) $USERNAME

# ============================================
# 8. NVIDIA Drivers (5070 Ti / Blackwell)
# ============================================
echo "=== Installing NVIDIA drivers ==="

# Remove any existing NVIDIA installations
apt remove --purge -y '^nvidia-.*' '^libnvidia-.*' 2>/dev/null || true
apt autoremove -y

# Install Ubuntu's recommended NVIDIA driver (565+ for Blackwell/5070Ti)
apt install -y ubuntu-drivers-common
ubuntu-drivers install

# Install CUDA toolkit
apt install -y nvidia-cuda-toolkit

# ============================================
# 9. Ollama Installation
# ============================================
echo "=== Installing Ollama ==="

if ! command -v ollama &> /dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "Ollama already installed, updating..."
  curl -fsSL https://ollama.com/install.sh | sh
fi

# Configure Ollama for network access and performance
mkdir -p /etc/systemd/system/ollama.service.d

cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
# Listen on all interfaces (UFW restricts to Tailscale only)
Environment="OLLAMA_HOST=0.0.0.0:11434"
# Allow connections from any origin (Open WebUI)
Environment="OLLAMA_ORIGINS=*"
# Set default context window to 32k tokens
Environment="OLLAMA_CONTEXT_LENGTH=32768"
# Keep models loaded longer (5 minutes)
Environment="OLLAMA_KEEP_ALIVE=5m"
# Flash attention for better memory efficiency
Environment="OLLAMA_FLASH_ATTENTION=1"
EOF

systemctl daemon-reload

# Don't start Ollama yet - needs reboot for NVIDIA drivers
systemctl enable ollama

echo ""
echo "=== Provisioning Complete ==="
echo ""
echo "SSH Port: $SSH_PORT"
echo "Shell: zsh with Dracula theme"
echo "NVIDIA: drivers installed (reboot required)"
echo "Ollama: installed and configured"
echo ""
echo "=== NEXT STEPS ==="
echo ""
echo "1. REBOOT to load NVIDIA drivers:"
echo "   sudo reboot"
echo ""
echo "2. After reboot, verify NVIDIA driver:"
echo "   nvidia-smi"
echo ""
echo "3. Connect to Tailscale:"
echo "   sudo tailscale up"
echo ""
echo "4. Start Ollama service:"
echo "   sudo systemctl start ollama"
echo ""
echo "5. Verify Ollama sees your GPU:"
echo "   ollama run llama3.2:3b"
echo "   (type /bye to exit)"
echo ""
echo "6. Get your Tailscale IP:"
echo "   tailscale ip -4"
echo ""
echo "7. Update Open WebUI config in the homelab-gitops repo:"
echo "   infrastructure/open-webui/configmap.yaml"
echo "   Change OLLAMA_BASE_URL to: http://<YOUR_TAILSCALE_IP>:11434"
echo ""
echo "=== Recommended Models for 5070 Ti (16GB VRAM) ==="
echo "ollama pull llama3.2:3b      # Fast, general purpose (2GB)"
echo "ollama pull llama3.1:8b      # Good balance (5GB)"
echo "ollama pull codellama:13b    # Code assistance (8GB)"
echo "ollama pull deepseek-r1:14b  # Reasoning model (9GB)"
echo "ollama pull qwen2.5:14b      # Strong multilingual (9GB)"
echo ""
echo "NOTE: SSH is now on port $SSH_PORT"
echo "      Reconnect with: ssh -p $SSH_PORT $USERNAME@<ip>"
echo ""
