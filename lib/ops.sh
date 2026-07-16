# ops.sh — thin Operating Point Resolver.
# Expands task-shaped --op ids to provider/model/effort/mode. Never ranks models.
# Policy is data (model-choice-policy pack); this file only resolves and prints cards.

ops_policy_path() {
  local p
  if [[ -n "${WASPFLOW_OPS_POLICY:-}" ]]; then
    p="$WASPFLOW_OPS_POLICY"
    [[ -f "$p" ]] || die "ops: WASPFLOW_OPS_POLICY not a file: $p"
    printf '%s\n' "$p"
    return 0
  fi
  if [[ -n "${DATA_PACKS_HOME:-}" ]]; then
    p="${DATA_PACKS_HOME}/model-choice-policy/operating-points.json"
    if [[ -f "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  fi
  p="${HOME}/.local/share/minnows-data/model-choice-policy/operating-points.json"
  if [[ -f "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  p="${WASPFLOW_ROOT}/data/model-choice-policy/operating-points.json"
  if [[ -f "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  die "ops: no operating-points.json found (set WASPFLOW_OPS_POLICY or install model-choice-policy data pack)"
}

ops_load() {
  OPS_POLICY_FILE="$(ops_policy_path)"
  OPS_POLICY_JSON="$(jq -c '
    .operating_points as $points |
    reduce $points[] as $op (.;
      if (($op.expands_to? != null) and ($op.fallback? != null) and ($op.expands_to != $op.fallback))
      then error("op " + $op.id + ": expands_to and fallback differ") else . end)
    | .operating_points |= map(.expands_to = (.expands_to // .fallback) | .requirements = ((.requirements // {}) + {ratified:(.requirements.ratified // false)}))
    | .preferred_over_live = [(.preferred_over // [])[] | select(.ratified == true)]
  ' "$OPS_POLICY_FILE" 2>&1)" || die "ops: cannot load policy: $OPS_POLICY_JSON"
  local unratified
  while IFS= read -r unratified; do
    [[ -z "$unratified" ]] || warn "ops: ignoring unratified preferred_over edge: $unratified"
  done < <(jq -r '(.preferred_over // [])[] | select(.ratified == false) | "\(.prefer.provider)/\(.prefer.model) > \(.over.provider)/\(.over.model)"' <<<"$OPS_POLICY_JSON")
  if declare -F selection_policy_validate >/dev/null; then selection_policy_validate "$OPS_POLICY_JSON"; fi
  # A same-arm edge is harmless in authored policy but must not become a
  # no-op escalation.  Retain the authored order and warn at load time; the
  # runtime still compares a target to the lane's persisted arm.
  while IFS=$'\t' read -r source target; do
    [[ -n "$source" && -n "$target" ]] || continue
    warn "ops: skipping structurally same-arm escalation edge: $source -> $target"
  done < <(jq -r '
    .operating_points as $ops |
    $ops[] as $source |
    ($source.expands_to) as $from |
    (($source.fallback_ladder // $source.escalate_to // [])[]) as $target |
    ($ops[] | select(.id == $target) | .expands_to) as $to |
    select($to != null and $from.provider == $to.provider and ($from.model // "") == ($to.model // "") and ($from.effort // "") == ($to.effort // "") and ($from.mode // "standard") == ($to.mode // "standard")) |
    "\($source.id)\t\($target)"' <<<"$OPS_POLICY_JSON")
  export OPS_POLICY_FILE
}

# Effective escalation ladder for an op.  This owns the policy-facing rules;
# callers decide which candidate is distinct from a concrete persisted arm.
# Emits compact rows {id,arm} in authored order.
ops_effective_ladder() {
  local op="$1"
  ops_get_point "$op" >/dev/null
  ops_load
  jq -c --arg op "$op" '
    .operating_points as $ops |
    ($ops[] | select(.id == $op)) as $source |
    ($source.fallback_ladder // $source.escalate_to // [])[] as $id |
    ($ops[] | select(.id == $id)) as $target |
    select($target != null) |
    select(($target.expands_to.provider != $source.expands_to.provider) or
           (($target.expands_to.model // "") != ($source.expands_to.model // "")) or
           (($target.expands_to.effort // "") != ($source.expands_to.effort // "")) or
           (($target.expands_to.mode // "standard") != ($source.expands_to.mode // "standard"))) |
    {id:$id,arm:$target.expands_to}' <<<"$OPS_POLICY_JSON"
}

ops_arm_json() {
  local op="$1"
  jq -c '.expands_to' <<<"$(ops_get_point "$op")"
}

ops_jq() {
  ops_load
  jq -c "$@" <<<"$OPS_POLICY_JSON"
}

ops_get_point() {
  local id="$1"
  ops_load
  local row
  row="$(jq -c --arg id "$id" '.operating_points[] | select(.id == $id)' <<<"$OPS_POLICY_JSON")"
  [[ -n "$row" ]] || die "ops: unknown operating point '$id' (try: waspflow ops list)"
  printf '%s\n' "$row"
}

# Print a compact decision card (terminal-friendly).
ops_print_card() {
  local row="$1"
  jq -r '
    "\(.id)",
    "Task: \(.task_family)",
    "Constraint: \(.constraint_family)",
    "",
    "Runs:",
    "  provider: \(.expands_to.provider)",
    "  model: \(.expands_to.model // "(provider default)")",
    "  effort: \(.expands_to.effort // "(unset)")",
    "  mode: \(.expands_to.mode // .expands_to.service_tier // "standard")",
    "",
    "Decision signal:",
    "  Frontier: \(.frontier_assumption.frontier_status // "unknown")",
    "  Dollar cost: \(.frontier_assumption.cost_basis // "?")",
    "  Quota pressure: \(.frontier_assumption.quota_basis // "?")",
    "  Strength: \(.frontier_assumption.expected_strength // "?")",
    "  Evidence: \(.frontier_assumption.evidence_confidence // "?")",
    "",
    "Use when:",
    ((.use_when // []) | map("  - \(.)") | join("\n")),
    "",
    "Avoid when:",
    ((.avoid_when // []) | map("  - \(.)") | join("\n")),
    "",
    "Escalate to: \((.escalate_to // []) | join(", ") | if . == "" then "(none)" else . end)",
    "De-escalate to: \((.deescalate_to // []) | join(", ") | if . == "" then "(none)" else . end)",
    "",
    "Known gaps:",
    ((.known_gaps // []) | if length == 0 then "  (none)" else map("  - \(.)") | join("\n") end),
    "",
    "Evidence refs: \((.evidence_refs // []) | join(", "))",
    "Override policy: \(.override_policy // "explicit_flags_win")"
  ' <<<"$row"
}

cmd_ops() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list)    ops_list "$@" ;;
    explain) ops_explain "$@" ;;
    resolve) ops_resolve "$@" ;;
    path)    ops_policy_path ;;
    -h|--help|help|"")
      cat <<'EOF'
waspflow ops — operating-point resolver (not a model picker)

  ops list [--task FAMILY] [--constraint FAMILY]
  ops explain <op-id>
  ops resolve <op-id> [--json]
  ops path

Doctrine: task-shaped operating points expand to explicit provider/model/effort/mode.
No silent auto-routing. Raw --provider/--model/--effort always win over --op.
EOF
      ;;
    *) die "ops: unknown subcommand '$sub' (list|explain|resolve|path)" ;;
  esac
}

ops_list() {
  local task="" constraint=""
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --task) task="${2:-}"; shift 2 ;;
      --constraint) constraint="${2:-}"; shift 2 ;;
      -h|--help) cmd_ops help; return 0 ;;
      *) die "ops list: unknown option '$1'" ;;
    esac
  done
  ops_load
  log "policy: $OPS_POLICY_FILE"
  jq -r --arg t "$task" --arg c "$constraint" '
    .operating_points[]
    | select(($t == "" or .task_family == $t) and ($c == "" or .constraint_family == $c))
    | [
        .id,
        .task_family,
        .constraint_family,
        .expands_to.provider,
        (.expands_to.model // "-"),
        (.expands_to.effort // "-"),
        (.frontier_assumption.frontier_status // "?"),
        (.frontier_assumption.evidence_confidence // "?")
      ] | @tsv
  ' <<<"$OPS_POLICY_JSON" \
    | awk -F'\t' 'BEGIN{
        printf "%-24s %-16s %-16s %-8s %-18s %-8s %-28s %s\n",
          "OP","TASK","CONSTRAINT","PROV","MODEL","EFFORT","FRONTIER","EVIDENCE"
      }
      { printf "%-24s %-16s %-16s %-8s %-18s %-8s %-28s %s\n", $1,$2,$3,$4,$5,$6,$7,$8 }'
}

ops_explain() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "ops explain: need <op-id>"
  local row
  row="$(ops_get_point "$id")"
  ops_load
  log "policy: $OPS_POLICY_FILE  catalog_ref: $(jq -r '.catalog_ref // empty' <<<"$OPS_POLICY_JSON")"
  ops_print_card "$row"
}

ops_resolve() {
  local id="" json=0
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --json) json=1; shift ;;
      -h|--help) die "usage: ops resolve <op-id> [--json]" ;;
      *)
        if [[ -z "$id" ]]; then id="$1"; shift
        else die "ops resolve: unexpected '$1'"
        fi
        ;;
    esac
  done
  [[ -n "$id" ]] || die "ops resolve: need <op-id>"
  local row
  row="$(ops_get_point "$id")"
  ops_load
  if [[ "$json" -eq 1 ]]; then
    local selection_disposition='{"included":true,"warnings":[],"auto_selectable":true}'
    if declare -F selection_disposition >/dev/null; then
      local fallback_provider fallback_model fallback_edge fallback_family
      fallback_provider="$(jq -r '.expands_to.provider // empty' <<<"$row")"
      fallback_model="$(jq -r '.expands_to.model // empty' <<<"$row")"
      fallback_edge="$(selection_edge_label "$fallback_provider" "$fallback_model")"
      fallback_family="$(jq -r '.task_family // "unknown"' <<<"$row")"
      selection_disposition="$(selection_disposition unknown unratified "$fallback_edge" none false false true "$fallback_family")"
    fi
    jq -n \
      --argjson op "$row" \
      --arg policy_file "$OPS_POLICY_FILE" \
      --argjson selection_disposition "$selection_disposition" \
      --argjson policy "$(jq -c '{id, policy_version, catalog_ref, generated_at}' <<<"$OPS_POLICY_JSON")" \
      '{
        resolve_schema_version: 2,
        op: $op.id,
        expands_to: $op.expands_to,
        task_family: $op.task_family,
        constraint_family: $op.constraint_family,
        frontier_assumption: $op.frontier_assumption,
        escalate_to: $op.escalate_to,
        deescalate_to: $op.deescalate_to,
        known_gaps: $op.known_gaps,
        override_policy: $op.override_policy,
        policy: $policy,
        policy_file: $policy_file,
        requirements: ($op.requirements // {ratified:false}),
        selection: ($selection_disposition + {stats_frontier:"empty"})
      }'
  else
    log "policy: $OPS_POLICY_FILE"
    jq -r '
      "\(.id) expands to:",
      "  provider: \(.expands_to.provider)",
      "  model: \(.expands_to.model // "(provider default)")",
      "  effort: \(.expands_to.effort // "(unset)")",
      "  mode: \(.expands_to.mode // .expands_to.service_tier // "standard")"
    ' <<<"$row"
    jq -r '"  catalog: \(.catalog_ref // "?")\n  policy: \(.id)@\(.policy_version // "?")"' <<<"$OPS_POLICY_JSON"
  fi
}

# Apply op expansion into named vars (provider model effort mode).
# Existing non-empty values are treated as explicit overrides (explicit_flags_win).
ops_apply_to_spawn() {
  local op_id="$1"
  local row exp_provider exp_model exp_effort exp_mode
  row="$(ops_get_point "$op_id")"
  exp_provider="$(jq -r '.expands_to.provider // empty' <<<"$row")"
  exp_model="$(jq -r '.expands_to.model // empty' <<<"$row")"
  exp_effort="$(jq -r '.expands_to.effort // empty' <<<"$row")"
  exp_mode="$(jq -r '.expands_to.mode // .expands_to.service_tier // empty' <<<"$row")"

  local overrides=()
  if [[ -n "${provider:-}" && -n "$exp_provider" && "$provider" != "$exp_provider" ]]; then
    overrides+=("provider $exp_provider -> $provider")
  fi
  if [[ -n "${model:-}" && -n "$exp_model" && "$model" != "$exp_model" ]]; then
    overrides+=("model $exp_model -> $model")
  fi
  if [[ -n "${effort:-}" && -n "$exp_effort" && "$effort" != "$exp_effort" ]]; then
    overrides+=("effort $exp_effort -> $effort")
  fi

  [[ -z "${provider:-}" ]] && provider="$exp_provider"
  [[ -z "${model:-}" ]] && model="$exp_model"
  [[ -z "${effort:-}" ]] && effort="$exp_effort"
  OP_MODE="${exp_mode:-standard}"
  OP_ID="$op_id"
  # Durable receipts for lane state (explicit_flags_win auditability)
  OP_EXPANDS_TO="$(jq -c '.expands_to' <<<"$row")"
  if [[ ${#overrides[@]} -gt 0 ]]; then
    EXPLICIT_OVERRIDES="$(printf '%s
' "${overrides[@]}" | jq -R . | jq -s -c .)"
  else
    EXPLICIT_OVERRIDES='[]'
  fi
  export OP_EXPANDS_TO EXPLICIT_OVERRIDES

  ops_load
  log "op $op_id expands to:"
  log "  provider: $provider"
  log "  model: ${model:-(provider default)}"
  log "  effort: ${effort:-(unset)}"
  log "  mode: $OP_MODE"
  log "  catalog: $(jq -r '.catalog_ref // "?"' <<<"$OPS_POLICY_JSON")"
  log "  policy: $(jq -r '.id + "@" + (.policy_version // "?")' <<<"$OPS_POLICY_JSON")"
  if [[ ${#overrides[@]} -gt 0 ]]; then
    log "explicit override applied:"
    local o
    for o in "${overrides[@]}"; do log "  $o"; done
  fi
}
