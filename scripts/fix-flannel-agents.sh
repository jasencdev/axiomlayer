#!/bin/bash
# Run this on bobcat and panther (worker nodes)
# Fixes flannel to use Tailscale interface
set -e

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

if [ -z "$TAILSCALE_IP" ]; then
    echo "ERROR: Tailscale not connected"
    exit 1
fi

echo "Tailscale IP: $TAILSCALE_IP"
echo "Adding --node-ip and --flannel-iface to k3s-agent..."

# Backup original
sudo cp /etc/systemd/system/k3s-agent.service /etc/systemd/system/k3s-agent.service.bak

# Check if already configured
if grep -q "flannel-iface=tailscale0" /etc/systemd/system/k3s-agent.service && grep -q "node-ip=$TAILSCALE_IP" /etc/systemd/system/k3s-agent.service; then
    echo "Already configured correctly"
else
    # Remove any existing node-ip or flannel-iface args first
    sudo sed -i 's| --node-ip=[^ ]*||g' /etc/systemd/system/k3s-agent.service
    sudo sed -i 's| --flannel-iface=[^ ]*||g' /etc/systemd/system/k3s-agent.service

    # Add the correct args
    sudo sed -i "s|ExecStart=/usr/local/bin/k3s agent|ExecStart=/usr/local/bin/k3s agent --node-ip=$TAILSCALE_IP --flannel-iface=tailscale0|" /etc/systemd/system/k3s-agent.service
    echo "Added --node-ip=$TAILSCALE_IP --flannel-iface=tailscale0"
fi

echo "Reloading and restarting k3s-agent..."
sudo systemctl daemon-reload
sudo systemctl restart k3s-agent

echo "Done. Checking status..."
sudo systemctl status k3s-agent --no-pager | head -10
