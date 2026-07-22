#!/bin/sh
# Download the latest Linux Federation release. Prefer the signed package; a
# self-contained tarball keeps a non-root install possible on systems without
# dpkg. Release URLs may be overridden for staging or an internal mirror.
set -eu

REPOSITORY="${WASPFLOW_FEDERATION_REPOSITORY:-tnunamak/waspflow}"
# Version-stable asset names via the releases/latest/download redirect: no
# GitHub API call, so shared-IP unauthenticated rate limits (403s from office
# NAT, CI, containers) cannot break a tester's install. The API remains a
# fallback for releases that only carry versioned asset names.
DOWNLOAD_BASE="${WASPFLOW_FEDERATION_DOWNLOAD_BASE:-https://github.com/${REPOSITORY}/releases/latest/download}"
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
  stable_name="$2"
  if curl -fsIL "$DOWNLOAD_BASE/$stable_name" >/dev/null 2>&1; then
    printf '%s\n' "$DOWNLOAD_BASE/$stable_name"
    return 0
  fi
  curl -fsSL "$API_URL" |
    sed -n "s|.*\"browser_download_url\": \"\([^\"]*${suffix}\)\".*|\1|p" |
    head -n 1
}

INSTALLED_VIA=""

install_tarball() {
  INSTALLED_VIA="tarball"
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

node_help() {
  printf '%s\n' \
    "  Waspflow Federation needs Node.js 20 or newer, which this machine does not have." \
    "  Install it with your preferred method, then re-run this installer. Two common options:" \
    "" \
    "    Ubuntu/Debian (NodeSource):" \
    "      curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs" \
    "" \
    "    Any Linux, no root (nvm):" \
    "      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash" \
    "      . \"\$HOME/.nvm/nvm.sh\" && nvm install 22" \
    >&2
  exit 1
}

if ! command -v node >/dev/null 2>&1; then
  node_help
fi
node_major="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$node_major" -lt 20 ]; then
  warn "found Node.js $(node --version), but 20 or newer is required"
  node_help
fi

case "$(uname -s)" in
  Linux) ;;
  *) die "this installer currently supports Linux; on macOS use the Homebrew formula in packaging/brew (untested)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ;;
  *) die "this release currently supports x86_64 Linux only" ;;
esac

TMP_DIR="$(mktemp -d)"
deb_url="$(asset_url '_amd64.deb' 'waspflow-federation_amd64.deb' || true)"
tar_url="$(asset_url '_linux_amd64.tar.gz' 'waspflow-federation_linux_amd64.tar.gz' || true)"

# The .deb declares Depends: nodejs (>= 20) against the SYSTEM package. A
# machine whose Node comes from nvm or a tarball passes the runtime check
# above but cannot satisfy that dpkg dependency — attempting dpkg -i there
# half-installs the package (state iU), scares the user with dependency
# errors, and leaves apt nagging forever (found live on a fresh tester
# machine). Only take the .deb path when the system nodejs package itself
# satisfies the dependency; otherwise the portable bundle is the right
# install, not the fallback.
system_nodejs_satisfies_deb() {
  installed="$(dpkg-query -W -f '${Version}' nodejs 2>/dev/null)" || return 1
  [ -n "$installed" ] || return 1
  major="${installed#*:}"
  major="${major%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge 20 ]
}

if [ -n "$deb_url" ] && command -v dpkg >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && system_nodejs_satisfies_deb; then
  deb_file="$TMP_DIR/waspflow-federation.deb"
  say "Installing the Debian package..."
  download "$deb_url" "$deb_file"
  if sudo dpkg -i "$deb_file"; then
    say "Installed the Debian package."
  elif [ -n "$tar_url" ]; then
    warn "the Debian package could not be installed; using the portable bundle instead"
    # Never leave a half-installed (unconfigured) package behind to break
    # every later apt operation on the user's machine.
    sudo dpkg --purge waspflow-federation >/dev/null 2>&1 || true
    install_tarball "$tar_url"
  else
    sudo dpkg --purge waspflow-federation >/dev/null 2>&1 || true
    die "the Debian package could not be installed"
  fi
elif [ -n "$tar_url" ]; then
  if [ -n "$deb_url" ] && command -v dpkg >/dev/null 2>&1 && ! system_nodejs_satisfies_deb; then
    say "Your Node.js is not from the system package manager; using the portable bundle (no sudo needed)."
  fi
  install_tarball "$tar_url"
else
  die "no Linux Federation .deb or portable tarball was found in the latest release"
fi

# Only the tarball installs under $INSTALL_ROOT; the .deb owns /usr/bin.
if [ "$INSTALLED_VIA" = "tarball" ]; then
  case ":$PATH:" in
    *":$INSTALL_ROOT/bin:"*) ;;
    *) warn "$INSTALL_ROOT/bin is not on PATH; add it before opening a new shell" ;;
  esac
fi

say "Ready. Start the guided onboarding flow with: waspflow federation"
