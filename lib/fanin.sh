#!/usr/bin/env bash
#
# fanin.sh — fan-in primitives. Waspflow makes fan-OUT cheap (spawn is O(1));
# this file makes fan-IN cheap too. See docs/lane-closeout-and-fan-in.md.
#
# Three primitives, all built on state waspflow already keeps:
#
#   1. Lane closeout ledger — a per-lane `outcome` field (open|harvested|
#      superseded|abandoned) with provenance, set at the moment the decision is
#      made. `list --status` and `reap --status` filter on it, so fan-in cleanup
#      is one command instead of per-lane git archaeology.
#
#   2. Content-capture check — `captured <lane> --in <ref>` answers "is this
#      lane's work already present in <ref>?" by CONTENT (signature tokens), not
#      ancestry. Ancestry (`git merge-base --is-ancestor`) lies after any non-merge
#      integration (cherry-pick / forward-port), which is the norm for reconciliation.
#
#   3. Bundle-before-reap — reap archives the lane's branch tip to a verified
#      git bundle before deleting anything, so "reaping is cleanup, not data loss"
#      is literally true even for unpushed branches.
#
# The `outcome` field is DISTINCT from the lifecycle `status` field (live/reaped):
# a lane can be `harvested` (outcome) AND `reaped` (status). Keeping them separate
# means reap never clobbers the closeout decision.

# Valid closeout outcomes. `open` is the implicit default (never set explicitly);
# a lane with no `outcome` field reads as `open`.
WASPFLOW_OUTCOMES=(open harvested superseded abandoned)

# Where reap archives bundled branch tips before deletion.
WASPFLOW_ARCHIVE_DIR="${WASPFLOW_ARCHIVE_DIR:-$WASPFLOW_HOME/archive}"

is_known_outcome() {
  local o
  for o in "${WASPFLOW_OUTCOMES[@]}"; do [[ "$o" == "$1" ]] && return 0; done
  return 1
}

# Read a lane's outcome, defaulting to `open` when unset.
lane_outcome() {
  local o; o="$(lane_get "$1" outcome)"
  [[ -n "$o" ]] && echo "$o" || echo "open"
}

# ---- Primitive 1: closeout ledger ------------------------------------------
# Set a lane's outcome + provenance. Args parsed by the caller (cmd_close).
# fanin_close <lane> <outcome> <provenance-key> <provenance-value>
#   harvested  -> into  <pr#|ref>
#   superseded -> by    <lane|ref>
#   abandoned  -> reason "..."
fanin_close() {
  local lane="$1" outcome="$2" pkey="${3:-}" pval="${4:-}"
  lane_exists "$lane" || die "close: no such lane '$lane'"
  is_known_outcome "$outcome" || die "close: unknown outcome '$outcome' (harvested|superseded|abandoned|open)"

  # Provenance is required for the terminal outcomes so the ledger is an audit
  # trail ("why is this reap-safe?") rather than a bare flag.
  case "$outcome" in
    harvested)  [[ -n "$pval" ]] || die "close --status harvested requires --into <pr#|ref>" ;;
    superseded) [[ -n "$pval" ]] || die "close --status superseded requires --by <lane|ref>" ;;
    abandoned)  [[ -n "$pval" ]] || die "close --status abandoned requires --reason \"...\"" ;;
  esac

  lane_set "$lane" \
    outcome "$outcome" \
    outcome_into    "$([[ "$pkey" == into   ]] && echo "$pval" || echo "$(lane_get "$lane" outcome_into)")" \
    outcome_by      "$([[ "$pkey" == by     ]] && echo "$pval" || echo "$(lane_get "$lane" outcome_by)")" \
    outcome_reason  "$([[ "$pkey" == reason ]] && echo "$pval" || echo "$(lane_get "$lane" outcome_reason)")" \
    outcome_epoch   "$(date +%s)"

  case "$outcome" in
    harvested)  log "close: lane '$lane' -> harvested (into $pval)" ;;
    superseded) log "close: lane '$lane' -> superseded (by $pval)" ;;
    abandoned)  log "close: lane '$lane' -> abandoned ($pval)" ;;
    open)       log "close: lane '$lane' -> open (reopened)" ;;
  esac
}

# Does a lane's outcome match a comma-separated filter (e.g. "harvested,abandoned")?
fanin_outcome_matches() {
  local lane="$1" filter="$2" cur; cur="$(lane_outcome "$lane")"
  local want
  IFS=',' read -ra want <<<"$filter"
  local w
  for w in "${want[@]}"; do [[ "$w" == "$cur" ]] && return 0; done
  return 1
}

# ---- Primitive 2: content-capture check ------------------------------------
# The lane's branch is waspflow/<lane> (see worktree.sh). Its fork point is the
# merge-base of that branch with the ref we're checking capture against.
fanin_lane_branch() { echo "waspflow/$1"; }

# Extract "signature tokens" from the lane's diff vs its fork point, tagged by
# KIND so each is checked the right way against the target ref:
#   file:<basename>   -> a new file the lane added; checked by PATH presence in ref
#   sym:<identifier>  -> an added top-level symbol; checked by CONTENT presence in ref
# Cheap and language-agnostic; it need not be perfect — a coarse "N of M present
# in target" is enough to turn a forensic delegation into a one-liner. Echoes one
# "kind:token" per line. Args: repo_root branch fork_ref
fanin_signature_tokens() {
  local repo_root="$1" branch="$2" fork_ref="$3"
  local base
  base="$(git -C "$repo_root" merge-base "$branch" "$fork_ref" 2>/dev/null)" || base=""
  [[ -n "$base" ]] || base="$fork_ref"

  {
    # New file basenames (added files in the lane, relative to fork point).
    git -C "$repo_root" diff --diff-filter=A --name-only "$base" "$branch" 2>/dev/null \
      | sed 's#.*/##' | grep -v '^$' | sed 's/^/file:/'

    # Added top-level symbols: lines the lane ADDED that declare a named entity.
    # Language-agnostic net over common declaration keywords. Stacked keywords
    # (`export function foo`, `pub async fn foo`) are the hazard: a non-overlapping
    # regex would stop at the inner keyword. So we match a declaration line, then
    # awk-skip ALL leading keyword/modifier words and take the first real
    # identifier that follows.
    git -C "$repo_root" diff "$base" "$branch" 2>/dev/null \
      | grep -E '^\+' \
      | grep -vE '^\+\+\+' \
      | sed -E 's/^\+//' \
      | grep -oE '^[[:space:]]*((export|public|private|static|pub|async|default)[[:space:]]+)*(function|func|def|class|struct|type|interface|const|let|var|enum|trait|impl|module)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
      | awk '{
          for (i=1;i<=NF;i++) {
            w=$i
            if (w ~ /^(function|func|def|class|struct|type|interface|const|let|var|enum|trait|impl|module|export|public|private|static|pub|async|default)$/) continue
            print w; break
          }
        }' \
      | sed 's/^/sym:/'
  } | sort -u | grep -v '^$' || true   # empty token set is valid, not an error
}

# Is a single tagged token present in <ref>? file: -> path in tree; sym: -> content.
# Args: repo_root ref "kind:token"
fanin_token_present() {
  local repo_root="$1" ref="$2" tagged="$3"
  local kind="${tagged%%:*}" tok="${tagged#*:}"
  case "$kind" in
    file) git -C "$repo_root" ls-tree -r --name-only "$ref" 2>/dev/null \
            | grep -qE "(^|/)$(printf '%s' "$tok" | sed 's/[.[\*^$]/\\&/g')\$" ;;
    sym)  git -C "$repo_root" grep -qF -e "$tok" "$ref" -- 2>/dev/null ;;
    *)    return 1 ;;
  esac
}

# Report CAPTURED | UNIQUE | PARTIAL for a lane against a ref, by content.
# Prints a human summary to stderr and the verdict word to stdout.
# Args: lane ref
fanin_captured() {
  local lane="$1" ref="$2"
  lane_exists "$lane" || die "captured: no such lane '$lane'"
  [[ -n "$ref" ]] || die "captured: --in <ref> required"
  require_cmd git

  local repo_root branch; repo_root="$(lane_get "$lane" repo_root)"
  [[ -n "$repo_root" ]] || repo_root="$(lane_get "$lane" origin_cwd)"
  [[ -n "$repo_root" ]] || die "captured: lane '$lane' has no recorded repo (not an isolated/git lane?)"
  branch="$(fanin_lane_branch "$lane")"

  git -C "$repo_root" rev-parse --verify --quiet "$branch" >/dev/null \
    || die "captured: lane branch '$branch' not found in $repo_root (already reaped its branch?)"
  git -C "$repo_root" rev-parse --verify --quiet "$ref" >/dev/null \
    || die "captured: ref '$ref' not found in $repo_root"

  local tokens; tokens="$(fanin_signature_tokens "$repo_root" "$branch" "$ref")"
  if [[ -z "$tokens" ]]; then
    warn "captured: lane '$lane' has no signature tokens vs $ref (empty/whitespace diff?) — treating as CAPTURED"
    echo "CAPTURED"; return 0
  fi

  local total=0 present=0 missing=()
  local tok
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    total=$((total+1))
    if fanin_token_present "$repo_root" "$ref" "$tok"; then
      present=$((present+1))
    else
      missing+=("${tok#*:} (${tok%%:*})")   # "landed.ts (file)" / "uniqueThing (sym)"
    fi
  done <<<"$tokens"

  local verdict
  if [[ "$present" -eq "$total" ]]; then
    verdict="CAPTURED"
  elif [[ "$present" -eq 0 ]]; then
    verdict="UNIQUE"
  else
    verdict="PARTIAL"
  fi

  warn "captured: lane '$lane' vs $ref — $verdict ($present/$total signature tokens present)"
  if [[ "${#missing[@]}" -gt 0 ]]; then
    warn "  unshipped tokens (harvest candidates):"
    local m
    for m in "${missing[@]}"; do warn "    $m"; done
  fi
  echo "$verdict"
}

# ---- Primitive 3: bundle-before-reap ---------------------------------------
# Archive a lane's branch tip to a verified git bundle before any deletion, so an
# unpushed branch is recoverable. No-op (success) if the lane has no git branch.
# Args: lane
fanin_bundle_lane() {
  local lane="$1"
  local repo_root branch; repo_root="$(lane_get "$lane" repo_root)"
  [[ -n "$repo_root" ]] || repo_root="$(lane_get "$lane" origin_cwd)"
  [[ -n "$repo_root" ]] || return 0
  branch="$(fanin_lane_branch "$lane")"
  git -C "$repo_root" rev-parse --verify --quiet "$branch" >/dev/null 2>&1 || return 0

  mkdir -p "$WASPFLOW_ARCHIVE_DIR"
  local stamp bundle
  stamp="$(date +%Y%m%d-%H%M%S)"
  bundle="$WASPFLOW_ARCHIVE_DIR/${lane}-${stamp}.bundle"

  if git -C "$repo_root" bundle create "$bundle" "$branch" >/dev/null 2>&1 \
     && git -C "$repo_root" bundle verify "$bundle" >/dev/null 2>&1; then
    lane_set "$lane" archive_bundle "$bundle"
    log "reap: archived branch '$branch' -> $bundle (verified)"
    return 0
  fi
  warn "reap: failed to bundle branch '$branch' (continuing without archive)"
  return 1
}
