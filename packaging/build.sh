#!/usr/bin/env bash
# Build Linux .deb and .rpm artifacts from an explicit, inspectable staging tree.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$package_dir/.." && pwd)"
stage_dir="$package_dir/stage"
dist_dir="$package_dir/dist"
package_version="${PACKAGE_VERSION:-0.1.0}"
clawmeter_bin="${CLAWMETER_BIN:-}"

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
[[ -n "$clawmeter_bin" ]] || {
  echo "CLAWMETER_BIN is required (for example: CLAWMETER_BIN=/usr/local/bin/clawmeter)" >&2
  exit 1
}
[[ -f "$clawmeter_bin" && -x "$clawmeter_bin" ]] || {
  echo "CLAWMETER_BIN must name an executable file: $clawmeter_bin" >&2
  exit 1
}

require_command go
require_command nfpm

rm -rf "$stage_dir"
mkdir -p "$stage_dir/usr/lib/waspflow/bin" \
  "$stage_dir/usr/lib/waspflow/lib" \
  "$stage_dir/usr/lib/waspflow/public" \
  "$stage_dir/usr/bin" \
  "$dist_dir"

# Keep the package scope explicit: only the federation entry points and their
# Node modules are staged, never the rest of the Waspflow control plane.
find "$repo_root/bin" -maxdepth 1 -type f -name 'waspflow-federation*' -print0 |
  xargs -0 -r -I{} install -m 0755 {} "$stage_dir/usr/lib/waspflow/bin/"
install -m 0644 "$repo_root"/lib/*.mjs "$stage_dir/usr/lib/waspflow/lib/"
install -m 0644 "$repo_root"/public/* "$stage_dir/usr/lib/waspflow/public/"
install -m 0755 "$clawmeter_bin" "$stage_dir/usr/lib/waspflow/clawmeter"

(cd "$repo_root/tray" && go build -trimpath -o "$stage_dir/usr/lib/waspflow/waspflow-federation-tray" ./cmd/waspflow-federation-tray)

# nFPM preserves source directory modes. Do not let a developer's permissive
# umask turn application directories into group-writable package paths.
find "$stage_dir" -type d -exec chmod 0755 {} +

cat >"$stage_dir/usr/bin/waspflow-federation" <<'EOF'
#!/bin/sh
set -eu

# Keep the bundled helper available to the Federation process without adding a
# second public command or depending on a host-wide clawmeter installation.
PATH="/usr/lib/waspflow:${PATH}"
export PATH

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

# nFPM resolves `contents.src` relative to its working directory, not the
# config file. Keep the config's staging paths stable for callers in any cwd.
(
  cd "$package_dir"
  PACKAGE_VERSION="$package_version" nfpm package \
    --config nfpm.yaml \
    --packager deb \
    --target "$dist_dir/waspflow-federation_${package_version}_amd64.deb"
  PACKAGE_VERSION="$package_version" nfpm package \
    --config nfpm.yaml \
    --packager rpm \
    --target "$dist_dir/waspflow-federation-${package_version}-1.x86_64.rpm"
)

printf 'built:\n  %s\n  %s\n' \
  "$dist_dir/waspflow-federation_${package_version}_amd64.deb" \
  "$dist_dir/waspflow-federation-${package_version}-1.x86_64.rpm"
