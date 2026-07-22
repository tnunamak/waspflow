#!/usr/bin/env bash
# Build and exercise the .deb in plain Docker; Docker Sandboxes is not involved.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$package_dir/.." && pwd)"
package_version="${PACKAGE_VERSION:-0.1.0}"
deb_path="$package_dir/dist/waspflow-federation_${package_version}_amd64.deb"

command -v docker >/dev/null 2>&1 || { echo "missing required command: docker" >&2; exit 1; }

PACKAGE_VERSION="$package_version" "$package_dir/build.sh"
[[ -f "$deb_path" ]] || { echo "expected build artifact missing: $deb_path" >&2; exit 1; }

docker run --rm \
  -v "$repo_root:/source:ro" \
  -v "$package_dir/dist:/artifacts:ro" \
  -e "DEB_NAME=$(basename "$deb_path")" \
  ubuntu:24.04 \
  bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    dpkg -i "/artifacts/$DEB_NAME"

    waspflow federation --help 2>&1 | grep -F "usage: waspflow federation"
    test -x /usr/bin/waspflow-federation
    test -x /usr/bin/waspflow
    test -x /usr/lib/waspflow/waspflow-federation-tray
    test -f /usr/lib/waspflow/public/index.html
    test -f /usr/lib/systemd/user/waspflow-federation-daemon.service
    test -f /etc/xdg/autostart/waspflow-federation-tray.desktop
    grep -Fx "ExecStart=/usr/bin/waspflow-federation daemon" /usr/lib/systemd/user/waspflow-federation-daemon.service

    # Doctor intentionally remains detect-and-guide when docker-sbx is absent;
    # its nonzero status must not hide the actionable preflight output.
    if waspflow federation doctor > /tmp/doctor.out 2>&1; then
      echo "doctor unexpectedly passed without docker-sbx" >&2
      exit 1
    fi
    grep -F "Sandbox install preflight" /tmp/doctor.out

    # The no-argument command is the installed first-run journey. It starts
    # the daemon through `ui`, prints the authenticated localhost URL, and the
    # server must return the packaged HTML on that URL.
    export WASPFLOW_FEDERATION_HOME=/tmp/federation-home
    waspflow federation > /tmp/first-run.out 2>&1
    grep -F "Paste the invite" /tmp/first-run.out
    for attempt in $(seq 1 30); do
      test -f "$WASPFLOW_FEDERATION_HOME/daemon.json" && break
      sleep 0.1
    done
    test -f "$WASPFLOW_FEDERATION_HOME/daemon.json"
    ui_url="$(sed -n "s|.*\(http://127.0.0.1:[0-9][0-9]*/?token=[^ ]*\).*|\1|p" /tmp/first-run.out | tail -n 1)"
    test -n "$ui_url"
    curl -fsS "$ui_url" -o /tmp/federation-ui.html
    grep -F "Waspflow Federation" /tmp/federation-ui.html
    kill "$(node -e "console.log(require(process.env.WASPFLOW_FEDERATION_HOME + '/daemon.json').pid)")"
  '

echo "package smoke passed: $deb_path"
