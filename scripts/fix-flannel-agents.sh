#!/bin/bash
# Run this on bobcat and panther (worker nodes)
set -e

echo "Adding --flannel-iface=tailscale0 to k3s-agent..."

# Backup original
sudo cp /etc/systemd/system/k3s-agent.service /etc/systemd/system/k3s-agent.service.bak

# Add flannel-iface if not present
if ! grep -q "flannel-iface" /etc/systemd/system/k3s-agent.service; then
    sudo sed -i 's|ExecStart=/usr/local/bin/k3s agent|ExecStart=/usr/local/bin/k3s agent --flannel-iface=tailscale0|' /etc/systemd/system/k3s-agent.service
    echo "Added --flannel-iface=tailscale0"
else
    echo "flannel-iface already configured"
fi

echo "Reloading and restarting k3s-agent..."
sudo systemctl daemon-reload
sudo systemctl restart k3s-agent

echo "Done. Checking status..."
sudo systemctl status k3s-agent --no-pager | head -10
