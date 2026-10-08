#!/usr/bin/env bash
#
# turn-state.sh — generation-scoped result state for revisions.

turn_state_begin_generation() {
  local lane="$1" report_signature="${2:-}" previous generation now history
  previous="$(lane_get "$lane" result)"
  generation="$(lane_get "$lane" turn_generation)"
  [[ "$generation" =~ ^[0-9]+$ ]] || generation=0
  now="$(date +%s)"
  if [[ -n "$previous" ]]; then
    history="$(lane_dir "$lane")/generation-results.jsonl"
    jq -cn --argjson generation "$generation" --arg result "$previous" --arg report_state "$(lane_get "$lane" report_state)" --arg at "$now" \
      '{generation:$generation,result:$result,report_state:(if $report_state == "" then null else $report_state end),finished_epoch:($at|tonumber)}' >>"$history"
  fi
  generation=$((generation + 1))
  lane_set "$lane" turn_generation "$generation" turn_state running turn_started_epoch "$now" result "" report_state pending report_before_signature "$report_signature" receipt_emitted "false" receipt_emitted_generation "" receipt_id "" verify_runs "[]" verify_state "" verify_failure_class "" verify_test_files_changed "" verify_checkpoint_epoch "" verify_checkpoint_fingerprint "" verify_epoch "" verify_exit_code "" prepare_state "" prepare_exit_code "" prepare_epoch "" baseline_oracle_ran "" baseline_oracle_state "" baseline_oracle_reason ""
}

turn_state_finish_generation() {
  local lane="$1" result="$2"
  lane_set "$lane" result "$result" turn_state terminal turn_finished_epoch "$(date +%s)"
}
