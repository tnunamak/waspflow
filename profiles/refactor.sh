#!/usr/bin/env bash
# profiles/refactor.sh — the REFACTORING task profile for the waspflow gated loop.
# Fills lib/loop.sh's slots with behavior-preserving refactoring content. The
# methodology + no-go zones mirror the refactor-loop skill (the agent-knowledge);
# this file is what the ENGINE calls to build prompts + commands.
#
# Repo-tunable via env: LOOP_LINT_DIRS, LOOP_NOGO (else PDPP defaults).

LOOP_LINT_DIRS="${LOOP_LINT_DIRS:-apps/console/src packages/operator-ui/src reference-implementation packages/polyfill-connectors/src}"
LOOP_NOGO="${LOOP_NOGO:-auth/grant/consent/token, owner-session/csrf, rs-read/records/db/storage, search/mcp/read-core, scheduler/controller/recovery, manifest semantics, connector internals}"

profile_lint_cmd() {
  printf 'npx --yes @biomejs/biome lint %s' "$LOOP_LINT_DIRS"
}
profile_lint_file_cmd() {
  printf 'npx --yes @biomejs/biome lint %s' "$1"
}

# The agent classifies the ORACLE's raw findings and ranks safe targets. It does
# NOT source the linter count. Writes JSON {classified,hardAreasInspected,safeTargets,recommendation}.
profile_classify_prompt() {
  local rawjson="$1" intent="$2"
  cat <<PROMPT
You are CLASSIFY+RANK in a behavior-preserving refactoring loop. Intent: "$intent".
The DETERMINISTIC linter already ran (do NOT re-run it or change the count). GROUND-TRUTH over-complex functions (file:line:complexity): $rawjson
For EACH finding, read the code at file:line, name the function symbol, and classify: safe-incidental | essential-complexity | protocol-sensitive | high-value-owner-gated, each with whyNotSafe (""=safe). You MUST inspect the no-go-prone areas and list which in hardAreasInspected: $LOOP_NOGO. Do NOT exclude-then-conclude "nothing exists" (the under-reach failure).
For each SAFE-INCIDENTAL finding add a safeTargets entry: a behavior-preserving move (decomplect/name/early-return/delete-dead/extract-only-deep — NOT inline-a-named-wrapper), value (scales with how often the code is read/changed), package dir, and the touched test command.
Write ONLY this JSON to your report file (no prose):
{"classified":[{"file","symbol","complexity","classification","whyNotSafe"}],"hardAreasInspected":[...],"safeTargets":[{"file","symbol","complexity","move","value","package","testCmd"}],"recommendation":"go-loop|one-pr-no-loop|non-finding|needs-owner","note":""}
PROMPT
}

# Highest-value safe target as JSON, or empty/null.
profile_select_target() {
  python3 -c '
import json,sys
try: d=json.loads(sys.stdin.read())
except: print(""); sys.exit(0)
s=sorted(d.get("safeTargets",[]), key=lambda x:-(x.get("value",0)))
print(json.dumps(s[0]) if s and d.get("recommendation")=="go-loop" else "")'
}

profile_test_cmd() {
  printf '%s' "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("testCmd") or "cd reference-implementation && node --test")'
}

profile_make_prompt() {
  local target="$1" report="$2"
  local file sym mv; file="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')"
  sym="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["symbol"])')"
  mv="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("move",""))')"
  cat <<PROMPT
MAKER. ONE behavior-preserving refactor: $file :: $sym. Move: $mv.
RULES: behavior-preserving EXACTLY (no logic/order/string change). grep-verify caller counts before any inline/delete. Do NOT inline a NAMED+COMMENTED helper. No new file/export/wrapper unless a genuinely deep extraction. ONE commit on a NEW branch named refactor/<short> off origin/main. If NOT behavior-preserving or the target is wrong, STOP and write "abandon" + why.
Write a short report to $report stating: the branch name (must match refactor/<short>), the commit sha, what burden you removed in one sentence.
PROMPT
}

profile_revise_prompt() {
  local target="$1" facts="$2" sem="$3" report="$4"
  local file sym; file="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')"
  sym="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["symbol"])')"
  cat <<PROMPT
MAKER, REVISING $file :: $sym. The gate FAILED.
Objective oracle facts (un-fakeable): $facts
Semantic verdict: $sem
Fix EXACTLY what failed, amend/commit on the SAME branch. If fundamentally wrong (behavior change / laundering), write "abandon" + why to $report.
PROMPT
}

profile_check_prompt() {
  local target="$1" branch="$2" facts="$3" report="$4"
  local file sym; file="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')"
  sym="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["symbol"])')"
  cat <<PROMPT
INDEPENDENT CHECKER (stronger model than the maker). The OBJECTIVE ORACLE ALREADY RAN — these are facts, you do NOT report exit codes: $facts
Your job is ONLY the semantic judgment the script can't make. READ the diff: \`git diff origin/main...$branch -- $file\`. Judge and write ONLY this JSON to $report:
{"behaviorPreserving":bool (no logic/order/string change; a clarity-fix changing a set/condition = false), "methodologyAligned":bool (decomplect/name/delete not slop — AI-slop checklist: net-positive prod LOC suspect, new 1-caller wrapper reject, named+commented helper inlined = reject, tautological tests reject), "surfaceUnchanged":bool (no export/route/manifest/DB), "callerCountsVerified":bool (grep-confirm any N-caller claim, true if none), "evidence":"cite the diff, >80 chars", "reason":""}
PROMPT
}

profile_done_prompt() {
  local target="$1" facts="$2" hardlist="$3" intent="$4" report="$5"
  local file sym; file="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')"
  sym="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["symbol"])')"
  cat <<PROMPT
DONE/AMBITION check (independent, stronger model). A refactor of $file :: $sym passed the structural gate (facts: $facts). Original intent: "$intent".
Read the committed diff. Write ONLY this JSON to $report:
{"complete":bool (genuinely done for THIS target, not half), "commensurate":bool (matches the ambition of the ask vs safe-but-small while the real impact sits in owner-gated/no-go findings: $hardlist), "verdict":"complete-and-commensurate|complete-but-under-ambitious|incomplete", "biggerTarget":"the owner-gated target the real impact sits in, or ''", "reason":""}
If safe-small-vs-big-ask, verdict=complete-but-under-ambitious and name biggerTarget.
PROMPT
}
