#!/usr/bin/env python3
"""Fail if plaintext marker bytes are present in Clipy history storage.

Example:
  python3 Resources/inspect_history_plaintext.py \
    --root "$HOME/Library/Application Support/com.clipy-app.Clipy" \
    --marker "CLIPY-RAW-MARKER-2026"

The script intentionally scans ordinary files byte-for-byte. It is designed for
release-gate fixtures that write unique markers into text, image metadata, RTF,
PDF, and URL clipboard payloads before enabling encrypted history.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


DEFAULT_NAMES = {
    "sqlite.db",
    "sqlite.db-wal",
    "sqlite.db-shm",
    "sqlite.db-journal",
    "default.realm",
    "default.realm.lock",
    "default.realm.management",
    "PINCache",
}


def iter_candidate_files(root: Path):
    if root.is_file():
        yield root
        return

    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if path.name in DEFAULT_NAMES or any(part in DEFAULT_NAMES for part in path.parts):
            yield path


def contains_marker(path: Path, marker: bytes) -> bool:
    with path.open("rb") as file:
        while True:
            chunk = file.read(1024 * 1024)
            if not chunk:
                return False
            if marker in chunk:
                return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="append", required=True, help="Storage root or file to scan. Repeatable.")
    parser.add_argument("--marker", action="append", required=True, help="Plaintext marker string. Repeatable.")
    args = parser.parse_args()

    markers = [marker.encode("utf-8") for marker in args.marker]
    roots = [Path(root).expanduser() for root in args.root]
    hits: list[tuple[Path, str]] = []

    for root in roots:
        if not root.exists():
            continue
        for path in iter_candidate_files(root):
            for marker_text, marker in zip(args.marker, markers):
                if contains_marker(path, marker):
                    hits.append((path, marker_text))

    if hits:
        for path, marker in hits:
            print(f"PLAINTEXT MARKER FOUND: {marker!r} in {path}", file=sys.stderr)
        return 1

    print("No plaintext markers found in scanned history storage.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
