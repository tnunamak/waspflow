#!/usr/bin/env python3
"""Regenerate lib/generated/effort-whitelists.sh from minnows capabilities."""
from __future__ import annotations
import json, os, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
cap = Path(os.environ.get(
    "MODEL_CATALOG_CAPABILITIES",
    str(Path.home() / "code/minnows/data/model-catalog/capabilities/effort-surfaces-2026-07.json"),
))
if not cap.is_file():
    print(f"missing {cap}", file=sys.stderr)
    sys.exit(1)
data = json.loads(cap.read_text())
provider_efforts = {"claude": set(), "codex": set(), "grok": set(), "antigravity": {"low", "medium", "high"}}
for s in data.get("surfaces") or []:
    ve = s.get("valid_efforts") or []
    prov = s.get("provider")
    if prov == "anthropic":
        provider_efforts["claude"].update(ve)
    elif prov == "openai":
        provider_efforts["codex"].update(ve)
    elif prov == "xai":
        provider_efforts["grok"].update(ve)
ORDER = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
lines = [
    "# Generated from model-catalog capabilities and provider-local contracts — do not hand-edit.",
    "# Regenerate: python3 scripts/gen_effort_whitelists.py (or minnows sync).",
    "# Catalog source: MODEL_CATALOG_CAPABILITIES or the local minnows checkout.",
    "",
]
for prov in ("claude", "codex", "grok", "antigravity"):
    effs = [e for e in ORDER if e in provider_efforts[prov]]
    lines.append(f"# {prov} valid efforts: {' '.join(effs)}")
    lines.append(f'WASPFLOW_EFFORTS_{prov.upper()}="{"|".join(effs)}"')
    lines.append("")
out = ROOT / "lib/generated/effort-whitelists.sh"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(lines) + "\n")
print(f"wrote {out}")
