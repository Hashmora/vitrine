#!/usr/bin/env python3
"""Summarize visual DJ artwork outcomes from a dj-diagnose ZIP.

Usage: python3 scripts/dj-artwork-report.py out/dj-diagnostics-*.zip
This tool never contacts the driver and does not expose any playlist names.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import zipfile


def analyze(path):
    with zipfile.ZipFile(path) as archive:
        events = [json.loads(x) for x in archive.read('events.jsonl').splitlines() if x]
    counts = Counter(e.get('event') for e in events)
    paints = [e for e in events if e.get('event') == 'artwork.draw' and
              e.get('data', {}).get('outcome')]
    placeholders = [e for e in events if e.get('event') == 'artwork.placeholder']
    print(f'File: {path}')
    print(f'Events: {len(events)}; artwork.draw={counts["artwork.draw"]}; '
          f'placeholder={len(placeholders)}; classified={counts["artwork.classifier"]}')
    if not paints:
        print('No overlay geometry outcome events. This recording predates the Part 14 probe.')
        return
    by_area = defaultdict(list)
    by_slot = defaultdict(list)
    for e in paints:
        data = e['data']
        by_area['Recents' if data.get('history') else 'Home'].append(data)
        by_slot[data.get('holderSlot', 'unknown')].append(data)
    for area in ('Home', 'Recents'):
        data = by_area[area]
        print(f'{area}: {len(data)} outcome samples; '
              f'overlay requested={sum(bool(x.get("requested")) for x in data)}; '
              f'drawn={sum(bool(x.get("drawn")) for x in data)}; '
              f'visible={sum(bool(x.get("visible")) for x in data)}; '
              f'offscreen={sum(bool(x.get("drawn")) and not x.get("visible") for x in data)}')
    print(f'Distinct image holders: {len(by_slot)}')
    failures = [
        (slot, values[-1]) for slot, values in by_slot.items()
        if any(x.get('requested') for x in values) and
        not any(x.get('visible') for x in values)
    ]
    print(f'Holders requested but never visible: {len(failures)}')
    for slot, data in failures[:12]:
        print(f'  holder {slot}: {data.get("width", 0)}x{data.get("height", 0)}, '
              f'coverReady={bool(data.get("coverReady"))}, '
              f'front={bool(data.get("front"))}, onWindow={bool(data.get("onWindow"))}')
    slots_missing = {p['data'].get('holderSlot') for p in placeholders
                     if p.get('data', {}).get('fallback')}
    outcome_slots = set(by_slot)
    print(f'Fallback holders lacking a paint outcome: '
          f'{len(slots_missing - outcome_slots)}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archives', nargs='+', type=Path)
    args = parser.parse_args()
    for path in args.archives:
        try:
            analyze(path)
        except (KeyError, FileNotFoundError, zipfile.BadZipFile, json.JSONDecodeError) as error:
            parser.error(f'{path}: {error}')


if __name__ == '__main__':
    main()
