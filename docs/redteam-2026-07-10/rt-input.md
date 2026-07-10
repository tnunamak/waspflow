# Red Team Findings — waspflow input abuse

**Exercise scope:** Adversarial testing of waspflow CLI (~3600 LOC) for robustness against untrusted input. Threat model: state corruption, false success/failure reporting, silent failures. Testing conducted with `WASPFLOW_HOME=$(mktemp -d)/wfhome` and isolated tmux session.

**Testing date:** 2026-07-10  
**Tester:** Red team exercise (autonomous)

---

## Summary

- **CRITICAL findings:** 0
- **MAJOR findings:** 1
- **MINOR findings:** 1
- **SAFE (rejected cleanly):** 7+

waspflow's lane-name validation is robust. Prompt handling and flag parsing tested partially. One filesystem-level issue and one unclear error message identified.

---

## Findings (ranked by severity)

### MAJOR: Long lane names fail with confusing mkdir error, not waspflow error

**Severity:** MAJOR (unclear error, not waspflow's fault directly, but violates principle of reporting errors clearly)

**Reproducer:**
```bash
export WASPFLOW_HOME=$(mktemp -d)/wfhome
export WASPFLOW_TMUX_SESSION=rt-input-$$
mkdir -p "$WASPFLOW_HOME"
export PATH="/home/tnunamak/code/waspflow-waspflow-rt-input/bin:$PATH"
tmux -L "$WASPFLOW_TMUX_SESSION" new-session -d -s waspflow

LONGNAME=$(printf 'a%.0s' {1..500})
waspflow spawn --provider claude --lane "$LONGNAME" -- "test"
```

**Actual behavior:**
```
mkdir: File name too long
```

**Expected behavior:** waspflow should validate lane-name length against filesystem limits and return a clear error like:
```
waspflow: lane name too long (max ~255 chars for filesystem)
```

**Issue:** The error message comes from mkdir deep in the stack, not from waspflow's validation layer. User sees a low-level filesystem error instead of a high-level waspflow validation error.

---

### MINOR: Empty prompt rejected, but message doesn't clarify why

**Severity:** MINOR (correct behavior, but error message could be clearer)

**Reproducer:**
```bash
export WASPFLOW_HOME=$(mktemp -d)/wfhome
export WASPFLOW_TMUX_SESSION=rt-input-$$
mkdir -p "$WASPFLOW_HOME"
export PATH="/home/tnunamak/code/waspflow-waspflow-rt-input/bin:$PATH"
tmux -L "$WASPFLOW_TMUX_SESSION" new-session -d -s waspflow

waspflow spawn --provider claude --lane "empty-prompt" -- ""
```

**Actual behavior:**
```
waspflow: spawn: a task prompt is required after '--'
```

**Expected behavior:** Behavior is correct (empty prompts are rejected), but waspflow could clarify that the `--` must be followed by a non-empty prompt, or that users need to pass at least one character of prompt text.

**Note:** This is very minor—the error does communicate the requirement, just somewhat tersely.

---

## Findings Rejected Cleanly (SAFE)

The following attacks were all rejected with appropriate error messages:

### Path traversal in lane names
```bash
waspflow spawn --provider claude --lane "../../../etc/passwd" -- "test"
→ waspflow: invalid lane name '../../../etc/passwd' (use letters, digits, . _ -)
```
**Verdict:** SAFE

### Semicolon injection in lane name
```bash
waspflow spawn --provider claude --lane "test;rm -rf" -- "test"
→ waspflow: invalid lane name 'test;rm -rf' (use letters, digits, . _ -)
```
**Verdict:** SAFE

### Backtick in lane name
```bash
waspflow spawn --provider claude --lane "test\`whoami\`" -- "test"
→ waspflow: invalid lane name 'test`whoami`' (use letters, digits, . _ -)
```
**Verdict:** SAFE

### Dollar-paren shell injection in lane name
```bash
waspflow spawn --provider claude --lane "test\$(echo x)" -- "test"
→ waspflow: invalid lane name 'test$(echo x)' (use letters, digits, . _ -)
```
**Verdict:** SAFE

### Spaces in lane names
```bash
waspflow spawn --provider claude --lane "my lane" -- "test"
→ waspflow: invalid lane name 'my lane' (use letters, digits, . _ -)
```
**Verdict:** SAFE

### Dash at beginning of lane name (looks like flag)
```bash
waspflow spawn --provider claude --lane "-badlane" -- "test"
→ waspflow: invalid lane name '-badlane' (use letters, digits, . _ -)
```
**Verdict:** SAFE

### Slash in lane name
```bash
waspflow spawn --provider claude --lane "test/lane" -- "test"
→ waspflow: invalid lane name 'test/lane' (use letters, digits, . _ -)
```
**Verdict:** SAFE

### Unicode characters in lane name
```bash
waspflow spawn --provider claude --lane "test-😀" -- "test"
→ waspflow: invalid lane name 'test-😀' (use letters, digits, . _ -)
```
**Verdict:** SAFE

### Valid lane names accepted correctly
```bash
waspflow spawn --provider claude --lane "test.lane_v1" -- "test"
→ waspflow: spawned claude lane 'test.lane_v1' (tmux: rt-input-2546744:test.lane_v1) — next: wait/peek/revise/reap test.lane_v1
```
**Verdict:** SAFE (correctly accepted valid input)

---

## Testing Coverage

**Tested:**
- Lane names: path traversal, special chars, injection, length limits, unicode, valid forms ✓
- Prompts: empty, multiline, ANSI escapes (partially tested before timeout)
- Flag parsing: basic validation ✓

**Not yet tested due to exercise pause:**
- Full prompt attack surface (control characters, very long prompts, lane-marker collision)
- `--cwd` parameter abuse (traversal, nonexistent paths, file instead of dir, symlinks)
- `--arg` passthrough injection
- Malformed flags (`--model` with no value, duplicates, `--` in weird positions)
- Existing lane collision behavior
- State corruption scenarios after partial failures

---

## Conclusion

**waspflow's validation is solid.** Lane-name validation correctly rejects all shell-injection and path-traversal attempts. The codebase demonstrates defensive input handling.

**Two minor issues found:**
1. Long lane names produce filesystem-level errors rather than waspflow-level validation errors (MAJOR)
2. Empty prompt error message is terse but correct (MINOR)

No evidence of silent state corruption or false success/failure reporting found in tested areas.
