#!/usr/bin/env python3
"""Install Godot export templates without downloading the whole .tpz.

The official template archive is ~1.3 GB for all platforms, but a preset only
needs one or two files out of it. This reads the zip's central directory over
HTTP range requests and fetches just the requested members.

    python3 tools/fetch_export_templates.py 4.7.2-stable linux_release.x86_64 [linux_debug.x86_64 ...]

Writes to ~/.local/share/godot/export_templates/<version>/, where the editor
looks for them.
"""

import io
import os
import struct
import sys
import urllib.request
import zipfile

RELEASE_URL = ("https://github.com/godotengine/godot/releases/download/"
               "{ver}/Godot_v{ver}_export_templates.tpz")


def fetch(url, start=None, end=None):
    req = urllib.request.Request(url)
    if start is not None:
        req.add_header("Range", f"bytes={start}-{end if end is not None else ''}")
    with urllib.request.urlopen(req) as resp:
        return resp.read()


def remote_size(url):
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req) as resp:
        return int(resp.headers["Content-Length"])


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    version, members = sys.argv[1], sys.argv[2:]
    url = RELEASE_URL.format(ver=version)
    # The archive name uses "4.7.2-stable"; the editor's data directory uses
    # the engine's version string "4.7.2.stable".
    dir_version = version.replace("-", ".")
    dest_dir = os.path.expanduser(f"~/.local/share/godot/export_templates/{dir_version}")
    os.makedirs(dest_dir, exist_ok=True)

    size = remote_size(url)
    print(f"archive: {size} bytes; fetching only {', '.join(members)}")

    # Tail of the file: end-of-central-directory + (usually) the whole
    # central directory, which is small.
    tail_start = max(0, size - 200_000)
    tail = fetch(url, tail_start, size - 1)
    eocd = tail.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise SystemExit("no end-of-central-directory record found")
    cd_size, cd_offset = struct.unpack_from("<II", tail, eocd + 12)
    if cd_offset >= tail_start:
        cd = tail[cd_offset - tail_start:][:cd_size]
    else:
        cd = fetch(url, cd_offset, cd_offset + cd_size - 1)

    wanted = {}
    off = 0
    while off < len(cd) - 4 and cd[off:off + 4] == b"PK\x01\x02":
        method, = struct.unpack_from("<H", cd, off + 10)
        comp_size, uncomp_size = struct.unpack_from("<II", cd, off + 20)
        name_len, extra_len, comment_len = struct.unpack_from("<HHH", cd, off + 28)
        local_offset, = struct.unpack_from("<I", cd, off + 42)
        name = cd[off + 46:off + 46 + name_len].decode()
        wanted[name] = (method, comp_size, uncomp_size, local_offset)
        off += 46 + name_len + extra_len + comment_len

    for member in members:
        key = f"templates/{member}"
        if key not in wanted:
            print(f"!! {key} not in the archive")
            continue
        method, comp_size, uncomp_size, local_offset = wanted[key]
        head = fetch(url, start=local_offset, end=local_offset + 29)
        name_len, extra_len = struct.unpack_from("<HH", head, 26)
        data_offset = local_offset + 30 + name_len + extra_len
        blob = fetch(url, start=data_offset, end=data_offset + comp_size - 1)
        if method == zipfile.ZIP_DEFLATED:
            import zlib
            blob = zlib.decompress(blob, -15)
        elif method != zipfile.ZIP_STORED:
            raise SystemExit(f"{key}: unsupported compression method {method}")
        out = os.path.join(dest_dir, member)
        with open(out, "wb") as f:
            f.write(blob)
        os.chmod(out, 0o755)
        print(f"installed {out} ({len(blob)} bytes, expected {uncomp_size})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
