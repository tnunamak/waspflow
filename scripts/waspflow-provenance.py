#!/usr/bin/env python3
"""Map current Waspflow windows to root sessions using raw spawn tool calls.

Read-only. A match requires an exact ``--lane`` argument in a tool command and
a command timestamp close to the lane's durable spawn epoch. Conversation text,
cwd similarity, and process-list output are not ownership proof.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import hashlib
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


HOME = Path.home()
STATE = HOME / ".local/state/waspflow"
CONVO_DB = HOME / ".local/share/minnows/convo/ledger.sqlite3"
SIDECAR = HOME / ".tmux/resurrect/assistant-sessions.json"
DEFAULT_SEARCH_ROOTS = (
    HOME / ".claude/projects",
    HOME / ".codex/sessions",
    HOME / ".qwen/projects",
)
OPERATOR_SEARCH_ROOTS_ENV = "WASPFLOW_PROVENANCE_SEARCH_ROOTS"
SPAWN_RE = re.compile(r"(?<![A-Za-z0-9_-])(?:[^\s\"']*/)?waspflow\s+spawn\b")
UUID_RE = re.compile(
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$",
    re.IGNORECASE,
)


def epoch(value: Any) -> int | None:
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


def run(argv: list[str], *, input_text: str | None = None, timeout: int = 60) -> str:
    try:
        result = subprocess.run(
            argv,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout


def checked_run(
    argv: list[str], *, input_text: str | None = None, timeout: int = 60
) -> tuple[str, str | None]:
    """Run a scan and distinguish no matches from an uncompleted scan."""
    try:
        result = subprocess.run(
            argv,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return "", "command_unavailable"
    except subprocess.TimeoutExpired:
        return "", "timed_out"
    except OSError:
        return "", "execution_error"
    # ripgrep uses 1 for a successful scan with no matches.
    if result.returncode in {0, 1}:
        return result.stdout, None
    return result.stdout, f"exit_{result.returncode}"


def current_live_lanes(state_dir: Path) -> dict[str, dict[str, Any]]:
    windows = {
        line.split("\t", 1)[1]: line.split("\t", 1)[0]
        for line in run(
            ["tmux", "list-windows", "-t", "waspflow", "-F", "#{window_id}\t#{window_name}"],
            timeout=30,
        ).splitlines()
        if "\t" in line
    }
    result: dict[str, dict[str, Any]] = {}
    for path in (state_dir / "lanes").glob("*/state.json"):
        name = path.parent.name
        if name not in windows:
            continue
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if record.get("status") != "live":
            continue
        record = dict(record)
        record["lane"] = name
        record["actual_window_id"] = windows[name]
        record["state_file"] = str(path)
        result[name] = record
    return result


def current_window_lanes(state_dir: Path) -> dict[str, dict[str, Any]]:
    windows = {
        line.split("\t", 1)[1]: line.split("\t", 1)[0]
        for line in run(
            ["tmux", "list-windows", "-t", "waspflow", "-F", "#{window_id}\t#{window_name}"],
            timeout=30,
        ).splitlines()
        if "\t" in line
    }
    result: dict[str, dict[str, Any]] = {}
    for name, window_id in windows.items():
        path = state_dir / "lanes" / name / "state.json"
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            record = {"status": "missing_state"}
        record = dict(record)
        record["lane"] = name
        record["actual_window_id"] = window_id
        record["state_file"] = str(path)
        result[name] = record
    return result


def named_lanes(state_dir: Path, names: Iterable[str]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for name in names:
        path = state_dir / "lanes" / name / "state.json"
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        record = dict(record)
        record["lane"] = name
        record["state_file"] = str(path)
        result[name] = record
    return result


def configured_search_roots(
    lanes: dict[str, dict[str, Any]], operator_roots: Iterable[Path], show_coverage: bool
) -> tuple[list[str], dict[str, Any] | None]:
    """Return default roots alone unless alternate-root discovery is active.

    The compatibility path deliberately keeps the historical strings and avoids
    filesystem probing. A configured alternate turns coverage on automatically
    so an unresolved result includes the search boundary that produced it.
    """
    defaults = [str(path) for path in DEFAULT_SEARCH_ROOTS]
    candidates: list[tuple[Path, str]] = []

    def add_config_home(value: Any, child: str, source: str, *, lane_value: bool = False) -> None:
        if not isinstance(value, str) or not value.strip():
            return
        if lane_value and value.strip() == "default":
            return
        candidates.append((Path(value).expanduser() / child, source))

    def add_direct_root(value: Any, source: str) -> None:
        if isinstance(value, str) and value.strip():
            candidates.append((Path(value).expanduser(), source))

    add_config_home(os.environ.get("CLAUDE_CONFIG_DIR"), "projects", "CLAUDE_CONFIG_DIR")
    add_config_home(os.environ.get("CODEX_HOME"), "sessions", "CODEX_HOME")
    add_direct_root(os.environ.get("CLAUDE_PROJECTS_DIR"), "CLAUDE_PROJECTS_DIR")
    add_direct_root(os.environ.get("CODEX_SESSIONS_DIR"), "CODEX_SESSIONS_DIR")
    for root in operator_roots:
        candidates.append((root.expanduser(), "--search-root"))
    for root in os.environ.get(OPERATOR_SEARCH_ROOTS_ENV, "").split(os.pathsep):
        add_direct_root(root, OPERATOR_SEARCH_ROOTS_ENV)
    for lane, state in sorted(lanes.items()):
        add_config_home(
            state.get("claude_config_dir"),
            "projects",
            f"lane:{lane}:claude_config_dir",
            lane_value=True,
        )
        add_config_home(
            state.get("codex_home"), "sessions", f"lane:{lane}:codex_home", lane_value=True
        )

    def canonical(path: Path) -> str:
        try:
            return str(path.resolve(strict=False))
        except OSError:
            return str(path.absolute())

    default_keys = {canonical(path) for path in DEFAULT_SEARCH_ROOTS}
    alternate_active = any(canonical(path) not in default_keys for path, _ in candidates)
    if not alternate_active and not show_coverage:
        return defaults, None

    grouped: dict[str, dict[str, Any]] = {}
    for path, source in [*( (path, "default") for path in DEFAULT_SEARCH_ROOTS), *candidates]:
        key = canonical(path)
        entry = grouped.setdefault(key, {"path": key, "sources": []})
        if source not in entry["sources"]:
            entry["sources"].append(source)

    searched: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    for path_text, entry in grouped.items():
        path = Path(path_text)
        try:
            if not path.exists():
                reason = "missing"
            elif not path.is_dir():
                reason = "not_directory"
            elif not os.access(path, os.R_OK | os.X_OK):
                reason = "unreadable"
            else:
                searched.append(entry)
                continue
        except OSError:
            reason = "unreadable"
        skipped.append({**entry, "reason": reason})
    return [entry["path"] for entry in searched], {
        "searched_roots": searched,
        "skipped_roots": skipped,
    }


def source_catalog(db_path: Path) -> tuple[dict[str, dict[str, Any]], list[str]]:
    catalog: dict[str, dict[str, Any]] = {}
    paths: list[str] = []
    if not db_path.exists():
        return catalog, paths
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        for row in conn.execute(
            "SELECT harness,path,session_id,project,source_status FROM source_files "
            "WHERE harness IN ('claude','codex','qwen')"
        ):
            item = dict(row)
            session_match = UUID_RE.search(str(item.get("session_id") or ""))
            if session_match:
                item["session_id"] = session_match.group(1)
            catalog[str(row["path"])] = item
            if Path(str(row["path"])).is_file():
                paths.append(str(row["path"]))
    finally:
        conn.close()
    return catalog, paths


def lane_search_pattern(names: Iterable[str]) -> str:
    # Restrict discovery to literal lane arguments. Some valid lane names are
    # generic words (commit, host, hero), making a name-only prefilter select
    # almost the entire conversation corpus.
    alternatives = "|".join(re.escape(name) for name in sorted(names, key=len, reverse=True))
    return rf"--lane(?:=|[[:space:]])+(?:\\?[\"'])?(?:{alternatives})(?=[[:space:]\\\"',}})]|$)"


def candidate_occurrences(
    names: Iterable[str], roots: list[str]
) -> tuple[dict[str, list[int]], str | None]:
    pattern = lane_search_pattern(names)
    output, scan_error = checked_run(
        ["rg", "--byte-offset", "-o", "--pcre2", "-e", pattern, "--glob", "*.jsonl", *roots],
        timeout=180,
    )
    result: defaultdict[str, list[int]] = defaultdict(list)
    for line in output.splitlines():
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        try:
            offset = int(parts[1])
        except ValueError:
            continue
        result[parts[0]].append(offset)
    return dict(result), scan_error


def fixed_occurrences(needle: str, roots: list[str]) -> dict[str, list[int]]:
    output = run(
        ["rg", "--byte-offset", "-o", "-F", needle, "--glob", "*.jsonl", *roots],
        timeout=180,
    )
    result: defaultdict[str, list[int]] = defaultdict(list)
    for line in output.splitlines():
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        try:
            result[parts[0]].append(int(parts[1]))
        except ValueError:
            continue
    return dict(result)


def tool_command_fields(obj: dict[str, Any]) -> list[tuple[str, str]]:
    commands: list[tuple[str, str]] = []
    # Claude Code assistant Bash tool calls.
    if obj.get("type") == "assistant":
        message = obj.get("message")
        content = message.get("content", []) if isinstance(message, dict) else []
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            if block.get("name") not in {"Bash", "bash", "exec_command"}:
                continue
            tool_input = block.get("input")
            if isinstance(tool_input, dict):
                command = tool_input.get("command") or tool_input.get("cmd")
                if isinstance(command, str):
                    field = (
                        "assistant.message.content[].input.command"
                        if tool_input.get("command")
                        else "assistant.message.content[].input.cmd"
                    )
                    commands.append((field, command))
    payload = obj.get("payload")
    if isinstance(payload, dict) and payload.get("type") in {"function_call", "custom_tool_call"}:
        name = str(payload.get("name") or "")
        if name in {"exec", "exec_command", "functions.exec"}:
            arguments = payload.get("arguments")
            if isinstance(arguments, str):
                try:
                    parsed = json.loads(arguments)
                except ValueError:
                    parsed = None
                if isinstance(parsed, dict) and isinstance(parsed.get("cmd"), str):
                    commands.append(("payload.arguments.cmd", parsed["cmd"]))
                else:
                    commands.append(("payload.arguments", arguments))
            custom_input = payload.get("input")
            if isinstance(custom_input, str):
                commands.append(("payload.input", custom_input))
    return commands


def tool_commands(obj: dict[str, Any]) -> list[str]:
    return [command for _, command in tool_command_fields(obj)]


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


def bounded_line_at(
    path: Path, offset: int, limit: int = 16 * 1024 * 1024
) -> tuple[bytes | None, int | None, bool]:
    """Read the line containing offset without allocating an unbounded row."""
    try:
        with path.open("rb") as stream:
            start = max(0, offset - limit)
            stream.seek(start)
            prefix = stream.read(offset - start)
            newline = prefix.rfind(b"\n")
            if newline < 0 and start > 0:
                return None, None, True
            line_start = start + newline + 1 if newline >= 0 else 0
            stream.seek(line_start)
            row = stream.readline(limit + 1)
    except OSError:
        return None, None, False
    if len(row) > limit or (not row.endswith(b"\n") and line_start + len(row) < path.stat().st_size):
        return None, line_start, True
    return row, line_start, False


def scan_spawns(
    occurrences: dict[str, list[int]],
    lanes: dict[str, dict[str, Any]],
    catalog: dict[str, dict[str, Any]],
    tolerance: int,
    include_command_field: bool,
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, int]]:
    hits: dict[str, list[dict[str, Any]]] = defaultdict(list)
    lane_pattern = re.compile("|".join(re.escape(name) for name in sorted(lanes, key=len, reverse=True)))
    diagnostics = {"oversized_candidate_rows": 0, "malformed_candidate_rows": 0}
    for filename, offsets in occurrences.items():
        path = Path(filename)
        source = catalog.get(filename, {})
        seen_rows: set[int] = set()
        for offset in offsets:
            row, line_start, oversized = bounded_line_at(path, offset)
            if oversized:
                diagnostics["oversized_candidate_rows"] += 1
                continue
            if row is None:
                continue
            # Multiple lane arguments can occur in one cohort command.
            if line_start is None or line_start in seen_rows:
                continue
            seen_rows.add(line_start)
            line = row.decode("utf-8", errors="replace")
            possible = {match.group(0) for match in lane_pattern.finditer(line)}
            if not possible:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                diagnostics["malformed_candidate_rows"] += 1
                continue
            line_epoch = timestamp_epoch(obj.get("timestamp"))
            for command_field, command in tool_command_fields(obj):
                if "spawn" not in command:
                    continue
                for lane in possible:
                    if not lane_argument(command, lane):
                        continue
                    spawn_epoch = epoch(lanes[lane].get("spawn_epoch"))
                    delta = abs(line_epoch - spawn_epoch) if line_epoch and spawn_epoch else None
                    hit = {
                            "root_harness": source.get("harness", ""),
                            "root_session_id": source.get("session_id", "") or path.stem.replace("rollout-", ""),
                            "root_project": source.get("project", ""),
                            "root_source_status": source.get("source_status", ""),
                            "root_path": filename,
                            "byte_offset": offset,
                            "tool_timestamp": obj.get("timestamp", ""),
                            "spawn_delta_seconds": delta,
                            "within_tolerance": delta is not None and delta <= tolerance,
                    }
                    if include_command_field:
                        hit["command_field"] = command_field
                    hits[lane].append(hit)
    return hits, diagnostics


def scan_spawn_commands(
    occurrences: dict[str, list[int]],
    catalog: dict[str, dict[str, Any]],
    lane_names: Iterable[str],
) -> list[dict[str, Any]]:
    """Index actual spawn tool calls, including variable-driven cohort commands."""
    records: list[dict[str, Any]] = []
    lane_pattern = re.compile(
        "|".join(re.escape(name) for name in sorted(lane_names, key=len, reverse=True))
    )
    for filename, offsets in occurrences.items():
        path = Path(filename)
        source = catalog.get(filename, {})
        seen_rows: set[int] = set()
        for offset in offsets:
            row, line_start, oversized = bounded_line_at(path, offset)
            if oversized or row is None or line_start is None or line_start in seen_rows:
                continue
            seen_rows.add(line_start)
            try:
                obj = json.loads(row.decode("utf-8", errors="replace"))
            except ValueError:
                continue
            for command in tool_commands(obj):
                if not SPAWN_RE.search(command):
                    continue
                records.append(
                    {
                        "root_harness": source.get("harness", ""),
                        "root_session_id": source.get("session_id", ""),
                        "root_project": source.get("project", ""),
                        "root_path": filename,
                        "tool_timestamp": obj.get("timestamp", ""),
                        "tool_epoch": timestamp_epoch(obj.get("timestamp")),
                        "command_sha256": hashlib.sha256(command.encode()).hexdigest(),
                        "mentioned_lanes": sorted(
                            {match.group(0) for match in lane_pattern.finditer(command)}
                        ),
                        "command_preview": " ".join(command.split())[:500],
                    }
                )
    return records


def sidecar_sessions(path: Path) -> dict[str, list[dict[str, Any]]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    result: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in data.get("sessions", []):
        if isinstance(item, dict) and item.get("session_id"):
            result[str(item["session_id"])].append(item)
    return dict(result)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=STATE)
    parser.add_argument("--convo-db", type=Path, default=CONVO_DB)
    parser.add_argument("--sidecar", type=Path, default=SIDECAR)
    parser.add_argument("--tolerance", type=int, default=600)
    parser.add_argument("--lanes", help="Comma-separated state lanes; includes reaped/parked lanes")
    parser.add_argument("--all-windows", action="store_true", help="Include every open Waspflow window")
    parser.add_argument("--skip-generic", action="store_true", help="Skip slower cohort/timestamp scan")
    parser.add_argument(
        "--search-root",
        action="append",
        default=[],
        type=Path,
        metavar="PATH",
        help="Additional transcript root; may be repeated",
    )
    parser.add_argument(
        "--show-search-coverage",
        action="store_true",
        help="Include searched and skipped roots even when no alternate root is configured",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.lanes:
        lanes = named_lanes(
            args.state_dir, (name.strip() for name in args.lanes.split(",") if name.strip())
        )
    elif args.all_windows:
        lanes = current_window_lanes(args.state_dir)
    else:
        lanes = current_live_lanes(args.state_dir)
    catalog, _ = source_catalog(args.convo_db)
    search_roots, search_coverage = configured_search_roots(
        lanes, args.search_root, args.show_search_coverage
    )
    occurrences, candidate_scan_error = candidate_occurrences(lanes, search_roots)
    if search_coverage is not None and candidate_scan_error is not None:
        search_coverage["unscanned_roots"] = search_coverage.pop("searched_roots")
        search_coverage["searched_roots"] = []
        search_coverage["candidate_scan_error"] = candidate_scan_error
    hits, scan_diagnostics = scan_spawns(
        occurrences, lanes, catalog, args.tolerance, search_coverage is not None
    )
    spawn_commands = []
    if not args.skip_generic:
        generic_occurrences = fixed_occurrences("waspflow spawn", search_roots)
        spawn_commands = scan_spawn_commands(generic_occurrences, catalog, lanes)
    sidecar = sidecar_sessions(args.sidecar)

    rows: list[dict[str, Any]] = []
    for name, lane in sorted(lanes.items()):
        all_hits = hits.get(name, [])
        exact = [hit for hit in all_hits if hit["within_tolerance"]]
        roots = sorted({(hit["root_harness"], hit["root_session_id"]) for hit in exact})
        if len(roots) == 1:
            provenance = "exact_spawn_call"
        elif len(roots) > 1:
            provenance = "conflicting_spawn_calls"
        elif all_hits:
            provenance = "spawn_call_outside_tolerance"
        else:
            provenance = "unresolved"
        root_records = []
        for harness, session_id in roots:
            matching = [h for h in exact if h["root_harness"] == harness and h["root_session_id"] == session_id]
            root_records.append(
                {
                    "harness": harness,
                    "session_id": session_id,
                    "in_current_sidecar": session_id in sidecar,
                    "sidecar": sidecar.get(session_id),
                    "evidence": matching,
                }
            )
        rows.append(
            {
                "lane": name,
                "provider": lane.get("provider", ""),
                "durable_status": lane.get("status", ""),
                "worker_session_id": lane.get("session_id", ""),
                "spawn_epoch": epoch(lane.get("spawn_epoch")),
                "actual_window_id": lane.get("actual_window_id", ""),
                "provenance": provenance,
                "roots": root_records,
                "other_spawn_hits": all_hits if not exact else [],
                "nearby_spawn_commands": sorted(
                    [
                        {
                            **command,
                            "spawn_delta_seconds": abs(command["tool_epoch"] - epoch(lane.get("spawn_epoch"))),
                        }
                        for command in spawn_commands
                        if command["tool_epoch"] is not None
                        and epoch(lane.get("spawn_epoch")) is not None
                        and abs(command["tool_epoch"] - epoch(lane.get("spawn_epoch"))) <= args.tolerance
                    ],
                    key=lambda item: item["spawn_delta_seconds"],
                )
                if provenance != "exact_spawn_call"
                else [],
            }
        )

    root_set = sorted(
        {
            (root["harness"], root["session_id"])
            for row in rows
            for root in row["roots"]
        }
    )
    summary = {
        "window_population": len(rows),
        "durable_status": dict(Counter(row["durable_status"] for row in rows)),
        "candidate_raw_files": len(occurrences),
        "candidate_occurrences": sum(len(offsets) for offsets in occurrences.values()),
        "generic_spawn_tool_calls": len(spawn_commands),
        "scan_diagnostics": scan_diagnostics,
        "provenance": dict(Counter(row["provenance"] for row in rows)),
        "exact_root_sessions": len(root_set),
        "exact_roots_in_current_sidecar": sum(session_id in sidecar for _, session_id in root_set),
        "exact_roots_not_in_current_sidecar": sum(session_id not in sidecar for _, session_id in root_set),
        "root_sessions": [
            {"harness": harness, "session_id": session_id, "in_current_sidecar": session_id in sidecar}
            for harness, session_id in root_set
        ],
    }
    output = {"summary": summary, "lanes": rows}
    if search_coverage is not None:
        output["search_coverage"] = search_coverage
    if args.json:
        print(json.dumps(output, indent=2))
    else:
        print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
