#!/bin/bash
# Run this on neko2 (control plane node)
set -e

echo "Adding --flannel-iface=tailscale0 to k3s server..."

# Backup original
sudo cp /etc/systemd/system/k3s.service /etc/systemd/system/k3s.service.bak

# Check if flannel-iface is already there
if ! grep -q "flannel-iface" /etc/systemd/system/k3s.service; then
    # Add flannel-iface after the server line
    sudo sed -i "/ExecStart=.*k3s/s|server|server --flannel-iface=tailscale0|" /etc/systemd/system/k3s.service
    echo "Added --flannel-iface=tailscale0"
else
    echo "flannel-iface already configured"
fi

echo "Reloading and restarting k3s..."
sudo systemctl daemon-reload
sudo systemctl restart k3s

echo "Waiting for k3s to start..."
sleep 10

echo "Done. Checking status..."
sudo systemctl status k3s --no-pager | head -10
