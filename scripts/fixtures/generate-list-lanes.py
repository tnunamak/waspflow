#!/usr/bin/env python3
"""Deterministic high-cardinality fixture data; no subprocesses or providers."""
import argparse
import json
from pathlib import Path

COUNTS = {"index": 1600, "batch": 240, "table": 240}
PREFIXES = {"index": "idx", "batch": "batch", "table": "table"}

def generate(mode, home):
    home = Path(home)
    for i in range(1, COUNTS[mode] + 1):
        lane = f"{PREFIXES[mode]}-{i:04d}"
        state = {"provider": "codex", "status": "reaped"}
        if mode == "index":
            state.update(rollout=str(home / "provider-log-must-not-be-read" / (lane + ".jsonl")),
                         cwd="/fixture", runtime_model="stored-model",
                         runtime_refresh_state="observed")
        else:
            state["cwd"] = f"/fixture/{i}"
            if mode == "batch":
                state["runtime_model"] = "saved"
        directory = home / "lanes" / lane
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "state.json").write_text(json.dumps(state, indent=2) + "\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=COUNTS)
    parser.add_argument("home")
    args = parser.parse_args()
    generate(args.mode, args.home)
