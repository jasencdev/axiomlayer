#!/bin/bash
set -e

# Bootstrap ArgoCD and GitOps
# Run after K3s is installed and kubectl is configured
#
# This script:
# 1. Installs Sealed Secrets controller (needed for secrets)
# 2. Installs ArgoCD via Helm
# 3. Applies the root application to bootstrap GitOps
#
# Usage: ./bootstrap-argocd.sh

REPO_URL="https://github.com/jasencdev/axiomlayer.git"
ARGOCD_VERSION="8.0.14"
SEALED_SECRETS_VERSION="0.24.5"

echo "=== ArgoCD Bootstrap Script ==="
echo ""

# Check kubectl access
if ! kubectl get nodes &>/dev/null; then
  echo "ERROR: kubectl not configured or cluster not accessible"
  exit 1
fi

echo "Cluster nodes:"
kubectl get nodes
echo ""

# ============================================
# 1. Install Helm (if not present)
# ============================================
if ! command -v helm &>/dev/null; then
  echo "=== Installing Helm ==="
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ============================================
# 2. Install Sealed Secrets Controller
# ============================================
echo "=== Installing Sealed Secrets Controller ==="

# Apply CRD first
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v${SEALED_SECRETS_VERSION}/controller.yaml

# Wait for controller
echo "Waiting for Sealed Secrets controller..."
kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=120s

# ============================================
# 3. Install ArgoCD via Helm
# ============================================
echo "=== Installing ArgoCD ==="

# Add Argo Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD with minimal config (full config comes from GitOps)
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version ${ARGOCD_VERSION} \
  --set global.domain=argocd.lab.axiomlayer.com \
  --set configs.params.server\\.insecure=true \
  --set server.ingress.enabled=false \
  --wait

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

# ============================================
# 4. Get ArgoCD admin password
# ============================================
echo ""
echo "=== ArgoCD Installed ==="
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Admin username: admin"
echo "Admin password: $ARGOCD_PASSWORD"
echo ""

# ============================================
# 5. Apply root application (bootstrap GitOps)
# ============================================
echo "=== Applying Root Application ==="

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: applications
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: main
    path: apps/argocd/applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  # Manual sync for root app - sync this to deploy everything
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
EOF

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Next steps:"
echo "1. Port-forward to ArgoCD: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "2. Login to ArgoCD UI at https://localhost:8080"
echo "3. Sync the 'applications' app to deploy all child apps"
echo "4. Or use CLI: argocd app sync applications"
echo ""
echo "Note: The sealed secrets in the repo need to be re-sealed with the new controller's key."
echo "      Run: kubeseal --fetch-cert > sealed-secrets-pub.pem"
echo "      Then re-seal all secrets in .env"
echo ""
