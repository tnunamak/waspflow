#!/usr/bin/env bash
# Regression coverage for bin/federation-detect-sbx, targeting a real defect
# found by owner UAT against a real sbx v0.35.0 install (2026-07-20): `sbx`
# has no `--version` FLAG ("ERROR: unknown flag: --version", exit 1); the
# real interface is the `version` SUBCOMMAND ("sbx version: vX.Y.Z <sha>",
# exit 0). The detector previously probed `sbx --version` and treated its
# nonzero exit as "not found on PATH" even though sbx was installed and
# working — a present-but-unknown-flag/subcommand result must never be read
# as absence.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
detector="$root/bin/federation-detect-sbx"
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

static_validate() {
  bash -n "$detector" 2>/dev/null || node --check "$detector"
  grep -Fq "'version'" "$detector"
  ! grep -Fq "'--version'" "$detector"
  echo "STATIC OK: detector probes the 'version' subcommand, not a '--version' flag"
}

# CORE REGRESSION: a stub that behaves exactly like real sbx v0.35.0 —
# rejects --version, accepts the version subcommand — must be reported PRESENT.
test_present_but_unknown_flag() {
  cat >"$stub_dir/sbx" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "ERROR: unknown flag: --version" >&2
  exit 1
fi
if [ "$1" = "version" ]; then
  echo "sbx version: v0.35.0 abc123def"
  exit 0
fi
echo "stub sbx: unsupported invocation: $*" >&2
exit 1
STUB
  chmod +x "$stub_dir/sbx"
  local out rc=0
  out="$(PATH="$stub_dir:$PATH" "$detector" 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || { echo "FAIL: present-but-unknown-flag sbx was reported unavailable (rc=$rc): $out" >&2; exit 1; }
  grep -qi "detected: version 0.35.0" <<<"$out" || { echo "FAIL: version 0.35.0 not reported: $out" >&2; exit 1; }
  echo "PASS: present-but-unknown-flag sbx (real v0.35.0 shape) is correctly detected as PRESENT"
}

# A binary that spawns and runs, but fails 'version' for some OTHER reason,
# must still be reported present (with a version-parse failure), never
# conflated with "not found on PATH".
test_present_but_broken() {
  cat >"$stub_dir/sbx" <<'STUB'
#!/bin/sh
echo "some unexpected daemon error" >&2
exit 1
STUB
  chmod +x "$stub_dir/sbx"
  local out rc=0
  out="$(PATH="$stub_dir:$PATH" "$detector" 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || { echo "FAIL: expected nonzero exit for unparseable version: rc=$rc" >&2; exit 1; }
  grep -qi "is on PATH but its version could not be parsed" <<<"$out" || { echo "FAIL: expected version-parse-failure message, got: $out" >&2; exit 1; }
  ! grep -qi "not found on PATH" <<<"$out" || { echo "FAIL: present-but-broken sbx was misreported as not found: $out" >&2; exit 1; }
  echo "PASS: present-but-broken sbx is reported as present with a version-parse failure, never as absent"
}

# Truly absent (ENOENT) must still report "not found on PATH".
test_truly_absent() {
  local node_dir; node_dir="$(dirname "$(command -v node)")"
  local out rc=0
  out="$(PATH="$node_dir" "$detector" 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || { echo "FAIL: expected nonzero exit for truly-absent sbx: rc=$rc" >&2; exit 1; }
  grep -qi "not found on PATH" <<<"$out" || { echo "FAIL: expected 'not found on PATH' message, got: $out" >&2; exit 1; }
  echo "PASS: truly-absent sbx (ENOENT) is correctly reported as not found"
}

static_validate
test_present_but_unknown_flag
test_present_but_broken
test_truly_absent
echo "federation-detect-sbx regression suite: ok"
