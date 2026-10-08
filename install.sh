#!/usr/bin/env bash
# install.sh — symlink waspflow onto PATH (~/.local/bin) and check deps.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bindir="${WASPFLOW_INSTALL_BIN:-$HOME/.local/bin}"
mkdir -p "$bindir"

ln -sf "$root/bin/waspflow" "$bindir/waspflow"
echo "linked $bindir/waspflow -> $root/bin/waspflow"

case ":$PATH:" in
  *":$bindir:"*) printf 'next: waspflow doctor\n' ;;
  *) printf 'next: add %q to PATH, then run: %q doctor\n' "$bindir" "$bindir/waspflow" ;;
esac
