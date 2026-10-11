#!/usr/bin/env python3
"""Revalidate strict helper matches before appending forensic parent events.

The input is the JSON report from ``waspflow-provenance.py``.  A row is usable
only when its one reported root can be independently traced back to a tool-call
command argument that contains the exact ``waspflow spawn --lane`` invocation.
Conversation prose and tool output are intentionally not read as evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


SPAWN_RE = re.compile(r"(?<![A-Za-z0-9_-])(?:[^\s\"']*/)?waspflow\s+spawn\b")
UUID_RE = re.compile(
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$",
    re.IGNORECASE,
)
MAX_ROW_BYTES = 16 * 1024 * 1024


class EvidenceError(ValueError):
    """The helper report cannot be independently tied to command arguments."""


def integer(value: Any) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def timestamp_epoch(value: Any) -> int | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def normalized_session_id(value: Any) -> str:
    session_id = str(value or "")
    match = UUID_RE.search(session_id)
    return match.group(1) if match else session_id


def sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def source_catalog(db_path: Path) -> dict[str, dict[str, str]]:
    if not db_path.exists():
        return {}
    catalog: dict[str, dict[str, str]] = {}
    try:
        connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        with connection:
            rows = connection.execute(
                "SELECT harness,path,session_id FROM source_files "
                "WHERE harness IN ('claude','codex','qwen')"
            )
            for row in rows:
                catalog[str(row["path"])] = {
                    "harness": str(row["harness"] or ""),
                    "session_id": normalized_session_id(row["session_id"]),
                }
    except sqlite3.Error as error:
        raise EvidenceError(f"cannot read conversation catalog: {error}") from error
    finally:
        try:
            connection.close()
        except UnboundLocalError:
            pass
    return catalog


def source_identity(path: Path, catalog: dict[str, dict[str, str]]) -> dict[str, str]:
    """Match the helper's source-file fallback when its catalog has no row."""
    known = catalog.get(str(path))
    if known is not None:
        return known
    return {
        "harness": "",
        "session_id": normalized_session_id(path.stem.replace("rollout-", "")),
    }


def bounded_line_at(path: Path, offset: int) -> bytes:
    try:
        with path.open("rb") as stream:
            start = max(0, offset - MAX_ROW_BYTES)
            stream.seek(start)
            prefix = stream.read(offset - start)
            newline = prefix.rfind(b"\n")
            if newline < 0 and start > 0:
                raise EvidenceError(f"candidate row exceeds {MAX_ROW_BYTES} bytes: {path}")
            line_start = start + newline + 1 if newline >= 0 else 0
            stream.seek(line_start)
            row = stream.readline(MAX_ROW_BYTES + 1)
            if len(row) > MAX_ROW_BYTES:
                raise EvidenceError(f"candidate row exceeds {MAX_ROW_BYTES} bytes: {path}")
            return row
    except OSError as error:
        raise EvidenceError(f"cannot read candidate source {path}: {error}") from error


def tool_command_fields(obj: dict[str, Any]) -> Iterable[tuple[str, str]]:
    """Yield only fields that held submitted shell-command arguments.

    Keep this aligned with the read-only helper.  In particular, no transcript,
    aggregated output, assistant prose, or generic JSON string is inspected.
    """
    if obj.get("type") == "assistant":
        message = obj.get("message")
        content = message.get("content", []) if isinstance(message, dict) else []
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            if block.get("name") not in {"Bash", "bash", "exec_command"}:
                continue
            tool_input = block.get("input")
            if not isinstance(tool_input, dict):
                continue
            command = tool_input.get("command")
            if isinstance(command, str) and command:
                yield "assistant.message.content[].input.command", command
                continue
            command = tool_input.get("cmd")
            if isinstance(command, str):
                yield "assistant.message.content[].input.cmd", command

    payload = obj.get("payload")
    if not isinstance(payload, dict) or payload.get("type") not in {"function_call", "custom_tool_call"}:
        return
    if str(payload.get("name") or "") not in {"exec", "exec_command", "functions.exec"}:
        return
    arguments = payload.get("arguments")
    if isinstance(arguments, str):
        try:
            parsed = json.loads(arguments)
        except ValueError:
            parsed = None
        if isinstance(parsed, dict) and isinstance(parsed.get("cmd"), str):
            yield "payload.arguments.cmd", parsed["cmd"]
        else:
            yield "payload.arguments", arguments
    custom_input = payload.get("input")
    if isinstance(custom_input, str):
        yield "payload.input", custom_input


def lane_argument(command: str, lane: str) -> bool:
    if not SPAWN_RE.search(command):
        return False
    escaped = re.escape(lane)
    return bool(
        re.search(
            rf"--lane(?:=|\s+)(?:[\"'])?{escaped}(?:[\"'])?(?=\s|[\"',}})]|$)",
            command,
        )
    )


def lane_spawn_epoch(state_dir: Path, lane: str) -> int:
    path = state_dir / lane / "state.json"
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise EvidenceError(f"cannot read lane state for {lane}: {error}") from error
    spawn_epoch = integer(state.get("spawn_epoch"))
    if spawn_epoch is None:
        raise EvidenceError(f"lane {lane} has no durable spawn epoch")
    return spawn_epoch


def exact_candidate(
    row: dict[str, Any], catalog: dict[str, dict[str, str]], state_dir: Path, tolerance: int
) -> dict[str, Any]:
    lane = row.get("lane")
    if not isinstance(lane, str) or not lane:
        raise EvidenceError("helper row has no lane label")
    roots = row.get("roots")
    if not isinstance(roots, list) or len(roots) != 1 or not isinstance(roots[0], dict):
        raise EvidenceError(f"lane {lane} must have exactly one reported root")
    root = roots[0]
    harness = str(root.get("harness") or "")
    session_id = normalized_session_id(root.get("session_id"))
    if not session_id:
        raise EvidenceError(f"lane {lane} has no root session identity")
    evidence = root.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        raise EvidenceError(f"lane {lane} has no exact root evidence")

    spawn_epoch = lane_spawn_epoch(state_dir, lane)
    ordered_evidence = sorted(
        (item for item in evidence if isinstance(item, dict)),
        key=lambda item: (
            str(item.get("tool_timestamp") or ""),
            str(item.get("root_path") or ""),
            integer(item.get("byte_offset")) or -1,
        ),
    )
    for item in ordered_evidence:
        path_text = item.get("root_path")
        offset = integer(item.get("byte_offset"))
        if not isinstance(path_text, str) or offset is None:
            continue
        path = Path(path_text)
        source = source_identity(path, catalog)
        if source["harness"] != harness or source["session_id"] != session_id:
            continue
        raw_row = bounded_line_at(path, offset)
        try:
            source_row = json.loads(raw_row.decode("utf-8", errors="strict"))
        except (UnicodeDecodeError, ValueError):
            continue
        command_epoch = timestamp_epoch(source_row.get("timestamp"))
        if command_epoch is None or abs(command_epoch - spawn_epoch) > tolerance:
            continue
        for field, command in tool_command_fields(source_row):
            if lane_argument(command, lane):
                return {
                    "lane": lane,
                    "root_harness": harness,
                    "root_session_id": session_id,
                    "matched_field": field,
                    "command_sha256": sha256(command),
                    "source_path_sha256": sha256(path_text),
                    "source_byte_offset": offset,
                    "tool_timestamp": str(source_row.get("timestamp") or ""),
                    "spawn_delta_seconds": abs(command_epoch - spawn_epoch),
                }
    raise EvidenceError(
        f"lane {lane} has no reported exact match in an executed command-argument field"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path, help="JSON from waspflow-provenance.py --json")
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=Path(os.environ.get("WASPFLOW_HOME", Path.home() / ".local/state/waspflow")) / "lanes",
    )
    parser.add_argument(
        "--convo-db",
        type=Path,
        default=Path.home() / ".local/share/minnows/convo/ledger.sqlite3",
    )
    parser.add_argument("--tolerance", type=int, default=600)
    parser.add_argument("--skip", action="append", default=[], metavar="LANE")
    args = parser.parse_args()
    if args.tolerance < 0:
        parser.error("--tolerance must be non-negative")
    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        parser.error(f"cannot read helper report: {error}")
    rows = report.get("lanes") if isinstance(report, dict) else None
    if not isinstance(rows, list):
        parser.error("helper report must contain a lanes array")
    labels = [row.get("lane") for row in rows if isinstance(row, dict)]
    if len(labels) != len(rows) or any(not isinstance(label, str) or not label for label in labels):
        parser.error("helper report contains an invalid lane label")
    if len(set(labels)) != len(labels):
        parser.error("helper report contains duplicate lane labels")

    skip = set(args.skip)
    try:
        catalog = source_catalog(args.convo_db)
        for row in sorted(rows, key=lambda item: str(item["lane"])):
            if row["lane"] in skip or row.get("provenance") != "exact_spawn_call":
                continue
            print(json.dumps(exact_candidate(row, catalog, args.state_dir, args.tolerance), sort_keys=True))
    except EvidenceError as error:
        print(f"provenance-backfill: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
