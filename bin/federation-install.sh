#!/bin/sh
# Download the latest Linux Federation release. Prefer the signed package; a
# self-contained tarball keeps a non-root install possible on systems without
# dpkg. Release URLs may be overridden for staging or an internal mirror.
set -eu

REPOSITORY="${WASPFLOW_FEDERATION_REPOSITORY:-tnunamak/waspflow}"
API_URL="${WASPFLOW_FEDERATION_RELEASE_API:-https://api.github.com/repos/${REPOSITORY}/releases/latest}"
INSTALL_ROOT="${WASPFLOW_FEDERATION_INSTALL_ROOT:-${HOME}/.local}"
TMP_DIR=""

say() { printf '%s\n' "  $*"; }
warn() { printf '%s\n' "  warning: $*" >&2; }
die() { printf '%s\n' "  error: $*" >&2; exit 1; }

cleanup() {
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

need() {
  command -v "$1" >/dev/null 2>&1 || die "need '$1' (command not found)"
}

download() {
  curl -fsSL "$1" -o "$2"
}

asset_url() {
  suffix="$1"
  curl -fsSL "$API_URL" |
    sed -n "s|.*\"browser_download_url\": \"\([^\"]*${suffix}\)\".*|\1|p" |
    head -n 1
}

install_tarball() {
  tar_url="$1"
  tar_file="$TMP_DIR/waspflow-federation.tar.gz"
  unpacked="$TMP_DIR/unpacked"
  say "Installing the portable Federation bundle into $INSTALL_ROOT..."
  download "$tar_url" "$tar_file"
  mkdir -p "$unpacked" "$INSTALL_ROOT/bin" "$INSTALL_ROOT/lib"
  tar -xzf "$tar_file" -C "$unpacked"
  test -d "$unpacked/usr/lib/waspflow" || die "release tarball does not contain the Federation runtime"
  rm -rf "$INSTALL_ROOT/lib/waspflow-federation"
  mv "$unpacked/usr/lib/waspflow" "$INSTALL_ROOT/lib/waspflow-federation"
  cat > "$INSTALL_ROOT/bin/waspflow-federation" <<EOF
#!/bin/sh
exec node "$INSTALL_ROOT/lib/waspflow-federation/bin/waspflow-federation" "\$@"
EOF
  cat > "$INSTALL_ROOT/bin/waspflow" <<EOF
#!/bin/sh
if [ "\${1:-}" = federation ]; then
  shift
  exec "$INSTALL_ROOT/bin/waspflow-federation" "\$@"
fi
echo "This Federation install provides only: waspflow federation ..." >&2
exit 64
EOF
  chmod 0755 "$INSTALL_ROOT/bin/waspflow-federation" "$INSTALL_ROOT/bin/waspflow"
}

need curl
need tar
need node
node_major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$node_major" -ge 20 ] || die "Node.js 20 or newer is required (found $(node --version))"

case "$(uname -s)" in
  Linux) ;;
  *) die "this installer currently supports Linux; on macOS use the Homebrew formula in packaging/brew (untested)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ;;
  *) die "this release currently supports x86_64 Linux only" ;;
esac

TMP_DIR="$(mktemp -d)"
deb_url="$(asset_url '_amd64.deb' || true)"
tar_url="$(asset_url '_linux_amd64.tar.gz' || true)"

if [ -n "$deb_url" ] && command -v dpkg >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  deb_file="$TMP_DIR/waspflow-federation.deb"
  say "Installing the Debian package..."
  download "$deb_url" "$deb_file"
  if sudo dpkg -i "$deb_file"; then
    say "Installed the Debian package."
  elif [ -n "$tar_url" ]; then
    warn "the Debian package could not be installed; using the portable bundle instead"
    install_tarball "$tar_url"
  else
    die "the Debian package could not be installed"
  fi
elif [ -n "$tar_url" ]; then
  install_tarball "$tar_url"
else
  die "no Linux Federation .deb or portable tarball was found in the latest release"
fi

case ":$PATH:" in
  *":$INSTALL_ROOT/bin:"*) ;;
  *) warn "$INSTALL_ROOT/bin is not on PATH; add it before opening a new shell" ;;
esac

say "Ready. Start the guided onboarding flow with: waspflow federation"
