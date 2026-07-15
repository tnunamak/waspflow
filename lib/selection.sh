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
  case "$1" in chatgpt_subscription|subscription_env_heuristic|oauth_env_heuristic) return 0 ;; *) return 1 ;; esac
}

# True only for the five-condition quota predicate in SELECTION_V1. A malformed
# observation is simply insufficient evidence, never a selection block.
selection_quota_filtered() {
  local billing="$1" quota="$2" scope="$3" path fetched now
  path="$(jq -r '.path // "unknown"' <<<"$billing" 2>/dev/null)"
  selection_is_subscription_billing "$path" || { printf 'false\n'; return; }
  [[ "$scope" != mismatched ]] || { printf 'false\n'; return; }
  jq -e '.state == "ok" and (.observation | type == "object") and (.observation.windows | type == "array" and length > 0) and all(.observation.windows[]; (.utilization_pct | type == "number") and (.utilization_pct >= 100)) and ((.observation.reset_credits_available == null) or (.observation.reset_credits_available == 0))' >/dev/null <<<"$quota" 2>/dev/null || { printf 'false\n'; return; }
  fetched="$(jq -r '.observation.fetched_at // empty' <<<"$quota")"
  now="$(date -u +%s)"
  local fetched_epoch
  fetched_epoch="$(date -u -d "$fetched" +%s 2>/dev/null || true)"
  [[ -n "$fetched_epoch" && $((now - fetched_epoch)) -ge 0 && $((now - fetched_epoch)) -le 600 ]] && printf 'true\n' || printf 'false\n'
}

selection_observe_availability() {
  local provider="$1" model="$2" scope="$3" raw header source valid listed=false
  [[ -n "$model" ]] || { jq -cn --arg p "$provider" '{schema_version:1,provider:$p,model:"",state:"not_applicable",evidence_source:"none",query_scope:"not_applicable",observed_at:null,detail:""}'; return; }
  raw="$("${provider}_valid_models" 2>/dev/null || true)"
  header="$(head -n 1 <<<"$raw")"; source="${header#source=}"
  case "$header" in source=live_query|source=local_cache|source=non_enumerable|source=none) ;; *) source=none ;; esac
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
    .preferred_over_live // [] as $edges |
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
  jq -r 'group_by(.task_family)[] | "  [" + .[0].task_family + "]", (.[] | "    \(.id)  constraint=\(.constraint_family) fallback=\(.expands_to.provider)/\(.expands_to.model // "(provider default)") quota=unknown")' <<<"$OPS_POLICY_JSON" >&2
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
  disposition="$(selection_disposition "$(jq -r '.state' <<<"$availability")" "$bar" "$edge" none "$(selection_quota_filtered "$billing" "$quota" "$scope")" "$ack" true "$family")"
  SELECTION_AVAILABILITY="$availability"; SELECTION_QUOTA_OBSERVATION="$quota"; SELECTION_QUOTA_FILTERED="$(selection_quota_filtered "$billing" "$quota" "$scope")"; SELECTION_DISPOSITION="$disposition"
  export SELECTION_AVAILABILITY SELECTION_QUOTA_OBSERVATION SELECTION_QUOTA_FILTERED SELECTION_DISPOSITION
}

selection_emit_warnings() {
  local disposition="$1" warning
  while IFS= read -r warning; do [[ -z "$warning" ]] || warn "selection: $warning"; done < <(jq -r '.warnings[]' <<<"$disposition")
}

selection_gate_op() {
  # args: op provider model scope billing ack auto
  local op="$1" provider="$2" model="$3" scope="$4" billing="$5" ack="$6" auto="$7" causes
  selection_prepare_op "$op" "$provider" "$model" "$scope" "$billing" "$ack"
  [[ "$(jq -r '.auto_selectable' <<<"$SELECTION_DISPOSITION")" == true ]] && return 0
  causes="$(jq -r --arg quota "$SELECTION_QUOTA_FILTERED" '(.warnings + [if $quota == "true" then "quota_filtered" else empty end]) | join(", ")' <<<"$SELECTION_DISPOSITION")"
  [[ -n "$causes" ]] || causes=not_auto_selectable
  err "selection required: op '$op' fallback is not auto-selectable ($causes)"
  if [[ "$SELECTION_QUOTA_FILTERED" == true || "$(jq -r '.warnings | index("availability_unknown") != null' <<<"$SELECTION_DISPOSITION")" == true ]]; then
    err "  retry: --model <id> or --accept-provider-default"
  fi
  if [[ "$(jq -r '.warnings | index("deprecated_by_edge") != null' <<<"$SELECTION_DISPOSITION")" == true ]]; then
    err "  retry: --op $op --auto --ack-deprecated"
  fi
  return 5
}
