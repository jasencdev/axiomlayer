# Open WebUI RAG Sync: Tag-Based Versioned Sync

This document explains the tag-based versioned sync approach for RAG synchronization, which solves issues with sync markers and ChromaDB duplicate detection.

## Table of Contents

- [Summary](#summary)
- [How It Works](#how-it-works)
- [CI Integration](#ci-integration)
- [Environment Variables](#environment-variables)
- [Release Workflow](#release-workflow)
- [Manual Sync](#manual-sync)
- [File Scope and Exclusions](#file-scope-and-exclusions)
- [KB Cleanup Strategy](#kb-cleanup-strategy)
- [Troubleshooting](#troubleshooting)
- [Migration from Commit-Based Sync](#migration-from-commit-based-sync)
- [Security Considerations](#security-considerations)
- [Implementation Notes](#implementation-notes)

## Summary

- **Problem 1**: Sync markers (`.rag-sync-commit`) were gitignored, causing CI to lose sync state between runs
- **Problem 2**: ChromaDB duplicate detection blocks delete-then-reupload of unchanged content
- **Solution**: Tag-based versioned sync where files are uploaded with version suffix (e.g., `README__v1.0.0.md`)

---

## How It Works

### Trigger: Git Tags Only

RAG sync only runs when you push a version tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

This triggers the `rag-sync` job in CI, which:
1. Extracts the version from the tag (e.g., `v1.0.0`)
2. Compares against the previous tag to find changed files
3. Uploads changed files with versioned filenames

### Versioned Filenames

Files are uploaded with the version suffix embedded in the filename:

| Original Path | Versioned Filename |
|---------------|-------------------|
| `README.md` | `README__v1.0.0.md` |
| `apps/dashboard/configmap.yaml` | `apps__dashboard__configmap__v1.0.0.yaml` |
| `docs/CLAUDE.md` | `docs__CLAUDE__v1.0.0.md` |

This provides:
- **No duplicate content issues**: Each version is a unique file
- **Version history**: Old versions remain in the KB for reference
- **Clear provenance**: Files are tied to specific releases

---

## CI Integration

### GitHub Actions Workflow

The `rag-sync` and `outline-sync` jobs trigger on tag push:

```yaml
# .github/workflows/ci.yaml
on:
  push:
    branches: [main]
    tags:
      - 'v*'  # Trigger on version tags

rag-sync:
  if: startsWith(github.ref, 'refs/tags/v')
  steps:
    - name: Get version from tag
      run: echo "VERSION=${GITHUB_REF#refs/tags/}" >> $GITHUB_OUTPUT
    - name: Sync repo to Open WebUI RAG
      env:
        RAG_VERSION: ${{ steps.version.outputs.VERSION }}
      run: ./scripts/sync-rag.sh
```

### Required Secrets

| Secret | Purpose |
|--------|---------|
| `OPEN_WEBUI_API_KEY` | API key from Open WebUI Settings |
| `OPEN_WEBUI_KNOWLEDGE_ID` | Knowledge base ID |
| `OUTLINE_API_TOKEN` | Outline API token |

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPEN_WEBUI_API_KEY` | Yes | API key from Open WebUI |
| `OPEN_WEBUI_KNOWLEDGE_ID` | Yes | Target knowledge base ID |
| `RAG_VERSION` | No | Version tag (auto-detected from git) |
| `FORCE_FULL_SYNC` | No | Set to `true` to sync all files |

---

## Release Workflow

### Creating a Release

```bash
# 1. Ensure all changes are committed and pushed
git add .
git commit -m "feat: your changes"
git push origin main

# 2. Create and push a version tag
git tag v1.0.0
git push origin v1.0.0
```

### What Happens

1. CI detects the tag push
2. `rag-sync` job runs with `RAG_VERSION=v1.0.0`
3. Script compares `v1.0.0` against previous tag (e.g., `v0.9.0`)
4. Changed files are uploaded with `__v1.0.0` suffix
5. KB now contains versioned entries

### First Release

For the first release (no previous tag), all matching files are uploaded:

```bash
git tag v1.0.0
git push origin v1.0.0
# All *.md and *.yaml files are uploaded with __v1.0.0 suffix
```

---

## Manual Sync

You can run the sync manually for testing:

```bash
# Source environment variables
source .env

# Run with explicit version
RAG_VERSION=v1.0.0-test ./scripts/sync-rag.sh

# Force full sync
RAG_VERSION=v1.0.0 FORCE_FULL_SYNC=true ./scripts/sync-rag.sh
```

---

## File Scope and Exclusions

### Included

- `*.md` - All markdown files
- `*.yaml` - All YAML files (apps, infrastructure, workflows)

### Excluded

- `*sealed-secret*` - Encrypted secrets
- `*.env*` - Environment files
- `*AGENTS.md*` - Agent configuration

### Size Limit

Files larger than 500 KB are skipped to keep ingestion fast.

---

## KB Cleanup Strategy

Over time, old versions accumulate in the knowledge base. Options:

1. **Keep all** (recommended): Historical context is useful, disk is cheap
2. **Manual cleanup**: Periodically delete old versions via Open WebUI UI
3. **Automated cleanup**: Add a cleanup step to delete `*__v{old}.*` patterns

---

## Troubleshooting

### No files uploaded

- Verify you pushed a tag matching `v*` pattern
- Check that files changed since the previous tag
- Verify environment variables are set in CI secrets

### Sync fails with API errors

- Verify `OPEN_WEBUI_API_KEY` is valid
- Verify `OPEN_WEBUI_KNOWLEDGE_ID` exists
- Check Open WebUI pod is running

### Files not appearing in KB

- Check file size (must be < 500 KB)
- Check exclusion patterns
- Verify file extension is `.md` or `.yaml`

---

## Migration from Commit-Based Sync

If migrating from the old commit-based sync:

1. The new approach doesn't use `.rag-sync-commit` marker files
2. First tagged release will sync all files (full sync)
3. Old non-versioned files remain in KB (clean up manually if desired)

---

## Security Considerations

- Never sync plaintext Kubernetes Secrets; use SealedSecrets
- API keys are stored in GitHub Secrets, not in code
- Internal cluster routing bypasses Authentik forward auth

---

## Implementation Notes

- Version is extracted from `RAG_VERSION` env var or `git describe --tags`
- Previous tag found via `git describe --tags --abbrev=0 HEAD^`
- Path encoding: `/` → `__` to preserve directory structure in filenames
- Upload uses internal service URL: `http://localhost:8080` via kubectl exec
