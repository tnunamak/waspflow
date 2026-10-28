#!/usr/bin/env bash
# selection.sh — Selection v1 policy facts and the non-interactive gate.
# This module decides only whether a policy arm may be selected. Provider
# preflight and Phase 1's live-negative validation remain their own boundaries.

selection_gate_mode() {
  local mode="${WASPFLOW_SELECTION_GATE:-warn}"
  case "$mode" in off|warn|enforce) printf '%s\n' "$mode" ;; *) die "selection: WASPFLOW_SELECTION_GATE must be off, warn, or enforce (got: $mode)" ;; esac
}

# Total fact functions. Their compact JSON result keeps callers from turning
# cumulative facts back into an exclusive decision ladder.
selection_included() { [[ "$1" != unavailable ]] && printf 'true\n' || printf 'false\n'; }
selection_warnings() {
  local availability="$1" bar="$2" edge="$3" family="$4"
  jq -cn --arg a "$availability" --arg b "$bar" --arg e "$edge" --arg f "$family" \
    '[if $a == "unknown" then "availability_unknown" else empty end,
      if $e == "deprecated_by_edge" then "deprecated_by_edge" else empty end,
      if $b == "fails" then "below_bar:" + $f else empty end]'
}
selection_auto_selectable() {
  local availability="$1" bar="$2" edge="$3" stats="$4" quota_filtered="$5" ack="$6" own_fallback="$7"
  [[ "$availability" == available && "$quota_filtered" != true && "$bar" != fails && "$own_fallback" == true ]] || { printf 'false\n'; return; }
  [[ "$edge" != deprecated_by_edge || "$ack" == true ]] && printf 'true\n' || printf 'false\n'
}
selection_disposition() {
  local availability="$1" bar="$2" edge="$3" stats="$4" quota_filtered="$5" ack="$6" own_fallback="$7" family="$8"
  jq -cn --argjson included "$(selection_included "$availability")" \
    --argjson warnings "$(selection_warnings "$availability" "$bar" "$edge" "$family")" \
    --argjson auto_selectable "$(selection_auto_selectable "$availability" "$bar" "$edge" "$stats" "$quota_filtered" "$ack" "$own_fallback")" \
    '{included:$included,warnings:$warnings,auto_selectable:$auto_selectable}'
}

selection_is_subscription_billing() {
  case "$1" in chatgpt_subscription|subscription_env_heuristic|oauth_env_heuristic|oauth_quota_heuristic) return 0 ;; *) return 1 ;; esac
}

# Empty output means quota does not block selection. Keep the reason and the
# boolean gate on the same decision path so diagnostics describe the actual veto.
selection_quota_block_reason() {
  local billing="$1" quota="$2" scope="$3" provider="${4:-}" model="${5:-}" path fetched now reason pool
  path="$(jq -r '.path // "unknown"' <<<"$billing" 2>/dev/null)"
  if [[ -z "$path" || "$path" == unknown || "$path" == scoped_unknown ]]; then
    reason="$(jq -r '.detail // empty' <<<"$billing" 2>/dev/null)"
    printf 'billing path is unknown%s\n' "${reason:+: $reason}"
    return 0
  fi
  selection_is_subscription_billing "$path" || return 0
  [[ "$scope" != mismatched ]] || { printf 'quota scope does not match provider\n'; return; }
  reason="$(jq -r '
    if .state == "stale" or .stale == true then "quota observation is stale"
    elif .state != "ok" then (.reason | if type == "string" and length > 0 then . else "quota observation is not ok" end)
    elif (.observation | type != "object") or (.observation.windows | type != "array" or length == 0) then "quota observation has no windows"
    elif any(.observation.windows[]; .utilization_pct | type != "number" or . < 0) then "quota observation has invalid utilization"
    else "" end' <<<"$quota" 2>/dev/null)" || reason="invalid quota JSON"
  [[ -z "$reason" ]] || { printf '%s\n' "$reason"; return; }
  fetched="$(jq -r '.observation.fetched_at // empty' <<<"$quota")"
  [[ -n "$fetched" ]] || { printf 'quota fetched_at is missing\n'; return; }
  now="$(date -u +%s)"
  local fetched_epoch
  # Python is a required dependency; ISO parsing also works with BSD date.
  fetched_epoch="$(python3 -c '
from datetime import datetime
import sys
value = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
if value.tzinfo is None:
    raise ValueError("quota timestamp requires a timezone")
print(int(value.timestamp()))
' "$fetched" 2>/dev/null)" || fetched_epoch=""
  [[ -n "$fetched_epoch" ]] || { printf 'quota fetched_at is invalid\n'; return; }
  (( now - fetched_epoch >= 0 )) || { printf 'quota fetched_at is in the future\n'; return; }
  (( now - fetched_epoch <= 600 )) || { printf 'quota observation is older than 600 seconds\n'; return; }
  if [[ "$path" == oauth_quota_heuristic || "$provider" == antigravity ]]; then
    case "$model" in
      gemini-*) pool='7d Gemini' ;;
      claude-*|gpt-*) pool='7d Claude + GPT' ;;
      *) printf 'quota pool is unknown for selected model\n'; return ;;
    esac
    if ! jq -e --arg pool "$pool" 'any(.observation.windows[]; .name == $pool)' >/dev/null <<<"$quota"; then
      printf 'quota observation has no window for selected model pool\n'
      return
    fi
    if jq -e --arg pool "$pool" 'any(.observation.windows[]; .name == $pool and .utilization_pct >= 100)' >/dev/null <<<"$quota"; then
      printf 'selected model quota pool is exhausted\n'
    fi
    return 0
  fi
  # A reset credit is not headroom until a reset has actually happened.
  if jq -e 'all(.observation.windows[]; .utilization_pct >= 100)' >/dev/null <<<"$quota"; then
    printf 'all quota windows are exhausted\n'
  fi
  return 0
}

# Automatic selection needs fresh current utilization for the applicable billing
# path. Forecasts describe projected window-end usage, not current headroom,
# and do not gate a run. Unknown quota is filtered; explicit choices remain escapes.
selection_quota_filtered() {
  local reason
  reason="$(selection_quota_block_reason "$1" "$2" "$3" "${4:-}" "${5:-}")"
  [[ -n "$reason" ]] && printf 'true\n' || printf 'false\n'
}

selection_observe_availability() {
  local provider="$1" model="$2" scope="$3" raw header source valid listed=false
  [[ -n "$model" ]] || { jq -cn --arg p "$provider" '{schema_version:1,provider:$p,model:"",state:"not_applicable",evidence_source:"none",query_scope:"not_applicable",observed_at:null,detail:""}'; return; }
  raw="$("${provider}_valid_models" 2>/dev/null || true)"
  header="$(head -n 1 <<<"$raw")"; source="${header#source=}"
  case "$header" in source=live_query|source=local_cache|source=non_enumerable|source=none) ;; *) source=none; raw="" ;; esac
  valid="$(tail -n +2 <<<"$raw")"; grep -qxF "$model" <<<"$valid" && listed=true
  local state=unknown
  [[ "$listed" == true ]] && state=available
  [[ "$source" == live_query && "$scope" == default && "$listed" != true ]] && state=unavailable
  jq -cn --arg p "$provider" --arg m "$model" --arg state "$state" --arg source "$source" --arg scope "$scope" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1,provider:$p,model:$m,state:$state,evidence_source:$source,query_scope:(if $source == "none" or $source == "non_enumerable" then "not_applicable" else $scope end),observed_at:$at,detail:""}'
}

selection_edge_label() {
  local provider="$1" model="$2"
  [[ -n "${OPS_POLICY_JSON:-}" ]] || ops_load
  jq -r --arg p "$provider" --arg m "$model" '
    (.preferred_over_live // []) as $edges |
    if any($edges[]; .over.provider == $p and .over.model == $m) then "deprecated_by_edge"
    elif any($edges[]; .prefer.provider == $p and .prefer.model == $m) then "preferred" else "none" end' <<<"$OPS_POLICY_JSON"
}

selection_policy_validate() {
  local policy="$1" edges cycle
  edges="$(jq -c '.preferred_over_live // []' <<<"$policy")"
  # DFS is intentionally performed in jq so policy validation remains a pure
  # load-time operation and failure names the complete closing path.
  cycle="$(jq -r '
    def key($x): $x.provider + "/" + $x.model;
    (.preferred_over_live // []) as $e |
    [ $e[] | {from:(key(.prefer)),to:(key(.over))} ] as $g |
    def walk($node; $path):
      if ($path | index($node)) != null then ($path[($path|index($node)):] + [$node])
      else first($g[] | select(.from == $node) | walk(.to; $path + [$node])) // empty end;
    first($g[] | walk(.from; [])) // empty' <<<"$policy" 2>/dev/null || true)"
  [[ -z "$cycle" ]] || die "ops: preferred_over cycle: $(tr '\n' ' ' <<<"$cycle" | sed 's/ $//')"
}

selection_menu() {
  ops_load
  printf 'selection required: choose an operating point (unranked across task families):\n' >&2
  jq -r '.operating_points | group_by(.task_family)[] | "  [" + .[0].task_family + "]", (.[] | "    \(.id)  constraint=\(.constraint_family) fallback=\(.expands_to.provider)/\(.expands_to.model // "(provider default)")")' <<<"$OPS_POLICY_JSON" >&2
  printf 'other models: any --model <id> proceeds; <provider> enumeration: waspflow doctor --models\n' >&2
  printf 'escapes: --op <id>; --model <id>; --accept-provider-default\n' >&2
}

selection_prepare_op() {
  # args: op provider model scope billing ack
  local op="$1" provider="$2" model="$3" scope="$4" billing="$5" ack="$6" row availability quota edge bar family disposition
  row="$(ops_get_point "$op")"; family="$(jq -r '.task_family' <<<"$row")"; bar=unratified
  availability="$(selection_observe_availability "$provider" "$model" "$scope")"
  quota="$(quota_observation_v1 "$provider")"
  edge="$(selection_edge_label "$provider" "$model")"
  SELECTION_QUOTA_BLOCK_REASON="$(selection_quota_block_reason "$billing" "$quota" "$scope" "$provider" "$model")"
  SELECTION_QUOTA_FILTERED=false
  [[ -z "$SELECTION_QUOTA_BLOCK_REASON" ]] || SELECTION_QUOTA_FILTERED=true
  disposition="$(selection_disposition "$(jq -r '.state' <<<"$availability")" "$bar" "$edge" none "$SELECTION_QUOTA_FILTERED" "$ack" true "$family")"
  SELECTION_AVAILABILITY="$availability"; SELECTION_QUOTA_OBSERVATION="$quota"; SELECTION_DISPOSITION="$disposition"
  export SELECTION_AVAILABILITY SELECTION_QUOTA_OBSERVATION SELECTION_QUOTA_FILTERED SELECTION_QUOTA_BLOCK_REASON SELECTION_DISPOSITION
}

selection_emit_warnings() {
  local disposition="$1" warning
  while IFS= read -r warning; do
    case "$warning" in
      availability_unknown)
        warn "selection: availability unknown; provider model availability could not be verified. Continuing with the selected model; the provider CLI will validate it."
        ;;
      '') ;;
      *) warn "selection: $warning" ;;
    esac
  done < <(jq -r '.warnings[]' <<<"$disposition")
}

selection_gate_op() {
  # args: op provider model scope billing ack auto
  local op="$1" provider="$2" model="$3" scope="$4" billing="$5" ack="$6" auto="$7" causes
  selection_prepare_op "$op" "$provider" "$model" "$scope" "$billing" "$ack"
  [[ "$(jq -r '.auto_selectable' <<<"$SELECTION_DISPOSITION")" == true ]] && return 0
  causes="$(jq -r --arg quota "$SELECTION_QUOTA_FILTERED" '(.warnings + [if $quota == "true" then "quota_filtered" else empty end]) | join(", ")' <<<"$SELECTION_DISPOSITION")"
  [[ -n "$causes" ]] || causes=not_auto_selectable
  err "selection required: op '$op' fallback provider=$provider availability_state=$(jq -r '.state' <<<"$SELECTION_AVAILABILITY") is not auto-selectable ($causes)"
  if [[ "$SELECTION_QUOTA_FILTERED" == true ]]; then
    err "  provider=$provider quota_state=$(jq -r '.state // "unknown"' <<<"$SELECTION_QUOTA_OBSERVATION") reason=$SELECTION_QUOTA_BLOCK_REASON"
  fi
  if [[ "$SELECTION_QUOTA_FILTERED" == true || "$(jq -r '.warnings | index("availability_unknown") != null' <<<"$SELECTION_DISPOSITION")" == true ]]; then
    err "  retry: --model <id> or --accept-provider-default"
  fi
  if [[ "$(jq -r '.warnings | index("deprecated_by_edge") != null' <<<"$SELECTION_DISPOSITION")" == true ]]; then
    err "  retry: --op $op --auto --ack-deprecated"
  fi
  return 5
}

# preferred_over edges are point-in-time judgments and are EXPECTED to rot when
# a newer model family ships (the gpt-5.4-mini→luna edge will itself go stale
# the day a post-5.6 family GAs). This surfaces that instead of letting the
# edge decay into a silent deny-list entry. Catalog is enrichment, never a
# gate: no catalog → no output, and this never blocks anything. Heuristic:
# an edge is stale-suspect when a GA model exists whose family shares the
# prefer-model family's alphabetic prefix but version-sorts newer.
# Args: policy_json catalog_models_json_path. Emits warn lines; rc 0 always.
selection_edge_staleness_report() {
  local policy="$1" catalog="$2"
  [[ -r "$catalog" ]] || return 0
  jq -r --slurpfile cat "$catalog" '
    def fam_prefix: sub("[-.0-9]+$"; "");
    def fam_ver: capture("(?<v>[0-9][-.0-9]*)$") | .v;
    ($cat[0].models // []) as $models |
    (.preferred_over_live // .preferred_over // []) | .[] |
    select((.ratified // true) == true) | . as $edge |
    .prefer.model as $pm |
    ($models[] | select(.id == $pm) | .family // empty) as $pfam |
    ($pfam | fam_prefix) as $prefix |
    [ $models[] | select(.status == "ga") | .family // empty
      | select(startswith($prefix)) | select(. != null) ] | unique as $fams |
    ($fams | sort_by(fam_ver | split(".") | map(tonumber? // 0)) | last) as $newest_fam |
    select($pfam != $newest_fam) |
    "  [warn] policy edge \($pm) over \($edge.over.model // "?") may be STALE: newest GA family in the \($prefix) lineage is \($newest_fam), prefer-side is \($pfam). Re-ratify or retire the edge."
  ' <<<"$policy" 2>/dev/null || true
}
