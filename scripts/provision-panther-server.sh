#!/bin/bash
set -e

# Panther Server Provisioning Script
# Combines k3s-server security hardening with panther-dotfiles terminal experience
#
# Run as: sudo ./provision-panther-server.sh <username> [--init|--join <server-ip>]
#
# First server:  sudo ./provision-panther-server.sh jasen --init
# Second server: sudo ./provision-panther-server.sh jasen --join <first-server-tailscale-ip>

USERNAME=${1:-jasen}
MODE=${2:---init}
JOIN_IP=${3:-}
SSH_PORT=22879
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Panther Server Provisioning for user: $USERNAME ==="

# ============================================
# 0. Cleanup Previous Botched Installs
# ============================================
echo "=== Cleaning up previous installations ==="
USER_HOME=$(eval echo ~$USERNAME)

# Kill any stuck tmux sessions
pkill -u $USERNAME tmux 2>/dev/null || true
sudo -u $USERNAME tmux kill-server 2>/dev/null || true

# Remove old oh-my-zsh
rm -rf "$USER_HOME/.oh-my-zsh"

# Remove old dotfiles that might conflict
rm -f "$USER_HOME/.zshrc"
rm -f "$USER_HOME/.zshrc.pre-oh-my-zsh"
rm -f "$USER_HOME/.zshrc.bak"
rm -f "$USER_HOME/.tmux.conf"
rm -f "$USER_HOME/.nanorc"
rm -f "$USER_HOME/.fzf.zsh"
rm -f "$USER_HOME/.fzf.bash"
rm -rf "$USER_HOME/.fzf"

# Remove old starship config
rm -f "$USER_HOME/.config/starship.toml"

# Remove old btop config
rm -rf "$USER_HOME/.config/btop"

# Remove any tmux auto-start from bash profiles that cause loops
sed -i '/tmux/d' "$USER_HOME/.bashrc" 2>/dev/null || true
sed -i '/tmux/d' "$USER_HOME/.bash_profile" 2>/dev/null || true
sed -i '/tmux/d' "$USER_HOME/.profile" 2>/dev/null || true

# Reset shell to bash temporarily (avoids zsh config issues during install)
chsh -s /bin/bash $USERNAME 2>/dev/null || true

# Clean up any broken apt state
apt --fix-broken install -y 2>/dev/null || true

echo "=== Cleanup complete ==="

# ============================================
# 1. System Update
# ============================================
echo "=== Updating system ==="
apt update && apt upgrade -y

# ============================================
# 2. Base Packages (merged from both scripts)
# ============================================
echo "=== Installing base packages ==="
apt install -y \
  btop \
  build-essential \
  ca-certificates \
  curl \
  dkms \
  dnsutils \
  fd-find \
  git \
  gnupg \
  grep \
  gzip \
  htop \
  jq \
  lsb-release \
  lshw \
  nano \
  ncdu \
  neofetch \
  net-tools \
  openssh-server \
  pipx \
  python-is-python3 \
  python3-pip \
  ripgrep \
  tmux \
  tree \
  unzip \
  wget \
  zsh

# ============================================
# 3. Modern CLI Tools
# ============================================
echo "=== Installing modern CLI tools ==="

# bat (cat replacement)
apt install -y bat || {
  wget -qO /tmp/bat.deb "https://github.com/sharkdp/bat/releases/download/v0.24.0/bat_0.24.0_amd64.deb"
  dpkg -i /tmp/bat.deb
}

# eza (ls replacement)
apt install -y eza || {
  mkdir -p /etc/apt/keyrings
  wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
  echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | tee /etc/apt/sources.list.d/gierens.list
  apt update && apt install -y eza
}

# ============================================
# 4. GitHub CLI
# ============================================
echo "=== Installing GitHub CLI ==="
if ! command -v gh &> /dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  apt update && apt install -y gh
fi

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
sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' "$SSH_CONFIG"
sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/' "$SSH_CONFIG"

systemctl restart ssh

# ============================================
# 7. UFW Firewall
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
# 8. Oh My Zsh + Plugins + Starship
# ============================================
echo "=== Setting up shell environment for $USERNAME ==="
USER_HOME=$(eval echo ~$USERNAME)

# Oh My Zsh
if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
  sudo -u $USERNAME sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# Zsh plugins
ZSH_CUSTOM="$USER_HOME/.oh-my-zsh/custom"
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
  sudo -u $USERNAME git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
  sudo -u $USERNAME git clone https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

# fzf
if [ ! -d "$USER_HOME/.fzf" ]; then
  sudo -u $USERNAME git clone --depth 1 https://github.com/junegunn/fzf.git "$USER_HOME/.fzf"
  sudo -u $USERNAME "$USER_HOME/.fzf/install" --all --no-bash --no-fish
fi

# Starship prompt
if ! command -v starship &> /dev/null; then
  curl -sS https://starship.rs/install.sh | sh -s -- -y
fi

# k9s
if ! command -v k9s &> /dev/null; then
  curl -sS https://webinstall.dev/k9s | sudo -u $USERNAME bash
fi

# lazydocker
if [ ! -f "$USER_HOME/.local/bin/lazydocker" ]; then
  curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | sudo -u $USERNAME bash
fi

# ============================================
# 9. Dotfiles
# ============================================
echo "=== Installing dotfiles ==="

# .zshrc
cat > "$USER_HOME/.zshrc" << 'ZSHRC'
# Panther ZSH Config
# ==================

# Oh My Zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""  # Using starship instead

plugins=(
  git
  docker
  kubectl
  zsh-autosuggestions
  zsh-syntax-highlighting
  fzf
  history
  sudo  # ESC ESC to add sudo
)

source $ZSH/oh-my-zsh.sh

# Starship prompt
eval "$(starship init zsh)"

# pipx path
export PATH="$PATH:$HOME/.local/bin"

# History
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# Modern CLI aliases
alias cat='batcat --paging=never'
alias catp='batcat'
alias ls='eza --icons'
alias ll='eza -la --icons --git'
alias lt='eza -la --icons --tree --level=2'
alias tree='eza --tree --icons'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Kubernetes
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kga='kubectl get all'
alias kgaa='kubectl get all -A'
alias kd='kubectl describe'
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias kx='kubectl exec -it'
alias kns='kubectl config set-context --current --namespace'
alias k9='k9s'

# Docker
alias d='docker'
alias dc='docker compose'
alias dps='docker ps'
alias dpsa='docker ps -a'
alias di='docker images'
alias ld='lazydocker'

# Git
alias g='git'
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git pull'
alias gd='git diff'
alias gco='git checkout'
alias gb='git branch'
alias glog='git log --oneline --graph --decorate -10'

# System
alias ports='sudo lsof -i -P -n | grep LISTEN'
alias myip='curl -s ifconfig.me'
alias dus='du -sh * | sort -h'
alias free='free -h'
alias df='df -h'
alias top='btop'
alias htop='btop'

# Tailscale
alias ts='tailscale'
alias tss='tailscale status'

# Cluster nodes
alias ssh-leopard='ssh -p 22879 leopard'
alias ssh-bobcat='ssh -p 22879 bobcat'
alias ssh-lynx='ssh -p 22879 lynx'
alias ssh-siberian='ssh siberian'
alias ssh-panther='ssh -p 22879 panther'

# Quick edits
alias zshrc='nano ~/.zshrc && source ~/.zshrc'
alias tmuxrc='nano ~/.tmux.conf'

# fzf configuration
export FZF_DEFAULT_OPTS='
  --height 40%
  --layout=reverse
  --border
  --color=fg:#c0caf5,bg:#1a1b26,hl:#bb9af7
  --color=fg+:#c0caf5,bg+:#292e42,hl+:#7dcfff
  --color=info:#7aa2f7,prompt:#7dcfff,pointer:#7dcfff
  --color=marker:#9ece6a,spinner:#9ece6a,header:#9ece6a
'

# Use fd for fzf if available
if command -v fdfind &> /dev/null; then
  export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
fi

# Quick cluster overview
cluster() {
  echo "=== Axiom Layer Cluster Status ==="
  kubectl get nodes -o wide
  echo ""
  echo "Pods by namespace:"
  kubectl get pods -A --no-headers | awk '{print $1}' | sort | uniq -c | sort -rn
}

# Quick Ollama status
ollama-status() {
  echo "=== Ollama Status ==="
  echo "siberian (5070 Ti):"
  curl -s http://siberian:11434/api/tags 2>/dev/null | jq -r '.models[].name' || echo "  offline"
}

# Neofetch on new shell (comment out if annoying)
if [[ $- == *i* ]] && [[ -z "$TMUX" ]]; then
  neofetch --ascii_distro ubuntu_small
fi
ZSHRC

# .tmux.conf
cat > "$USER_HOME/.tmux.conf" << 'TMUXCONF'
# Panther tmux config
# ====================

# Better prefix (Ctrl+a instead of Ctrl+b)
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# Start windows and panes at 1, not 0
set -g base-index 1
setw -g pane-base-index 1

# Renumber windows when one is closed
set -g renumber-windows on

# More history
set -g history-limit 50000

# Mouse support
set -g mouse on

# Faster escape time
set -sg escape-time 0

# True color support
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"

# Reload config
bind r source-file ~/.tmux.conf \; display "Config reloaded!"

# Split panes with | and -
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# New window in current path
bind c new-window -c "#{pane_current_path}"

# Navigate panes with vim keys
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Resize panes with vim keys
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# Quick pane cycling
bind -n M-h select-pane -L
bind -n M-j select-pane -D
bind -n M-k select-pane -U
bind -n M-l select-pane -R

# Alt+number to switch windows
bind -n M-1 select-window -t 1
bind -n M-2 select-window -t 2
bind -n M-3 select-window -t 3
bind -n M-4 select-window -t 4
bind -n M-5 select-window -t 5

# Status bar
set -g status-position top
set -g status-interval 5

# Status bar colors (Tokyo Night inspired)
set -g status-style "bg=#1a1b26,fg=#c0caf5"

# Left status
set -g status-left-length 50
set -g status-left "#[fg=#7aa2f7,bold]  #S #[fg=#565f89]| "

# Right status
set -g status-right-length 100
set -g status-right "#[fg=#565f89]| #[fg=#9ece6a] #(free -h | awk '/^Mem/ {print $3}')/#(free -h | awk '/^Mem/ {print $2}') #[fg=#565f89]| #[fg=#bb9af7] #(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',') #[fg=#565f89]| #[fg=#7dcfff] %H:%M "

# Window status
set -g window-status-format "#[fg=#565f89] #I:#W "
set -g window-status-current-format "#[fg=#7aa2f7,bold] #I:#W "

# Pane borders
set -g pane-border-style "fg=#565f89"
set -g pane-active-border-style "fg=#7aa2f7"

# Message style
set -g message-style "bg=#1a1b26,fg=#7aa2f7"

# Quick layouts
# Cockpit: k9s left, btop top-right, shell bottom-right
bind D new-window -n "cockpit" \; \
  send-keys "k9s" Enter \; \
  split-window -h -p 40 \; \
  send-keys "btop" Enter \; \
  split-window -v -p 30 \; \
  select-pane -L

# Monitoring: btop full
bind M new-window -n "monitor" "btop"

# Logs: follow system logs
bind G new-window -n "logs" "journalctl -f"
TMUXCONF

# .nanorc
cat > "$USER_HOME/.nanorc" << 'NANORC'
# Panther nanorc
set linenumbers
set constantshow
set smooth
set autoindent
set tabsize 2
set tabstospaces
set softwrap
set smarthome
set mouse
set matchbrackets "(<[{)>]}"
set suspend
set multibuffer
set historylog
set positionlog

include "/usr/share/nano/*.nanorc"
include "/usr/share/nano/extra/*.nanorc"

set titlecolor bold,white,blue
set promptcolor white,black
set statuscolor bold,white,blue
set errorcolor bold,white,red
set spotlightcolor black,yellow
set selectedcolor white,magenta
set stripecolor ,black
set scrollercolor white
set numbercolor cyan
set keycolor cyan
set functioncolor green

bind ^S savefile main
bind ^Q exit main
bind ^F whereis main
bind ^R replace main
bind ^G gotoline main
bind ^Z undo main
bind ^Y redo main
bind ^C copy main
bind ^V paste main
bind ^X cut main
NANORC

# starship.toml
mkdir -p "$USER_HOME/.config"
cat > "$USER_HOME/.config/starship.toml" << 'STARSHIP'
format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$kubernetes\
$docker_context\
$cmd_duration\
$line_break\
$character"""

[character]
success_symbol = "[>](bold green)"
error_symbol = "[>](bold red)"

[username]
style_user = "bold cyan"
style_root = "bold red"
format = "[$user]($style)"
show_always = false

[hostname]
ssh_only = true
format = "[@$hostname](bold blue) "
trim_at = "."

[directory]
style = "bold blue"
format = "[$path]($style)[$read_only]($read_only_style) "
truncation_length = 3
truncate_to_repo = true

[git_branch]
symbol = ""
style = "bold purple"
format = "[$symbol$branch]($style) "

[git_status]
format = '([\[$all_status$ahead_behind\]]($style) )'
style = "bold yellow"

[kubernetes]
format = '[$symbol$context( \($namespace\))]($style) '
style = "bold cyan"
symbol = "k8s "
disabled = false

[kubernetes.context_aliases]
"default" = "axiom"

[cmd_duration]
min_time = 2_000
format = "[$duration](bold yellow) "
STARSHIP

# btop.conf
mkdir -p "$USER_HOME/.config/btop"
cat > "$USER_HOME/.config/btop/btop.conf" << 'BTOPCONF'
color_theme = "tokyo-night"
vim_keys = True
rounded_corners = True
graph_symbol = "braille"
shown_boxes = "cpu mem net proc"
update_ms = 1000
proc_sorting = "cpu lazy"
proc_colors = True
proc_gradient = True
show_disks = True
show_io_stat = True
net_auto = True
show_battery = True
BTOPCONF

# Fix ownership
chown -R $USERNAME:$USERNAME "$USER_HOME/.zshrc" "$USER_HOME/.tmux.conf" "$USER_HOME/.nanorc" "$USER_HOME/.config"

# Set zsh as default
chsh -s $(which zsh) $USERNAME

# ============================================
# 10. Realtek R8125 Driver (for NUC NICs)
# ============================================
echo "=== Installing Realtek R8125 driver ==="
if ! dpkg -l | grep -q realtek-r8125-dkms; then
  apt install -y realtek-r8125-dkms 2>/dev/null || {
    echo "R8125 dkms package not in repos - may need manual install"
  }
fi

# ============================================
# 11. Console Setup (for HiDPI/laptops)
# ============================================
echo "=== Configuring console ==="
cat > /etc/default/console-setup << 'EOF'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="Terminus"
FONTSIZE="16x32"
EOF
update-initramfs -u 2>/dev/null || true

# Lid close behavior (ignore for servers)
sed -i 's/#HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf

# ============================================
# 12. K3s Installation
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
  echo "sudo ./provision-panther-server.sh <username> --join $TAILSCALE_IP"

elif [ "$MODE" == "--join" ]; then
  if [ -z "$JOIN_IP" ]; then
    echo "ERROR: Must provide server IP to join"
    echo "Usage: sudo ./provision-panther-server.sh <username> --join <server-tailscale-ip>"
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
echo "=========================================="
echo "  Panther Server Provisioning Complete"
echo "=========================================="
echo ""
echo "SSH Port:     $SSH_PORT"
echo "Shell:        zsh + starship + oh-my-zsh"
echo "Tailscale IP: $TAILSCALE_IP"
echo "K3s:          installed and running"
echo ""
echo "Features:"
echo "  - SSH hardened (key-only, non-standard port)"
echo "  - UFW firewall enabled"
echo "  - Modern CLI: eza, bat, fzf, ripgrep"
echo "  - k9s, lazydocker, btop"
echo "  - Tokyo Night theme everywhere"
echo ""
echo "Test with: kubectl get nodes"
echo ""
echo "NOTE: SSH is now on port $SSH_PORT"
echo "      Reconnect with: ssh -p $SSH_PORT $USERNAME@$TAILSCALE_IP"
echo ""
