#!/usr/bin/env bash
#
# project.sh — generic project/process integrity checks for waspflow.
#
# This is deliberately not PDPP-specific. Projects can add a small
# .waspflow/config.json file to teach waspflow about local mutex files, blocker
# globs, report globs, and extra health commands. The built-in checks remain
# useful in any git repo: current worktree state, all repo worktrees, and
# waspflow lanes associated with the project.

set -euo pipefail

WASPFLOW_CHECK_RISKS=0
WASPFLOW_CHECK_WARNINGS=0
WASPFLOW_CHECK_ADVICE=()

_project_abs_dir() {
  local dir="$1"
  (cd "$dir" && pwd)
}

project_root_for() {
  local cwd="$1"
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || _project_abs_dir "$cwd"
}

project_find_config() {
  local cwd="$1" explicit="${2:-}"
  if [[ -n "$explicit" ]]; then
    [[ -f "$explicit" ]] || die "check: config file not found: $explicit"
    printf '%s/%s\n' "$(_project_abs_dir "$(dirname "$explicit")")" "$(basename "$explicit")"
    return 0
  fi

  local dir
  dir="$(_project_abs_dir "$cwd")"
  while :; do
    if [[ -f "$dir/.waspflow/config.json" ]]; then
      echo "$dir/.waspflow/config.json"
      return 0
    fi
    if [[ -f "$dir/.waspflow.json" ]]; then
      echo "$dir/.waspflow.json"
      return 0
    fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
  echo ""
}

_check_section() { printf '\n## %s\n' "$*"; }
_check_ok() { printf 'OK: %s\n' "$*"; }
_check_info() { printf '%s\n' "- $*"; }
_check_advice() {
  local code="$1" existing
  for existing in "${WASPFLOW_CHECK_ADVICE[@]:-}"; do
    [[ "$existing" == "$code" ]] && return 0
  done
  WASPFLOW_CHECK_ADVICE+=("$code")
}

_check_advice_for() {
  local msg="$*"
  case "$msg" in
    DIRTY\ current\ worktree*|DIRTY\ worktree*) _check_advice dirty ;;
    current\ branch\ upstream\ delta*|worktree\ branch=*upstream\ delta*|current\ branch\ has\ no\ upstream*) _check_advice branch ;;
    unreaped\ exited\ lane*) _check_advice unreaped ;;
    lane\ has\ failed\ deliverable*) _check_advice deliverable ;;
    mutex\ *\ is\ OPEN*) _check_advice mutex ;;
    found\ *) _check_advice blocker ;;
    command\ *\ failed*|*\ failed\ rc=*) _check_advice command ;;
  esac
}

_check_warn() {
  WASPFLOW_CHECK_WARNINGS=$((WASPFLOW_CHECK_WARNINGS + 1))
  _check_advice_for "$*"
  printf '! %s\n' "$*"
}
_check_risk() {
  WASPFLOW_CHECK_RISKS=$((WASPFLOW_CHECK_RISKS + 1))
  _check_advice_for "$*"
  printf '! %s\n' "$*"
}

_wc_lines() {
  wc -l | tr -d ' '
}

_git_branch_label() {
  local path="$1"
  git -C "$path" branch --show-current 2>/dev/null || true
}

_git_ahead_behind() {
  local path="$1"
  git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || {
    echo ""
    return 0
  }
  git -C "$path" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || true
}

project_check_current_git() {
  local root="$1"
  _check_section "Git"
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    _check_ok "not a git repository"
    return 0
  fi

  local branch dirty ahead_behind behind ahead
  branch="$(_git_branch_label "$root")"
  [[ -n "$branch" ]] || branch="(detached)"
  dirty="$(git -C "$root" status --porcelain 2>/dev/null | _wc_lines)"
  if [[ "$dirty" -gt 0 ]]; then
    _check_risk "DIRTY current worktree branch=$branch changed_paths=$dirty root=$root"
  else
    _check_ok "current worktree clean branch=$branch"
  fi

  ahead_behind="$(_git_ahead_behind "$root")"
  if [[ -n "$ahead_behind" ]]; then
    behind="${ahead_behind%%[[:space:]]*}"
    ahead="${ahead_behind##*[[:space:]]}"
    if [[ "$ahead" -gt 0 || "$behind" -gt 0 ]]; then
      _check_warn "current branch upstream delta ahead=$ahead behind=$behind"
    else
      _check_ok "current branch in sync with upstream"
    fi
  else
    _check_warn "current branch has no upstream"
  fi
}

project_check_worktrees() {
  local root="$1"
  _check_section "Git Worktrees"
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    _check_ok "not a git repository"
    return 0
  fi

  local any=0 path="" branch="" line dirty ahead_behind behind ahead
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        if [[ -n "$path" ]]; then
          any=1
          dirty="$(git -C "$path" status --porcelain 2>/dev/null | _wc_lines)"
          branch="${branch:-$(_git_branch_label "$path")}"
          [[ -n "$branch" ]] || branch="(detached)"
          if [[ "$path" == "$root" ]]; then
            _check_info "current worktree listed above branch=$branch path=$path"
          elif [[ "$dirty" -gt 0 ]]; then
            _check_risk "DIRTY worktree branch=$branch changed_paths=$dirty path=$path"
          else
            _check_info "clean worktree branch=$branch path=$path"
          fi
          if [[ "$path" != "$root" ]]; then
            ahead_behind="$(_git_ahead_behind "$path")"
            if [[ -n "$ahead_behind" ]]; then
              behind="${ahead_behind%%[[:space:]]*}"
              ahead="${ahead_behind##*[[:space:]]}"
              if [[ "$ahead" -gt 0 || "$behind" -gt 0 ]]; then
                _check_warn "worktree branch=$branch upstream delta ahead=$ahead behind=$behind path=$path"
              fi
            fi
          fi
        fi
        path="${line#worktree }"
        branch=""
        ;;
      branch\ refs/heads/*)
        branch="${line#branch refs/heads/}"
        ;;
    esac
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)

  if [[ -n "$path" ]]; then
    any=1
    dirty="$(git -C "$path" status --porcelain 2>/dev/null | _wc_lines)"
    branch="${branch:-$(_git_branch_label "$path")}"
    [[ -n "$branch" ]] || branch="(detached)"
    if [[ "$path" == "$root" ]]; then
      _check_info "current worktree listed above branch=$branch path=$path"
    elif [[ "$dirty" -gt 0 ]]; then
      _check_risk "DIRTY worktree branch=$branch changed_paths=$dirty path=$path"
    else
      _check_info "clean worktree branch=$branch path=$path"
    fi
    if [[ "$path" != "$root" ]]; then
      ahead_behind="$(_git_ahead_behind "$path")"
      if [[ -n "$ahead_behind" ]]; then
        behind="${ahead_behind%%[[:space:]]*}"
        ahead="${ahead_behind##*[[:space:]]}"
        if [[ "$ahead" -gt 0 || "$behind" -gt 0 ]]; then
          _check_warn "worktree branch=$branch upstream delta ahead=$ahead behind=$behind path=$path"
        fi
      fi
    fi
  fi

  [[ "$any" -eq 1 ]] || _check_ok "no git worktrees found"
}

_project_path_in_scope() {
  local root="$1" path="$2"
  [[ -n "$path" ]] || return 1
  case "$path" in
    "$root"|"$root"/*) return 0 ;;
  esac
  return 1
}

project_check_lanes() {
  local root="$1" config="$2" stale_seconds=0
  _check_section "Waspflow Lanes"
  if [[ -n "$config" ]]; then
    stale_seconds="$(jq -r '.lanes.stale_seconds // 0' "$config" 2>/dev/null || echo 0)"
  fi

  local lanes lane any=0 provider status cwd origin result outcome updated now age live label
  lanes="$(list_lanes || true)"
  if [[ -z "$lanes" ]]; then
    _check_ok "no lanes"
    return 0
  fi

  now="$(date +%s)"
  while IFS= read -r lane; do
    [[ -n "$lane" ]] || continue
    cwd="$(lane_get "$lane" cwd)"
    origin="$(lane_get "$lane" origin_cwd)"
    if ! _project_path_in_scope "$root" "$cwd" && ! _project_path_in_scope "$root" "$origin"; then
      continue
    fi
    provider="$(lane_get "$lane" provider)"
    status="$(lane_get "$lane" status)"
    result="$(lane_get "$lane" result)"
    outcome="$(lane_outcome "$lane")"
    updated="$(lane_get "$lane" updated_at)"
    live="exited"
    tmux_window_exists "$lane" && live="live"
    [[ "$status" == "reaped" ]] && live="reaped"
    if [[ "$status" == "reaped" && ( "$outcome" == "abandoned" || "$outcome" == "superseded" ) ]]; then
      continue
    fi
    if [[ "$status" == "reaped" && ( "$result" == "succeeded" || "$result" == "recovered" || -z "$result" ) ]]; then
      continue
    fi
    any=1
    label="lane=$lane provider=${provider:-?} status=${status:-?} window=$live result=${result:-none} cwd=$cwd"
    if [[ "$status" == "live" && "$live" == "exited" ]]; then
      _check_risk "unreaped exited lane: $label"
    elif [[ "$result" == "failed" || "$result" == "report_missing" ]]; then
      _check_risk "lane has failed deliverable: $label"
    else
      _check_info "$label"
    fi
    if [[ "$stale_seconds" =~ ^[0-9]+$ && "$stale_seconds" -gt 0 && "$status" == "live" && "$updated" =~ ^[0-9]+$ ]]; then
      age=$((now - updated))
      if [[ "$age" -gt "$stale_seconds" ]]; then
        _check_warn "stale live lane age_seconds=$age threshold=$stale_seconds lane=$lane"
      fi
    fi
  done <<<"$lanes"

  [[ "$any" -eq 1 ]] || _check_ok "no lanes for this project"
}

project_check_mutexes() {
  local root="$1" config="$2"
  _check_section "Mutexes"
  [[ -n "$config" ]] || { _check_ok "no config"; return 0; }
  local count
  count="$(jq -r '(.mutexes // []) | length' "$config" 2>/dev/null || echo 0)"
  [[ "$count" -gt 0 ]] || { _check_ok "no configured mutexes"; return 0; }

  local i name file pattern path
  for ((i=0; i<count; i++)); do
    name="$(jq -r --argjson i "$i" '.mutexes[$i].name // ("mutex-" + ($i|tostring))' "$config")"
    file="$(jq -r --argjson i "$i" '.mutexes[$i].file // ""' "$config")"
    pattern="$(jq -r --argjson i "$i" '.mutexes[$i].open_pattern // ""' "$config")"
    if [[ -z "$file" || -z "$pattern" ]]; then
      _check_warn "mutex '$name' ignored: requires file + open_pattern"
      continue
    fi
    case "$file" in /*) path="$file" ;; *) path="$root/$file" ;; esac
    if [[ ! -f "$path" ]]; then
      _check_warn "mutex '$name' file missing: $path"
      continue
    fi
    if grep -Eq "$pattern" "$path"; then
      _check_risk "mutex '$name' is OPEN ($file matched $pattern)"
    else
      _check_ok "mutex '$name' closed"
    fi
  done
}

project_check_globs() {
  local root="$1" config="$2" key="$3" title="$4" risk_when_found="$5"
  _check_section "$title"
  [[ -n "$config" ]] || { _check_ok "no config"; return 0; }
  local count
  count="$(jq -r "(.${key}.globs // []) | length" "$config" 2>/dev/null || echo 0)"
  [[ "$count" -gt 0 ]] || { _check_ok "no configured globs"; return 0; }

  local i glob matches=() match
  shopt -s nullglob globstar
  for ((i=0; i<count; i++)); do
    glob="$(jq -r --argjson i "$i" ".${key}.globs[\$i]" "$config")"
    case "$glob" in
      /*) matches+=($glob) ;;
      *) matches+=($root/$glob) ;;
    esac
  done
  shopt -u nullglob globstar

  if [[ "${#matches[@]}" -eq 0 ]]; then
    _check_ok "none found"
    return 0
  fi
  for match in "${matches[@]}"; do
    if [[ "$risk_when_found" == "1" ]]; then
      _check_risk "found $match"
    else
      _check_info "$match"
    fi
  done
}

project_check_reports() {
  local root="$1" config="$2"
  _check_section "Recent Reports"
  [[ -n "$config" ]] || { _check_ok "no config"; return 0; }
  local count limit
  count="$(jq -r '(.reports.globs // []) | length' "$config" 2>/dev/null || echo 0)"
  limit="$(jq -r '.reports.limit // 20' "$config" 2>/dev/null || echo 20)"
  [[ "$count" -gt 0 ]] || { _check_ok "no configured report globs"; return 0; }

  local tmp i glob
  tmp="$(mktemp)"
  shopt -s nullglob globstar
  for ((i=0; i<count; i++)); do
    glob="$(jq -r --argjson i "$i" '.reports.globs[$i]' "$config")"
    case "$glob" in
      /*) stat -c '%Y %n' $glob 2>/dev/null >>"$tmp" || true ;;
      *) stat -c '%Y %n' $root/$glob 2>/dev/null >>"$tmp" || true ;;
    esac
  done
  shopt -u nullglob globstar

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    _check_ok "none found"
    return 0
  fi
  local sorted shown=0
  sorted="$(mktemp)"
  sort -rn "$tmp" >"$sorted"
  while read -r _ path; do
    _check_info "$path"
    shown=$((shown + 1))
    [[ "$shown" -ge "$limit" ]] && break
  done <"$sorted"
  rm -f "$tmp" "$sorted"
}

project_check_commands() {
  local root="$1" config="$2"
  _check_section "Project Commands"
  [[ -n "$config" ]] || { _check_ok "no config"; return 0; }
  local count
  count="$(jq -r '(.commands // []) | length' "$config" 2>/dev/null || echo 0)"
  [[ "$count" -gt 0 ]] || { _check_ok "no configured commands"; return 0; }

  local i name command severity tmp rc
  for ((i=0; i<count; i++)); do
    name="$(jq -r --argjson i "$i" '.commands[$i].name // ("command-" + ($i|tostring))' "$config")"
    command="$(jq -r --argjson i "$i" '.commands[$i].command // ""' "$config")"
    severity="$(jq -r --argjson i "$i" '.commands[$i].severity // "risk"' "$config")"
    if [[ -z "$command" ]]; then
      _check_warn "command '$name' ignored: empty command"
      continue
    fi
    tmp="$(mktemp)"
    rc=0
    (cd "$root" && bash -lc "$command") >"$tmp" 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      _check_ok "$name"
    elif [[ "$severity" == "info" || "$severity" == "warn" || "$severity" == "warning" ]]; then
      _check_warn "$name failed rc=$rc"
    else
      _check_risk "$name failed rc=$rc"
    fi
    if [[ -s "$tmp" ]]; then
      sed -n '1,12p' "$tmp" | sed 's/^/  | /'
      local lines
      lines="$(wc -l <"$tmp" | tr -d ' ')"
      [[ "$lines" -gt 12 ]] && printf '  | ... (%s more lines)\n' "$((lines - 12))"
    fi
    rm -f "$tmp"
  done
}

project_check_usage() {
  cat <<'EOF'
waspflow check [--cwd DIR] [--config FILE] [--no-fail] [--explain]

Run a generic project integrity gate:
  - current git worktree dirty/ahead state
  - all git worktrees for the repo
  - waspflow lanes associated with this project
  - optional mutex/blocker/report/command checks from .waspflow/config.json

Config example:
{
  "lanes": { "stale_seconds": 14400 },
  "mutexes": [
    {
      "name": "live-stack",
      "file": "tmp/workstreams/current-state.md",
      "open_pattern": "^- Status: OPEN"
    }
  ],
  "blockers": { "globs": [".git/workstreams/blockers/*"] },
  "reports": { "globs": ["tmp/workstreams/*.md"], "limit": 10 },
  "commands": [
    { "name": "OpenSpec status", "command": "node scripts/openspec-status.mjs", "severity": "warn" }
  ]
}
EOF
}

project_check_explain() {
  _check_section "What To Do Next"
  if [[ "$WASPFLOW_CHECK_RISKS" -eq 0 && "$WASPFLOW_CHECK_WARNINGS" -eq 0 ]]; then
    _check_info "Nothing is blocking orchestration. You can spawn a lane, continue review, or close out."
    return 0
  fi

  local code any=0
  for code in "${WASPFLOW_CHECK_ADVICE[@]:-}"; do
    any=1
    case "$code" in
      dirty) printf '%s\n' '- Dirty worktree: run `git status --short`, then deliberately commit, stash, or remove the changes.' ;;
      branch) printf '%s\n' '- Branch sync: pull with `git pull --ff-only`, push accepted commits, or set an upstream if this branch is intentionally local.' ;;
      unreaped) printf '%s\n' '- Unreaped exited lane: inspect with `waspflow peek <lane>` and `waspflow status <lane>`, then `waspflow reap <lane>`.' ;;
      deliverable) printf '%s\n' '- Failed/missing report: revise the lane or treat it as failed; do not convert it to success without the deliverable.' ;;
      mutex) printf '%s\n' '- Open mutex: read the mutex file and wait for the owner/operator window to close before touching that protected resource.' ;;
      blocker) printf '%s\n' '- Blocker file: open the listed blocker and resolve or explicitly accept the risk before launching more work.' ;;
      command) printf '%s\n' '- Project command failure: fix the command output or mark that command as warning-only in config if it is advisory.' ;;
    esac
  done
  [[ "$any" -eq 1 ]] || _check_info "Review the warnings above; this check type has no specific remediation yet."
}

project_init_usage() {
  cat <<'EOF'
waspflow init [--cwd DIR] [--profile NAME]... [--force] [--print]

Write .waspflow/config.json for a project. Profiles are composable:
  basic             lane staleness threshold only
  reports           show recent tmp/workstreams/*.md reports
  blockers          treat .git/workstreams/blockers/* as action-blocking
  live-stack-mutex  check tmp/workstreams/current-state.md for "Status: OPEN"
  openspec          run `openspec validate --all --strict` as a project command
  serious-repo      basic + reports + blockers

Examples:
  waspflow init
  waspflow init --profile serious-repo
  waspflow init --profile serious-repo --profile openspec
  waspflow init --profile live-stack-mutex --print
EOF
}

project_init_has_profile() {
  local want="$1"; shift
  local p
  for p in "$@"; do [[ "$p" == "$want" ]] && return 0; done
  return 1
}

project_init_build_json() {
  local profiles=("$@")
  local expr='{ lanes: { stale_seconds: 14400 } }'

  if project_init_has_profile reports "${profiles[@]}"; then
    expr="$expr + { reports: { globs: [\"tmp/workstreams/*.md\"], limit: 20 } }"
  fi
  if project_init_has_profile blockers "${profiles[@]}"; then
    expr="$expr + { blockers: { globs: [\".git/workstreams/blockers/*\"] } }"
  fi
  if project_init_has_profile live-stack-mutex "${profiles[@]}"; then
    expr="$expr + { mutexes: [{ name: \"live-stack\", file: \"tmp/workstreams/current-state.md\", open_pattern: \"^- Status: OPEN\" }] }"
  fi
  if project_init_has_profile openspec "${profiles[@]}"; then
    expr="$expr + { commands: [{ name: \"OpenSpec validate\", command: \"openspec validate --all --strict\", severity: \"risk\" }] }"
  fi

  jq -n "$expr"
}

project_init_expand_profiles() {
  local expanded=()
  local p
  for p in "$@"; do
    case "$p" in
      basic) expanded+=(basic) ;;
      reports) expanded+=(reports) ;;
      blockers) expanded+=(blockers) ;;
      live-stack-mutex) expanded+=(live-stack-mutex) ;;
      openspec) expanded+=(openspec) ;;
      serious-repo) expanded+=(basic reports blockers) ;;
      *) die "init: unknown profile '$p' (try: waspflow init --help)" ;;
    esac
  done
  printf '%s\n' "${expanded[@]}" | awk '!seen[$0]++'
}

cmd_init() {
  local cwd="$PWD" force=0 print_only=0
  local -a profiles=()
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --) shift ;;
      --cwd) cwd="${2:-}"; shift 2 ;;
      --profile) profiles+=("${2:-}"); shift 2 ;;
      --force) force=1; shift ;;
      --print) print_only=1; shift ;;
      -h|--help) project_init_usage; return 0 ;;
      *) die "init: unknown option '$1'" ;;
    esac
  done

  require_cmd jq
  cwd="$(_project_abs_dir "$cwd")"
  local root config_dir config profiles_expanded json
  root="$(project_root_for "$cwd")"
  config_dir="$root/.waspflow"
  config="$config_dir/config.json"
  [[ "${#profiles[@]}" -gt 0 ]] || profiles=(basic)
  mapfile -t profiles_expanded < <(project_init_expand_profiles "${profiles[@]}")
  json="$(project_init_build_json "${profiles_expanded[@]}")"

  if [[ "$print_only" -eq 1 ]]; then
    printf '%s\n' "$json"
    return 0
  fi

  if [[ -e "$config" && "$force" -ne 1 ]]; then
    die "init: $config already exists (use --force to overwrite, or --print to inspect)"
  fi
  mkdir -p "$config_dir"
  printf '%s\n' "$json" >"$config"
  log "wrote $config"
  log "profiles: ${profiles_expanded[*]}"
  log "next: waspflow check --explain"
}

cmd_check() {
  local cwd="$PWD" config="" no_fail=0 explain=0
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --) shift ;;
      --cwd) cwd="${2:-}"; shift 2 ;;
      --config) config="${2:-}"; shift 2 ;;
      --no-fail) no_fail=1; shift ;;
      --explain) explain=1; shift ;;
      -h|--help) project_check_usage; return 0 ;;
      *) die "check: unknown option '$1'" ;;
    esac
  done

  cwd="$(_project_abs_dir "$cwd")"
  local root
  root="$(project_root_for "$cwd")"
  config="$(project_find_config "$cwd" "$config")"

  WASPFLOW_CHECK_RISKS=0
  WASPFLOW_CHECK_WARNINGS=0
  WASPFLOW_CHECK_ADVICE=()
  printf '# waspflow check\n'
  printf 'Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Project root: %s\n' "$root"
  if [[ -n "$config" ]]; then
    printf 'Config: %s\n' "$config"
    jq empty "$config" 2>/dev/null || die "check: invalid JSON config: $config"
  else
    printf 'Config: none\n'
  fi

  project_check_current_git "$root"
  project_check_worktrees "$root"
  project_check_lanes "$root" "$config"
  project_check_mutexes "$root" "$config"
  project_check_globs "$root" "$config" "blockers" "Blockers" 1
  project_check_reports "$root" "$config"
  project_check_commands "$root" "$config"

  _check_section "Summary"
  printf 'Risks: %s\n' "$WASPFLOW_CHECK_RISKS"
  printf 'Warnings: %s\n' "$WASPFLOW_CHECK_WARNINGS"
  [[ "$explain" -eq 1 ]] && project_check_explain
  if [[ "$WASPFLOW_CHECK_RISKS" -gt 0 && "$no_fail" -ne 1 ]]; then
    return 2
  fi
  return 0
}
