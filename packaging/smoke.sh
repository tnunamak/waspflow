#!/usr/bin/env bash
# Build and exercise the .deb in plain Docker; Docker Sandboxes is not involved.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$package_dir/.." && pwd)"
package_version="${PACKAGE_VERSION:-0.1.0}"
clawmeter_bin="${CLAWMETER_BIN:-}"
deb_path="$package_dir/dist/waspflow-federation_${package_version}_amd64.deb"

[[ -n "$clawmeter_bin" ]] || {
  echo "CLAWMETER_BIN is required (for example: CLAWMETER_BIN=/usr/local/bin/clawmeter)" >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || { echo "missing required command: docker" >&2; exit 1; }

CLAWMETER_BIN="$clawmeter_bin" PACKAGE_VERSION="$package_version" "$package_dir/build.sh"
[[ -f "$deb_path" ]] || { echo "expected build artifact missing: $deb_path" >&2; exit 1; }

docker run --rm \
  -v "$repo_root:/source:ro" \
  -v "$package_dir/dist:/artifacts:ro" \
  -e "DEB_NAME=$(basename "$deb_path")" \
  ubuntu:24.04 \
  bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl systemd
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    dpkg -i "/artifacts/$DEB_NAME"

    waspflow federation --help | grep -F "usage: waspflow federation"
    test -x /usr/bin/waspflow-federation
    test -x /usr/bin/waspflow
    test -x /usr/lib/waspflow/waspflow-federation-tray
    test -x /usr/lib/waspflow/clawmeter
    test -f /usr/lib/waspflow/public/index.html
    test -f /usr/lib/systemd/user/waspflow-federation-daemon.service
    test -f /etc/xdg/autostart/waspflow-federation-tray.desktop
    if command -v systemd-analyze >/dev/null 2>&1; then
      systemd-analyze verify /usr/lib/systemd/user/waspflow-federation-daemon.service
    fi
  '

echo "package smoke passed: $deb_path"
