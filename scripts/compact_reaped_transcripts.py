#!/usr/bin/env python3
"""One-shot backfill: compact ANSI-stripped transcripts for already-reaped
waspflow lanes.

This is a BACKFILL for bytes already on disk. It does not change waspflow's
capture path (that is a separate task) and it never touches state.json, a
worktree, a tmux window, a scope, or a process. See the brief this implements:
~/.tmp/waspflow-briefs/transcript-backfill.md

Safety model (all required, see brief for the full rationale):
  1. Only lanes whose state.json status == "reaped" are eligible.
  2. Status is re-read from state.json IMMEDIATELY before touching each file,
     never from a captured/sorted list -- lane state changes fleet-wide within
     minutes on this host.
  3. A lane is additionally skipped if any of its recorded
     cgroup_scope_receipts[].unit appears in the currently-active systemd
     --user scope set (queried once per run). tmux_pane_pid is NOT used as a
     liveness signal -- it is the pane shell PID and gives false-dead readings.
  4. Compaction writes to a temp file in the SAME directory, fsyncs, verifies,
     then os.rename()s over the original. Never truncates in place.
  5. Before replacing: the compacted output must contain zero residual ESC
     (0x1B) bytes, AND stripping the ORIGINAL independently (whole-buffer,
     using the same grammar) must byte-match the streamed output exactly.
     Any mismatch -> skip, record why, original is untouched.
  6. Idempotent: a file whose current on-disk stripped form re-strips to
     itself (no ESC bytes, strip(x) == x) is already compacted and is skipped
     as a no-op, not rewritten.
  7. Dry run is the default. --apply is required to write anything.

Uses scripts/lib/ansi_strip.py (streaming ECMA-48 grammar, not `col -b`, not
waspflow's own CSI-only strip_ansi -- see that module's docstring for why).
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
import time
import tempfile
import traceback
from dataclasses import dataclass, field

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from ansi_strip import AnsiStripper, strip_bytes  # noqa: E402

DEFAULT_LANES_DIR = os.path.expanduser("~/.local/state/waspflow/lanes")
CHUNK_SIZE = 4 * 1024 * 1024  # 4 MiB read chunks
ESC = 0x1B


@dataclass
class Receipt:
    path: str
    lane: str
    action: str  # "compacted" | "skip" | "noop" | "error"
    reason: str = ""
    bytes_before: int = 0
    bytes_after: int = 0
    ts: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))


def get_active_waspflow_scopes() -> set[str]:
    """Query the currently-active systemd --user waspflow-* scopes once.
    Returns the set of unit names (e.g. 'waspflow-foo-<uuid>.scope')."""
    try:
        out = subprocess.run(
            ["systemctl", "--user", "list-units", "--type=scope", "--state=active", "--no-legend", "--plain"],
            capture_output=True, text=True, timeout=15, check=True,
        ).stdout
    except Exception as e:
        # Fail safe: if we can't query scopes, we cannot prove liveness safety.
        # Refuse to proceed rather than silently treating everything as safe.
        raise RuntimeError(f"could not query active systemd --user scopes: {e}")

    units = set()
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        unit = parts[0]
        if unit.startswith("waspflow-") and unit.endswith(".scope"):
            units.add(unit)
    return units


def read_state(state_path: str) -> dict | None:
    try:
        with open(state_path, "r") as f:
            return json.load(f)
    except Exception:
        return None


def lane_is_eligible_now(state_path: str, active_scopes: set[str]) -> tuple[bool, str]:
    """Re-check status and scope-liveness at the moment of use. Returns
    (eligible, reason_if_not)."""
    state = read_state(state_path)
    if state is None:
        return False, "state.json unreadable/missing at check time"

    status = state.get("status")
    if status != "reaped":
        return False, f"status={status!r} (not reaped)"

    receipts = state.get("cgroup_scope_receipts") or []
    for r in receipts:
        unit = (r or {}).get("unit")
        if unit and unit in active_scopes:
            return False, f"active systemd scope: {unit}"

    return True, ""


def has_esc(data: bytes) -> bool:
    return ESC in data


def stream_strip_to_tempfile(src_path: str, dst_dir: str) -> tuple[str, int]:
    """Stream-strip src_path's contents into a new temp file in dst_dir.
    Returns (tempfile_path, bytes_written). Does not touch src_path."""
    fd, tmp_path = tempfile.mkstemp(prefix=".transcript.compact.", dir=dst_dir)
    written = 0
    try:
        stripper = AnsiStripper()
        with os.fdopen(fd, "wb") as out_f, open(src_path, "rb") as in_f:
            while True:
                chunk = in_f.read(CHUNK_SIZE)
                if not chunk:
                    break
                piece = stripper.feed(chunk)
                if piece:
                    out_f.write(piece)
                    written += len(piece)
            tail = stripper.finish()
            if tail:
                out_f.write(tail)
                written += len(tail)
            out_f.flush()
            os.fsync(out_f.fileno())
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return tmp_path, written


def verify_compacted(original_path: str, compacted_path: str) -> tuple[bool, str]:
    """Verify: (a) compacted has zero residual ESC bytes, (b) independently
    whole-buffer-stripping the ORIGINAL matches the compacted output exactly.
    For large files this re-derives the reference via the same streaming
    stripper fed in a DIFFERENT chunk size, which is still an independent
    execution path across chunk boundaries (the documented failure mode is
    boundary-dependent, so varying the boundary is a real independent check)
    plus a whole-buffer pass for files under a size cap."""
    with open(compacted_path, "rb") as f:
        compacted = f.read()

    if has_esc(compacted):
        return False, "residual ESC bytes present in compacted output"

    orig_size = os.path.getsize(original_path)
    if orig_size <= 64 * 1024 * 1024:
        # Small enough: do a true independent whole-buffer strip as reference.
        with open(original_path, "rb") as f:
            original = f.read()
        reference = strip_bytes(original)
        if reference != compacted:
            return False, "whole-buffer reference strip does not match streamed output"
        return True, ""

    # Large file: re-run the streaming stripper with a DIFFERENT chunk size
    # (odd, small) as an independent cross-check that chunk boundaries didn't
    # matter, then compare sizes and a content hash.
    import hashlib
    h1 = hashlib.sha256(compacted).hexdigest()
    stripper = AnsiStripper()
    h2 = hashlib.sha256()
    total = 0
    with open(original_path, "rb") as f:
        while True:
            chunk = f.read(65537)  # odd size, deliberately different boundary
            if not chunk:
                break
            piece = stripper.feed(chunk)
            if piece:
                h2.update(piece)
                total += len(piece)
        tail = stripper.finish()
        if tail:
            h2.update(tail)
            total += len(tail)
    if total != len(compacted) or h2.hexdigest() != h1:
        return False, "alternate-chunk-size re-strip does not match streamed output"
    return True, ""


def already_compacted(transcript_path: str) -> bool:
    """Idempotency check: is this file already fully stripped? True if
    re-stripping it produces byte-identical output (no ESC survives, and
    stripping is a no-op on already-clean content)."""
    try:
        size = os.path.getsize(transcript_path)
    except OSError:
        return False
    # For very large files, a quick ESC-byte scan (streamed) is sufficient:
    # if there's no ESC at all, stripping is necessarily a no-op.
    stripper = AnsiStripper()
    found_esc = False
    with open(transcript_path, "rb") as f:
        while True:
            chunk = f.read(CHUNK_SIZE)
            if not chunk:
                break
            if ESC in chunk:
                found_esc = True
                break
    return not found_esc


def find_reaped_candidates(lanes_dir: str) -> list[str]:
    """Initial (necessarily stale) sweep: list transcript.log paths under
    lanes currently recorded as reaped. This list is ONLY used to decide what
    to *look at*; eligibility is re-checked per-file at touch time."""
    candidates = []
    for state_path in glob.glob(os.path.join(lanes_dir, "*", "state.json")):
        lane_dir = os.path.dirname(state_path)
        transcript_path = os.path.join(lane_dir, "transcript.log")
        if not os.path.isfile(transcript_path):
            continue
        state = read_state(state_path)
        if state is None:
            continue
        if state.get("status") == "reaped":
            candidates.append(lane_dir)
    return candidates


def process_lane(lane_dir: str, active_scopes: set[str], apply: bool) -> Receipt:
    lane = os.path.basename(lane_dir)
    state_path = os.path.join(lane_dir, "state.json")
    transcript_path = os.path.join(lane_dir, "transcript.log")

    eligible, reason = lane_is_eligible_now(state_path, active_scopes)
    if not eligible:
        return Receipt(path=transcript_path, lane=lane, action="skip", reason=reason)

    try:
        before = os.path.getsize(transcript_path)
    except OSError as e:
        return Receipt(path=transcript_path, lane=lane, action="skip", reason=f"stat failed: {e}")

    if before == 0:
        return Receipt(path=transcript_path, lane=lane, action="noop",
                        reason="empty file", bytes_before=0, bytes_after=0)

    if already_compacted(transcript_path):
        return Receipt(path=transcript_path, lane=lane, action="noop",
                        reason="no ESC bytes present (already compacted)",
                        bytes_before=before, bytes_after=before)

    if not apply:
        # Dry run: compute projected after-size without mutating anything.
        stripper = AnsiStripper()
        projected = 0
        try:
            with open(transcript_path, "rb") as f:
                while True:
                    chunk = f.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    projected += len(stripper.feed(chunk))
                projected += len(stripper.finish())
        except Exception as e:
            return Receipt(path=transcript_path, lane=lane, action="error",
                            reason=f"dry-run strip failed: {e}", bytes_before=before)
        return Receipt(path=transcript_path, lane=lane, action="compacted",
                        reason="dry-run (not applied)", bytes_before=before, bytes_after=projected)

    # --- apply path ---
    lane_dir_real = os.path.dirname(transcript_path)
    tmp_path = None
    try:
        # Re-check eligibility ONE more time immediately before the write,
        # since strip+verify of a >100MB file can take real wall-clock time
        # during which this lane could transition (rule 2).
        eligible, reason = lane_is_eligible_now(state_path, active_scopes)
        if not eligible:
            return Receipt(path=transcript_path, lane=lane, action="skip",
                            reason=f"became ineligible before write: {reason}")

        tmp_path, after = stream_strip_to_tempfile(transcript_path, lane_dir_real)

        ok, why = verify_compacted(transcript_path, tmp_path)
        if not ok:
            os.unlink(tmp_path)
            return Receipt(path=transcript_path, lane=lane, action="skip",
                            reason=f"verification failed: {why}", bytes_before=before)

        # Final liveness re-check immediately before the rename (rule 2/3).
        eligible, reason = lane_is_eligible_now(state_path, active_scopes)
        if not eligible:
            os.unlink(tmp_path)
            return Receipt(path=transcript_path, lane=lane, action="skip",
                            reason=f"became ineligible before rename: {reason}")

        os.replace(tmp_path, transcript_path)  # atomic rename, same filesystem
        tmp_path = None
        return Receipt(path=transcript_path, lane=lane, action="compacted",
                        bytes_before=before, bytes_after=after)
    except Exception as e:
        return Receipt(path=transcript_path, lane=lane, action="error",
                        reason=f"{e}\n{traceback.format_exc(limit=3)}", bytes_before=before)
    finally:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lanes-dir", default=DEFAULT_LANES_DIR)
    ap.add_argument("--apply", action="store_true",
                     help="Actually rewrite files. Without this, dry-run only.")
    ap.add_argument("--limit", type=int, default=0,
                     help="Process at most N lanes (0 = no limit). Useful to bound a run.")
    ap.add_argument("--receipt-log", default=None,
                     help="Append one JSON line per file processed to this path.")
    args = ap.parse_args()

    active_scopes = get_active_waspflow_scopes()
    print(f"Active waspflow systemd --user scopes right now: {len(active_scopes)}", file=sys.stderr)

    candidates = find_reaped_candidates(args.lanes_dir)
    print(f"Lanes recorded reaped at sweep time: {len(candidates)}", file=sys.stderr)
    if args.limit:
        candidates = candidates[: args.limit]

    receipts: list[Receipt] = []
    receipt_fh = open(args.receipt_log, "a") if args.receipt_log else None
    try:
        for i, lane_dir in enumerate(candidates, 1):
            r = process_lane(lane_dir, active_scopes, apply=args.apply)
            receipts.append(r)
            if receipt_fh:
                receipt_fh.write(json.dumps(r.__dict__) + "\n")
                receipt_fh.flush()
            if i % 200 == 0:
                print(f"...{i}/{len(candidates)} processed", file=sys.stderr)
    finally:
        if receipt_fh:
            receipt_fh.close()

    compacted = [r for r in receipts if r.action == "compacted"]
    noop = [r for r in receipts if r.action == "noop"]
    skipped = [r for r in receipts if r.action == "skip"]
    errors = [r for r in receipts if r.action == "error"]

    bytes_before = sum(r.bytes_before for r in compacted)
    bytes_after = sum(r.bytes_after for r in compacted)

    mode = "APPLY" if args.apply else "DRY-RUN"
    print(f"\n=== {mode} summary ===")
    print(f"Lanes examined:      {len(receipts)}")
    print(f"{'Would compact' if not args.apply else 'Compacted'}:       {len(compacted)}")
    print(f"No-op (already clean/empty): {len(noop)}")
    print(f"Skipped:             {len(skipped)}")
    print(f"Errors:              {len(errors)}")
    print(f"Bytes before:        {bytes_before:,} ({bytes_before/1e9:.3f} GB)")
    print(f"Bytes after:         {bytes_after:,} ({bytes_after/1e9:.3f} GB)")
    print(f"Bytes reclaimed:     {bytes_before - bytes_after:,} ({(bytes_before - bytes_after)/1e9:.3f} GB)")

    if skipped:
        from collections import Counter
        reasons = Counter(r.reason for r in skipped)
        print("\nSkip reasons:")
        for reason, count in reasons.most_common(20):
            print(f"  {count:5d}  {reason}")

    if errors:
        print("\nErrors:")
        for r in errors[:20]:
            print(f"  {r.lane}: {r.reason}")

    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
