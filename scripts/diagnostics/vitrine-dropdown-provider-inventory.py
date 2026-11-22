#!/usr/bin/env python3
"""SG_DRIVER-only audit for Legacy dropdown sources that still fall back to UIKit.

Requires Stage 170 build (SG_DRIVER=1) on the iOS 18 simulator. All navigation
and screenshots are automatic; no manual menu tapping. Only known menu-opening
buttons are pressed. No menu *action* other than entering a submenu is chosen.

Run:
    python3 scripts/diagnostics/vitrine-dropdown-provider-inventory.py \
      --port 8087 --out out

The report lists observed menus; it is NOT proof that unvisited menus are covered.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib import parse, request
from zipfile import ZipFile, ZIP_DEFLATED

DEFAULT_UDID = "ED66415E-FC8E-44EA-B306-33BB985B9CE8"
AUDIT_PREFIX = "dropdown.provider.inventory "
ROUTE_PATTERN = re.compile(r'SGTabTitle:\s*@"([^"]+)"\s*,\s*SGTabURI:\s*@"([^"]+)"')
ID_PATTERN = re.compile(r"\bid=([^\s]+)")
CANDIDATE = re.compile(r"(context.?menu|more(?:button)?|ellipsis|menu(?:button)?|options|sort(?:button)?|filter(?:button)?)", re.I)
FORBIDDEN = re.compile(r"(delete|remove|logout|signout|leave|purchase|play|pause|follow|like|send|download|share|erase|clear)", re.I)
MENU_SIGNALS = ("Vitrine.Dropdown.Panel", "_UIContextMenuView", "_UIMenu", "_UIContextMenuListView")


class Driver:
    def __init__(self, port: int):
        self.port = port

    def call(self, command: str, **params):
        query = parse.urlencode(params, quote_via=parse.quote)
        url = f"http://127.0.0.1:{self.port}/" + parse.quote(command)
        if query:
            url += "?" + query
        req = request.Request(url, headers={"X-Phone-Driver": "1"})
        try:
            with request.urlopen(req, timeout=30) as resp:
                data = resp.read()
        except Exception as exc:
            raise RuntimeError(f"SG_DRIVER {command} port {self.port}: {exc}") from exc
        if command == "tree":
            return data.decode("utf-8", "replace")
        obj = json.loads(data)
        if obj.get("ok") is not True:
            raise RuntimeError(f"SG_DRIVER {command}: {obj.get('error', obj)!r}"[:500])
        return obj


def write_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run(args: list[str], timeout=35):
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
        return {"ok": proc.returncode == 0, "returncode": proc.returncode,
                "stdout": proc.stdout[-500:], "stderr": proc.stderr[-1000:]}
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "error": str(exc)}


def extract_events(log: dict):
    events = []
    for row in log.get("lines", []):
        msg = row.get("text", "")
        for line in msg.splitlines():
            pos = line.find(AUDIT_PREFIX)
            if pos < 0:
                continue
            try:
                payload = json.JSONDecoder().raw_decode(line[pos + len(AUDIT_PREFIX):])[0]
                if isinstance(payload, dict):
                    payload["sequence"] = row.get("seq")
                    events.append(payload)
            except (json.JSONDecodeError, ValueError):
                continue
    return events


def menu_candidates(tree: str):
    found = []
    seen = set()
    for line in tree.splitlines():
        match = ID_PATTERN.search(line)
        if not match:
            continue
        identifier = match.group(1).strip("\"'")
        if identifier in seen or not CANDIDATE.search(identifier) or FORBIDDEN.search(identifier):
            continue
        # Ignore old/hidden/noninteractive captions. Do not assume a class
        # without "Button" is safe just because its ID mentions "menu".
        cls = line.lstrip().split(" ", 1)[0]
        if not any(key in cls for key in ("Button", "button", "Control", "UIControl")):
            continue
        if "hidden" in line or "a=0.00" in line:
            continue
        seen.add(identifier)
        found.append({"id": identifier, "class": cls})
    return found


def built_in_routes(repo: Path):
    for relative in ("tweak/Sources/Native/Navbar/NavbarSettings.m",
                     "tweak/Sources/Redesigned/Navbar/NavbarSettings.m"):
        path = repo / relative
        if path.is_file():
            items = ROUTE_PATTERN.findall(path.read_text(encoding="utf-8", errors="replace"))
            if items:
                return [{"name": name, "uri": uri} for name, uri in items]
    return []


def log_and_tree(drv: Driver, path: Path, events: list, source: str):
    path.mkdir(parents=True, exist_ok=True)
    meta = {"source": source, "errors": []}
    for cmd, file in (("state", "state.json"), ("tree", "tree.txt"), ("log", "log.json")):
        try:
            obj = drv.call(cmd)
            if cmd == "tree":
                (path / file).write_text(obj[:8_000_000], encoding="utf-8")
                meta["menus"] = [m for m in MENU_SIGNALS if m in obj]
                meta["candidates"] = menu_candidates(obj)
            else:
                write_json(path / file, obj)
                if cmd == "log":
                    found = extract_events(obj)
                    for item in found:
                        item["step"] = source
                    events.extend(found)
                    meta["observations"] = len(found)
                if cmd == "state":
                    meta["top"] = obj.get("top")
                    meta["menuReported"] = obj.get("menu")
        except Exception as exc:
            meta["errors"].append(f"{cmd}: {exc}")
    write_json(path / "meta.json", meta)
    return meta


def snap(udid: str, path: Path):
    return run(["xcrun", "simctl", "io", udid, "screenshot", str(path)], timeout=30)


def safe_action(drv: Driver, path: Path, command: str, **params):
    try:
        obj = drv.call(command, **params)
        result = {"ok": True, "response": obj}
    except Exception as exc:
        result = {"ok": False, "error": str(exc)}
    write_json(path, result)
    return result["ok"]


def reset_menu(drv: Driver, folder: Path, index: int):
    # Dismiss by tapping blank content near screen's leading edge.
    safe_action(drv, folder / f"dismiss-{index}.json", "tap", at="5,540")
    time.sleep(.25)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8087)
    ap.add_argument("--udid", default=DEFAULT_UDID)
    ap.add_argument("--out", type=Path, default=Path("out"))
    ap.add_argument("--route-limit", type=int, default=17)
    ap.add_argument("--max-buttons", type=int, default=3)
    ap.add_argument("--no-routes", action="store_true", help="Only built-in player and tab scenarios")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    if args.self_test:
        sample = {'lines': [{'seq': 1, 'text': '[Vitrine] ' + AUDIT_PREFIX +
                             '{"kind":"button","supported":false,"reason":"unresolved-deferred"}'}]}
        assert extract_events(sample)[0]["reason"] == "unresolved-deferred"
        tree = '  UIButton {{0, 0}, {40, 40}} id=YourLibraryFolderHeader.contextMenu'
        assert menu_candidates(tree)[0]["id"] == "YourLibraryFolderHeader.contextMenu"
        assert not menu_candidates('  UIButton {{0, 0}, {40, 40}} id=deleteMenuButton')
        print("Stage 170 self-test: OK")
        return 0
    repo = Path.cwd()
    root = args.out.resolve() / ("vitrine-dropdown-providers-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    root.mkdir(parents=True, exist_ok=False)
    events = []
    steps = []
    drv = Driver(args.port)
    try:
        st = drv.call("state")
        write_json(root / "start.json", st)
    except Exception as exc:
        print("SG_DRIVER unavailable:", exc, file=sys.stderr)
        return 2
    write_json(root / "environment.json", {
        "port": args.port, "udid": args.udid,
        "git": run(["git", "log", "-1", "--format=%h %s"]),
        "simulators": run(["xcrun", "simctl", "list", "devices", "booted"]),
    })

    # Deterministic, safe player-menu scenario: never select a song-affecting action.
    player = root / "player"
    safe_action(drv, player / "open-player.json", "player.open")
    time.sleep(.45)
    before = log_and_tree(drv, player / "before", events, "player-before")
    if safe_action(drv, player / "open-menu.json", "player.more"):
        time.sleep(.5)
        after = log_and_tree(drv, player / "after", events, "player-after")
        write_json(player / "screenshot.json", snap(args.udid, player / "screen.png"))
        steps.append({"scenario": "player-more", "before": before.get("menus"), "after": after.get("menus")})
        if after.get("menuReported"):
            if safe_action(drv, player / "open-more.json", "menu.pick", title="More"):
                time.sleep(.45)
                more = log_and_tree(drv, player / "more", events, "player-more-submenu")
                write_json(player / "more-screenshot.json", snap(args.udid, player / "more.png"))
                steps.append({"scenario": "player-more-submenu", "menus": more.get("menus")})
    reset_menu(drv, player, 0)
    safe_action(drv, player / "close-player.json", "player.close")

    # Visit non-destructive UI tabs. Candidate IDs are discovered from UIKit
    # trees; only menu-like button classes/IDs are ever tapped.
    for label in ("Home", "Search", "Your Library"):
        path = root / "tabs" / label.replace(" ", "-")
        entered = safe_action(drv, path / "navigation.json", "tab", arg=label)
        time.sleep(.5)
        before = log_and_tree(drv, path / "before", events, f"tab-{label}")
        steps.append({"scenario": f"tab-{label}", "ok": entered,
                      "candidates": before.get("candidates", [])})
        buttons = before.get("candidates", [])[:max(0, args.max_buttons)]
        if label == "Your Library":
            # The + may open a sheet, not a UIMenu; still valuable to classify.
            buttons.append({"id": "YourLibraryHeader.plus", "class": "known"})
        for idx, candidate in enumerate(buttons):
            cid = candidate["id"]
            if not safe_action(drv, path / f"button-{idx}-tap.json", "tap", id=cid):
                continue
            time.sleep(.35)
            result = log_and_tree(drv, path / f"button-{idx}", events, f"tab-{label}:{cid}")
            write_json(path / f"button-{idx}-screenshot.json",
                       snap(args.udid, path / f"button-{idx}.png"))
            steps.append({"scenario": f"tab-{label}:{cid}",
                          "menus": result.get("menus"), "menuReported": result.get("menuReported")})
            reset_menu(drv, path, idx)

    if not args.no_routes:
        routes = built_in_routes(repo)[:max(0, args.route_limit)]
        write_json(root / "routes.json", routes)
        for n, route in enumerate(routes, 1):
            folder = root / "routes" / f"{n:02d}"
            uri = route["uri"]
            if not (uri.startswith("spotify:") or uri.startswith("https://open.spotify.com/")):
                continue
            navigation = run(["xcrun", "simctl", "openurl", args.udid, uri], timeout=30)
            write_json(folder / "navigation.json", navigation)
            time.sleep(.55)
            before = log_and_tree(drv, folder / "before", events, f"route-{n}:{route['name']}")
            for i, button in enumerate(before.get("candidates", [])[:max(0, args.max_buttons)]):
                if not safe_action(drv, folder / f"button-{i}-tap.json", "tap", id=button["id"]):
                    continue
                time.sleep(.35)
                after = log_and_tree(drv, folder / f"button-{i}", events,
                                     f"route-{n}:{route['name']}:{button['id']}")
                steps.append({"scenario": f"route-{n}:{route['name']}:{button['id']}",
                              "menus": after.get("menus"), "top": after.get("top")})
                write_json(folder / f"button-{i}-screenshot.json",
                           snap(args.udid, folder / f"button-{i}.png"))
                reset_menu(drv, folder, i)

    unique = {}
    for entry in events:
        key = (entry.get("kind"), entry.get("class"), entry.get("id"), entry.get("label"),
               entry.get("owner"), entry.get("reason"), entry.get("interaction"),
               entry.get("delegate"))
        if key not in unique:
            unique[key] = entry
    fieldnames = ["kind", "class", "owner", "id", "label", "menuTitle", "titles",
                  "elements", "primary", "alreadyOwned", "supported",
                  "reason", "interaction", "delegate", "step"]
    with (root / "menu_origins.csv").open("w", encoding="utf-8-sig", newline="") as fd:
        writer = csv.DictWriter(fd, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for entry in unique.values():
            writer.writerow({k: json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list))
                             else v for k, v in entry.items() if k in fieldnames})
    write_json(root / "menu_origins.json", list(unique.values()))
    write_json(root / "steps.json", steps)
    summary = {
        "totalObserved": len(unique),
        "ownableButtons": sum(x.get("kind") == "button" and x.get("supported") is True for x in unique.values()),
        "unresolvedButtons": sum(x.get("kind") == "button" and x.get("supported") is False for x in unique.values()),
        "interactionSources": sum(x.get("kind") == "interaction" for x in unique.values()),
        "steps": len(steps),
        "notes": [
            "Observed menu sources only; not a complete list of Spotify menu providers",
            "Unsupported/deferred sources remain on system presentation in Stage 169",
            "Do not infer that a route was reached solely because simctl openurl returned success",
            "SG_DRIVER log buffer can drop events; snapshots collected after navigation and clicks",
        ],
    }
    write_json(root / "summary.json", summary)
    with ZipFile(root.with_suffix(".zip"), "w", ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(root.rglob("*")):
            if file.is_file():
                archive.write(file, file.relative_to(root.parent))
    print("ARCHIVE:", root.with_suffix(".zip"))
    print("SUMMARY:", json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
