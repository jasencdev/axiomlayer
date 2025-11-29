#!/bin/bash
set -e

TAILSCALE_IP="100.67.134.110"
ETCD_CERTS="--cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key"

echo "=== Fixing neko etcd member IP ==="

# Start k3s if not running
echo "Starting k3s..."
sudo systemctl start k3s
sleep 5

# Try to get member list with timeout - may fail due to quorum issues
echo "Getting etcd member ID (with 3s timeout)..."
for i in {1..5}; do
    MEMBER_INFO=$(timeout 3 sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_CERTS member list 2>/dev/null || true)
    if [ -n "$MEMBER_INFO" ]; then
        break
    fi
    echo "Attempt $i failed, retrying..."
    sleep 2
done

if [ -z "$MEMBER_INFO" ]; then
    echo "Could not get member list via API. Checking etcd logs for member name..."
    # Extract member name from k3s logs
    MEMBER_NAME=$(journalctl -u k3s --no-pager -n 50 | grep -oP 'Found \[\K[^=]+' | head -1)
    echo "Found member name: $MEMBER_NAME"

    if [ -z "$MEMBER_NAME" ]; then
        echo "ERROR: Could not determine member info"
        exit 1
    fi

    # For single-node with wrong IP, we need to update via etcdctl
    # Keep trying until we get a response
    echo "Retrying etcdctl with longer timeout..."
    MEMBER_INFO=$(timeout 10 sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_CERTS member list 2>/dev/null || true)
fi

echo "Current members: $MEMBER_INFO"

MEMBER_ID=$(echo "$MEMBER_INFO" | grep -oE '^[a-f0-9]+' | head -1)
echo "Member ID: $MEMBER_ID"

if [ -z "$MEMBER_ID" ]; then
    echo "ERROR: Could not get member ID. Etcd may not be responding."
    echo ""
    echo "Manual fix: Run these commands one by one:"
    echo "  sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_CERTS member list"
    echo "  sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_CERTS member update <ID> --peer-urls=https://$TAILSCALE_IP:2380"
    echo "  sudo systemctl restart k3s"
    exit 1
fi

# Update member peer URL
echo "Updating member peer URL to https://$TAILSCALE_IP:2380..."
timeout 10 sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_CERTS \
    member update $MEMBER_ID --peer-urls=https://$TAILSCALE_IP:2380

# Restart k3s
echo "Restarting k3s..."
sudo systemctl restart k3s

# Wait and verify
sleep 10
echo "Checking k3s status..."
sudo systemctl status k3s --no-pager | head -20

echo "Checking etcd member list..."
timeout 5 sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_CERTS member list || echo "Could not verify - check manually"

echo "Checking nodes..."
kubectl get nodes -o wide || echo "kubectl not ready yet"

echo "=== Done ==="
