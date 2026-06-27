#!/usr/bin/env bash
# profiles/refactor.sh — the GENERIC behavior-preserving refactoring profile for the
# waspflow gated loop. Ships in waspflow; NO repo-specific knowledge. All repo specifics
# (lint dirs/cmd, no-go globs, file→test map) come from a config file IN THE TARGET REPO,
# discovered via $LOOP_REFACTOR_CONFIG or <worktree>/.waspflow/refactor.json.
#
# DECOMPLECTED DESIGN (Claude+Codex, SLVP-ideal). Strict schemas live ONLY at deterministic
# boundaries (oracle output, repo config). NO agent hands structured telemetry to the engine:
#   - target selection is DETERMINISTIC in the engine over the ORACLE's raw findings — there
#     is NO classify agent (it would only guess "safe?" before a diff exists; the oracle gate
#     + checker on the real diff are strictly stronger). no-go is a path-glob list.
#   - the MAKER writes a real branch diff, or one `ABANDON: <reason>` line. The engine reads
#     git, not a maker report.
#   - the CHECKER reads the real diff and emits one token: `VERDICT: LAND` | `VERDICT: REVISE`.
#   - the DONE agent emits one token: `DONE` | `CONTINUE` | `ESCALATE`.
# Facts the engine can measure, the engine measures. Judgment stays prose. A missing/ambiguous
# token FAILS CLOSED.
#
# Config schema (.waspflow/refactor.json), all optional with conservative generic fallbacks:
#   { "lintCmd":  "npx --yes @biomejs/biome lint",
#     "lintDirs": "src",
#     "noGoGlobs":["**/auth/**","**/*credential*"],   # PATH globs excluded from selection (machine-checkable)
#     "noGo":     "auth, payments, ...",               # human-readable no-go note for the maker (prose only)
#     "vendorGlobs":["**/node_modules/**","**/*.gen.ts"],
#     "testMap":  [["src/","pnpm -s test"], ...] }     # file-PREFIX → test cmd (longest prefix wins)

_refactor_config() {
  local cfg="${LOOP_REFACTOR_CONFIG:-}"
  [ -z "$cfg" ] && [ -n "${LOOP_WORKTREE:-}" ] && cfg="$LOOP_WORKTREE/.waspflow/refactor.json"
  [ -n "$cfg" ] && [ -f "$cfg" ] && printf '%s' "$cfg"
}
# Read one STRING config key with a fallback. $1 (ignored, kept for call-site clarity) $2 key $3 fallback
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

profile_lint_cmd()      { printf '%s %s' "$LOOP_LINT_CMD" "$LOOP_LINT_DIRS"; }
profile_lint_file_cmd() { printf '%s %s' "$LOOP_LINT_CMD" "$1"; }

# ── DETERMINISTIC TARGET SELECTION (engine-side, over ORACLE findings) ───────────────
# Reads the oracle's raw findings JSON on stdin (list of {file,line,complexity,...}),
# applies repo no-go + vendor PATH globs, and echoes ONE target JSON {file,line,complexity}
# = the highest-complexity eligible finding (stable tiebreak: lowest file then line).
# Empty output → engine reports an honest non-finding. NO agent involved.
profile_select_target() {
  local cfg; cfg="$(_refactor_config)"
  python3 -c '
import json, sys, fnmatch
findings = json.load(sys.stdin)
cfg = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
nogo, vendor = [], []
if cfg:
    try:
        c = json.load(open(cfg))
        nogo   = [g for g in (c.get("noGoGlobs")   or []) if isinstance(g, str)]
        vendor = [g for g in (c.get("vendorGlobs") or []) if isinstance(g, str)]
    except Exception:
        nogo, vendor = [], []
pin = (c.get("pinTarget") if cfg else None) or None  # Codex dispatcher-verify #2: exact target pin
def excluded(path):
    return any(fnmatch.fnmatch(path, g) for g in nogo) or any(fnmatch.fnmatch(path, g) for g in vendor)
elig = [f for f in (findings if isinstance(findings, list) else [])
        if f.get("file") and f.get("line") is not None and f.get("complexity") is not None
        and not excluded(f["file"])]
if not elig:
    print(""); sys.exit(0)
if pin and isinstance(pin, dict):
    # PINNED: select EXACTLY the ledgered finding by (file, complexity). Line shifts after
    # mechanical commits so it is a tiebreak, not a key. If no exact match → FAIL CLOSED (empty),
    # so a packet can NEVER silently refactor a different (easier/shifted) function in the file.
    # Codex re-verify: two targets can share (file,complexity) — the LINE disambiguates (it is
    # accurate at selection time, before any same-file land). Require a match within a tight line
    # window; carry the PINNED SYMBOL into the output so the oracle can span-ground clearing.
    pf, pcx, pln, psym = pin.get("file"), pin.get("complexity"), pin.get("line"), pin.get("symbol","")
    matches = [f for f in elig if f["file"] == pf and str(f["complexity"]) == str(pcx)]
    if pln is not None:
        # Codex re-verify-3 #2: when a line is pinned, REQUIRE a match within the tight window.
        # If none → FAIL CLOSED (do NOT fall back to any same-complexity finding — that would let
        # a stale pin silently select the wrong same-(file,complexity) function).
        near = [f for f in matches if abs(int(f["line"]) - int(pln)) <= 30]
        if not near:
            print(""); sys.exit(0)
        near.sort(key=lambda f: abs(int(f["line"]) - int(pln)))
        matches = near
    if not matches:
        print(""); sys.exit(0)
    t = matches[0]
    print(json.dumps({"file": t["file"], "line": t["line"], "complexity": t["complexity"],
                      "symbol": psym or t.get("symbol", "")}))
    sys.exit(0)
else:
    # UNPINNED: highest complexity wins; stable tiebreak by (file, line).
    elig.sort(key=lambda f: (-int(f["complexity"]), str(f["file"]), int(f["line"])))
    t = elig[0]
print(json.dumps({"file": t["file"], "line": t["line"], "complexity": t["complexity"],
                  "symbol": t.get("symbol", "")}))
' "${cfg:-}"
}

# DETERMINISTIC test command from the touched FILE via the repo testMap. Unknown path →
# empty → oracle gate fails closed. Agent never authors this.
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
else: print("")
' "${cfg:-}"
}

# ── AGENT PROMPTS — each reduces to a real artifact + ONE fail-closed sentinel ───────

# MAKER: one behavior-preserving refactor of the engine-chosen target, or ABANDON.
# The engine reads GIT (branch diff), not a maker report. Sentinel: ABANDON: <reason>.
profile_make_prompt() {
  local target="$1" report="$2"
  local file line; file="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')"
  line="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["line"])')"
  cat <<PROMPT
MAKER in an automated behavior-preserving refactoring loop. TARGET (engine-selected, the
highest-complexity eligible function): $file, around line $line. It has an over-complexity
lint diagnostic. Decomplect it (extract a genuinely deep helper / introduce an early return /
delete dead code / name a magic value) so the diagnostic clears — WITHOUT changing behavior.

RULES (behavior-preserving EXACTLY): no logic/order/string/output change. grep-verify caller
counts before any inline or delete. Do NOT inline a NAMED+COMMENTED helper. No new export/route/
file/wrapper unless it is a genuinely deep extraction. Stay within $file unless a caller MUST
change. Repo no-go areas (do not refactor sensitive logic): $LOOP_NOGO.

Commit ONE change on a NEW branch named refactor/<short-slug> branched off the CURRENT HEAD
of this worktree (run: git checkout -b refactor/<short-slug>). Do NOT check out origin/main or
any other base first — the worktree is already on the correct base commit for this task.

OUTPUT (the engine reads git, not your prose): write a 1-2 sentence note to $report saying the
branch name and what burden you removed. If this target is essential complexity, unsafe, or
cannot be done behavior-preservingly, make NO commit and write exactly one line to $report:
ABANDON: <one-sentence reason>
PROMPT
}

# REVISE: same target, the gate failed; fix on the SAME branch, or ABANDON.
profile_revise_prompt() {
  local target="$1" facts="$2" verdict="$3" report="$4"
  local file; file="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')"
  cat <<PROMPT
MAKER, REVISING your refactor of $file. The gate did NOT pass.
Objective oracle facts (un-fakeable, the engine measured these): $facts
Independent checker verdict + reasons: $verdict
Fix EXACTLY what failed and amend/commit on the SAME branch (keep it behavior-preserving). If
the target is fundamentally essential/unsafe or your change can't be made behavior-preserving,
write exactly one line to $report: ABANDON: <reason>
PROMPT
}

# CHECKER (stronger/different model): reads the REAL diff. Sentinel: VERDICT: LAND | REVISE.
# The oracle already passed before this runs; the checker catches semantic behavior changes the
# oracle can't prove. It is given ONLY the diff + oracle facts (NOT a maker summary).
profile_check_prompt() {
  local target="$1" branch="$2" facts="$3" report="$4"
  local file; file="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')"
  cat <<PROMPT
INDEPENDENT CHECKER (stronger/different model than the maker). The deterministic ORACLE ALREADY
PASSED — these are FACTS, do not restate exit codes: $facts
Your ONE job is the semantic judgment the script cannot make. READ THE ACTUAL DIFF (do not trust
any summary): \`git diff origin/main...$branch -- $file\` (and any other touched file in the diff).
Judge ONLY: is this a genuine behavior-preserving decomplection (no logic/order/string/output
change; caller counts intact; no slop — no net-positive prod LOC for its own sake, no new 1-caller
wrapper, no named+commented helper inlined, no tautological tests; no export/route/manifest/DB
surface change)?

Write your reasoning as prose to $report, then end with EXACTLY ONE line, nothing after it:
VERDICT: LAND      (iff it is a real behavior-preserving decomplection)
VERDICT: REVISE    (any behavior risk, slop, surface change, OR if you could not read the diff)
If you are unsure or evidence is missing, choose REVISE.
PROMPT
}

# DONE/AMBITION (independent): loop control ONLY — cannot rescue a failed gate.
# Sentinel: DONE | CONTINUE | ESCALATE.
profile_done_prompt() {
  local target="$1" facts="$2" remaining="$3" intent="$4" report="$5"
  local file; file="$(printf '%s' "$target" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')"
  cat <<PROMPT
AMBITION / LOOP-CONTROL check (independent, stronger/different model). A behavior-preserving
refactor of $file just PASSED the oracle + checker gate (facts: $facts). Original ask: "$intent".
Remaining eligible over-complex findings the engine could pick next: $remaining

Decide ONLY whether the loop should continue, and write prose reasoning to $report ending with
EXACTLY ONE line, nothing after it:
DONE       (the ask is satisfied by what landed)
CONTINUE   (landed change is good but the ask wants more — engine should select the next target)
ESCALATE   (the real impact sits in essential/owner-gated areas the loop must not touch alone)
You are NOT judging whether the diff passed (it did). You only decide continue-or-stop.
PROMPT
}
