#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Builds pinned sources locally; does not publish or create a Git tag.
# Shared configuration explicitly uses --disable-gpl and --disable-nonfree.
exec python3 "$SCRIPT_DIR/scripts/build_release.py" --target windows-x86_64 "$@"
