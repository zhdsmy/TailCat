#!/bin/bash
# Renders the main screens with sample data (temp directory + fake tailcat, never your real rules)
# into build/snapshots/, or build/snapshots-dark/ with --dark. See Sources/TailCat/Snapshot.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/snapshots"
for arg in "$@"; do
  [[ "$arg" == "--dark" ]] && OUT="build/snapshots-dark"
done
for arg in "$@"; do
  case "$arg" in
    --language=en|--language=zh-Hans|--language=zh-Hant) OUT="$OUT-${arg#--language=}" ;;
  esac
done

swift build
rm -rf "$OUT"
.build/debug/TailCat --snapshot "$OUT" "$@"
