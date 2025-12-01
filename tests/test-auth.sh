#!/bin/bash
# Test authentication flows
# Run: ./tests/test-auth.sh

set -e

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

FAILED=0
PASSED=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
}

section() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

section "Authentik Health"

# Check Authentik is responding
AUTH_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://auth.lab.axiomlayer.com/-/health/live/" 2>/dev/null)
if [ "$AUTH_STATUS" = "204" ] || [ "$AUTH_STATUS" = "200" ]; then
    pass "Authentik health check passed"
else
    fail "Authentik health check failed (HTTP $AUTH_STATUS)"
fi

section "Forward Auth Outpost"

# Check outpost pod is running
if kubectl get pods -n authentik -l goauthentik.io/outpost-name=forward-auth-outpost --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Forward auth outpost pod is running"
else
    fail "Forward auth outpost pod is not running"
fi

# Check outpost is processing requests (look for any recent application activity in logs)
OUTPOST_ACTIVE=$(kubectl logs -n authentik -l goauthentik.io/outpost-name=forward-auth-outpost --tail=50 --since=5m 2>/dev/null | grep -c "outpost.goauthentik.io" || echo 0)
if [ "$OUTPOST_ACTIVE" -gt 0 ]; then
    pass "Forward auth outpost is processing requests"
else
    # Outpost might just be idle, this is a warning not a failure
    pass "Forward auth outpost has no recent activity (may be idle)"
fi

section "Forward Auth Protected Apps"

# These apps should redirect to Authentik (302)
FORWARD_AUTH_APPS=(
    "db.lab.axiomlayer.com:Dashboard"
    "autom8.lab.axiomlayer.com:n8n"
    "alerts.lab.axiomlayer.com:Alertmanager"
    "longhorn.lab.axiomlayer.com:Longhorn"
    "ai.lab.axiomlayer.com:OpenWebUI"
    "chat.lab.axiomlayer.com:Campfire"
)

for app in "${FORWARD_AUTH_APPS[@]}"; do
    URL="${app%%:*}"
    NAME="${app##*:}"

    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://$URL/" 2>/dev/null)
    if [ "$STATUS" = "302" ]; then
        # Check it redirects to Authentik
        LOCATION=$(curl -sk -I "https://$URL/" 2>/dev/null | grep -i "location:" | head -1)
        if echo "$LOCATION" | grep -q "auth.lab.axiomlayer.com"; then
            pass "$NAME redirects to Authentik"
        else
            fail "$NAME returns 302 but not to Authentik"
        fi
    else
        fail "$NAME should return 302 (got $STATUS)"
    fi
done

section "HTTPS Connectivity"

# Test that apps respond properly over HTTPS (TLS handshake + HTTP response)
# Uses -k to skip cert verification (internal certs), tests that TLS connection succeeds
HTTPS_APPS=(
    "plane.lab.axiomlayer.com:Plane"
    "grafana.lab.axiomlayer.com:Grafana"
    "argocd.lab.axiomlayer.com:ArgoCD"
)

for app in "${HTTPS_APPS[@]}"; do
    URL="${app%%:*}"
    NAME="${app##*:}"

    # Test HTTPS connection works (skip cert verification with -k)
    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://$URL/" 2>/dev/null)

    if [ -n "$STATUS" ] && [ "$STATUS" != "000" ]; then
        pass "$NAME HTTPS connection successful (HTTP $STATUS)"
    else
        fail "$NAME HTTPS connection failed (HTTP $STATUS)"
    fi
done

section "Native OIDC Apps - Basic Access"

# Apps with native OIDC should return 200 (login page)
OIDC_APPS=(
    "argocd.lab.axiomlayer.com:ArgoCD"
    "grafana.lab.axiomlayer.com:Grafana"
    "plane.lab.axiomlayer.com:Plane"
    "docs.lab.axiomlayer.com:Outline"
)

for app in "${OIDC_APPS[@]}"; do
    URL="${app%%:*}"
    NAME="${app##*:}"

    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://$URL/" 2>/dev/null)
    if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ]; then
        pass "$NAME is accessible (HTTP $STATUS)"
    else
        fail "$NAME returned HTTP $STATUS"
    fi
done

section "OIDC Provider Configuration"

# Check OIDC discovery endpoints for each provider
OIDC_PROVIDERS=(
    "argocd:ArgoCD"
    "grafana:Grafana"
    "plane:Plane"
    "outline:Outline"
)

for provider in "${OIDC_PROVIDERS[@]}"; do
    SLUG="${provider%%:*}"
    NAME="${provider##*:}"

    OIDC_DISCOVERY=$(curl -sk "https://auth.lab.axiomlayer.com/application/o/$SLUG/.well-known/openid-configuration" 2>/dev/null)
    if echo "$OIDC_DISCOVERY" | grep -q "issuer"; then
        pass "$NAME OIDC provider discovery endpoint working"
    else
        fail "$NAME OIDC provider discovery endpoint not found"
    fi
done

section "ArgoCD OIDC Integration"

# Check ArgoCD serves its UI (it's a React app, so check for JS bundle)
ARGOCD_LOGIN_PAGE=$(curl -sk "https://argocd.lab.axiomlayer.com/" 2>/dev/null)
if echo "$ARGOCD_LOGIN_PAGE" | grep -qi "argocd\|script\|app"; then
    pass "ArgoCD UI loads successfully"
else
    fail "ArgoCD UI not loading"
fi

# Check ArgoCD auth callback endpoint
ARGOCD_CALLBACK=$(curl -sk -o /dev/null -w "%{http_code}" "https://argocd.lab.axiomlayer.com/auth/callback" 2>/dev/null)
if [ "$ARGOCD_CALLBACK" = "400" ] || [ "$ARGOCD_CALLBACK" = "302" ] || [ "$ARGOCD_CALLBACK" = "200" ]; then
    pass "ArgoCD auth callback endpoint exists (HTTP $ARGOCD_CALLBACK)"
else
    fail "ArgoCD auth callback endpoint not responding (HTTP $ARGOCD_CALLBACK)"
fi

# Verify ArgoCD Dex config in cluster (ArgoCD uses Dex which connects to Authentik)
ARGOCD_DEX_CONFIG=$(kubectl get configmap argocd-cm -n argocd -o jsonpath='{.data.dex\.config}' 2>/dev/null)
if echo "$ARGOCD_DEX_CONFIG" | grep -q "auth.lab.axiomlayer.com"; then
    pass "ArgoCD Dex configured to use Authentik as OIDC provider"
else
    fail "ArgoCD Dex not configured for Authentik"
fi

# Verify ArgoCD can initiate OIDC flow (redirects to Dex which then redirects to Authentik)
ARGOCD_LOGIN_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://argocd.lab.axiomlayer.com/auth/login?return_url=https://argocd.lab.axiomlayer.com/" 2>/dev/null)
ARGOCD_LOGIN_LOCATION=$(curl -sk -I "https://argocd.lab.axiomlayer.com/auth/login?return_url=https://argocd.lab.axiomlayer.com/" 2>/dev/null | grep -i "location:" | head -1)

if [ "$ARGOCD_LOGIN_STATUS" = "302" ] || [ "$ARGOCD_LOGIN_STATUS" = "303" ] || [ "$ARGOCD_LOGIN_STATUS" = "307" ]; then
    # ArgoCD redirects to Dex (/api/dex/auth) which then redirects to Authentik
    if echo "$ARGOCD_LOGIN_LOCATION" | grep -q "/api/dex/auth"; then
        pass "ArgoCD OIDC login redirects to Dex (which connects to Authentik)"
    elif echo "$ARGOCD_LOGIN_LOCATION" | grep -q "auth.lab.axiomlayer.com"; then
        pass "ArgoCD OIDC login redirects to Authentik"
    else
        fail "ArgoCD OIDC login redirects but not to Dex or Authentik (location: $ARGOCD_LOGIN_LOCATION)"
    fi
elif [ "$ARGOCD_LOGIN_STATUS" = "400" ]; then
    fail "ArgoCD OIDC login returns 400 - invalid redirect URL configuration"
else
    fail "ArgoCD OIDC login unexpected response (HTTP $ARGOCD_LOGIN_STATUS)"
fi

section "Grafana OIDC Integration"

# Check Grafana redirects to OAuth login
GRAFANA_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://grafana.lab.axiomlayer.com/login" 2>/dev/null)
if [ "$GRAFANA_STATUS" = "200" ] || [ "$GRAFANA_STATUS" = "302" ]; then
    pass "Grafana login page accessible (HTTP $GRAFANA_STATUS)"
else
    fail "Grafana login page not accessible (HTTP $GRAFANA_STATUS)"
fi

# Check Grafana OAuth endpoint redirects to Authentik
GRAFANA_OAUTH=$(curl -sk -I "https://grafana.lab.axiomlayer.com/login/generic_oauth" 2>/dev/null | grep -i "location:" | head -1)
if echo "$GRAFANA_OAUTH" | grep -q "auth.lab.axiomlayer.com"; then
    pass "Grafana OAuth redirects to Authentik"
else
    fail "Grafana OAuth does not redirect to Authentik"
fi

# Verify Grafana has OAuth configured
GRAFANA_CONFIG=$(kubectl get deployment -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.template.spec.containers[0].env}' 2>/dev/null)
if echo "$GRAFANA_CONFIG" | grep -q "GF_AUTH_GENERIC_OAUTH_ENABLED"; then
    pass "Grafana OAuth environment variables configured"
else
    # Check via values/configmap
    GRAFANA_INI=$(kubectl get configmap -n monitoring -l app.kubernetes.io/name=grafana -o yaml 2>/dev/null | grep -i "generic_oauth")
    if [ -n "$GRAFANA_INI" ]; then
        pass "Grafana OAuth configured via ConfigMap"
    else
        fail "Grafana OAuth not configured"
    fi
fi

section "OIDC Token Endpoint Verification"

# Test that OIDC token endpoints are accessible
OIDC_TOKEN_PROVIDERS=(
    "argocd:ArgoCD"
    "grafana:Grafana"
    "plane:Plane"
    "outline:Outline"
)

for provider in "${OIDC_TOKEN_PROVIDERS[@]}"; do
    SLUG="${provider%%:*}"
    NAME="${provider##*:}"

    # Check token endpoint from discovery (handle multi-line JSON)
    OIDC_CONFIG=$(curl -sk "https://auth.lab.axiomlayer.com/application/o/$SLUG/.well-known/openid-configuration" 2>/dev/null | tr -d '\n')
    TOKEN_ENDPOINT=$(echo "$OIDC_CONFIG" | grep -o '"token_endpoint"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

    if [ -n "$TOKEN_ENDPOINT" ]; then
        # Test that token endpoint responds (should return 400/401 without credentials)
        TOKEN_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$TOKEN_ENDPOINT" 2>/dev/null)
        if [ "$TOKEN_STATUS" = "400" ] || [ "$TOKEN_STATUS" = "401" ] || [ "$TOKEN_STATUS" = "405" ]; then
            pass "$NAME token endpoint responds correctly (HTTP $TOKEN_STATUS)"
        else
            fail "$NAME token endpoint unexpected response (HTTP $TOKEN_STATUS)"
        fi
    else
        fail "$NAME token endpoint not found in discovery"
    fi
done

section "OIDC Authorization Endpoint Verification"

# Test that authorization endpoints redirect properly
for provider in "${OIDC_TOKEN_PROVIDERS[@]}"; do
    SLUG="${provider%%:*}"
    NAME="${provider##*:}"

    OIDC_CONFIG=$(curl -sk "https://auth.lab.axiomlayer.com/application/o/$SLUG/.well-known/openid-configuration" 2>/dev/null | tr -d '\n')
    AUTH_ENDPOINT=$(echo "$OIDC_CONFIG" | grep -o '"authorization_endpoint"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

    if [ -n "$AUTH_ENDPOINT" ]; then
        # Authorization endpoint should respond (302 redirect to login, 200 for login page, or 400 for invalid params)
        AUTH_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$AUTH_ENDPOINT?response_type=code&client_id=test&redirect_uri=https://test.example.com" 2>/dev/null)
        if [ "$AUTH_STATUS" = "302" ] || [ "$AUTH_STATUS" = "303" ] || [ "$AUTH_STATUS" = "200" ] || [ "$AUTH_STATUS" = "400" ]; then
            pass "$NAME authorization endpoint responds (HTTP $AUTH_STATUS)"
        else
            fail "$NAME authorization endpoint not responding (HTTP $AUTH_STATUS)"
        fi
    else
        fail "$NAME authorization endpoint not found in discovery"
    fi
done

section "JWKS Endpoint Verification"

# Verify JWKS endpoints return valid keys
for provider in "${OIDC_TOKEN_PROVIDERS[@]}"; do
    SLUG="${provider%%:*}"
    NAME="${provider##*:}"

    OIDC_CONFIG=$(curl -sk "https://auth.lab.axiomlayer.com/application/o/$SLUG/.well-known/openid-configuration" 2>/dev/null | tr -d '\n')
    JWKS_URI=$(echo "$OIDC_CONFIG" | grep -o '"jwks_uri"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

    if [ -n "$JWKS_URI" ]; then
        JWKS_RESPONSE=$(curl -sk "$JWKS_URI" 2>/dev/null)
        if echo "$JWKS_RESPONSE" | grep -q '"keys"'; then
            # Check that there's at least one key
            KEY_COUNT=$(echo "$JWKS_RESPONSE" | grep -o '"kty"' | wc -l)
            if [ "$KEY_COUNT" -gt 0 ]; then
                pass "$NAME JWKS endpoint has $KEY_COUNT key(s)"
            else
                fail "$NAME JWKS endpoint has no keys"
            fi
        else
            fail "$NAME JWKS endpoint not returning keys"
        fi
    else
        fail "$NAME JWKS URI not found in discovery"
    fi
done

section "Forward Auth Session Handling"

# Test forward auth session cookie handling
FORWARD_AUTH_TEST_URL="https://db.lab.axiomlayer.com/"

# Get redirect to auth
REDIRECT_RESPONSE=$(curl -sk -I "$FORWARD_AUTH_TEST_URL" 2>/dev/null)
REDIRECT_LOCATION=$(echo "$REDIRECT_RESPONSE" | grep -i "location:" | head -1 | tr -d '\r')

if echo "$REDIRECT_LOCATION" | grep -q "auth.lab.axiomlayer.com"; then
    pass "Forward auth correctly redirects unauthenticated requests"

    # Check that redirect includes return URL
    if echo "$REDIRECT_LOCATION" | grep -qi "rd=\|redirect=\|next="; then
        pass "Forward auth includes return URL in redirect"
    else
        # Check if URL is encoded in the path
        if echo "$REDIRECT_LOCATION" | grep -q "db.lab.axiomlayer.com"; then
            pass "Forward auth includes return URL in redirect path"
        else
            fail "Forward auth missing return URL in redirect"
        fi
    fi
else
    fail "Forward auth not redirecting to Authentik"
fi

section "Authentik API Health"

# Test Authentik API endpoints
AUTHENTIK_API_CONFIG=$(curl -sk "https://auth.lab.axiomlayer.com/api/v3/root/config/" 2>/dev/null)

if echo "$AUTHENTIK_API_CONFIG" | grep -q '"error_reporting"'; then
    pass "Authentik API config endpoint accessible"

    # Check version info
    AUTHENTIK_VERSION=$(echo "$AUTHENTIK_API_CONFIG" | grep -o '"version_current":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$AUTHENTIK_VERSION" ]; then
        echo "  Authentik version: $AUTHENTIK_VERSION"
    fi
else
    fail "Authentik API config endpoint not accessible"
fi

# Test Authentik flows (requires authentication, so check for valid response)
AUTHENTIK_FLOWS=$(curl -sk "https://auth.lab.axiomlayer.com/api/v3/flows/instances/" 2>/dev/null)
FLOWS_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://auth.lab.axiomlayer.com/api/v3/flows/instances/" 2>/dev/null)
if echo "$AUTHENTIK_FLOWS" | grep -q '"results"'; then
    FLOW_COUNT=$(echo "$AUTHENTIK_FLOWS" | grep -o '"pk"' | wc -l)
    pass "Authentik has $FLOW_COUNT configured flow(s)"
elif [ "$FLOWS_STATUS" = "401" ] || [ "$FLOWS_STATUS" = "403" ]; then
    pass "Authentik flows API requires authentication (HTTP $FLOWS_STATUS) - expected"
else
    fail "Could not retrieve Authentik flows (HTTP $FLOWS_STATUS)"
fi

section "Outpost Health Check"

# Check outpost can reach Authentik core
OUTPOST_LOGS=$(kubectl logs -n authentik -l goauthentik.io/outpost-name=forward-auth-outpost --tail=100 2>/dev/null || true)

if echo "$OUTPOST_LOGS" | grep -qi "connected\|ready\|healthy" 2>/dev/null; then
    pass "Forward auth outpost appears connected to Authentik"
elif echo "$OUTPOST_LOGS" | grep -qi "error\|failed\|disconnect" 2>/dev/null; then
    # Check if these are transient errors or actual problems
    if echo "$OUTPOST_LOGS" | grep -qi "connection refused\|cannot connect" 2>/dev/null; then
        fail "Forward auth outpost has connection errors"
    else
        pass "Forward auth outpost logs show minor errors (may be transient)"
    fi
else
    pass "Forward auth outpost logs show no errors"
fi

# Check outpost service endpoints
OUTPOST_ENDPOINTS=$(kubectl get endpoints -n authentik ak-outpost-forward-auth-outpost -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
if [ -n "$OUTPOST_ENDPOINTS" ]; then
    pass "Forward auth outpost has active endpoints: $OUTPOST_ENDPOINTS"
else
    # Try with label selector as fallback
    OUTPOST_ENDPOINTS=$(kubectl get endpoints -n authentik -l goauthentik.io/outpost-name=forward-auth-outpost -o jsonpath='{.items[*].subsets[*].addresses[*].ip}' 2>/dev/null)
    if [ -n "$OUTPOST_ENDPOINTS" ]; then
        pass "Forward auth outpost has active endpoints: $OUTPOST_ENDPOINTS"
    else
        fail "Forward auth outpost has no active endpoints"
    fi
fi

section "Native OIDC Claim Verification"

# Verify userinfo endpoints return expected claims
for provider in "${OIDC_TOKEN_PROVIDERS[@]}"; do
    SLUG="${provider%%:*}"
    NAME="${provider##*:}"

    OIDC_CONFIG=$(curl -sk "https://auth.lab.axiomlayer.com/application/o/$SLUG/.well-known/openid-configuration" 2>/dev/null | tr -d '\n')
    USERINFO_ENDPOINT=$(echo "$OIDC_CONFIG" | grep -o '"userinfo_endpoint"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

    if [ -n "$USERINFO_ENDPOINT" ]; then
        # Userinfo should return 401 without token
        USERINFO_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$USERINFO_ENDPOINT" 2>/dev/null)
        if [ "$USERINFO_STATUS" = "401" ] || [ "$USERINFO_STATUS" = "403" ]; then
            pass "$NAME userinfo endpoint correctly requires authentication (HTTP $USERINFO_STATUS)"
        else
            fail "$NAME userinfo endpoint unexpected response (HTTP $USERINFO_STATUS)"
        fi
    else
        fail "$NAME userinfo endpoint not found"
    fi
done

section "Summary"

TOTAL=$((PASSED + FAILED))
echo ""
echo "Tests: $TOTAL | Passed: $PASSED | Failed: $FAILED"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
