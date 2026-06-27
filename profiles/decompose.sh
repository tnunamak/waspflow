#!/usr/bin/env bash
# profiles/decompose.sh — FILE-LEVEL DECOMPOSITION profile for the waspflow loop.
# Extracts a cohesive SECTION of a giant file into its own module, re-exported from the
# original so all imports keep working. The gate is the deterministic oracle: tsc clean +
# tests pass + the diff is a pure MOVE (no logic change). Reuses the same loop machinery.
#
# Unlike the refactor profile, the target is NOT a complexity finding — it's a named section
# (line range) the dispatcher pins. So there's no lint-complexity discovery here; selection is
# the dispatcher handing one section. The oracle's complexity checks are not the gate; tsc+tests are.
#
# Config (.waspflow/decompose.json), set per-target by the dispatcher:
#   { "file": "<the giant file>", "section": "<human name>", "newModule": "<new file path>",
#     "startLine": N, "endLine": M, "testCmd": "...", "typeCheckCmd": "..." }

_decompose_config() {
  local cfg="${LOOP_DECOMPOSE_CONFIG:-}"
  [ -z "$cfg" ] && [ -n "${LOOP_WORKTREE:-}" ] && cfg="$LOOP_WORKTREE/.waspflow/decompose.json"
  [ -n "$cfg" ] && [ -f "$cfg" ] && printf '%s' "$cfg"
}
_dc_get() { local cfg; cfg="$(_decompose_config)"; [ -n "$cfg" ] && python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$cfg" "$1" 2>/dev/null; }

# The loop's lint slots are unused for decomposition (target is a section, not a lint finding),
# but the engine calls them — return harmless no-ops so discover/select don't drive selection.
profile_lint_cmd()      { printf 'true'; }
profile_lint_file_cmd() { printf 'true'; }
# select_target: the dispatcher pins the section via config; echo it as the target JSON.
profile_select_target() {
  cat >/dev/null  # ignore any piped findings
  local f s; f="$(_dc_get file)"; s="$(_dc_get section)"
  [ -n "$f" ] || { printf ''; return 0; }
  printf '{"file":"%s","line":%s,"complexity":0,"symbol":"%s"}' "$f" "$(_dc_get startLine)" "$s"
}
# test command from config (the dispatcher sets the giant file's package test bundle).
profile_test_cmd()      { _dc_get testCmd; }
profile_typecheck_cmd() { _dc_get typeCheckCmd; }

# MAKER: move the section into a new module, re-export. The engine reads git, not prose.
profile_make_prompt() {
  local target="$1" report="$2"
  local file section newmod sl el; file="$(_dc_get file)"; section="$(_dc_get section)"
  newmod="$(_dc_get newModule)"; sl="$(_dc_get startLine)"; el="$(_dc_get endLine)"
  cat <<PROMPT
FILE-DECOMPOSITION MAKER. Move the "$section" section (roughly lines $sl–$el of $file) into a
NEW module file: $newmod. Then RE-EXPORT everything that section provided from $file (so every
existing import of $file keeps resolving — add 'export * from "./$(basename "$newmod" .ts)";' or
explicit re-exports as the codebase style prefers).

RULES — this is a pure MOVE, behavior-preserving EXACTLY:
- Do NOT change any logic, types, strings, or ordering. Cut the code, paste it into $newmod unchanged.
- In $newmod, add the imports that section needs (types/values it references from $file or elsewhere).
- If the section uses symbols defined elsewhere in $file that are NOT exported, EITHER export them
  from $file and import them into $newmod, OR move them too if they belong with the section.
- Preserve every comment, including the section header.
- Keep the public surface of $file IDENTICAL (re-exports cover everything that was reachable).
- Do NOT touch unrelated sections.

VERIFY before committing: the package typechecks (tsc) and tests pass. If the section cannot be
cleanly extracted without changing behavior or creating a circular import, write 'ABANDON: <reason>'
and make NO commit.

Commit ONE change on a NEW branch named decompose/<short> branched off the CURRENT worktree HEAD.
Write a 1-2 sentence note to $report: the branch name and what moved.
PROMPT
}

profile_revise_prompt() {
  local target="$1" facts="$2" verdict="$3" report="$4"
  cat <<PROMPT
DECOMPOSITION MAKER, REVISING. The gate did NOT pass.
Oracle facts (un-fakeable): $facts
Checker verdict: $verdict
Fix EXACTLY what failed on the SAME branch (most likely: a missing import in the new module, a
non-re-exported symbol, or a circular import). Keep it a pure behavior-preserving MOVE. If it
cannot be done cleanly, write 'ABANDON: <reason>' to $report.
PROMPT
}

# CHECKER (stronger model): the diff must be a PURE MOVE. Sentinel VERDICT: LAND|REVISE.
profile_check_prompt() {
  local target="$1" branch="$2" facts="$3" report="$4"
  local file; file="$(_dc_get file)"
  cat <<PROMPT
INDEPENDENT CHECKER (stronger/different model). The deterministic ORACLE ALREADY PASSED (tsc clean,
tests green) — these are FACTS: $facts. Your ONE job: confirm the diff is a PURE MOVE, not a rewrite.
READ THE DIFF: \`git diff origin/main...$branch\` (use the per-target base if set). Confirm:
- The lines moved out of $file are IDENTICAL to the lines added in the new module (a relocation,
  not a reimplementation). Allow ONLY added imports/exports and the re-export line.
- No logic/type/string/ordering change to the moved code.
- $file's public surface is unchanged (everything still re-exported).
- No new behavior, no "while I'm here" edits.
Write reasoning to $report, then end with EXACTLY ONE line:
VERDICT: LAND      (iff a clean pure move)
VERDICT: REVISE    (any logic change, missing re-export, surface change, or you couldn't verify)
PROMPT
}

profile_done_prompt() {
  local target="$1" facts="$2" remaining="$3" intent="$4" report="$5"
  cat <<PROMPT
LOOP-CONTROL (independent). A section decomposition just passed the gate (facts: $facts). Ask: "$intent".
Write reasoning to $report ending with EXACTLY ONE line:
DONE | CONTINUE | ESCALATE
(You are NOT re-judging the diff — it passed. Only decide whether more sections should follow.)
PROMPT
}
