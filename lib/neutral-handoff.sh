#!/usr/bin/env bash
# Neutral, offline export for an operator-mediated handoff. It never starts a
# provider and never transfers a shared worktree's ownership.

neutral_handoff_export() {
  local lane="$1" destination="${2:-$(lane_dir "$1")/neutral-handoff.json}"
  local worktree transcript historical prompt report steering provenance
  worktree="$(lane_get "$lane" worktree)"
  [[ -n "$worktree" ]] || { err "neutral handoff: shared-worktree ownership cannot be transferred"; return 1; }
  transcript="$(lane_transcript "$lane")"
  historical="$(lane_dir "$lane")/transcript-historical.log"
  steering="$(lane_get "$lane" latest_steering)"; [[ -n "$steering" ]] || steering="$(lane_get "$lane" prompt)"
  prompt="$(printf '%s' "$steering" | sed -E "s/((api[_-]?key|token|password|secret)[[:space:]]*=[[:space:]]*')[^']*/\\1[REDACTED]/Ig; s/((api[_-]?key|token|password|secret)[[:space:]]*=[[:space:]]*\")[^\"]*/\\1[REDACTED]/Ig; s/((api[_-]?key|token|password|secret)[[:space:]]*=[[:space:]]*)[^[:space:]]+/\\1[REDACTED]/Ig; s/(\"?(api[_-]?key|token|password|secret)\"?[[:space:]]*:[[:space:]]*\")[^\"]*/\\1[REDACTED]/Ig; s/(Authorization:[[:space:]]*(Bearer|Basic)[[:space:]]+)[^[:space:]]+/\\1[REDACTED]/Ig")"
  report="$(lane_get "$lane" report)"
  if [[ -f "$transcript" ]]; then
    sed -E "s/((api[_-]?key|token|password|secret)[[:space:]]*=[[:space:]]*')[^']*/\\1[REDACTED]/Ig; s/((api[_-]?key|token|password|secret)[[:space:]]*=[[:space:]]*\")[^\"]*/\\1[REDACTED]/Ig; s/((api[_-]?key|token|password|secret)[[:space:]]*=[[:space:]]*)[^[:space:]]+/\\1[REDACTED]/Ig; s/(\"?(api[_-]?key|token|password|secret)\"?[[:space:]]*:[[:space:]]*\")[^\"]*/\\1[REDACTED]/Ig; s/(Authorization:[[:space:]]*(Bearer|Basic)[[:space:]]+)[^[:space:]]+/\\1[REDACTED]/Ig" "$transcript" >"$historical"
  else
    : >"$historical"
  fi
  provenance="$(lane_get "$lane" provenance_parent_ref)"
  jq -cn --arg lane "$lane" --arg provider "$(lane_get "$lane" provider)" --arg session_id "$(lane_get "$lane" session_id)" --arg provenance "$provenance" \
    --arg prompt "$prompt" --arg report "$report" --arg transcript "$historical" \
    '{schema_version:1,kind:"neutral_handoff",lane:$lane,provider:$provider,provider_session_id:($session_id|if .=="" then null else . end),parent_provenance:($provenance|if .=="" then null else . end),steering:$prompt,report_requirement:($report|if .=="" then null else . end),transcript:{state:"historical",path:$transcript},ownership_transfer:"not_transferred"}' >"$destination"
}
