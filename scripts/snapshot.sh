#!/bin/bash
# Renders the main screens with sample data (temp directory + fake tailcat, never your real rules)
# into build/snapshots/, or build/snapshots-dark/ with --dark. See Sources/TailCat/Snapshot.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/snapshots"
[[ "${1:-}" == "--dark" ]] && OUT="build/snapshots-dark"

swift build
rm -rf "$OUT"
.build/debug/TailCat --snapshot "$OUT" "$@"
