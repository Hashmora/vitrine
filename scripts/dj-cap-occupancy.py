#!/usr/bin/env python3
"""Measure non-DJ track-reference occupancy from existing DJ diagnostic captures.

This intentionally does not modify dj-diagnose.py: the live recorder may have
local changes in the user's working tree. Snapshot counts are *not* network
requests, transferred bytes, CPU work or battery measurements.

Usage:
    python3 scripts/dj-cap-occupancy.py out/dj-diagnostics-20261120-010846.zip
    python3 scripts/dj-cap-occupancy.py out/dj-diagnostics-20261120-010846/samples.jsonl
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import zipfile


def non_dj_cap_cost(samples):
    """Summarize extra retained refs beyond native caps of 2 per direction."""
    records = [s["dj"] for s in samples if isinstance(s, dict)
               and isinstance(s.get("dj"), dict)
               and s["dj"].get("contextKind") == "other"
               and isinstance(s["dj"].get("future"), list)]
    if not records:
        return {"snapshots": 0}

    next_extra = [max(0, len(s["future"]) - 2) for s in records]
    prev_extra = [max(0, int(s["reverseCount"]) - 2) for s in records
                  if isinstance(s.get("reverseCount"), (int, float))]
    result = {
        "snapshots": len(records),
        "avgExtraNext": round(statistics.mean(next_extra), 2),
        "peakExtraNext": max(next_extra),
        "withExtraNext": sum(count > 0 for count in next_extra),
    }
    if prev_extra:
        result.update({
            "prevObserved": len(prev_extra),
            "avgExtraPrev": round(statistics.mean(prev_extra), 2),
            "peakExtraPrev": max(prev_extra),
            "withExtraPrev": sum(count > 0 for count in prev_extra),
        })
    return result


def read_samples(path):
    if path.is_dir():
        path = path / "samples.jsonl"
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as archive:
            matches = [name for name in archive.namelist() if name.split("/")[-1] == "samples.jsonl"]
            if len(matches) != 1:
                raise ValueError("Expected exactly one samples.jsonl in the ZIP")
            content = archive.read(matches[0]).decode("utf-8")
    else:
        content = path.read_text(encoding="utf-8")
    for number, line in enumerate(content.splitlines(), 1):
        if line.strip():
            try:
                yield json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Malformed samples.jsonl line {number}: {exc}") from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="DJ diagnostic ZIP, capture folder or samples.jsonl")
    parser.add_argument("--output", type=Path, help="Optional JSON report path")
    args = parser.parse_args()
    data = non_dj_cap_cost(read_samples(args.capture))
    if data["snapshots"] == 0:
        print("No non-DJ state samples with future tracks found.")
    else:
        print(f"Non-DJ samples: {data['snapshots']}")
        print(f"Extra future refs vs cap=2: average {data['avgExtraNext']:.2f}; "
              f"peak {data['peakExtraNext']}; in {data['withExtraNext']} samples")
        if "avgExtraPrev" in data:
            print(f"Extra previous refs vs cap=2: average {data['avgExtraPrev']:.2f}; "
                  f"peak {data['peakExtraPrev']}; in {data['withExtraPrev']} of "
                  f"{data['prevObserved']} samples with reverseCount")
    print("These are state snapshots, not separate ESP messages or network/CPU/battery measurements.")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
