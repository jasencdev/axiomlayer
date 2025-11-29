#!/bin/bash
# Run this on neko2 (secondary control plane node)
# Fixes flannel to use Tailscale interface
set -e

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

if [ -z "$TAILSCALE_IP" ]; then
    echo "ERROR: Tailscale not connected"
    exit 1
fi

echo "Tailscale IP: $TAILSCALE_IP"
echo "Adding --node-ip, --advertise-address, and --flannel-iface to k3s server..."

# Backup original
sudo cp /etc/systemd/system/k3s.service /etc/systemd/system/k3s.service.bak

# Check if already configured
if grep -q "flannel-iface=tailscale0" /etc/systemd/system/k3s.service && grep -q "node-ip=$TAILSCALE_IP" /etc/systemd/system/k3s.service; then
    echo "Already configured correctly"
else
    # Remove any existing args first
    sudo sed -i 's| --node-ip=[^ ]*||g' /etc/systemd/system/k3s.service
    sudo sed -i 's| --advertise-address=[^ ]*||g' /etc/systemd/system/k3s.service
    sudo sed -i 's| --flannel-iface=[^ ]*||g' /etc/systemd/system/k3s.service

    # Add the correct args after 'server'
    sudo sed -i "s|server|server --node-ip=$TAILSCALE_IP --advertise-address=$TAILSCALE_IP --flannel-iface=tailscale0|" /etc/systemd/system/k3s.service
    echo "Added --node-ip=$TAILSCALE_IP --advertise-address=$TAILSCALE_IP --flannel-iface=tailscale0"
fi

echo "Reloading and restarting k3s..."
sudo systemctl daemon-reload
sudo systemctl restart k3s

echo "Waiting for k3s to start..."
sleep 10

echo "Done. Checking status..."
sudo systemctl status k3s --no-pager | head -10
