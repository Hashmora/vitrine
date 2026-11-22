#!/usr/bin/env python3
"""Offline dropdown entrypoint inventory. No dynamic hook or menu action is performed.

Reads Mach-O ObjC class and selector string sections from a decrypted Spotify IPA,
optionally intersects them with an existing ObjC class inventory and the SG_DRIVER
provider-inventory archive. Presence in static metadata is NOT proof of a call site.
"""
from __future__ import annotations

import argparse
import collections
import csv
import io
import json
from pathlib import Path
import re
import struct
import zipfile

SELECTOR = re.compile(r"(?:contextMenu|ContextMenu|MenuInteraction|DeferredMenu|"
                      r"showsMenu|setMenu:|menuWith|menuFor|presentMenu|"
                      r"PopoverPresentation|popoverPresentation|"
                      r"configurationForMenu|editingMenu)", re.I)

def sections(data: bytes):
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xfeedfacf:
        raise ValueError("Not an arm64 little-endian 64-bit Mach-O")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    cursor = 32
    result = {}
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, cursor)
        if command == 0x19:  # LC_SEGMENT_64
            segment = data[cursor+8:cursor+24].split(b"\0")[0].decode()
            count = struct.unpack_from("<I", data, cursor+64)[0]
            sc = cursor+72
            for _ in range(count):
                name, _, _, length, offset = struct.unpack_from("<16s16sQQI",data,sc)
                name = name.split(b"\0")[0].decode()
                result[(segment,name)] = (offset,length)
                sc += 80
        cursor += size
    return result

def get_strings(data, sects, section):
    key = ("__TEXT",section)
    if key not in sects: return set()
    offset,length = sects[key]
    return {x.decode("utf-8","replace") for x in
            data[offset:offset+length].split(b"\0") if x}

def swift_display(raw: str) -> str:
    if not raw.startswith("_TtC"): return raw
    s=raw[4:]
    components=[]
    for _ in range(3):
        m=re.match(r"\d+",s)
        if not m: break
        n=int(m.group())
        s=s[len(m.group()):]
        if len(s)<n: break
        components.append(s[:n]);s=s[n:]
    return ".".join(components) if len(components)>=2 else raw

def category(name):
    n=name.lower()
    if "contextmenu_internalimpl." in n or "contextmenu_platformlegacyadapterimpl." in n:
        return ("P0","spotify-menu-infrastructure")
    if "sptshowentitycontextmenu" in n: return ("P0","entity-controller")
    if "yourlibrarycontextmenu" in n: return ("P0","library-menu")
    if "nowplaying_elementsimpl.contextmenubutton" in n: return ("P0","player-entry")
    if "contextmenuviewcontroller" in n or "contextmenunavigationcontroller" in n:
        return ("P1","dedicated-controller")
    if "sptpopover" in n or "navigationui_sheetimpl.popover" in n:
        return ("P1","popover-controller")
    if "search_featureimpl.contextmenu" in n: return ("P1","search-menu")
    if "contextmenupresenter" in n or "contextmenuitemprovider" in n:
        return ("P1","provider-or-presenter")
    if "contextmenubutton" in n or "contextmenuhandler" in n:
        return ("P1","menu-entry-or-handler")
    if "contextmenu" in n: return ("P2","context-menu-related")
    return None

def read_old_inventory(path):
    if not path: return []
    p=Path(path)
    if zipfile.is_zipfile(p):
        with zipfile.ZipFile(p) as f:
            candidates=[x for x in f.namelist() if x.endswith("all_objc_classes.csv")]
            if not candidates: raise ValueError("No all_objc_classes.csv in inventory archive")
            return list(csv.DictReader(io.StringIO(f.read(candidates[0]).decode("utf-8-sig"))))
    return list(csv.DictReader(io.StringIO(p.read_text(encoding="utf-8-sig"))))

def read_runtime(path):
    if not path: return []
    p=Path(path)
    if zipfile.is_zipfile(p):
        with zipfile.ZipFile(p) as z:
            names=[x for x in z.namelist() if x.endswith("menu_origins.csv")]
            if not names: raise ValueError("No menu_origins.csv in SG_DRIVER archive")
            return list(csv.DictReader(io.StringIO(z.read(names[0]).decode("utf-8-sig"))))
    return list(csv.DictReader(io.StringIO(p.read_text(encoding="utf-8-sig"))))

def write_csv(path,rows,fields):
    with open(path,"w",encoding="utf-8-sig",newline="") as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction="ignore")
        w.writeheader();w.writerows(rows)

def analyze(args):
    destination=Path(args.out);destination.mkdir(parents=True,exist_ok=True)
    present_classes=set()
    present_selectors=set()
    if args.ipa:
        with zipfile.ZipFile(args.ipa) as z:
            executables=[n for n in z.namelist() if n.startswith("Payload/") and
                         (n.endswith("/Spotify") or n.endswith(".framework/SpotifyShared"))]
            if not executables: raise ValueError("No Spotify Mach-O executable in IPA")
            for name in executables:
                data=z.read(name)
                sects=sections(data)
                present_classes |= get_strings(data,sects,"__objc_classname")
                present_selectors |= get_strings(data,sects,"__objc_methname")
    old=read_old_inventory(args.inventory)
    runtime=read_runtime(args.runtime)
    runtime_names=set()
    for r in runtime:
        for key in ("owner","class","delegate"):
            if r.get(key):
                runtime_names.add(r[key])
                runtime_names.add(r[key].split(".")[-1])
    rows=[]
    legacy_names=set()
    for r in old:
        raw=r.get("raw_class","")
        display=r.get("display_name",raw)
        score=category(display)
        if not score: continue
        legacy_names.add(raw)
        priority,kind=score
        seen = bool(runtime) and (display in runtime_names or raw in runtime_names or
                       display.split(".")[-1] in runtime_names)
        rows.append(dict(priority=priority,kind=kind,display_name=display,raw_class=raw,
                         ipa_legacy="yes",ipa_supplied=("yes" if raw in present_classes else
                                                  "no" if args.ipa else "not_checked"),
                         previously_mentioned=r.get("mentioned_in_vitrine",""),
                         runtime_confirmed=("yes" if seen else "not_observed" if runtime else "not_checked"),
                         evidence="class_definition_not_proven_call_site"))
    for raw in sorted(present_classes-legacy_names):
        display=swift_display(raw)
        score=category(display)
        if not score:continue
        priority,kind=score
        seen = bool(runtime) and (display in runtime_names or raw in runtime_names or
                       display.split(".")[-1] in runtime_names)
        rows.append(dict(priority=priority,kind=kind,display_name=display,raw_class=raw,
                         ipa_legacy="no_or_no_inventory",ipa_supplied="yes",
                         previously_mentioned="unknown",
                         runtime_confirmed=("yes" if seen else "not_observed" if runtime else "not_checked"),
                         evidence="class_metadata_not_proven_call_site"))
    rows.sort(key=lambda r: (r["priority"],r["kind"],r["display_name"]))
    fields=["priority","kind","display_name","raw_class","ipa_legacy","ipa_supplied",
            "previously_mentioned","runtime_confirmed","evidence"]
    write_csv(destination/"menu_candidate_classes.csv",rows,fields)
    selectors=sorted(s for s in present_selectors if SELECTOR.search(s) and len(s)<200)
    write_csv(destination/"menu_selector_names.csv",
              [dict(selector=s,evidence="objc_method_name_not_proven_invocation") for s in selectors],
              ["selector","evidence"])
    if runtime:
        write_csv(destination/"runtime_menu_origins.csv",runtime,
                  list(dict.fromkeys(k for r in runtime for k in r)))
    counter=collections.Counter(r["kind"] for r in rows)
    summary=dict(
        supplied_ipa=str(args.ipa or ""),
        old_inventory=str(args.inventory or ""),
        runtime_archive=str(args.runtime or ""),
        static_candidate_classes=len(rows), categories=dict(counter),
        menu_related_method_names=len(selectors),
        observed_runtime_origins=len(runtime),
        confirmed_matched_candidates=sum(r["runtime_confirmed"]=="yes" for r in rows),
        limits=[
            "Class presence is not a proof that a menu is presented in a running UI.",
            "Objective-C method names are not exact call sites or source-to-controller edges.",
            "Swift-only call sites may not have Objective-C selector names.",
            "A route audit cannot reach all feature states or authenticated screens.",
            "Matching a class across two Spotify versions does not prove method or layout compatibility."])
    (destination/"summary.json").write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding="utf-8")
    (destination/"README.md").write_text(
        "# Dropdown IPA cross-reference\n\n"
        "`menu_candidate_classes.csv` is a prioritized inventory of **potential** Spotify menu sources, "
        "not a list of verified menu invocations. `menu_selector_names.csv` contains selector names from "
        "Mach-O metadata, not disassembled call sites.\n\n"
        "P0 = inspect first; P1 = inspect next; P2 = classify before touching UI. "
        "Only `runtime_confirmed=yes` is evidence of a runtime owner or delegate seen by SG_DRIVER. "
        "Avoid changing unrelated long-press context menus or bottom sheets into dropdowns without classification.\n",
        encoding="utf-8")
    print(json.dumps(summary,ensure_ascii=False,indent=2))

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa",help="decrypted IPA to scan (optional if old inventory supplied)")
    parser.add_argument("--inventory",help="earlier IPA ObjC class inventory CSV/ZIP")
    parser.add_argument("--runtime",help="SG_DRIVER stage170 menu provider inventory CSV/ZIP")
    parser.add_argument("--out",default="out/vitrine-dropdown-ipa-crossref")
    args=parser.parse_args()
    if not args.ipa and not args.inventory: parser.error("supply --ipa and/or --inventory")
    analyze(args)
