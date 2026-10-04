"""App Store Connect chores for the TestFlight workflow, through the API key in
ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 (an Admin team key).

  asc.py prepare          bundle ID registered, app record found, an internal
                          tester group (every App Store Connect user, every build)
  asc.py wait <build>     waits for that build to finish processing

Apple's API can't create the app record itself; `prepare` stops with what to
do when it's missing.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # pyjwt[crypto]

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.vedantbhatt.lensi")
GROUP = "Lensi team"


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
        os.environ["ASC_KEY_P8"].strip().replace("\\n", "\n"),
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method, path, body=None, params=None):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            raw = res.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:800]
        raise SystemExit(f"App Store Connect said {e.code} to {method} {path}: {detail}")


def fail(msg):
    print(f"::error::{msg}")
    raise SystemExit(1)


def prepare():
    found = call("GET", "/bundleIds", params={"filter[identifier]": BUNDLE_ID, "limit": 5})["data"]
    if not [b for b in found if b["attributes"]["identifier"] == BUNDLE_ID]:
        call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {"identifier": BUNDLE_ID, "name": "Lensi", "platform": "IOS"}}})
        print(f"registered bundle ID {BUNDLE_ID}")
    else:
        print(f"bundle ID {BUNDLE_ID} is registered")

    apps = call("GET", "/apps", params={"filter[bundleId]": BUNDLE_ID, "limit": 5})["data"]
    if not apps:
        fail(
            f"No app in App Store Connect for {BUNDLE_ID} yet, and Apple's API can't create one. "
            f"In App Store Connect: Apps > + > New App > iOS, any name (e.g. Lensi), bundle ID {BUNDLE_ID}, "
            "SKU lensi, then run this workflow again."
        )
    app = apps[0]
    print(f"app record: {app['attributes']['name']} ({app['id']})")

    groups = call("GET", f"/apps/{app['id']}/betaGroups", params={"limit": 50})["data"]
    group = next((g for g in groups if g["attributes"].get("isInternalGroup") and g["attributes"]["name"] == GROUP), None)
    if not group:
        group = call(
            "POST",
            "/betaGroups",
            {
                "data": {
                    "type": "betaGroups",
                    "attributes": {"name": GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
                    "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}},
                }
            },
        )["data"]
        print(f"made internal group {GROUP}")
    # Every App Store Connect user on the team tests (internal testers must be users).
    have = {t["attributes"].get("email", "").lower() for t in call("GET", f"/betaGroups/{group['id']}/betaTesters", params={"limit": 200})["data"]}
    for u in call("GET", "/users", params={"limit": 200})["data"]:
        a = u["attributes"]
        email = (a.get("username") or a.get("email") or "").lower()
        if not email or email in have:
            continue
        call(
            "POST",
            "/betaTesters",
            {
                "data": {
                    "type": "betaTesters",
                    "attributes": {"email": email, "firstName": a.get("firstName") or "", "lastName": a.get("lastName") or ""},
                    "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}},
                }
            },
        )
        print(f"added tester {email}")
    print("testers ready")


def wait(build):
    app = call("GET", "/apps", params={"filter[bundleId]": BUNDLE_ID, "limit": 1})["data"][0]
    deadline = time.time() + 40 * 60
    while time.time() < deadline:
        builds = call("GET", "/builds", params={"filter[app]": app["id"], "filter[version]": build, "limit": 1})["data"]
        state = builds[0]["attributes"]["processingState"] if builds else "NOT YET VISIBLE"
        print(time.strftime("%H:%M:%S"), f"build {build}: {state}", flush=True)
        if state == "VALID":
            print(f"build {build} is in TestFlight: open the TestFlight app on the iPhone and install Lensi")
            return
        if state in ("FAILED", "INVALID"):
            fail(f"App Store Connect could not process build {build} ({state}); Apple emails the reason to the account holder.")
        time.sleep(30)
    print(f"build {build} is still processing; it shows up in TestFlight when Apple finishes")


if __name__ == "__main__":
    {"prepare": lambda: prepare(), "wait": lambda: wait(sys.argv[2])}[sys.argv[1]]()
