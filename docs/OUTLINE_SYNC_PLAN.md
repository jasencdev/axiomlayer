# Outline Sync Plan

Working notes for moving the refreshed engineering docs into Outline and the company wiki.

## Table of Contents

- [Goals](#goals)
- [Proposed Outline Structure](#proposed-outline-structure)
- [API Workflow](#api-workflow)
- [Next Actions](#next-actions)
- [Automation Hook](#automation-hook)

---

## Goals

1. Keep the engineering source of truth in Git while mirroring the latest content into Outline for easier discovery.
2. Split audiences: detailed runbooks/architecture for engineers, simplified service overviews for the wider company wiki.
3. Automate publishing via the Outline API so updates travel with each pull request.

## Proposed Outline Structure

- **Engineering**
  - Architecture (from `docs/ARCHITECTURE.md`)
  - Infrastructure (Traefik, Authentik, backups, monitoring, etc.)
  - Applications (per-app runbooks from `docs/APPLICATIONS.md`)
  - Runbooks & Troubleshooting (`docs/RUNBOOKS.md`, `docs/TROUBLESHOOTING.md`)
  - Secrets & Compliance (`docs/SECRETS.md` high-level view, no raw values)
  - Networking (`docs/NETWORKING.md`)
- **Company Wiki**
  - Service Catalog (short version of `README.md` Live Services table)
  - Access & Accounts (link to Authentik + Outline login instructions)
  - Incident Process (links back to Runbooks sections)

## API Workflow

1. Request an Outline API token with `documents.read`, `documents.write`, and `collections.write` scopes.
2. For each markdown source file:
   - Convert to Outline-compatible markdown (no GitHub-specific callouts).
   - Map it to a document slug + parent document/collection.
   - Call `POST /api/documents.create` (or `documents.update` if `id` exists) with `{ title, text, collectionId, parentDocumentId, publish: true }`.
3. Store the resulting Outline document IDs in a small JSON map (e.g. `.outline-sync.json`) so future syncs can call `documents.update`.
4. Wire the sync script into CI or a local helper (`scripts/sync-outline.sh`) that runs after docs change.

## Next Actions

1. **Need**: Outline API token + collection IDs for the Engineering and Company wiki spaces.
2. Prototype a sync script (Node.js or Python w/ `requests`) that:
   - Reads the JSON map,
   - Pushes updated markdown,
   - Raises an error if Outline returns validation issues.
3. Dry-run with `README.md` + `docs/ARCHITECTURE.md` to validate formatting.
4. Once stable, gate CI merges on `bin/outline-sync --check` so docs stay in lockstep.

## Automation Hook

- The sync script lives at `scripts/outline_sync.py` and uses `outline_sync/config.json` + `outline_sync/state.json`.
- `.github/workflows/ci.yaml` contains the `outline-sync` job, which runs on every push to `main` (after CI succeeds) when the repository secret `OUTLINE_API_TOKEN` is present.
- For forks or branches without the secret, the job logs a skip message so contributors can still run CI.
