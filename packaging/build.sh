#!/usr/bin/env bash
# Build Linux artifacts from an explicit, inspectable staging tree.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$package_dir/.." && pwd)"
stage_dir="$package_dir/stage"
dist_dir="$package_dir/dist"
package_version="${PACKAGE_VERSION:-0.1.0}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

[[ "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || {
  echo "PACKAGE_VERSION must be a semver value such as 0.1.0, got: $package_version" >&2
  exit 1
}
require_command go

nfpm_package() {
  local packager="$1"
  local target="$2"

  if command -v nfpm >/dev/null 2>&1; then
    (
      cd "$package_dir"
      PACKAGE_VERSION="$package_version" nfpm package \
        --config nfpm.yaml \
        --packager "$packager" \
        --target "$target"
    )
    return
  fi

  require_command docker
  # Keep the release toolchain hermetic when a developer does not have nFPM.
  # The bind mount lets nFPM see the same relative paths declared in nfpm.yaml.
  docker run --rm --user "$(id -u):$(id -g)" \
    -e PACKAGE_VERSION="$package_version" \
    -v "$package_dir:/work" \
    -w /work \
    goreleaser/nfpm \
    package --config nfpm.yaml --packager "$packager" --target "$target"
}

rm -rf "$stage_dir"
mkdir -p "$stage_dir/usr/lib/waspflow/bin" \
  "$stage_dir/usr/lib/waspflow/lib" \
  "$stage_dir/usr/lib/waspflow/public" \
  "$stage_dir/usr/bin" \
  "$dist_dir"

# Keep the package scope explicit: only Federation entry points and their Node
# modules are staged, never the rest of the Waspflow control plane.
find "$repo_root/bin" -maxdepth 1 -type f -name 'waspflow-federation*' -print0 |
  xargs -0 -r -I{} install -m 0755 {} "$stage_dir/usr/lib/waspflow/bin/"
install -m 0644 "$repo_root"/lib/*.mjs "$stage_dir/usr/lib/waspflow/lib/"
install -m 0644 "$repo_root"/public/* "$stage_dir/usr/lib/waspflow/public/"

(cd "$repo_root/tray" && go build -trimpath -o "$stage_dir/usr/lib/waspflow/waspflow-federation-tray" ./cmd/waspflow-federation-tray)

# nFPM preserves source directory modes. Do not let a developer's permissive
# umask turn application paths into group-writable package paths.
chmod -R go-w "$stage_dir"
chmod go-w "$package_dir/assets/waspflow-federation-daemon.service" "$package_dir/assets/waspflow-federation-tray.desktop"
find "$stage_dir" -type d -exec chmod 0755 {} +

cat >"$stage_dir/usr/bin/waspflow-federation" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  node /usr/lib/waspflow/bin/waspflow-federation "$@" || status=$?
  # The source CLI currently emits its usage with status 1. A package command's
  # explicit help invocation should still be successful.
  [ "${status:-0}" -eq 1 ] && exit 0
  exit "${status:-0}"
fi

exec node /usr/lib/waspflow/bin/waspflow-federation "$@"
EOF
chmod 0755 "$stage_dir/usr/bin/waspflow-federation"

cat >"$stage_dir/usr/bin/waspflow" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = "federation" ]; then
  shift
  exec /usr/bin/waspflow-federation "$@"
fi

echo "This waspflow-federation package provides only: waspflow federation ..." >&2
exit 64
EOF
chmod 0755 "$stage_dir/usr/bin/waspflow"

# The nFPM target stays relative to packaging/ so the same config works for a
# local executable and the Docker fallback (where this directory is /work).
nfpm_package deb "dist/waspflow-federation_${package_version}_amd64.deb"
# nFPM does not provide a portable tar packager. Archive the same staged
# filesystem tree, which keeps the fallback payload byte-for-byte aligned with
# the Debian package's runtime.
tar -C "$stage_dir" -czf "$dist_dir/waspflow-federation_${package_version}_linux_amd64.tar.gz" usr

printf 'built:\n  %s\n  %s\n' \
  "$dist_dir/waspflow-federation_${package_version}_amd64.deb" \
  "$dist_dir/waspflow-federation_${package_version}_linux_amd64.tar.gz"
