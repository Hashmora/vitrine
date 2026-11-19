#!/usr/bin/env python3
"""Compare non-DJ future-track occupancy with and without DJ Queue.

This reads existing redacted driver captures; it never modifies playback.
Snapshot counts are NOT request counts, network bytes, retained-heap bytes,
CPU time or energy. An A/B comparison should capture the *same ordinary*
playlist at a comparable position for the same duration, with Spotify restarted
between the DJ Queue setting changes.

    python3 scripts/dj-cap-occupancy.py out/with-dj.zip --baseline out/without-dj.zip
    python3 scripts/dj-cap-occupancy.py out/with-dj.zip --output out/cap-report.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import zipfile


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    low, high = int(index), min(len(ordered) - 1, int(index) + 1)
    return round(ordered[low] + (ordered[high] - ordered[low]) * (index - low), 2)


def non_dj_cap_cost(samples):
    """Count distinct snapshots and refs above the native cap of 2 per direction."""
    records = [s for s in samples if isinstance(s, dict) and
               isinstance(s.get("dj"), dict) and
               s["dj"].get("contextKind") == "other" and
               isinstance(s["dj"].get("future"), list)]
    if not records:
        return {"snapshots": 0}

    futures = [len(s["dj"]["future"]) for s in records]
    next_extra = [max(0, count - 2) for count in futures]
    prev = [int(s["dj"]["reverseCount"]) for s in records
            if isinstance(s["dj"].get("reverseCount"), (int, float))]
    prev_extra = [max(0, count - 2) for count in prev]

    # Snapshots sampled every ~0.7s can repeat the SAME playback state. Count
    # state signatures separately instead of pretending each is a new request.
    signatures = []
    for sample in records:
        dj = sample["dj"]
        cur = dj.get("current") or {}
        def token(t):
            return t.get("id") if isinstance(t, dict) else None
        signatures.append((token(cur), tuple(token(t) for t in dj["future"]),
                           dj.get("reverseCount")))
    transitions = sum(a != b for a, b in zip(signatures, signatures[1:]))
    timestamps = [s["t"] for s in records if isinstance(s.get("t"), (int, float))]
    result = {
        "snapshots": len(records),
        "durationSeconds": round(max(timestamps) - min(timestamps), 2) if timestamps else None,
        "distinctStateSignatures": len(set(signatures)),
        "observedStateTransitions": transitions,
        "avgFutureCount": round(statistics.mean(futures), 2),
        "p95FutureCount": percentile(futures, 0.95),
        "peakFutureCount": max(futures),
        "avgExtraNext": round(statistics.mean(next_extra), 2),
        "peakExtraNext": max(next_extra),
        "withExtraNext": sum(count > 0 for count in next_extra),
        "limitations": "Repeated state snapshots, not individual ESP responses; no CPU/network/heap measurement",
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


def compare(on, baseline):
    if not on["snapshots"] or not baseline["snapshots"]:
        return {"valid": False, "reason": "Both captures need non-DJ state samples"}
    return {
        "valid": True,
        "deltaAvgFutureRefs": round(on["avgFutureCount"] - baseline["avgFutureCount"], 2),
        "deltaPeakFutureRefs": on["peakFutureCount"] - baseline["peakFutureCount"],
        "note": "Observational difference, not bytes/CPU or network traffic. Match contexts and playback conditions.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="DJ Queue enabled: diagnostic ZIP, directory or samples.jsonl")
    parser.add_argument("--baseline", type=Path, help="Same non-DJ playlist with DJ Queue disabled (after restart)")
    parser.add_argument("--output", type=Path, help="Optional JSON report path")
    args = parser.parse_args()
    on = non_dj_cap_cost(read_samples(args.capture))
    if on["snapshots"] == 0:
        print("No non-DJ state samples with future tracks found.")
    else:
        print(f"Non-DJ snapshots: {on['snapshots']} across {on['durationSeconds']} seconds; "
              f"{on['distinctStateSignatures']} distinct observed state signatures")
        print(f"Future refs per snapshot: avg {on['avgFutureCount']:.2f}, "
              f"p95 {on['p95FutureCount']:.2f}, peak {on['peakFutureCount']}")
        print(f"Extra future refs above native cap=2: avg {on['avgExtraNext']:.2f}, "
              f"peak {on['peakExtraNext']}, in {on['withExtraNext']} snapshots")
        if "avgExtraPrev" in on:
            print(f"Extra previous refs: avg {on['avgExtraPrev']:.2f}, peak {on['peakExtraPrev']} "
                  f"({on['prevObserved']} snapshots with reverseCount)")
        else:
            print("Previous-track count unavailable in this capture; do not estimate it.")
    result = {"enabled": on}
    if args.baseline:
        baseline = non_dj_cap_cost(read_samples(args.baseline))
        result["baseline"] = baseline
        result["comparison"] = compare(on, baseline)
        if result["comparison"]["valid"]:
            print(f"A/B difference in average future refs: {result['comparison']['deltaAvgFutureRefs']:+.2f}")
        else:
            print("No valid A/B comparison: one capture lacks non-DJ state samples.")
    print("Not measured: separate ESP request counts, network bytes, CPU time, heap size or battery.")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
