# Headless Grok must preserve supported effort and reject unsupported effort.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-grok-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  source "$root/lib/exec.sh"
  grok() { printf '%s\n' "$@" >"$fixture/argv"; printf 'answer\n'; }
  for effort in none minimal low medium high xhigh max; do
    _exec_grok "$fixture" "" "$effort" task "$fixture/output"
    expected="$(printf '%s\n' --effort "$effort")"
    grep -A1 -x -- --effort "$fixture/argv" >"$fixture/effort"
    [[ "$(cat "$fixture/effort")" == "$expected" ]]
  done
  rm -f "$fixture/argv"
  if _exec_grok "$fixture" "" ultra task "$fixture/output"; then
    echo 'unsupported Grok effort launched' >&2; exit 1
  fi
  [[ ! -e "$fixture/argv" ]]
)
