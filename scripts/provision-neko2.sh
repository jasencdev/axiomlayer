#!/bin/bash
set -e

# Neko Provisioning Script
# Run as: sudo ./provision-neko.sh <username>

USERNAME=${1:-jasen}
SSH_PORT=22879

echo "=== Provisioning Neko for user: $USERNAME ==="

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

# Change SSH port
sed -i "s/^#*Port.*/Port $SSH_PORT/" "$SSH_CONFIG"

# Security settings
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
ufw allow $SSH_PORT/tcp comment 'SSH'
ufw --force enable

# ============================================
# 7. Oh My Zsh + Dracula Theme
# ============================================
echo "=== Installing Oh My Zsh for $USERNAME ==="
USER_HOME=$(eval echo ~$USERNAME)

# Install Oh My Zsh
if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
  sudo -u $USERNAME sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# Install Dracula theme
DRACULA_DIR="$USER_HOME/.oh-my-zsh/custom/themes/dracula"
if [ ! -d "$DRACULA_DIR" ]; then
  sudo -u $USERNAME git clone https://github.com/dracula/zsh.git "$DRACULA_DIR"
  sudo -u $USERNAME ln -sf "$DRACULA_DIR/dracula.zsh-theme" "$USER_HOME/.oh-my-zsh/custom/themes/dracula.zsh-theme"
fi

# Configure .zshrc
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
ZSHRC

chown $USERNAME:$USERNAME "$USER_HOME/.zshrc"

# Change default shell to zsh
chsh -s $(which zsh) $USERNAME

# ============================================
# 8. Realtek R8125 Driver (for NUC NICs)
# ============================================
echo "=== Installing Realtek R8125 driver ==="
if ! dpkg -l | grep -q realtek-r8125-dkms; then
  # Check if we need to build from source or if it's available
  apt install -y realtek-r8125-dkms 2>/dev/null || {
    echo "R8125 dkms package not in repos - may need manual install"
    echo "See: https://github.com/awesometic/realtek-r8125-dkms"
  }
fi

echo ""
echo "=== Provisioning Complete ==="
echo ""
echo "SSH Port: $SSH_PORT"
echo "Shell: zsh with Dracula theme"
echo "Tailscale: installed (run 'sudo tailscale up' to connect)"
echo ""
echo "=== Next Steps ==="
echo "1. Connect Tailscale:"
echo "   sudo tailscale up"
echo ""
echo "NOTE: SSH is now on port $SSH_PORT"
echo "      Reconnect with: ssh -p $SSH_PORT $USERNAME@<ip>"
