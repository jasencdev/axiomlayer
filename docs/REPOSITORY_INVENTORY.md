# Repository Inventory and Audit

**Generated**: 2025-12-01
**Purpose**: Comprehensive inventory of all components for documentation completeness

## Applications (apps/)

| Directory | Status | Documentation | Notes |
|-----------|--------|---------------|-------|
| argocd | ✅ Active | CLAUDE.md, README.md | GitOps controller + Application CRDs |
| campfire | ✅ Active | CLAUDE.md, README.md | Team chat (37signals) |
| dashboard | ✅ Active | CLAUDE.md, README.md | Service portal at db.lab.axiomlayer.com |
| n8n | ✅ Active | CLAUDE.md, README.md | Workflow automation at autom8.lab.axiomlayer.com |
| outline | ✅ Active | CLAUDE.md, README.md | Documentation wiki at docs.lab.axiomlayer.com |
| plane | ✅ Active | CLAUDE.md, README.md | Project management at plane.lab.axiomlayer.com |
| telnet-server | ✅ Active | CLAUDE.md, README.md | Demo application with SSO |

**Total Applications**: 7
**Documented**: 7/7 (100%)

## Infrastructure Components (infrastructure/)

| Directory | Status | Documentation | Notes |
|-----------|--------|---------------|-------|
| actions-runner | ✅ Active | CLAUDE.md, README.md | GitHub Actions self-hosted runners |
| alertmanager | ✅ Active | CLAUDE.md, README.md | Alert routing and management |
| authentik | ✅ Active | CLAUDE.md, README.md | SSO/OIDC provider at auth.lab.axiomlayer.com |
| backups | ✅ Active | CLAUDE.md, README.md | Automated database backup CronJob |
| cert-manager | ✅ Active | CLAUDE.md, README.md | TLS certificates via Let's Encrypt |
| cloudnative-pg | ✅ Active | CLAUDE.md, README.md | PostgreSQL operator (CNPG) |
| external-dns | ✅ Active | CLAUDE.md, README.md | Automatic Cloudflare DNS management |
| longhorn | ✅ Active | CLAUDE.md, README.md | Distributed storage at longhorn.lab.axiomlayer.com |
| monitoring | ✅ Active | CLAUDE.md, README.md | Grafana/Prometheus extras (OIDC, certs) |
| nfs-proxy | ✅ Active | CLAUDE.md, README.md | NFS proxy for Longhorn backups to NAS |
| open-webui | ✅ Active | CLAUDE.md, README.md | AI chat interface at ai.lab.axiomlayer.com |
| sealed-secrets | ✅ Active | CLAUDE.md, README.md | Sealed Secrets controller (GitOps-managed) |

**Total Infrastructure Components**: 12
**Documented**: 12/12 (100%)

## Scripts (scripts/)

| Script | Purpose | Documentation | Usage Examples |
|--------|---------|---------------|----------------|
| backup-homelab.sh | Local backup helper | README.md | ⚠️ Needs detailed docs |
| bootstrap-argocd.sh | ArgoCD + GitOps bootstrap | CLAUDE.md | ⚠️ Needs detailed docs |
| check-no-plaintext-secrets.sh | Security validation | ❌ Not documented | ❌ Needs documentation |
| fix-etcd-ip.sh | etcd IP fix utility | ❌ Not documented | ❌ Needs documentation |
| fix-flannel-agents.sh | Flannel agent fix | ❌ Not documented | ❌ Needs documentation |
| fix-flannel-neko2.sh | Flannel neko2 fix | ❌ Not documented | ❌ Needs documentation |
| provision-k3s-agent.sh | K3s agent provisioning | README.md | ⚠️ Needs detailed docs |
| provision-k3s-ollama-agent.sh | K3s GPU agent provisioning | README.md | ⚠️ Needs detailed docs |
| provision-k3s-server.sh | K3s server provisioning | CLAUDE.md, README.md | ⚠️ Needs detailed docs |
| provision-neko2.sh | Neko2 node provisioning | ❌ Not documented | ❌ Needs documentation |
| provision-neko.sh | Neko node provisioning | ❌ Not documented | ❌ Needs documentation |
| provision-ollama-workstation.sh | Ollama workstation setup | ❌ Not documented | ❌ Needs documentation |
| provision-siberian.sh | GPU workstation automation | README.md | ⚠️ Needs detailed docs |
| sync-outline.sh | Outline wiki sync | CLAUDE.md, README.md | ⚠️ Needs detailed docs |
| sync-rag.sh | RAG knowledge base sync | CLAUDE.md, README.md | ⚠️ Needs detailed docs |
| validate-kustomize.sh | Kustomize validation | ❌ Not documented | ❌ Needs documentation |

**Total Scripts**: 16
**Documented**: 10/16 (62.5%)
**Need Detailed Docs**: 16/16 (100%)

## Test Scripts (tests/)

| Script | Purpose | Test Count | Documentation |
|--------|---------|------------|---------------|
| smoke-test.sh | Infrastructure health checks | 111 tests | CLAUDE.md, README.md |
| test-app-functionality.sh | Application functionality tests | Unknown | ⚠️ Brief mention only |
| test-auth.sh | Authentication flow tests | 27 tests | CLAUDE.md, README.md |
| test-backup-restore.sh | Backup/restore validation | Unknown | ⚠️ Brief mention only |
| test-monitoring.sh | Monitoring stack tests | Unknown | ⚠️ Brief mention only |
| test-network-policies.sh | Network policy validation | Unknown | ⚠️ Brief mention only |
| validate-manifests.sh | Kustomize manifest validation | 20 checks | CLAUDE.md, README.md |

**Total Test Scripts**: 7
**Well Documented**: 3/7 (42.9%)
**Need Detailed Docs**: 4/7 (57.1%)

## Documentation Files

| File | Purpose | Status |
|------|---------|--------|
| README.md | Main repository README | ✅ Complete, updated with zsh |
| CLAUDE.md | Operator/maintainer guide | ✅ Complete, updated with zsh |
| CONTRIBUTING.md | Contribution guidelines | ✅ **NEW**: Created with zsh requirements |
| .github/copilot-instructions.md | GitHub Copilot context | ✅ Updated with zsh |
| AGENTS.md | AI agent instructions | ⚠️ Needs zsh update? |
| docs/ARCHITECTURE.md | Architecture overview | ⚠️ Needs verification |
| docs/APPLICATIONS.md | Application catalog | ⚠️ Needs verification |
| docs/TROUBLESHOOTING.md | Troubleshooting guide | ⚠️ Needs verification |
| docs/NETWORKING.md | Networking documentation | ⚠️ Needs verification |
| docs/OUTLINE_SYNC_PLAN.md | Outline sync documentation | ⚠️ Needs verification |

## Secrets and Environment Variables

### Documented in CLAUDE.md

| Variable | Purpose | Component |
|----------|---------|-----------|
| AUTHENTIK_AUTH_TOKEN | Authentik API access | Authentik |
| AUTHENTIK_POSTGRESQL_PASSWORD | Authentik DB password | Authentik |
| AUTHENTIK_SECRET_KEY | Authentik encryption key | Authentik |
| CLOUDFLARE_API_TOKEN | DNS-01 challenges | cert-manager, external-dns |
| GITHUB_RUNNER_TOKEN | GitHub Actions runner PAT | actions-runner |
| GRAFANA_OIDC_CLIENT_ID/SECRET | Grafana OIDC | Grafana |
| OUTLINE_OIDC_CLIENT_ID/SECRET | Outline OIDC | Outline |
| PLANE_OIDC_CLIENT_ID/SECRET | Plane OIDC | Plane |
| N8N_DB_PASSWORD | n8n database | n8n |
| N8N_ENCRYPTION_KEY | n8n encryption | n8n |
| OPEN_WEBUI_SECRET_KEY | Open WebUI encryption | Open WebUI |
| CAMPFIRE_SECRET_KEY_BASE | Campfire Rails secret | Campfire |
| GHCR_DOCKERCONFIGJSON | GitHub Container Registry | Cluster |
| K3_JOIN_SERVER | K3s cluster join token | K3s |
| PLANE_API_KEY | Plane API access | CI/CD |
| OUTLINE_API_KEY/TOKEN | Outline API access | CI/CD |
| OPEN_WEBUI_API_KEY | Open WebUI API access | CI/CD |
| OPEN_WEBUI_KNOWLEDGE_ID | RAG knowledge base ID | CI/CD |

**Total Environment Variables**: 19+
**All documented in CLAUDE.md**: ✅

### GitHub Actions Secrets

| Secret | Purpose | Used By |
|--------|---------|---------|
| ARGOCD_AUTH_TOKEN | ArgoCD API access | CI sync trigger |
| OUTLINE_API_TOKEN | Outline wiki sync | Documentation sync |
| OPEN_WEBUI_API_KEY | Open WebUI RAG sync | RAG knowledge base |
| OPEN_WEBUI_KNOWLEDGE_ID | RAG knowledge base ID | RAG knowledge base |

**Total CI Secrets**: 4
**All documented in CLAUDE.md**: ✅

## ArgoCD Applications

### ArgoCD Applications

All applications in `apps/argocd/applications/`:

| Application Manifest | Target Path | Documented | Notes |
|---------------------|-------------|------------|-------|
| root.yaml | apps/argocd/applications/ | ✅ | App of Apps (manual sync) |
| argocd-helm.yaml | N/A (Helm chart) | ✅ | ArgoCD self-management |
| actions-runner-controller.yaml | infrastructure/actions-runner | ✅ | GitHub Actions controller |
| actions-runner-infra.yaml | infrastructure/actions-runner | ✅ | GitHub Actions runners |
| alertmanager.yaml | infrastructure/alertmanager | ✅ | Alert management |
| authentik-helm.yaml | infrastructure/authentik | ✅ | Authentik Helm chart |
| authentik.yaml | infrastructure/authentik | ✅ | Authentik extras/config |
| backups.yaml | infrastructure/backups | ✅ | Backup automation |
| campfire.yaml | apps/campfire | ✅ | Team chat |
| cert-manager-helm.yaml | infrastructure/cert-manager | ✅ | cert-manager Helm chart |
| cert-manager.yaml | infrastructure/cert-manager | ✅ | cert-manager extras |
| cloudnative-pg.yaml | infrastructure/cloudnative-pg | ✅ | PostgreSQL operator |
| dashboard.yaml | apps/dashboard | ✅ | Service portal |
| external-dns.yaml | infrastructure/external-dns | ✅ | DNS automation |
| kube-prometheus-stack.yaml | infrastructure/monitoring | ✅ | Prometheus/Grafana Helm |
| loki.yaml | infrastructure/monitoring | ✅ | Loki logging stack |
| longhorn-helm.yaml | infrastructure/longhorn | ✅ | Longhorn Helm chart |
| longhorn.yaml | infrastructure/longhorn | ✅ | Longhorn extras |
| monitoring-extras.yaml | infrastructure/monitoring | ✅ | Grafana cert + namespace |
| n8n.yaml | apps/n8n | ✅ | Workflow automation |
| nfs-proxy.yaml | infrastructure/nfs-proxy | ✅ | NFS proxy for backups |
| open-webui.yaml | infrastructure/open-webui | ✅ | AI chat interface |
| outline.yaml | apps/outline | ✅ | Documentation wiki |
| plane-extras.yaml | apps/plane | ✅ | Plane customizations |
| plane.yaml | apps/plane | ✅ | Project management |
| sealed-secrets.yaml | infrastructure/sealed-secrets | ✅ | Sealed Secrets controller |
| telnet-server.yaml | apps/telnet-server | ✅ | Demo app |

**Total ArgoCD Applications**: 28
**All applications tracked and deployed via GitOps** ✅

## Gaps and Action Items

### Critical Documentation Gaps

1. **Scripts** - 6 scripts have NO documentation:
   - check-no-plaintext-secrets.sh
   - fix-etcd-ip.sh
   - fix-flannel-agents.sh
   - fix-flannel-neko2.sh
   - provision-neko2.sh
   - provision-neko.sh
   - provision-ollama-workstation.sh
   - validate-kustomize.sh

2. **Tests** - 4 test scripts need detailed documentation:
   - test-app-functionality.sh (what does it test?)
   - test-backup-restore.sh (what does it test?)
   - test-monitoring.sh (what does it test?)
   - test-network-policies.sh (what does it test?)

3. **Per-Component READMEs** - No component has its own README:
   - apps/*/README.md - MISSING
   - infrastructure/*/README.md - MISSING

### Documentation Improvements Needed

1. **Script Usage Examples** - Every script needs:
   - Description
   - Prerequisites
   - Parameters/arguments
   - Usage examples
   - Error handling notes

2. **Test Documentation** - Every test script needs:
   - What it tests
   - How many tests
   - Expected output
   - Failure scenarios

3. **Component READMEs** - Every component should have:
   - Purpose/overview
   - Configuration options
   - Dependencies
   - How to customize
   - Troubleshooting

4. **Architecture Docs** - Need verification:
   - docs/ARCHITECTURE.md
   - docs/APPLICATIONS.md
   - docs/NETWORKING.md
   - docs/TROUBLESHOOTING.md

### Audit Checklist

- [ ] Verify all ArgoCD Application manifests listed
- [ ] Create detailed script documentation
- [ ] Create detailed test documentation
- [ ] Create per-component READMEs
- [ ] Verify/update architecture docs
- [ ] Update AGENTS.md with zsh requirements
- [ ] Create scripts/README.md index
- [ ] Create tests/README.md index
- [ ] Document disaster recovery procedures
- [ ] Document common failure scenarios

## Summary

### Completion Status

- **Applications**: 7/7 documented (100%) ✅
- **Infrastructure**: 12/12 documented (100%) ✅
- **Scripts**: 10/16 documented (62.5%) ⚠️
- **Tests**: 3/7 well-documented (42.9%) ⚠️
- **Secrets/Env Vars**: 19+ documented (100%) ✅
- **Shell Compatibility**: Documented in all key files ✅

### Priority Actions

1. **HIGH**: Document all 6 undocumented scripts
2. **HIGH**: Add detailed test documentation for 4 test scripts
3. **MEDIUM**: Create per-component READMEs
4. **MEDIUM**: Verify and update architecture docs
5. **LOW**: Create index READMEs for scripts/ and tests/ directories

**Note**: This inventory should be updated whenever components are added, removed, or significantly modified.
