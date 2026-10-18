#!/usr/bin/env python3
"""Audit a Godot 4.x .pck against what this project needs at runtime.

Almost every asset is loaded through a runtime-computed path (`ItemCatalog` /
`FurnitureCatalog` / the audio bank build `dir + file` strings), so a pack can
look fine while silently missing pieces. The worst offender is the kitchen
layout: `resources/layouts/*.txt` is loaded with `FileAccess`, and plain text
files are *not* resources, so they are dropped by `export_filter="all_resources"`
unless the preset's include filter names them. A pack without them boots into an
empty world (menu and UI fine, no kitchen at all).

Usage:
    python3 tools/pck_audit.py <file.pck> [project_dir]

Exit status 1 when anything expected is missing, so it can gate a build.
"""

import os
import re
import struct
import sys

# --- pack index -------------------------------------------------------------
# Godot 4 keeps the file index at the end of the pack. Entries are:
#   u32 path_len (4-byte aligned, padding counted), path bytes (+padding),
#   u64 offset, u64 size, u8 md5[16], u32 flags.


def _entry(data, p):
    n = len(data)
    if p + 4 > n:
        return None
    length = struct.unpack_from("<I", data, p)[0]
    if not (3 <= length <= 4096) or length % 4 != 0:
        return None
    raw = data[p + 4 : p + 4 + length]
    if raw.count(0) > 3:
        return None
    path = raw.rstrip(b"\x00")
    if not path or any(c < 32 or c > 126 for c in path):
        return None
    q = p + 4 + length
    if q + 36 > n:
        return None
    ofs, size = struct.unpack_from("<QQ", data, q)
    if ofs > n or size > n:
        return None
    if struct.unpack_from("<I", data, q + 32)[0] > 0xFFFF:
        return None
    return path.decode(), ofs, size, q + 36


def read_pck(path):
    """Return (set_of_paths, meta) for a standalone .pck."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"GDPC":
        raise SystemExit(f"{path}: not a Godot pack (magic {data[:4]!r})")
    fmt, vmaj, vmin, vpatch, flags = struct.unpack_from("<IIIII", data, 4)
    # The index sits at the end; find its first entry by scanning the tail.
    n = len(data)
    start = None
    for p in range(max(0, n - 4_000_000), n - 4):
        if _entry(data, p):
            cur, count = p, 0
            while cur < n:
                e = _entry(data, cur)
                if e is None:
                    break
                count += 1
                cur = e[3]
            if cur == n and count > 100:
                start = p
                break
    if start is None:
        raise SystemExit(f"{path}: could not locate the pack index")
    files = set()
    cur = start
    while cur < n:
        e = _entry(data, cur)
        files.add("res://" + e[0])
        cur = e[3]
    return files, (fmt, vmaj, vmin, vpatch, len(files))


# --- expected resources -----------------------------------------------------


def import_destinations(project_dir):
    """source_file -> [imported destination paths] for every .import file."""
    expected = {}
    for root, dirs, names in os.walk(project_dir):
        dirs[:] = [d for d in dirs if d not in (".godot", ".git", "builds")]
        if "/.godot" in root or "/.git" in root:
            continue
        for name in names:
            if not name.endswith(".import"):
                continue
            ipath = os.path.join(root, name)
            with open(ipath, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
            src = re.search(r'source_file="([^"]+)"', text)
            dests = re.findall(r'"(res://\.godot/imported/[^"]+)"', text)
            key = src.group(1) if src else os.path.relpath(ipath, project_dir)
            expected[key] = dests
    return expected


# Plain (non-resource) files the game reads by path. The layouts are the
# critical ones: without them the world is empty.
MUST_SHIP = [
    "res://scenes/main.tscn",
    "res://resources/layouts/start_kitchen.txt",
    "res://resources/layouts/menu_kitchen.txt",
    "res://resources/layouts/demo_kitchen.txt",
    "res://resources/props/cutting_table.tscn",
    "res://resources/props/plating_station.tscn",
    "res://resources/props/mascot_red.tscn",
    "res://resources/props/mascot_yellow.tscn",
    "res://resources/props/corporate_shrine.tscn",
    "res://resources/props/shelf_stocked.tscn",
    "res://resources/props/fridge_stocked.tscn",
    "res://resources/props/table_dressed.tscn",
    "res://scripts/main.gd",
    "res://scripts/ui/game_ui.gd",
    "res://assets/music/Airport%20Lounge - build.mp3",
    "res://assets/music/District%20Four - work.mp3",
    "res://assets/music/Classic%20Horror%201 - lose.mp3",
]


def present(files, path):
    """A logical resource is in the pack directly, via a .remap entry (text
    scenes/scripts/audio stored converted), or via its .import metadata
    (models/textures resolved to .godot/imported/... at runtime)."""
    return (path in files or (path + ".remap") in files or (path + ".import") in files)


def main():
    pck = sys.argv[1]
    project_dir = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    files, meta = read_pck(pck)
    print(f"pack: {pck}")
    print(f"godot {meta[1]}.{meta[2]}.{meta[3]} pack format v{meta[0]}, {meta[4]} entries")

    by_ext = {}
    for p in files:
        ext = os.path.splitext(p)[1] or "<none>"
        by_ext[ext] = by_ext.get(ext, 0) + 1
    print("  " + ", ".join(f"{n} {e}" for e, n in
                           sorted(by_ext.items(), key=lambda kv: -kv[1])[:14]))

    expected = import_destinations(project_dir)
    missing_import = []
    dest_total = 0
    for src, dests in sorted(expected.items()):
        dest_total += len(dests)
        if dests and not any(present(files, d) for d in dests):
            missing_import.append(src)
    print(f"\nimported sources: {len(expected)} "
          f"(destinations listed: {dest_total}); sources with NO destination in the pack: "
          f"{len(missing_import)}")
    for src in missing_import[:20]:
        print(f"  MISSING: {src}")

    missing_fixed = [p for p in MUST_SHIP if not present(files, p)]
    print(f"\nmust-ship plain resources: {len(MUST_SHIP) - len(missing_fixed)}/{len(MUST_SHIP)} present")
    for p in missing_fixed:
        print(f"  MISSING: {p}")

    missing = missing_import or missing_fixed
    print(f"\nRESULT: {'FAIL' if missing else 'ok'}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
