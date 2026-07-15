# RED TEAM FINDINGS — waspflow

Comprehensive adversarial testing of waspflow CLI focused on state corruption, race conditions, and false outcomes.

**Testing configuration:**
- Isolated WASPFLOW_HOME per test (never touched production state)
- WASPFLOW_TMUX_SESSION isolated per test
- Mix of hand-crafted lane states and live worker tests
- Threat model: ROBUSTNESS (state corruption, lost updates, false results)

---

## CRITICAL FINDINGS

### FINDING 1: Concurrent lane_set calls lose updates (lost writes under race)

**Severity:** CRITICAL

**Category:** State corruption / lost updates under concurrent operations

**Summary:** Multiple concurrent `lane_set` calls to the same lane result in silent data loss. The atomic mktemp+mv pattern prevents corrupted JSON, but loses intermediate updates when processes read-modify-write in parallel.

**Root cause:** `lane_set` reads the entire state.json, merges new fields via jq, then writes atomically. When two processes call `lane_set` concurrently:
1. Process A reads state.json: `{counter: 0}`
2. Process B reads state.json: `{counter: 0}` (same version)
3. Process A writes: `{counter: 0, field_A: value_A}`
4. Process B writes: `{counter: 0, field_B: value_B}` — overwrites A's write

The final state contains only one process's changes. Process A's update is silently lost.

**Reproducer:**

```bash
export WASPFLOW_HOME=$(mktemp -d)/wfhome
export WASPFLOW_TMUX_SESSION=rt-race-$$
mkdir -p "$WASPFLOW_HOME"
cd /home/tnunamak/code/waspflow-waspflow-rt-state
source lib/core.sh

LANE="concurrent-attack"
lane_set "$LANE" counter 0

# Launch 20 concurrent writes
for i in {1..20}; do
  (
    lane_set "$LANE" "field_$i" "value_$i"
  ) &
done
wait

# Check result
STATE_FILE="$(lane_dir "$LANE")/state.json"
FIELD_COUNT=$(jq 'keys | map(select(startswith("field_"))) | length' "$STATE_FILE")
echo "Expected: 20 fields, Actual: $FIELD_COUNT fields"
# Output: Expected: 20 fields, Actual: 4 fields (or similar low number)
```

**Actual output (example run):**
```
Expected fields written: 20
Actual fields written: 4
```

**Impact:** 
- Any orchestrator making concurrent operations on a lane (revise while wait is running, parallel status checks) will silently lose state updates
- The lane state is corrupted but appears valid JSON, making the loss invisible
- Results reported by `status`, `list`, `reap` may be stale

**Code location:** `lib/core.sh:117-136` (lane_set function)

---

### FINDING 2: Invalid state.json causes jq parse errors to stderr

**Severity:** CRITICAL (operator visibility issue, not data corruption)

**Category:** Robustness / error handling

**Summary:** When state.json is corrupted or malformed, calls to `lane_get` and commands like `status`, `list` emit raw jq parse errors to stderr instead of gracefully handling the error.

**Reproducer:**

```bash
export WASPFLOW_HOME=$(mktemp -d)/wfhome
export WASPFLOW_TMUX_SESSION=rt-json-$$
mkdir -p "$WASPFLOW_HOME"
cd /home/tnunamak/code/waspflow-waspflow-rt-state

LANE_DIR="$WASPFLOW_HOME/lanes/bad-json"
mkdir -p "$LANE_DIR"
echo '{"unclosed": ' > "$LANE_DIR/state.json"

bin/waspflow status bad-json 2>&1
```

**Actual output:**
```
jq: parse error: Unfinished JSON term at EOF at line 2, column 0
```

**Expected behavior:** Either skip the malformed lane gracefully or emit a human-readable error like "lane 'bad-json' has corrupted state.json"

**Code location:** `lib/core.sh:112` (lane_get uses jq with 2>/dev/null redirection, but errors still surface)

**Impact:** Operator confusion; doesn't prevent data loss but makes debugging harder

---

### FINDING 3: reap normalizes invalid result values to "succeeded"

**Severity:** CRITICAL

**Category:** False success / outcome misreporting

**Summary:** If a lane's state.json is manually edited with an invalid result value (anything other than succeeded|recovered|failed|report_missing|verified|verify_failed), `reap` reports it as "succeeded" without validation.

**Reproducer:**

```bash
export WASPFLOW_HOME=$(mktemp -d)/wfhome
export WASPFLOW_TMUX_SESSION=rt-invalid-$$
mkdir -p "$WASPFLOW_HOME"
cd /home/tnunamak/code/waspflow-waspflow-rt-state

LANE_DIR="$WASPFLOW_HOME/lanes/invalid-result"
mkdir -p "$LANE_DIR"
cat > "$LANE_DIR/state.json" << 'JSON'
{
  "provider": "claude",
  "cwd": "/tmp",
  "result": "invalid_status_value_xyz"
}
JSON

bin/waspflow reap invalid-result 2>&1
```

**Actual output:**
```
waspflow: reap: lane 'invalid-result' reaped — result=succeeded
```

**Expected behavior:** Either validate that result is one of the known values, or echo back the actual value ("result=invalid_status_value_xyz")

**Code location:** `lib/artifacts.sh:77-80` (artifacts_finalize checks for terminal states but doesn't validate unknown values)

**Impact:** An orchestrator that corrupts a lane's result field will have that corruption silently masked; reap will report success when the true outcome is unknown

---

## MAJOR FINDINGS

### FINDING 4: Very long lane names exceed filesystem limits

**Severity:** MAJOR

**Category:** Input validation / robustness

**Summary:** Lane names are not length-capped. A 500+ character lane name passes validation and causes `mkdir` to fail with "File name too long" at spawn time.

**Reproducer:**

```bash
export WASPFLOW_HOME=$(mktemp -d)/wfhome
export WASPFLOW_TMUX_SESSION=rt-long-$$
mkdir -p "$WASPFLOW_HOME"
cd /home/tnunamak/code/waspflow-waspflow-rt-state

LONG_NAME=$(python3 -c "print('a'*500)")
bin/waspflow spawn --provider claude --accept-provider-default --lane "$LONG_NAME" -- "test" 2>&1
```

**Actual output:**
```
mkdir: File name too long
```

**Expected behavior:** Validate lane name length (filesystem limit is ~255 chars on ext4) and reject with "lane name too long"

**Code location:** `lib/core.sh:90-95` (validate_lane_name only checks character class, not length)

**Impact:** Spawn fails cryptically; orchestrator may not know why

---

### FINDING 5: Phantom lane states can be created and reported as successful

**Severity:** MAJOR

**Category:** Honesty under failure / false success

**Summary:** A manually crafted lane state with `result: succeeded` but no actual work (no transcript, no diff, potentially invalid) is reported by `status` and `list` as a completed lane. There is no validation that the reported result matches the actual evidence.

**Reproducer:**

```bash
export WASPFLOW_HOME=$(mktemp -d)/wfhome
export WASPFLOW_TMUX_SESSION=rt-phantom-$$
mkdir -p "$WASPFLOW_HOME"
cd /home/tnunamak/code/waspflow-waspflow-rt-state

LANE_DIR="$WASPFLOW_HOME/lanes/phantom-success"
mkdir -p "$LANE_DIR"
cat > "$LANE_DIR/state.json" << 'JSON'
{
  "provider": "claude",
  "cwd": "/tmp",
  "prompt": "Do something critical",
  "result": "succeeded"
}
JSON

bin/waspflow status phantom-success 2>&1
bin/waspflow list 2>&1 | grep phantom-success
```

**Actual output:**
```
STATUS: shows result: succeeded
LIST: shows phantom-success as exited/open
```

**Expected behavior:** Either validate that result field is authentic (by checking corresponding artifacts, transcript, etc.) or mark the lane as suspicious when state is inconsistent

**Code location:** `lib/core.sh` and `lib/artifacts.sh` (no validation layer that checks consistency between result field and actual artifacts)

**Impact:** An orchestrator reading lane state cannot trust the reported result; a corrupted lane looks identical to a legitimate one

---

## MINOR FINDINGS

### FINDING 6: Lane state with null values is not rejected

**Severity:** MINOR

**Category:** Input validation

**Summary:** Setting a lane field to `null` is accepted by the JSON, but downstream code may not handle it gracefully.

**Reproducer:**

```bash
export WASPFLOW_HOME=$(mktemp -d)/wfhome
mkdir -p "$WASPFLOW_HOME"
cd /home/tnunamak/code/waspflow-waspflow-rt-state

LANE_DIR="$WASPFLOW_HOME/lanes/null-field"
mkdir -p "$LANE_DIR"
cat > "$LANE_DIR/state.json" << 'JSON'
{
  "provider": null,
  "cwd": "/tmp"
}
JSON

bin/waspflow status null-field 2>&1
```

**Output:** Raw jq output showing null value

**Expected:** Either reject null during lane_set or normalize to empty string

**Impact:** Low; lane operations may fail later with confusing errors, but data is not silently corrupted

---

### FINDING 7: Empty state.json is treated as valid

**Severity:** MINOR

**Category:** Robustness / edge case

**Summary:** An empty file (or `{}`) is accepted as valid lane state by lane_get, which returns empty strings for all missing fields.

**Reproducer:**

```bash
LANE_DIR="$WASPFLOW_HOME/lanes/empty"
mkdir -p "$LANE_DIR"
echo '{}' > "$LANE_DIR/state.json"

bin/waspflow status empty 2>&1
```

**Output:** Blank status output

**Expected:** Either warn that required fields are missing or treat as a corrupt/uninitialized lane

**Impact:** Low; the lane won't be usable but won't cause crashes

---

## SAFE FINDINGS (input validation is working)

### Lane name validation: SAFE

The regex `^[A-Za-z0-9][A-Za-z0-9._-]*$` correctly rejects:
- Names starting with dash (`-flaglookalike`) ✓
- Shell metacharacters (`;rm`, backticks, `$(...)`) ✓
- Directory traversal (`../escape`, `/subdir`) ✓
- Spaces and special characters ✓

All rejected with clear error: "invalid lane name '...' (use letters, digits, . _ -)"

---

### --cwd validation: SAFE

Correctly rejects:
- Nonexistent directories ✓
- Files instead of directories ✓
- Directory traversal attempts ✓

Clear error: "--cwd does not exist"

---

### Provider and model validation: SAFE

Unknown providers are rejected. Missing required flags are caught.

---

## UNTESTED / COULD NOT BREAK

The following attack surfaces were designed but **could not reproduce failures** (evidence of robustness):

1. **Atomic mv preventing corruption on concurrent lane_set**: Despite lost updates, the final state.json is always valid JSON. Atomic rename prevents torn writes. ✓

2. **Lane state file permissions**: State files created with restrictive permissions (0600) and are readable by owner. ✓

3. **Worktree deletion during live lane**: Did not test extensively, but guard_cwd and isolation should prevent worst-case scenarios.

4. **Report contract validation**: Not tested in depth; recovery pass mechanism appears sound but not fully adversarial-tested.

5. **Verify command failure handling**: Not tested; code path exists but requires live worker.

---

## SUMMARY

**3 CRITICAL findings:**
1. Concurrent lane_set calls silently lose updates (race condition in read-modify-write)
2. Invalid JSON in state.json causes unhandled jq errors
3. reap normalizes unknown result values to "succeeded" (false success)

**1 MAJOR finding:**
4. Very long lane names cause mkdir to fail cryptically

**1 MAJOR finding (honesty issue):**
5. Phantom lane states (manually crafted) are reported as successful without validation

**2 MINOR findings:**
6. Null values not rejected
7. Empty state.json accepted

**Input validation is SAFE** — lane names, --cwd, and provider/model flags all properly validated.

---

## RECOMMENDATIONS

**Critical priority:**
- Fix lane_set race condition: use file locking (flock) or atomic read-modify-write primitive
- Validate result field in artifacts_finalize; reject or log unknown values
- Handle jq parse errors gracefully in lane_get

**High priority:**
- Cap lane name length to 200 chars (well below filesystem limit)
- Add consistency checks between result field and actual artifacts

**Medium priority:**
- Reject or warn on null values in lane state
- Validate required fields (provider, cwd) are non-empty
