#!/usr/bin/env python3
"""Stage 173: record owned Legacy dropdown openings and classify picker routes.

Uses SG_DRIVER and xcrun simctl (no manual navigation). Observes menu creation,
configuration callbacks, and dedicated controller presentations, without
executing menu actions. Only menu-opening buttons and the More *submenu* are
tapped; other menu commands are not executed.

Requires Stage 172 dylib, which emits dropdown.provider.inventory events.
The runtime trace cannot prove that unreachable app states are covered.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import csv
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from zipfile import ZipFile, ZIP_DEFLATED


def load_inventory_module():
    filename = Path(__file__).with_name("vitrine-dropdown-provider-inventory.py")
    spec = importlib.util.spec_from_file_location("sgr_stage170_inventory", filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


legacy = load_inventory_module()
PLAYER_ID = re.compile(r"\bid=(?:Context menu|NowPlaying[^ ]*(?:context|more)[^ ]*)", re.I)
NOW_PLAYING = re.compile(r"(?:NowPlaying|now-playing|Now Playing)", re.I)
EXCLUDED = re.compile(r"(?:delete|remove|signout|logout|purchase|follow|like|download|play|pause|share)", re.I)


def menu_ready(tree: str) -> bool:
    for line in tree.splitlines():
        if PLAYER_ID.search(line) and "hidden" not in line and "a=0.00" not in line:
            return True
    return False


def unique_events(events: list[dict]) -> list[dict]:
    seen, out = set(), []
    for event in events:
        key = (event.get("sequence"), json.dumps(
            {k: v for k, v in event.items() if k not in ("step", "sequence")},
            ensure_ascii=False, sort_keys=True))
        if key in seen:
            continue
        seen.add(key)
        out.append(event)
    return out


def build_chains(events: list[dict]) -> list[dict]:
    groups = {}
    for event in events:
        pointer = event.get("interactionPointer")
        if not pointer:
            continue
        record = groups.setdefault(pointer, {
            "interactionPointer": pointer,
            "anchorPointer": "",
            "anchorClass": "",
            "owner": "",
            "delegate": "",
            "attachmentSeen": False,
            "configurationSeen": False,
            "hasConfiguration": None,
            "hasActionProvider": None,
            "firstStep": "",
            "lastStep": "",
        })
        if event.get("kind") == "interaction":
            record["attachmentSeen"] = True
        if event.get("kind") == "configuration":
            record["configurationSeen"] = True
            record["hasConfiguration"] = event.get("hasConfiguration")
            record["hasActionProvider"] = event.get("hasActionProvider")
        for dest, source in (("anchorPointer", "anchorPointer"),
                             ("anchorClass", "class"), ("owner", "owner"),
                             ("delegate", "delegate")):
            if event.get(source):
                record[dest] = event[source]
        if not record["firstStep"]:
            record["firstStep"] = event.get("step", "")
        record["lastStep"] = event.get("step", "")
    return sorted(groups.values(), key=lambda r: (r["owner"], r["anchorClass"], r["delegate"]))


class Trace:
    def __init__(self, driver, root: Path, udid: str):
        self.driver = driver
        self.root = root
        self.udid = udid
        self.events = []
        self.steps = []
        self.failures = []

    def command(self, command: str, path: Path, **params) -> bool:
        return legacy.safe_action(self.driver, path, command, **params)

    def snapshot(self, folder: Path, name: str, label: str):
        folder.mkdir(parents=True, exist_ok=True)
        details = {"label": label, "errors": []}
        # Read events BEFORE a large "tree" dump fills SG_DRIVER's log ring.
        for cmd, filename in (("state", "state.json"), ("log", "log.json"),
                              ("tree", "tree.txt")):
            try:
                val = self.driver.call(cmd)
                if cmd == "tree":
                    (folder / filename).write_text(val[:8_000_000], encoding="utf-8")
                    details["candidates"] = legacy.menu_candidates(val)
                    details["menuSignals"] = [s for s in legacy.MENU_SIGNALS if s in val]
                    details["playerMenuButton"] = menu_ready(val)
                else:
                    legacy.write_json(folder / filename, val)
                    if cmd == "state":
                        details["top"] = val.get("top")
                        details["menu"] = val.get("menu")
                        details["player"] = val.get("player")
                    else:
                        for item in legacy.extract_events(val):
                            item["step"] = label
                            self.events.append(item)
            except Exception as exc:
                details["errors"].append(f"{cmd}: {exc}")
        legacy.write_json(folder / "meta.json", details)
        return details

    def screenshot(self, folder: Path, name: str):
        legacy.write_json(folder / f"{name}-screenshot.json",
                          legacy.snap(self.udid, folder / f"{name}.png"))

    def dismiss(self, folder: Path, number: int):
        legacy.reset_menu(self.driver, folder, number)

    def wait_for_player(self, path: Path, timeout: float = 9.0):
        # Stage 170 sampled an appearing NowPlayingOverlayContainer after only
        # 450ms, when the 'Context menu' button was not in the view tree yet.
        deadline = time.monotonic() + timeout
        attempts = []
        ready = False
        while time.monotonic() < deadline:
            try:
                state = self.driver.call("state")
                tree = self.driver.call("tree")
                ready = menu_ready(tree)
                attempts.append({
                    "top": state.get("top"), "player": state.get("player"),
                    "menuButtonVisible": ready,
                    "nowPlayingTree": bool(NOW_PLAYING.search(tree)),
                })
                if ready:
                    break
            except Exception as exc:
                attempts.append({"error": str(exc)})
            time.sleep(0.4)
        legacy.write_json(path / "readiness-polls.json", attempts)
        return ready

    def player_scenario(self):
        folder = self.root / "player"
        folder.mkdir(parents=True, exist_ok=True)
        opened = self.command("player.open", folder / "open-player.json")
        ready = self.wait_for_player(folder) if opened else False
        before = self.snapshot(folder / "before", "before", "player-ready")
        self.screenshot(folder, "player-before")
        response = False
        # If SG_DRIVER's semantic command still misses the control, a visible
        # accessibility ID is a safe alternative. Never tap a blind coordinate.
        if ready:
            response = self.command("player.more", folder / "open-menu.json")
            if not response:
                response = self.command("tap", folder / "open-menu-id.json",
                                        id="Context menu")
        else:
            legacy.write_json(folder / "no-menu-button.json", {
                "reason": "player button was not visible after readiness polling",
                "lastTop": before.get("top"),
                "navigationAttempted": opened,
            })
        if response:
            time.sleep(0.5)
            after = self.snapshot(folder / "after", "after", "player-more")
            self.screenshot(folder, "player-more")
            if after.get("menu") or after.get("menuSignals"):
                if self.command("menu.pick", folder / "submenu-action.json", title="More"):
                    time.sleep(0.4)
                    self.snapshot(folder / "submenu", "submenu", "player-more-submenu")
                    self.screenshot(folder, "player-submenu")
        else:
            self.failures.append({"scenario": "player-more",
                                  "reason": "no accessible visible player menu button",
                                  "top": before.get("top")})
        self.steps.append({"scenario": "player-more",
                           "playerOpenCommand": opened, "ready": ready,
                           "menuOpened": response})
        self.dismiss(folder, 0)
        self.command("player.close", folder / "close-player.json")

    def route_scenarios(self, routes, limit: int, max_buttons: int):
        for idx, route in enumerate(routes[:max(0, limit)], 1):
            folder = self.root / "routes" / f"{idx:02d}-{re.sub('[^A-Za-z0-9]+','-', route['name']).strip('-')}"
            folder.mkdir(parents=True, exist_ok=True)
            uri = route["uri"]
            if not (uri.startswith("spotify:") or uri.startswith("https://open.spotify.com/")):
                continue
            try:
                before_state = self.driver.call("state")
            except Exception:
                before_state = {}
            nav = legacy.run(["xcrun", "simctl", "openurl", self.udid, uri], timeout=25)
            legacy.write_json(folder / "navigation.json", nav)
            if not nav.get("ok"):
                self.failures.append({"scenario": route["name"], "reason": "openurl failed"})
                continue
            # A successful openurl only confirms a URL dispatch, not arrival
            # on the intended screen. Record the top controller before/after.
            time.sleep(0.8)
            before = self.snapshot(folder / "before", "before", f"route:{route['name']}")
            self.screenshot(folder, "route-before")
            top_unchanged = bool(before_state.get("top") and
                                 before_state.get("top") == before.get("top"))
            candidates = before.get("candidates", [])[:max(0, max_buttons)]
            # URI dispatch does not dismiss an existing sorting picker.
            # Avoid tapping controls that belong to the previous screen.
            stale_picker = (top_unchanged and
                            "Picker" in str(before.get("top", "")))
            self.steps.append({"scenario": f"route:{route['name']}",
                               "uri": uri, "topBefore": before_state.get("top"),
                               "topAfter": before.get("top"),
                               "arrivalConfirmed": not top_unchanged,
                               "arrivalEvidence": "controller_changed" if not top_unchanged
                                                  else "URI-dispatched-only",
                               "candidates": candidates,
                               "pickerBlockingRoute": stale_picker})
            if stale_picker:
                continue
            for n, candidate in enumerate(candidates):
                target = candidate.get("id", "")
                if EXCLUDED.search(target):
                    continue
                if not self.command("tap", folder / f"tap-{n}.json", id=target):
                    continue
                time.sleep(0.3)
                after = self.snapshot(folder / f"after-{n}", "after",
                                      f"route:{route['name']}:{target}")
                self.screenshot(folder, f"after-{n}")
                after_top = str(after.get("top") or "")
                is_picker = "Picker" in after_top or "SortingFiltering" in after_top
                self.steps.append({"scenario": f"route:{route['name']}:{target}",
                                   "topBefore": before.get("top"),
                                   "topAfter": after.get("top"),
                                   "menuSignals": after.get("menuSignals"),
                                   "menu": after.get("menu"),
                                   "classification": "picker-controller" if is_picker
                                       else "owned-dropdown" if "Vitrine.Dropdown.Panel"
                                           in (after.get("menuSignals") or [])
                                       else "other"})
                self.dismiss(folder, n)
                if is_picker:
                    self.command("tap", folder / f"close-picker-{n}.json",
                                 id="SPTSortingFilteringPicker.cancel")
                    time.sleep(0.3)

    def write(self, ipa: Path | None):
        records = unique_events(self.events)
        legacy.write_json(self.root / "runtime_events.json", records)
        chains = build_chains(records)
        legacy.write_json(self.root / "menu_chains.json", chains)
        fields = ["kind", "class", "owner", "id", "label", "menuTitle", "titles",
                  "elements", "primary", "alreadyOwned", "supported", "reason",
                  "status", "sourceClass", "directElements",
                  "interaction", "delegate", "interactionPointer", "anchorPointer",
                  "hasConfiguration", "hasActionProvider", "configurationClass",
                  "presenterPointer", "presentedPointer", "style", "step"]
        with (self.root / "menu_origins.csv").open("w", newline="", encoding="utf-8-sig") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
            writer.writeheader()
            for event in records:
                writer.writerow({k: json.dumps(v, ensure_ascii=False) if isinstance(v, (list, dict))
                                 else v for k, v in event.items() if k in fields})
        with (self.root / "menu_chains.csv").open("w", newline="", encoding="utf-8-sig") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(build_chains([{
                "kind": "interaction", "interactionPointer": "fixture"
            }])[0].keys()), extrasaction="ignore")
            writer.writeheader()
            writer.writerows(chains)
        legacy.write_json(self.root / "steps.json", self.steps)
        legacy.write_json(self.root / "failures.json", self.failures)
        summary = {
            "stage": 172,
            "events": len(records),
            "interactions": sum(x.get("kind") == "interaction" for x in records),
            "actualConfigurations": sum(x.get("kind") == "configuration" for x in records),
            "dedicatedPresentations": sum(x.get("kind") == "presentation" for x in records),
            "menuButtons": sum(x.get("kind") == "button" for x in records),
            "interactionChains": len(chains),
            "observedRuntimeOrigins": len(records),
            "ownedDropdownOpens": sum(x.get("kind") == "owned-dropdown"
                                       and x.get("status") == "opened" for x in records),
            "pickerPresentations": sum(x.get("kind") == "picker-presentation"
                                       for x in records),
            "driverConfirmedDropdowns": sum(
                x.get("classification") == "owned-dropdown" for x in self.steps
            ) + int(any(x.get("scenario") == "player-more" and x.get("menuOpened")
                        for x in self.steps)),
            "driverObservedPickerTransitions": sum(
                x.get("classification") == "picker-controller" for x in self.steps),
            "playerMoreOpened": any(x.get("scenario") == "player-more" and
                                    x.get("menuOpened") for x in self.steps),
            "unreached": self.failures,
            "limits": [
                "An interaction/configuration pair is confirmed only when it shares an interactionPointer.",
                "A controller presentation is separate evidence, not proof of the same interaction chain.",
                "An unchanged top controller after openurl means arrival was NOT confirmed.",
                "Unvisited Spotify features and Swift-only call sites remain outside runtime coverage.",
                "Only the simulator build can verify that runtime hooks actually fire.",
                "SG_DRIVER-confirmed owned menus are independent from UIKit hooks.",
                "Sorting/filtering pickers are controllers, not UIMenu dropdowns.",
            ]
        }
        # Static scanner is optional. It must read the freshly collected CSV,
        # not a stale Stage 170 archive or an empty default runtime argument.
        if ipa and ipa.is_file():
            result = legacy.run([
                sys.executable,
                str(Path(__file__).with_name("vitrine-dropdown-ipa-crossref.py")),
                "--ipa", str(ipa), "--runtime", str(self.root / "menu_origins.csv"),
                "--out", str(self.root / "static-crossref")
            ], timeout=120)
            legacy.write_json(self.root / "static-crossref-run.json", result)
            summary["staticCrossrefSucceeded"] = result.get("ok", False)
        legacy.write_json(self.root / "summary.json", summary)
        output = self.root.with_suffix(".zip")
        with ZipFile(output, "w", ZIP_DEFLATED, compresslevel=6) as z:
            for file in sorted(self.root.rglob("*")):
                if file.is_file():
                    z.write(file, file.relative_to(self.root.parent))
        return output, summary


def self_test():
    raw = ('UIButton {{0,0},{30,30}} id=Context menu\n'
           'UIButton {{0,0},{30,30}} hidden id=Context menu')
    assert menu_ready(raw)
    assert not menu_ready('UIButton hidden id=Context menu')
    ev = [
        {"kind": "interaction", "interactionPointer": "0x123", "delegate": "SpotifyDelegate",
         "sequence": 1, "step": "one"},
        {"kind": "interaction", "interactionPointer": "0x123", "delegate": "SpotifyDelegate",
         "sequence": 1, "step": "two"},
        {"kind": "configuration", "interactionPointer": "0x123",
         "hasConfiguration": True, "hasActionProvider": True, "sequence": 2,
         "step": "three"},
    ]
    assert len(unique_events(ev)) == 2
    linked = build_chains(unique_events(ev))
    assert len(linked) == 1 and linked[0]["configurationSeen"]
    assert linked[0]["hasActionProvider"] is True
    print("Stage 173 self-test: OK")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8087)
    parser.add_argument("--udid", default=legacy.DEFAULT_UDID)
    parser.add_argument("--out", type=Path, default=Path("out"))
    parser.add_argument("--route-limit", type=int, default=17)
    parser.add_argument("--max-buttons", type=int, default=3)
    parser.add_argument("--no-routes", action="store_true")
    parser.add_argument("--ipa", type=Path, help="optional decrypted Spotify IPA for static crossref")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    root = args.out.resolve() / ("vitrine-dropdown-trace-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    root.mkdir(parents=True, exist_ok=False)
    driver = legacy.Driver(args.port)
    trace = Trace(driver, root, args.udid)
    try:
        info = driver.call("state")
    except Exception as exc:
        print(f"SG_DRIVER not reachable on port {args.port}: {exc}", file=sys.stderr)
        return 2
    legacy.write_json(root / "environment.json", {
        "initialState": info,
        "port": args.port, "udid": args.udid,
        "git": legacy.run(["git", "log", "-1", "--oneline"]),
        "simulators": legacy.run(["xcrun", "simctl", "list", "devices", "booted"]),
    })
    try:
        trace.player_scenario()
        if not args.no_routes:
            routes = legacy.built_in_routes(Path.cwd())
            legacy.write_json(root / "routes.json", routes)
            trace.route_scenarios(routes, args.route_limit, args.max_buttons)
    finally:
        path, summary = trace.write(args.ipa)
        print("ARCHIVE:", path)
        print("SUMMARY:", json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
