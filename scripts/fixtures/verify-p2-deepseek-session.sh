# A live refresh cannot cache a foreign timestamp-only session candidate.
(
  fixture="$(mktemp -d "$scratch/waspflow-p2-deepseek-XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  export WASPFLOW_HOME="$fixture/home" WASPFLOW_LIB="$root/lib" DSH_HOME="$fixture/dsh"
  source "$root/lib/core.sh"; source "$root/lib/providers/deepseek.sh"
  lane_set lane provider deepseek cwd "$fixture" session_id ""
  touch "$(_deepseek_marker_file lane)"
  sleep 0.02
  mkdir -p "$DSH_HOME/sessions/project/session-foreign"
  [[ -z "$(deepseek_discover_session lane)" && -z "$(lane_get lane session_id)" ]]
  mkdir -p "$DSH_HOME/sessions/project/session-own"
  [[ -z "$(deepseek_discover_session lane true)" && -z "$(lane_get lane session_id)" ]]
  rm -rf "$DSH_HOME/sessions/project/session-foreign"
  [[ "$(deepseek_discover_session lane true)" == session-own ]]
  [[ "$(lane_get lane session_id)" == session-own ]]
)
