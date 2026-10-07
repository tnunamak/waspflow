#!/usr/bin/env bash
#
# resource-ledger.sh — append-only-ish inventory of resources a lane may clean.
#
# A lane may only remove a resource which this ledger identifies by an exact
# path and an explicit ownership receipt.  It deliberately has no discovery
# operation: in particular it never searches TMPDIR or /tmp for look-alikes.

resource_ledger_file() { printf '%s/resources.json\n' "$(lane_dir "$1")"; }

resource_ledger_register() {
  local lane="$1" kind="$2" path="$3" state="${4:-owned}" file tmp
  [[ "$kind" =~ ^[a-z][a-z0-9_-]*$ && "$path" == /* ]] || return 1
  case "$state" in owned|retained|transferred|unknown|released) ;; *) return 1 ;; esac
  file="$(resource_ledger_file "$lane")"
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$(mktemp "$(dirname "$file")/.resources.XXXXXX")" || return 1
  if [[ ! -f "$file" ]]; then printf '%s\n' '{"version":1,"resources":[]}' >"$file" || { rm -f "$tmp"; return 1; }; fi
  jq --arg kind "$kind" --arg path "$path" --arg state "$state" '
    .version = 1
    | .resources = ((.resources // []) | if type == "array" then . else [] end)
    | .resources |= map(select(.kind != $kind or .path != $path))
    | .resources += [{kind:$kind,path:$path,state:$state,owned:($state == "owned"),recorded_at:now}]
  ' "$file" >"$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

resource_ledger_register_if_unknown() {
  local lane="$1" kind="$2" path="$3" state="${4:-owned}"
  [[ "$(resource_ledger_state "$lane" "$path")" != unknown ]] || resource_ledger_register "$lane" "$kind" "$path" "$state"
}

resource_ledger_owned_existing() {
  local lane="$1" file
  file="$(resource_ledger_file "$lane")"
  [[ -f "$file" ]] || return 0
  jq -r '.resources[]? | select(.state == "owned") | [.kind, .path] | @tsv' "$file" 2>/dev/null \
    | while IFS=$'\t' read -r kind path; do [[ -e "$path" ]] && printf '%s:%s\n' "$kind" "$path"; done
}

resource_ledger_state() {
  local lane="$1" path="$2" file
  file="$(resource_ledger_file "$lane")"
  [[ -f "$file" ]] || { printf 'unknown\n'; return 0; }
  jq -r --arg path "$path" '([.resources[]? | select(.path == $path) | .state] | last) // "unknown"' "$file" 2>/dev/null || printf 'unknown\n'
}

resource_ledger_mark() {
  local lane="$1" path="$2" state="$3" file tmp
  case "$state" in retained|transferred|unknown|released) ;; *) return 1 ;; esac
  file="$(resource_ledger_file "$lane")"; [[ -f "$file" ]] || return 1
  tmp="$(mktemp "$(dirname "$file")/.resources.XXXXXX")" || return 1
  jq --arg path "$path" --arg state "$state" '
    .resources |= map(if .path == $path then .state = $state | .owned = false | .updated_at = now else . end)
  ' "$file" >"$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Return a JSON object for receipts.  Unknown and transferred entries stay
# visible; only an exact owned entry may later be released by cleanup.
resource_ledger_inventory() {
  local lane="$1" file
  file="$(resource_ledger_file "$lane")"
  [[ -f "$file" ]] || { printf '%s\n' '{"owned":[],"retained":[],"transferred":[],"unknown":[],"released":[]}'; return 0; }
  jq '{owned:[.resources[]? | select(.state == "owned")], retained:[.resources[]? | select(.state == "retained")], transferred:[.resources[]? | select(.state == "transferred")], unknown:[.resources[]? | select(.state == "unknown")], released:[.resources[]? | select(.state == "released")]}' "$file"
}
