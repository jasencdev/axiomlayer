#!/usr/bin/env python3
"""
Sync local markdown docs to Outline using the official API.

Usage:
    OUTLINE_API_TOKEN=... python3 scripts/outline_sync.py

Configuration lives in outline_sync/config.json and state (collection/document
IDs) is tracked in outline_sync/state.json so repeated runs update the same
Outline documents instead of creating duplicates.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "outline_sync" / "config.json"
STATE_PATH = ROOT / "outline_sync" / "state.json"


def load_json(path: Path, default: Dict[str, Any]) -> Dict[str, Any]:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return default.copy()


def save_json(path: Path, data: Dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")


def outline_request(api_url: str, token: str, endpoint: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{api_url.rstrip('/')}/{endpoint}",
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Outline API error ({endpoint}): {error_body}") from exc
    result = json.loads(body)
    if not result.get("ok", True):
        raise RuntimeError(f"Outline API responded with failure for {endpoint}: {result}")
    return result


def ensure_token() -> str:
    token = os.environ.get("OUTLINE_API_TOKEN")
    if not token:
        raise SystemExit("OUTLINE_API_TOKEN environment variable is required")
    return token


def ensure_collection(api_url: str, token: str, config: Dict[str, Any], state: Dict[str, Any]) -> str:
    collection_id = state.get("collectionId")
    if collection_id:
        return collection_id
    name = config["collectionName"]
    print(f"Creating Outline collection '{name}'...")
    resp = outline_request(api_url, token, "collections.create", {"name": name})
    collection_id = resp["data"]["id"]
    state["collectionId"] = collection_id
    return collection_id


def sync_document(
    api_url: str,
    token: str,
    collection_id: str,
    entry: Dict[str, Any],
    text: str,
    state: Dict[str, Any],
) -> str:
    path_key = entry["path"]
    doc_state = state.setdefault("documents", {}).get(path_key, {})
    doc_id = doc_state.get("id")
    payload = {
        "title": entry["title"],
        "text": text,
        "publish": True,
    }
    parent_id = entry.get("parentDocumentId")
    if parent_id:
        payload["parentDocumentId"] = parent_id
    if doc_id:
        payload["id"] = doc_id
        outline_request(api_url, token, "documents.update", payload)
        print(f"Updated '{entry['title']}'")
        return doc_id
    payload["collectionId"] = collection_id
    resp = outline_request(api_url, token, "documents.create", payload)
    doc_id = resp["data"]["id"]
    state.setdefault("documents", {})[path_key] = {"id": doc_id}
    print(f"Created '{entry['title']}'")
    return doc_id


def path_to_title(path: str) -> str:
    """Convert a file path to a document title."""
    name = Path(path).stem
    # Handle common naming patterns
    name = name.replace("-", " ").replace("_", " ")
    # Title case, but preserve uppercase acronyms
    words = name.split()
    titled = []
    for word in words:
        if word.isupper():
            titled.append(word)
        else:
            titled.append(word.title())
    return " ".join(titled)


def discover_docs(config: Dict[str, Any]) -> list:
    """Auto-discover markdown files in docs/ and merge with config."""
    # Start with explicit config entries
    explicit = {e["path"]: e for e in config.get("documents", [])}

    # Auto-discover docs/*.md files
    docs_dir = ROOT / "docs"
    if docs_dir.exists():
        for md_file in sorted(docs_dir.glob("*.md")):
            rel_path = str(md_file.relative_to(ROOT))
            if rel_path not in explicit:
                explicit[rel_path] = {
                    "path": rel_path,
                    "title": path_to_title(rel_path),
                }

    # Also include README.md if configured

    return list(explicit.values())


def main() -> None:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"Missing config file at {CONFIG_PATH}")
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    state = load_json(STATE_PATH, {"documents": {}})
    token = ensure_token()
    api_url = config.get("apiUrl", "https://docs.lab.axiomlayer.com/api")

    collection_id = ensure_collection(api_url, token, config, state)

    # Auto-discover docs and merge with config
    documents = discover_docs(config)

    for entry in documents:
        rel_path = entry["path"]
        file_path = ROOT / rel_path
        if not file_path.exists():
            print(f"Skipping '{rel_path}' (missing file)")
            continue
        text = file_path.read_text(encoding="utf-8")
        sync_document(api_url, token, collection_id, entry, text, state)

    save_json(STATE_PATH, state)
    print(f"\nSync complete. State saved to {STATE_PATH}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as err:
        print(err, file=sys.stderr)
        sys.exit(1)
