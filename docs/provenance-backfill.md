# Forensic parent backfill

`waspflow provenance backfill` appends a parent fact only when the read-only
`waspflow-provenance.py` helper found one exact root. It is for recovering old
launches that have an `absent` parent in their immutable `lane_started` receipt.

The operation records `parent.evidence_class: forensic_spawn_call` in a new
`lane_parent_backfilled` event. It never rewrites `lane_started` and it never
changes lane state, a worktree, or a tmux window.

## Run

First create the input with the strict helper. Pass the lanes whose original
launch receipts have an absent parent.

```bash
state_home="${WASPFLOW_HOME:-$HOME/.local/state/waspflow}"
absent_lanes="$(jq -r 'select(.event_type == "lane_started" and .parent.evidence_class == "absent") | .lane.label' \
  "$state_home/provenance.jsonl" | paste -sd, -)"
waspflow-provenance.py --lanes "$absent_lanes" --json > provenance-helper.json
```

Then append the revalidated facts. Repeat `--skip` for any lane another owner
has reserved.

```bash
waspflow provenance backfill --report provenance-helper.json \
  --skip reserved-lane
```

The command validates every `exact_spawn_call` row again against the source
JSONL record. It accepts only a matching `waspflow spawn --lane` value in a
submitted tool-command argument. It does not inspect assistant prose,
transcripts, `aggregated_output`, or other tool output. A failed revalidation
stops the operation before it appends any event.

Each event contains the recovered root session, the command SHA-256 digest,
the exact command-input field, a hashed source path, the source byte offset,
and the source timestamp. It does not retain the raw command.

The event ID is derived from the lane UUID and event kind. The ledger append
lock recognizes it on a later run, so a retry reports `already_present` and
writes no duplicate event. Unresolved rows produce no event and remain
available for a later report.
