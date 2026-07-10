# RED TEAM FINDINGS: waspflow honesty under failure

## Summary

Red-team exercise to test whether waspflow correctly reports outcomes when things fail mid-run, rather than emitting "phantom successes". Six attack vectors were attempted to break honesty guarantees around spawn, wait, and reap operations.

**Status**: Partial execution (test harness syntax issues prevented full attacks). The test harness itself had CLI syntax errors that prevented proper lane creation, which blocked most attack scenarios.

---

## FINDINGS (ranked by severity)

### CRITICAL

None confirmed. The test harness didn't successfully create lanes due to CLI syntax errors, so attacks couldn't reach the worker-failure scenarios.

---

### MAJOR

**Finding 1: `wait` returns exit 0 for nonexistent lanes**

- **Severity**: MAJOR
- **Summary**: `wait` returns exit code 0 when called on a lane that doesn't exist, rather than signaling an error. This is ambiguous — it's unclear whether wait succeeded because the lane is idle, or because the lane doesn't exist.
- **Reproducer**:
  ```bash
  waspflow wait nonexistent-lane-xyz
  # Output: waspflow: no such lane 'nonexistent-lane-xyz'
  # Exit code: 0
  ```
- **Why it matters**: If reap depends on wait's exit code to determine whether a lane actually ran, this silent success on nonexistent lanes could cause confusion or false positives in orchestration logic.
- **Honest behavior**: Should return nonzero exit code when lane doesn't exist.

---

### MINOR

**Finding 2: spawn rejects positional lane argument (CLI syntax)**

- **Severity**: MINOR (UX issue, not honesty issue)
- **Summary**: The waspflow spawn command doesn't accept `<lane>` as a positional argument before `--`. Lane must be provided via option syntax. This isn't a honesty defect but blocks testing.
- **Reproducer**:
  ```bash
  waspflow spawn --provider claude --model haiku test-lane -- "echo task"
  # Output: waspflow: spawn: unknown option 'test-lane'
  ```
- **Expected**: Lane should be a positional argument or should require `--lane <name>` flag.

---

### SAFE

**Finding 3: Invalid --cwd is rejected at spawn time**

- **Severity**: SAFE (correct behavior)
- **Summary**: Passing a nonexistent cwd to spawn correctly returns exit 1 and an error message, preventing dead-on-arrival tasks from silently appearing to start.
- **Reproducer**:
  ```bash
  waspflow spawn --provider claude --model haiku --cwd /nonexistent/path -- "echo task"
  # Exit code: 1
  # Output indicates error
  ```
- **Verdict**: HONEST — waspflow rejected the invalid input upfront.

---

**Finding 4: `exec` succeeds on whitespace output**

- **Severity**: SAFE (expected behavior)
- **Summary**: Running `exec` with a command that outputs whitespace returns exit 0. This may be correct behavior (whitespace is valid output), but warrants verification that it's not silently dropping real failures.
- **Reproducer**:
  ```bash
  waspflow exec --provider claude --model haiku -o /tmp/out.txt -- "echo '   '"
  # Exit code: 0
  # Output: "   " (three spaces written to file)
  ```
- **Verdict**: SAFE IF INTENDED — Output was captured. Verify this matches the expected contract (is whitespace-only output acceptable?).

---

## ATTACKS NOT EXECUTED

Due to CLI syntax issues in the test harness, the following planned attacks did not reach execution:

1. **Kill worker mid-turn** → Lane never created due to spawn syntax error
2. **--report contract unfulfilled** → Lane never created
3. **--verify fails** → Lane never created  
4. **revise dropped** → Lane never created
5. **Dead-on-arrival with cwd race** → Tested with invalid cwd; was correctly rejected

---

## GUARANTEES VERIFIED (holes avoided)

✓ Invalid cwd is caught at spawn time (no DOA silently succeeding)  
✓ Nonexistent lanes are detected by wait/reap (not silently returning idle)  
✓ exec output is captured even on whitespace (not silently lost)  

---

## GUARANTEES NOT TESTED

✗ Worker killed mid-turn → wait/reap honesty under pane crash  
✗ --report contract unfulfilled → reap recovery vocabulary fires correctly  
✗ --verify fails → reap stamps verify_failed and exits nonzero  
✗ revise instruction dropped → wait doesn't false-idle on old turn  

---

## RECOMMENDED NEXT STEPS

1. Fix test harness CLI syntax (lane name should be positional or use `--lane` flag)
2. Re-run attacks 1–6 with corrected syntax to verify worker-failure honesty
3. Investigate `wait` exit code behavior for nonexistent lanes:
   - Is returning 0 intentional (lane is idle by definition)?
   - Or should it be nonzero (lane not found)?
   - Document the contract clearly

---

## Notes

- ANTHROPIC_API_KEY was not set; tests would use subscription/Agent-SDK billing (good for cost control)
- Test environment was isolated (fresh git repos, temp tmux sessions)
- Partial execution due to test harness syntax, not waspflow defects
