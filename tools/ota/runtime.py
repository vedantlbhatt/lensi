#!/usr/bin/env python3
"""Prints the native runtime this checkout's JavaScript needs: a short hash of everything that
goes into the app's native build (the Swift module, the config and its plugins, native
packages, the recipe for the Core ML models). An over-the-air update only runs on an app built
from the same native code, so the app carries this in its Info.plist (plugins/withOTA.js) and
updates are published per runtime (tools/ota/publish.py).

Hashes the files git knows under those paths (tracked, or new and not ignored), as they are
on disk, so it's the same on a Mac and on Linux, and needs no build. Prints "none" outside a
git checkout.
"""
import hashlib
import os
import subprocess
import sys

NATIVE = [
    "app/app.json",
    "app/plugins",
    "app/package.json",
    "app/package-lock.json",
    "app/modules/lensi-ar/ios",
    "app/modules/lensi-ar/expo-module.config.json",
    "app/modules/lensi-ar/package.json",
    "tools/sam",
]


def runtime(root):
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", *NATIVE],
            capture_output=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return "none"
    files = sorted({f for f in out.decode().split("\0") if f})
    if not files:
        return "none"
    h = hashlib.sha256()
    for f in files:
        p = os.path.join(root, f)
        if not os.path.isfile(p):
            continue
        h.update(f.encode() + b"\0")
        with open(p, "rb") as fh:
            h.update(hashlib.sha256(fh.read()).digest())
    return h.hexdigest()[:12]


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(here))
    print(runtime(root))
