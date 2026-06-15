#!/usr/bin/env bash
# install.sh — symlink waspflow onto PATH (~/.local/bin) and check deps.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bindir="${WASPFLOW_INSTALL_BIN:-$HOME/.local/bin}"
mkdir -p "$bindir"

ln -sf "$root/bin/waspflow" "$bindir/waspflow"
echo "linked $bindir/waspflow -> $root/bin/waspflow"

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "note: $bindir is not on your PATH — add it to use 'waspflow' directly." ;;
esac

echo
"$root/bin/waspflow" doctor || true
