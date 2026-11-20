#!/usr/bin/env python3
"""Stage 72 — read-only Legacy Glass regression evidence, iOS 18 simulator.

Collects three *separate* manual scenarios:
  npv     interrupted open / reverse / hold (and quick reverse) from minimized bar
  tabbar  captions vs icons-only and tab accent on/off
  codes   redesigned Search / the original hidden Spotify Codes button

Run with the existing SG_DRIVER=1 Spotify build; no tweak rebuild or app data reset.
A video is evidence, NOT a claim that the gesture happened or the bug is fixed.
Every scenario is explicitly confirmed by the operator. Incomplete evidence stays
INCOMPLETE. Requires standard-library Python 3 and Apple's xcrun on macOS.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
import zipfile
from datetime import datetime

UDID = "ED66415E-FC8E-44EA-B306-33BB985B9CE8"
SCENARIOS = ("npv", "tabbar", "codes", "codes-native")
CLASSES = ("SGRLegacyTabBar", "SGRLegacyLens", "UITabBarButton",
           "SGRNowPlayingBar", "SGRNowPlayingCard", "UIImageView",
           "SPTEncoreIconView", "UISwitch")
SOURCE_PATHS = (
    "tweak/Sources/Redesigned/Navbar/TabBarLegacy.x",
    "tweak/Sources/Redesigned/Navbar/TabBarLens.m",
    "tweak/Sources/Redesigned/Navbar/NavbarSettings.m",
    "tweak/Sources/Redesigned/Navbar/TabBarMinimize.x",
    "tweak/Sources/Redesigned/Navbar/LegacyNowPlayingTouch.x",
    "tweak/Sources/Redesigned/Player/PlayerMorph.x",
    "tweak/Sources/Redesigned/Player/PlayerGestures.x",
    "tweak/Sources/Redesigned/Search/SearchPage.x",
    "tweak/Sources/Redesigned/Search/SearchHeader.x",
    "tweak/Sources/Redesigned/Navbar/Navbar.h",
)
FOCUS = re.compile(r"TabBar|LegacyLens|NowPlaying|MiniPlayer|CompactOverlay|PlayerMorph|"
                   r"Accent|Capsule|Glass|Scannables|SearchToolBar|Scan|Code|UISwitch|"
                   r"UITabBarButton|_UIImageView|SPTEncoreIconView|Label", re.I)


def dump(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, default=str) + "\n", encoding="utf-8")


def run(cmd, timeout=35):
    try:
        cp = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=timeout, check=False)
        return {"argv": cmd, "returncode": cp.returncode,
                "stdout": cp.stdout[-6000:], "stderr": cp.stderr[-6000:]}
    except Exception as ex:
        return {"argv": cmd, "returncode": -1, "exception": repr(ex)}


class Driver:
    def __init__(self, port):
        self.root = f"http://127.0.0.1:{port}"

    def call(self, command, **params):
        encoded = urllib.parse.urlencode({k: str(v) for k, v in params.items()},
                                         quote_via=urllib.parse.quote)
        url = f"{self.root}/{urllib.parse.quote(command)}" + ("?" + encoded if encoded else "")
        req = urllib.request.Request(url, headers={"X-Phone-Driver": "1"})
        with urllib.request.urlopen(req, timeout=22) as response:
            raw = response.read().decode("utf-8", "replace")
        if command == "tree":
            return raw
        result = json.loads(raw)
        if not isinstance(result, dict) or not result.get("ok", False):
            raise RuntimeError(f"{command}: {str(result)[:500]}")
        return result


def check_mp4(path):
    path = Path(path)
    report = {"file": path.name, "ok": False, "size": path.stat().st_size if path.exists() else 0}
    if report["size"] < 4096:
        report["reason"] = "missing or too small"
        return report
    try:
        with path.open("rb") as f:
            pos, atoms, end = 0, [], report["size"]
            while pos + 8 <= end:
                f.seek(pos)
                n, kind = struct.unpack(">I4s", f.read(8))
                name = kind.decode("ascii", "replace")
                if n == 1:
                    n = struct.unpack(">Q", f.read(8))[0]
                    header = 16
                else:
                    header = 8
                    if n == 0:
                        n = end - pos
                if n < header or pos + n > end:
                    raise ValueError(f"invalid atom {name} at {pos}")
                atoms.append(name)
                pos += n
        if pos != end or not {"ftyp", "moov", "mdat"}.issubset(set(atoms)):
            raise ValueError(f"missing atoms or truncated: {atoms}")
        report.update(ok=True, atoms=atoms)
        return report
    except Exception as ex:
        report["reason"] = repr(ex)
        return report


def prompt(message):
    print("\n" + "=" * 62 + "\n" + message + "\n" + "=" * 62, flush=True)
    response = input("Enter — продолжить, q — пропустить сценарий: ").strip().lower()
    return response not in ("q", "quit", "skip")


def confirm(message):
    ans = input(message + " [y/N]: ").strip().lower()
    return ans in ("y", "yes", "да", "д")


class Collector:
    def __init__(self, args):
        self.args = args
        self.repo = Path(args.repo).expanduser().resolve()
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.root = (self.repo / args.output / f"stage72-legacy-navigation-{stamp}").resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.driver = Driver(args.port)
        self.report = {"status": "INCOMPLETE", "scenarios": {}, "warnings": [],
                       "simulator": args.udid, "driverPort": args.port,
                       "started": datetime.now().isoformat(timespec="seconds")}

    def warn(self, message):
        self.report["warnings"].append(message)
        print("  [warning]", message, flush=True)

    def call(self, tag, command, **kwargs):
        try:
            result = self.driver.call(command, **kwargs)
            return result
        except Exception as ex:
            self.warn(f"{tag}: {command}{kwargs}: {repr(ex)}")
            return {"ok": False, "error": repr(ex)}

    def screenshot(self, path, required=True):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        result = run(["xcrun", "simctl", "io", self.args.udid,
                      "screenshot", "--type=png", str(p)], timeout=30)
        if required and (result["returncode"] != 0 or not p.exists() or p.stat().st_size < 2000):
            raise RuntimeError(f"screenshot failed at {path}: {result}")
        return result

    def snapshot(self, tag, deep=True):
        folder = self.root / tag
        print("  снимок:", tag, flush=True)
        state = self.call(tag, "state")
        tree = self.call(tag, "tree")
        folder.mkdir(parents=True, exist_ok=True)
        if not isinstance(tree, str) or len(tree) < 80:
            raise RuntimeError(f"missing usable tree: {tag}")
        (folder / "tree.txt").write_text(tree, encoding="utf-8")
        (folder / "focus.txt").write_text("\n".join(
            f"{n:5d} {line}" for n, line in enumerate(tree.splitlines(), 1) if FOCUS.search(line)) + "\n",
            encoding="utf-8")
        dump(folder / "state.json", state)
        self.screenshot(f"{tag}/screen.png")
        if deep:
            for cls in CLASSES:
                obj = self.call(tag, "find", **{"class": cls})
                dump(folder / "find" / f"{cls}.json", obj)
                if obj.get("ok") is False or not int(obj.get("count", 0)):
                    continue
                if cls in ("SGRLegacyTabBar", "SGRLegacyLens", "SGRNowPlayingBar"):
                    for index in range(min(2, int(obj.get("count", 0)))):
                        dump(folder / "layers" / f"{cls}-{index}.json",
                             self.call(tag, "layers", **{"class": cls, "index": index, "depth": 7}))
                        for key in ("frame", "hidden", "alpha", "layer.opacity",
                                    "layer.presentationLayer.transform", "layer.animationKeys"):
                            dump(folder / "properties" / f"{cls}-{index}-{key.replace('.', '_')}.json",
                                 self.call(tag, "get", **{"class": cls, "index": index, "path": key}))
            dump(folder / "codes-button.json",
                 self.call(tag, "find", id="SearchToolBar.AccessoryItem.ScannablesButton"))
        dump(folder / "log.json", self.call(tag, "log"))
        return state

    def record_manual(self, tag, hold=False):
        folder = self.root / tag
        folder.mkdir(parents=True, exist_ok=True)
        output = folder / "motion.mp4"
        logging = (folder / "recording.log").open("w", encoding="utf-8")
        argv = ["xcrun", "simctl", "io", self.args.udid,
                "recordVideo", "--codec=h264", "--force", str(output)]
        p = None
        timeline = []
        try:
            p = subprocess.Popen(argv, stdout=logging, stderr=subprocess.STDOUT)
            ready_by = time.monotonic() + 12
            while time.monotonic() < ready_by:
                logging.flush()
                if p.poll() is not None:
                    raise RuntimeError("recordVideo exited before capture")
                if "Recording started" in (folder / "recording.log").read_text(errors="replace"):
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("recordVideo did not report Recording started")
            print("\n  ЗАПИСЬ: открой Simulator и выполни жест сейчас.", flush=True)
            print("  Пример: 1–2 с покой → вверх до середины → обратно вниз → "
                  + ("держать 3–4 с → отпустить." if hold else "сразу отпустить."), flush=True)
            times = (0.45, 1.2, 2.3, 3.3, 4.4, 5.5, 6.6, 7.7, 9.1)
            began = time.monotonic()
            for num, when in enumerate(times):
                wait = began + when - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
                start = time.monotonic() - began
                path = f"{tag}/samples/frame{num:02d}-{int(when * 1000)}ms.png"
                self.screenshot(path)
                timeline.append({"requested_s": when, "started_s": round(start, 3),
                                 "finished_s": round(time.monotonic()-began, 3), "path": path})
            until = began + 10.2 - time.monotonic()
            if until > 0:
                time.sleep(until)
        finally:
            if p and p.poll() is None:
                p.send_signal(signal.SIGINT)
                try:
                    p.wait(timeout=16)
                except subprocess.TimeoutExpired:
                    p.terminate()
                    p.wait(timeout=8)
            logging.close()
        dump(folder / "timeline.json", {"argv": argv, "samples": timeline,
                                        "user_must_confirm_real_gesture": True})
        video = check_mp4(output)
        dump(folder / "video-check.json", video)
        if not video["ok"]:
            raise RuntimeError("invalid or missing video: " + str(video))
        print("  видео проверено:", output.name, video["size"], "bytes", flush=True)
        return video

    def npv(self):
        tag = "npv"
        if not prompt("1/3 NPV: открой Home с минимизированным таббаром и видимым мини-плеером."
                      "\nПлеер должен быть свернут. Ничего не нажимай во время первого снимка."):
            return False
        state = self.snapshot(f"{tag}/rest")
        if state.get("player") is True:
            self.warn("NPV baseline reports full player open, expected minimized player")
            return False
        for name, held in (("reverse-and-hold", True), ("reverse-quick", False)):
            if not prompt("NPV: " + ("Проведи мини-плеер вверх до середины, верни вниз, НЕ отпуская удерживай на 3–4 секунды, потом отпусти."
                                      if held else "Повтори вверх до середины → обратно вниз, но сразу отпусти. Без удержания.")
                          + "\nКогда нажмёшь Enter, начнётся запись 10 секунд; жест делай в этот интервал."):
                return False
            self.snapshot(f"{tag}/{name}/before", deep=False)
            self.record_manual(f"{tag}/{name}", hold=held)
            self.snapshot(f"{tag}/{name}/after", deep=True)
            time.sleep(1.1)
            self.snapshot(f"{tag}/{name}/settled", deep=True)
            if not confirm(f"Действительно выполнил {name} целиком в пределах 10-секундной записи?"):
                self.warn(name + ": gesture not confirmed by operator")
                return False
        return True

    def tabbar(self):
        states = (
            ("labels-accent-on", "Подписи ВКЛ; Tabs in the accent ВКЛ"),
            ("icons-only-accent-on", "Подписи ВЫКЛ; Tabs in the accent ВКЛ"),
            ("icons-only-accent-off", "Подписи ВЫКЛ; Tabs in the accent ВЫКЛ"),
        )
        for name, description in states:
            if not prompt(f"Tab Bar Settings: установи {description}. ОСТАВЬ ОТКРЫТЫМИ настройки таббара."):
                return False
            self.snapshot(f"tabbar/{name}/settings", deep=True)
            if not prompt(f"Теперь из настроек открой Home с состоянием: {description}."
                          "\nПодожди, пока таббар полностью разложится; НЕ нажимай вкладку до снимка."):
                return False
            self.snapshot(f"tabbar/{name}/rest", deep=True)
            if not prompt("Нажми и отпусти активную вкладку (например Home), чтобы проверить размер иконки в поднятом стекле."):
                return False
            self.snapshot(f"tabbar/{name}/after-tap", deep=True)
            if not confirm(f"Состояние {name} было выставлено точно?"):
                self.warn("tabbar configuration not confirmed: " + name)
                return False
        return True

    def codes(self, native=False):
        tag = "codes-native" if native else "codes"
        if not prompt(("Переключи приложение в Native UI, перезапусти Spotify, открой экран Search."
                       if native else "В Redesigned открой Search, где отсутствует Spotify Codes (камера).")
                      + "\nОставь страницу Search открытой для дерева и снимка."):
            return False
        state = self.snapshot(tag + "/search", deep=True)
        tree = (self.root / tag / "search" / "tree.txt").read_text(encoding="utf-8")
        matched = "SearchToolBar.AccessoryItem.ScannablesButton" in tree or "Scannables" in tree
        dump(self.root / tag / "search-analysis.json", {"scannables_in_tree": matched,
                                                        "top": state.get("top"), "native": native})
        # This intentionally does NOT open Scannables: its popup is a future iteration.
        if not confirm(("Native" if native else "Redesigned") + " Search был открыт в момент снимка?"):
            return False
        return True

    def sources(self):
        meta = {"system": platform.platform(), "python": sys.version,
                "requested": list(self.args.scenarios), "repo": str(self.repo)}
        for command in (("git", "rev-parse", "HEAD"),
                        ("git", "branch", "--show-current"),
                        ("git", "log", "-8", "--oneline"),
                        ("git", "status", "--porcelain")):
            meta[" ".join(command)] = run(list(command), timeout=12)
        dump(self.root / "repo-source" / "metadata.json", meta)
        for path in SOURCE_PATHS:
            source = self.repo / path
            if source.is_file():
                dst = self.root / "repo-source" / path
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, dst)
            else:
                self.warn("missing source: " + path)

    def geometry(self):
        """Summarise view coordinates without claiming that the visual bug is fixed."""
        geometry = {}
        for state in ("labels-accent-on", "icons-only-accent-on", "icons-only-accent-off"):
            base = self.root / "tabbar" / state / "rest" / "find"
            if not base.exists():
                continue
            def views(cls):
                f = base / (cls + ".json")
                if not f.exists():
                    return []
                try:
                    raw = json.loads(f.read_text())
                    return [v for v in raw.get("views", []) if v.get("shown") is not False and
                            isinstance(v.get("frame"), list) and len(v["frame"]) == 4]
                except (ValueError, TypeError):
                    return []
            buttons = [v for v in views("UITabBarButton") if v["frame"][1] > 350 and
                       v["frame"][2] > 28 and v["frame"][3] > 25]
            buttons.sort(key=lambda v: v["frame"][0])
            icons = [v for v in views("UIImageView") if v["frame"][1] > 350 and
                     8 <= v["frame"][2] <= 50 and 8 <= v["frame"][3] <= 50]
            entries = []
            for b in buttons:
                x,y,w,h = b["frame"]
                cx,cy = x+w/2, y+h/2
                matches=[]
                for icon in icons:
                    ix,iy,iw,ih = icon["frame"]
                    icx,icy = ix+iw/2, iy+ih/2
                    if x-8 <= icx <= x+w+8 and y-10 <= icy <= y+h+10:
                        matches.append({"frame": icon["frame"], "offset_from_button_center_y":round(icy-cy,2),
                                        "center_x_delta":round(icx-cx,2)})
                matches.sort(key=lambda e: (abs(e["center_x_delta"]), abs(e["offset_from_button_center_y"])))
                entries.append({"button": b["frame"], "closest_icons": matches[:4]})
            lenses = [v.get("frame") for v in views("SGRLegacyLens")]
            geometry[state] = {"button_count": len(buttons), "buttons": entries,
                               "lens_frames": lenses,
                               "note": "Closest UIImageViews can include overlays; check the linked screen.png."}
        if geometry:
            dump(self.root / "analysis" / "tabbar-geometry.json", geometry)
        return geometry

    def finish(self):
        self.geometry()
        wanted = list(self.args.scenarios)
        self.report["finished"] = datetime.now().isoformat(timespec="seconds")
        self.report["status"] = ("EVIDENCE_CAPTURED" if all(self.report["scenarios"].get(x) == "CAPTURED"
                                                          for x in wanted) else "INCOMPLETE")
        dump(self.root / "summary.json", self.report)
        zip_path = self.root.with_suffix(".zip")
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for p in self.root.rglob("*"):
                if p.is_file():
                    z.write(p, str(p.relative_to(self.root.parent)))
        print("\nSTATUS:", self.report["status"])
        print("Evidence ZIP:", zip_path)
        print("Снимки/видео — данные для анализа, не подтверждение исправления багов.")
        return self.report["status"] == "EVIDENCE_CAPTURED"


def self_test():
    import tempfile
    with tempfile.TemporaryDirectory() as folder:
        out = Path(folder) / "fake.mp4"
        assert not check_mp4(out)["ok"]
        # Valid ftyp/moov/mdat box structure without pretending there is playable video.
        out.write_bytes(b"\x00\x00\x00\x08ftyp" + b"\x00\x00\x00\x08moov" +
                        b"\x00\x00\x10\x08mdat" + b"\x00"*4096)
        assert check_mp4(out)["ok"]
        assert not check_mp4(out.with_name("missing.mp4"))["ok"]
        assert urllib.parse.urlencode({"id": "SearchToolBar.AccessoryItem.ScannablesButton",
                                       "text": "Spotify Codes"}, quote_via=urllib.parse.quote).find("%20") >= 0
    print("SELF-TEST: OK (no simulator needed)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=".", help="spoti-fork repository, default current directory")
    parser.add_argument("--output", default="out", help="artifact folder in the repository")
    parser.add_argument("--udid", default=UDID)
    parser.add_argument("--port", type=int, default=8087)
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=["npv", "tabbar", "codes"])
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not shutil.which("xcrun"):
        parser.error("requires xcrun (run this on the Mac with Xcode tools installed)")
    collector = Collector(args)
    try:
        state = collector.driver.call("state")
        if not state.get("ok"):
            raise RuntimeError("SG_DRIVER not ready")
        collector.sources()
        for scenario in args.scenarios:
            try:
                ok = collector.codes(native=True) if scenario == "codes-native" else getattr(collector, scenario)()
                collector.report["scenarios"][scenario] = "CAPTURED" if ok else "INCOMPLETE"
            except KeyboardInterrupt:
                collector.warn("interrupted during " + scenario)
                collector.report["scenarios"][scenario] = "INCOMPLETE"
                break
            except Exception as ex:
                collector.warn(scenario + ": " + repr(ex))
                collector.report["scenarios"][scenario] = "INCOMPLETE"
                print("Продолжаю со следующим сценарием", flush=True)
    except Exception as ex:
        collector.warn("preflight: " + repr(ex))
    return 0 if collector.finish() else 2


if __name__ == "__main__":
    sys.exit(main())
