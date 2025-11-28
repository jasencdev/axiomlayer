#!/bin/bash
# Provision Ubuntu 24.04 workstation with NVIDIA 5070Ti + Ollama
# Run this script on the workstation after fresh Ubuntu 24.04 install

set -euo pipefail

echo "=== AxiomLayer Ollama Workstation Provisioning ==="
echo "Target: Ubuntu 24.04 with NVIDIA RTX 5070 Ti"
echo ""

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Do not run this script as root. Run as your normal user."
    exit 1
fi

# ============================================
# STEP 1: System Update
# ============================================
echo "[1/7] Updating system packages..."
sudo apt update && sudo apt upgrade -y

# ============================================
# STEP 2: Install NVIDIA Drivers
# ============================================
echo "[2/7] Installing NVIDIA drivers..."

# Remove any existing NVIDIA installations
sudo apt remove --purge -y '^nvidia-.*' '^libnvidia-.*' 2>/dev/null || true
sudo apt autoremove -y

# Install Ubuntu's recommended NVIDIA driver (565+ for Blackwell/5070Ti)
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers install

# Alternative: Install specific driver version if needed
# sudo apt install -y nvidia-driver-565

echo "NVIDIA driver installation complete."
echo "NOTE: A reboot is required before continuing."

# ============================================
# STEP 3: Install CUDA Toolkit
# ============================================
echo "[3/7] Installing CUDA toolkit..."

# Install CUDA toolkit from Ubuntu repos (simpler, works well)
sudo apt install -y nvidia-cuda-toolkit

# ============================================
# STEP 4: Install Tailscale
# ============================================
echo "[4/7] Installing Tailscale..."

if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale installed. Run 'sudo tailscale up' after reboot to connect."
else
    echo "Tailscale already installed."
fi

# ============================================
# STEP 5: Install Ollama
# ============================================
echo "[5/7] Installing Ollama..."

if ! command -v ollama &> /dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "Ollama already installed, updating..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

# ============================================
# STEP 6: Configure Ollama for Network Access
# ============================================
echo "[6/7] Configuring Ollama for network access..."

# Create systemd override to allow external connections
sudo mkdir -p /etc/systemd/system/ollama.service.d

sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_ORIGINS=*"
EOF

sudo systemctl daemon-reload

# ============================================
# STEP 7: Setup Complete
# ============================================
echo "[7/7] Installation complete!"
echo ""
echo "=== NEXT STEPS ==="
echo ""
echo "1. REBOOT the system to load NVIDIA drivers:"
echo "   sudo reboot"
echo ""
echo "2. After reboot, verify NVIDIA driver:"
echo "   nvidia-smi"
echo ""
echo "3. Connect to Tailscale:"
echo "   sudo tailscale up"
echo ""
echo "4. Start Ollama service:"
echo "   sudo systemctl enable ollama"
echo "   sudo systemctl start ollama"
echo ""
echo "5. Verify Ollama sees your GPU:"
echo "   ollama run llama3.2:3b"
echo "   (type /bye to exit)"
echo ""
echo "6. Get your Tailscale IP:"
echo "   tailscale ip -4"
echo ""
echo "7. Update Open WebUI config with your Tailscale IP in:"
echo "   infrastructure/open-webui/configmap.yaml"
echo "   Change OLLAMA_BASE_URL to: http://<YOUR_TAILSCALE_IP>:11434"
echo ""
echo "=== Recommended Models for 5070 Ti (16GB VRAM) ==="
echo "ollama pull llama3.2:3b      # Fast, general purpose (2GB)"
echo "ollama pull llama3.1:8b      # Good balance (5GB)"
echo "ollama pull codellama:13b    # Code assistance (8GB)"
echo "ollama pull llama3.1:70b-q4  # Large, slower (40GB+ needs CPU offload)"
echo "ollama pull deepseek-r1:14b  # Reasoning model (9GB)"
echo "ollama pull qwen2.5:14b      # Strong multilingual (9GB)"
echo ""
