# A catalog level outside the sort order must survive generated output.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-effort-XXXXXX")"
  trap '__rc=$?; { (( __rc == 0 )) && rm -rf "$fixture"; }' EXIT
  mkdir -p "$fixture/scripts"
  cp "$root/scripts/gen_effort_whitelists.py" "$fixture/scripts/"
  printf '%s\n' '{"surfaces":[{"provider":"openai","valid_efforts":["low","future-level"]},{"provider":"xai","valid_efforts":["minimal","new-level"]}]}' >"$fixture/catalog.json"
  MODEL_CATALOG_CAPABILITIES="$fixture/catalog.json" python3 "$fixture/scripts/gen_effort_whitelists.py" >"$fixture/stdout" 2>"$fixture/stderr"
  grep -qx 'WASPFLOW_EFFORTS_CODEX="low|future-level"' "$fixture/lib/generated/effort-whitelists.sh"
  grep -qx 'WASPFLOW_EFFORTS_GROK="minimal|new-level"' "$fixture/lib/generated/effort-whitelists.sh"
  grep -q 'future-level, new-level' "$fixture/stderr"
)
