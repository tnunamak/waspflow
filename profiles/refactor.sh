#!/usr/bin/env bash
# profiles/refactor.sh — the GENERIC behavior-preserving refactoring profile for the
# waspflow gated loop. This file ships in waspflow and contains NO repo-specific
# knowledge. ALL repo specifics (lint dirs, no-go zones, package→test map) come from
# a config file IN THE TARGET REPO, discovered via $LOOP_REFACTOR_CONFIG or
# <worktree>/.waspflow/refactor.json. The engine sets $LOOP_WORKTREE before sourcing.
#
# Config schema (.waspflow/refactor.json), all optional with safe generic fallbacks:
#   { "lintDirs": "src",                          # dirs the repo-wide linter scans
#     "lintCmd":  "npx --yes @biomejs/biome lint", # the linter invocation (must print biome-style output)
#     "noGo":     "auth, payments, ...",           # human-readable no-touch zones for the classifier
#     "testMap":  [["src/", "pnpm -s test"], ...] } # file-PREFIX → deterministic test command (longest prefix wins)
#
# If no config is found, defaults are conservative and NOT tied to any project.

_refactor_config() {
  local cfg="${LOOP_REFACTOR_CONFIG:-}"
  [ -z "$cfg" ] && [ -n "${LOOP_WORKTREE:-}" ] && cfg="$LOOP_WORKTREE/.waspflow/refactor.json"
  [ -n "$cfg" ] && [ -f "$cfg" ] && printf '%s' "$cfg"
}
# Read one config key with a fallback. $1 jq-path  $2 fallback
_refactor_cfg_get() {
  local cfg; cfg="$(_refactor_config)"
  if [ -n "$cfg" ]; then
    python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2])
print(v if isinstance(v,str) and v else sys.argv[3])' "$cfg" "$2" "$3" 2>/dev/null || printf '%s' "$3"
  else
    printf '%s' "$3"
  fi
}

LOOP_LINT_DIRS="${LOOP_LINT_DIRS:-$(_refactor_cfg_get x lintDirs "src")}"
LOOP_LINT_CMD="${LOOP_LINT_CMD:-$(_refactor_cfg_get x lintCmd "npx --yes @biomejs/biome lint")}"
LOOP_NOGO="${LOOP_NOGO:-$(_refactor_cfg_get x noGo "auth/credentials/secrets, persistence/migrations, public API surface, anything security- or money-sensitive")}"

profile_lint_cmd() {
  printf '%s %s' "$LOOP_LINT_CMD" "$LOOP_LINT_DIRS"
}
profile_lint_file_cmd() {
  printf '%s %s' "$LOOP_LINT_CMD" "$1"
}

# The agent classifies the ORACLE's raw findings and ranks safe targets. It does
# NOT source the linter count. Writes JSON {classified,hardAreasInspected,safeTargets,recommendation}.
profile_classify_prompt() {
  local rawjson="$1" intent="$2"
  cat <<PROMPT
You are CLASSIFY+RANK in a behavior-preserving refactoring loop. Intent: "$intent".
The DETERMINISTIC linter already ran (do NOT re-run it or change the count). GROUND-TRUTH over-complex functions (file:line:complexity): $rawjson
For EACH finding, read the code at file:line, name the function symbol, and classify: safe-incidental | essential-complexity | protocol-sensitive | high-value-owner-gated, each with whyNotSafe (""=safe). You MUST inspect the no-go-prone areas and list which in hardAreasInspected: $LOOP_NOGO. Do NOT exclude-then-conclude "nothing exists" (the under-reach failure).
For each SAFE-INCIDENTAL finding add a safeTargets entry: a behavior-preserving move (decomplect/name/early-return/delete-dead/extract-only-deep — NOT inline-a-named-wrapper), value (integer, scales with how often the code is read/changed), and the package dir. ALSO carry the EXACT linter "line" AND "complexity" for that finding into the entry (the oracle joins on file+line+complexity — do NOT omit, rename, or alter them). Do NOT propose a test command; the engine derives the required test deterministically from the package.

OUTPUT CONTRACT — this is parsed by a STRICT machine, not a human. Write ONLY this JSON object to your report file (no prose, no markdown fences, no extra keys at the top level). You MUST use these EXACT top-level key names — "classified", "hardAreasInspected", "safeTargets", "recommendation", "note". Any other names (e.g. "findings", "safe_targets", "no_go_count", snake_case variants) will be REJECTED and the run fails closed. "recommendation" MUST be exactly one of: go-loop | one-pr-no-loop | non-finding | needs-owner. Every one of the $(printf '%s' "$rawjson" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null) findings MUST appear in "classified".

Copy this skeleton exactly and fill it:
{
  "classified": [
    {"file":"path/x.ts","symbol":"fnName","line":123,"complexity":31,"classification":"safe-incidental","whyNotSafe":""},
    {"file":"path/y.ts","symbol":"authThing","line":50,"complexity":40,"classification":"protocol-sensitive","whyNotSafe":"auth/token no-go zone"}
  ],
  "hardAreasInspected": ["auth/grant/consent/token","scheduler/controller/recovery"],
  "safeTargets": [
    {"file":"path/x.ts","symbol":"fnName","line":123,"complexity":31,"move":"extract a deep helper","value":8,"package":"packages/operator-ui/src"}
  ],
  "recommendation": "go-loop",
  "note": ""
}
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

# DETERMINISTIC test command, derived from the touched FILE via the REPO'S testMap
# (Codex review-4 #2: the agent must NOT author the oracle's test command — it could
# pick `true`). The map lives in the target repo's .waspflow/refactor.json, NOT here.
# Longest file-PREFIX wins. Unknown path → empty → the oracle gate FAILS CLOSED.
profile_test_cmd() {
  local target="$1" cfg; cfg="$(_refactor_config)"
  printf '%s' "$target" | python3 -c '
import json,sys
d=json.load(sys.stdin); f=(d.get("file") or "")
cfg=sys.argv[1] if len(sys.argv)>1 and sys.argv[1] else None
testmap=[]
if cfg:
    try:
        c=json.load(open(cfg)); tm=c.get("testMap") or []
        testmap=[(p[0],p[1]) for p in tm if isinstance(p,list) and len(p)==2]
    except Exception: testmap=[]
for pre,cmd in sorted(testmap, key=lambda x:-len(x[0])):
    if f.startswith(pre): print(cmd); break
else: print("")  # no repo testMap match → empty → oracle hard-fails (no false-pass)
' "${cfg:-}"
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
