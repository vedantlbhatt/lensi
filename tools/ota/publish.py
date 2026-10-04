#!/usr/bin/env python3
"""Publishes a commit's JavaScript as an over-the-air update (src/lib/ota.ts).

  publish.py <export> <site> <id> [message]

<export> is what `expo export:embed --platform ios` made: main.jsbundle, with the assets it
uses beside it (assets/...). <site> is a copy of the `ota` branch, changed in place:

  ios/<runtime>/update.json        what the app reads first (src/lib/ota.ts `Update`)
  ios/<runtime>/<id>/main.jsbundle and assets/...

Only the newest update of each runtime is kept, and only the newest few runtimes (an app
built from older native code keeps whatever update it already has).
"""
import datetime
import hashlib
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runtime import runtime  # noqa: E402

RAW = "https://raw.githubusercontent.com/vedantlbhatt/lensi/ota"
KEEP_RUNTIMES = 4


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    export, site, uid = sys.argv[1], sys.argv[2], sys.argv[3]
    message = sys.argv[4] if len(sys.argv) > 4 else ""
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    rt = runtime(repo)
    if rt == "none":
        raise SystemExit("no runtime: run from a git checkout")
    bundle = os.path.join(export, "main.jsbundle")
    if not os.path.isfile(bundle):
        raise SystemExit(f"no {bundle}")

    here = os.path.join(site, "ios", rt)
    shutil.rmtree(here, ignore_errors=True)
    dest = os.path.join(here, uid)
    shutil.copytree(export, dest)
    parts = []
    for top, _, files in os.walk(dest):
        for name in sorted(files):
            full = os.path.join(top, name)
            rel = os.path.relpath(full, dest).replace(os.sep, "/")
            parts.append({"path": rel, "md5": md5(full), "bytes": os.path.getsize(full)})
    parts.sort(key=lambda p: p["path"])
    update = {
        "id": uid,
        "runtime": rt,
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "message": message,
        "base": f"{RAW}/ios/{rt}/{uid}/",
        "bundle": next(p for p in parts if p["path"] == "main.jsbundle"),
        "assets": [p for p in parts if p["path"] != "main.jsbundle"],
    }
    with open(os.path.join(here, "update.json"), "w") as f:
        json.dump(update, f, indent=1)

    # The newest few runtimes stay; older native builds keep what they have.
    ios = os.path.join(site, "ios")
    dated = []
    for name in os.listdir(ios):
        u = os.path.join(ios, name, "update.json")
        if os.path.isfile(u):
            with open(u) as f:
                dated.append((json.load(f).get("createdAt", ""), name))
    for _, name in sorted(dated, reverse=True)[KEEP_RUNTIMES:]:
        shutil.rmtree(os.path.join(ios, name), ignore_errors=True)

    size = sum(p["bytes"] for p in parts)
    print(f"runtime {rt}: update {uid[:7]} ({len(parts)} files, {size / 1e6:.1f} MB)")
    print(f"{RAW}/ios/{rt}/update.json")


if __name__ == "__main__":
    main()
