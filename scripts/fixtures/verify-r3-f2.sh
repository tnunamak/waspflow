#!/usr/bin/env bash
# r3-f2: replacement generation, generation-aware receipts, and exec output.
(
  r3f2="$(mktemp -d "${WASPFLOW_TEST_TMPDIR:-$HOME/.tmp}/waspflow-r3-f2-XXXXXX")"
  trap 'rm -rf "$r3f2"' EXIT
  export WASPFLOW_HOME="$r3f2/home" WASPFLOW_LIB="$root/lib"
  source "$root/lib/core.sh"
  source "$root/lib/artifacts.sh"
  source "$root/lib/fanin.sh"
  source "$root/lib/escalation.sh"
  source "$root/lib/exec.sh"

  # B4: a replacement submission starts a generation before its provider can
  # synchronously write a report. This reaches the real submission seam with a
  # fake provider and no tmux or external provider.
  printf old >"$r3f2/replacement-report"
  old_signature="$(artifacts_report_signature "$r3f2/replacement-report")"
  lane_set replacement provider fake cwd "$r3f2" git_tracked false result succeeded report "$r3f2/replacement-report" report_contract_version 2 report_before_signature absent \
    deferred_switch '' pending_transition '{"phase":"launch_provisioned","mode":"in_place","to_arm":{"provider":"fake"},"provisional_session":{"launch_attempted":false}}'
  fake_confirm_escalation_submission() { return 1; }
  fake_resume_with_arm() {
    [[ "$(lane_get replacement turn_generation)" == 1 ]] || return 97
    [[ -z "$(lane_get replacement result)" ]] || return 98
    [[ "$(lane_get replacement report_before_signature)" == "$old_signature" ]] || return 99
    printf replacement >"$r3f2/replacement-report"
    artifacts_report_present replacement
  }
  load_provider() { :; }
  escalate_mark_confirmed_locked() { :; }
  escalate_resume_launch_locked replacement false "$(lane_get replacement pending_transition)"
  jq -e '.generation == 0 and .result == "succeeded"' "$(lane_dir replacement)/generation-results.jsonl" >/dev/null

  # B9: durable lane receipts retain every generation while receipt.json is the
  # current generation's authoritative outcome; retries stay idempotent.
  lane_set ledger provider codex cwd "$r3f2" git_tracked false lane_uuid r3-f2-ledger spawn_epoch 1 result succeeded
  artifacts_emit_receipt_v1 ledger succeeded
  first_id="$(jq -r .receipt_id "$(lane_dir ledger)/receipt.json")"
  artifacts_begin_turn_generation ledger
  turn_state_finish_generation ledger failed
  lane_set ledger receipt_emitted false receipt_emitted_generation '' receipt_id ''
  artifacts_emit_receipt_v1 ledger failed
  second_id="$(jq -r .receipt_id "$(lane_dir ledger)/receipt.json")"
  [[ "$first_id" != "$second_id" ]]
  jq -s --arg uuid r3-f2-ledger '
    map(select(.receipt_kind == "lane" and .lane_uuid == $uuid))
    | length == 2 and (map(.generation) | sort) == [0, 1]
    and (map(select(.generation == 0).result) == ["succeeded"])
    and (map(select(.generation == 1).result) == ["failed"])
  ' "$WASPFLOW_HOME/receipts.jsonl" | grep -qx true
  artifacts_emit_receipt_v1 ledger failed
  [[ "$(jq -r .receipt_id "$(lane_dir ledger)/receipt.json")" == "$second_id" ]]
  [[ "$(jq -s --arg uuid r3-f2-ledger 'map(select(.receipt_kind == "lane" and .lane_uuid == $uuid)) | length' "$WASPFLOW_HOME/receipts.jsonl")" == 2 ]]

  # B9-migration: a stale prior-generation marker, and a legacy marker with
  # no generation, cannot suppress this generation's durable receipt.
  lane_set stale-marker provider codex cwd "$r3f2" git_tracked false lane_uuid r3-f2-stale spawn_epoch 1 result succeeded turn_generation 1 receipt_emitted true receipt_emitted_generation 0
  artifacts_emit_receipt_v1 stale-marker succeeded
  [[ "$(jq -r .generation "$(lane_dir stale-marker)/receipt.json")" == 1 ]]
  [[ "$(lane_get stale-marker receipt_emitted_generation)" == 1 ]]
  lane_set legacy-marker provider codex cwd "$r3f2" git_tracked false lane_uuid r3-f2-legacy spawn_epoch 1 result failed turn_generation 1 receipt_emitted true receipt_emitted_generation ''
  artifacts_emit_receipt_v1 legacy-marker failed
  [[ "$(jq -r .generation "$(lane_dir legacy-marker)/receipt.json")" == 1 ]]
  [[ "$(lane_get legacy-marker receipt_emitted_generation)" == 1 ]]

  # Finding #18 and LOW-5: all nonblank exit-zero answers publish, and
  # stdout-mode output is newline-terminated even when Codex omits it.
  split_after_ddash() {
    FLAGS=(); REST=(); local seen=0 arg
    for arg in "$@"; do
      if [[ "$seen" -eq 0 && "$arg" == -- ]]; then seen=1; continue; fi
      if [[ "$seen" -eq 0 ]]; then FLAGS+=("$arg"); else REST+=("$arg"); fi
    done
  }
  selection_gate_mode() { echo off; }
  is_known_provider() { return 0; }
  validate_model() { :; }
  resolve_mcp_policy() { MCP_ARGV_JSON='[]'; MCP_ENV_JSON='{}'; MCP_WARNING=''; }
  codex_preflight() { :; }
  mcp_policy_load_json() { :; }
  billing_path_v1() { echo '{}'; }
  artifacts_emit_exec_receipt_v1() { :; }
  _exec_access_preflight() { return 0; }
  EXEC_PREFLIGHT_JSON='{}'
  EXEC_FIXTURE_OUTPUT=''
  _exec_codex() { printf '%s' "$EXEC_FIXTURE_OUTPUT" >"$5"; }
  answer_index=0
  for answer in 'N/A' 'no response' 'permission denied' 'Error: provider unavailable'; do
    answer_index=$((answer_index + 1))
    EXEC_FIXTURE_OUTPUT="$answer"
    exec_run --provider codex --cwd "$r3f2" -o "$r3f2/answer-$answer_index.out" -- prompt
    [[ "$(cat "$r3f2/answer-$answer_index.out")" == "$answer" ]]
  done
  printf OLD >"$r3f2/blank.out"
  EXEC_FIXTURE_OUTPUT=$' \n\t '
  if exec_run --provider codex --cwd "$r3f2" -o "$r3f2/blank.out" -- prompt; then
    echo 'r3-f2 exec: whitespace-only output succeeded' >&2; exit 1
  fi
  [[ "$(cat "$r3f2/blank.out")" == OLD ]]
  EXEC_FIXTURE_OUTPUT=OK
  exec_run --provider codex --cwd "$r3f2" -o "$r3f2/codex.out" -- prompt
  printf 'OK\n' >"$r3f2/expected-stdout"
  cmp -s "$r3f2/expected-stdout" "$r3f2/codex.out"
  exec_run --provider codex --cwd "$r3f2" -- prompt >"$r3f2/stdout"
  cmp -s "$r3f2/expected-stdout" "$r3f2/stdout"
)
