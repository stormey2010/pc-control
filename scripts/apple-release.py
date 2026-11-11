"""Read release status or manage this app's beta group using saved Apple API access.

Credentials stay in the protected per-user release directory, never in source.
"""
import argparse
import json
import os
from pathlib import Path
import time

import jwt
import requests

APP = "6833300906"
BASE = "https://api.appstoreconnect.apple.com"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["status", "prepare-beta", "distribute"])
    parser.add_argument("--build")
    args = parser.parse_args()
    p = json.loads((Path(os.environ["LOCALAPPDATA"]) / "PCControlRelease" / "apple-signing.json").read_text())
    now = int(time.time())
    token = jwt.encode({"iss": p["issuerId"], "iat": now - 10, "exp": now + 600, "aud": "appstoreconnect-v1"}, p["privateKey"], algorithm="ES256", headers={"kid": p["keyId"], "typ": "JWT"})
    session = requests.Session()
    session.headers["Authorization"] = "Bearer " + token

    def api(method, path, **kwargs):
        r = session.request(method, BASE + path, timeout=30, **kwargs)
        if not r.ok:
            try:
                errors = [(e.get("code"), e.get("detail")) for e in r.json().get("errors", [])]
            except ValueError:
                errors = [("HTTP", str(r.status_code))]
            raise SystemExit(f"Apple API {r.status_code}: {errors}")
        return r.json() if r.content else {}

    if args.action == "status":
        data = api("GET", "/v1/builds", params={"filter[app]": APP, "sort": "-uploadedDate", "limit": 10, "include": "preReleaseVersion,buildBetaDetail"})
        included = {i["id"]: i for i in data.get("included", [])}
        records = []
        for build in data.get("data", []):
            attr = build["attributes"]
            pre = build.get("relationships", {}).get("preReleaseVersion", {}).get("data")
            beta = build.get("relationships", {}).get("buildBetaDetail", {}).get("data")
            records.append({"id": build["id"], "build": attr.get("version"), "version": included.get((pre or {}).get("id"), {}).get("attributes", {}).get("version"), "processing": attr.get("processingState"), "uploadedAt": attr.get("uploadedDate"), "expired": attr.get("expired"), "beta": included.get((beta or {}).get("id"), {}).get("attributes", {})})
        print(json.dumps(records, indent=2))
        return

    groups = api("GET", "/v1/betaGroups", params={"filter[app]": APP, "limit": 100})["data"]
    group = next((g for g in groups if g["attributes"].get("isInternalGroup")), None)
    if group is None:
        group = api("POST", "/v1/betaGroups", json={"data": {"type": "betaGroups", "attributes": {"name": "Internal Testing", "isInternalGroup": True}, "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
    print("Internal group ready:", group["attributes"]["name"], group["id"])

    localizations = api("GET", f"/v1/apps/{APP}/betaAppLocalizations")["data"]
    attributes = {"description": "A native local remote for your Windows PC. Use the trackpad to move, click, drag, and scroll; type with the iPhone keyboard; control volume, media, and display brightness. Pair using the private setup QR from the PC Control agent. The PC must be signed in and on the same local network.", "privacyPolicyUrl": "https://github.com/stormey2010/pc-control/blob/main/ios/PRIVACY.md"}
    english = next((x for x in localizations if x["attributes"].get("locale") == "en-US"), None)
    if english:
        api("PATCH", "/v1/betaAppLocalizations/" + english["id"], json={"data": {"type": "betaAppLocalizations", "id": english["id"], "attributes": attributes}})
    else:
        api("POST", "/v1/betaAppLocalizations", json={"data": {"type": "betaAppLocalizations", "attributes": {"locale": "en-US", **attributes}, "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    print("Beta app description and privacy URL saved.")

    if args.action == "distribute":
        if not args.build:
            raise SystemExit("--build is required")
        build = api("GET", "/v1/builds/" + args.build)["data"]
        if build["attributes"].get("processingState") != "VALID":
            raise SystemExit("Build is not yet processed and valid")
        api("POST", f"/v1/betaGroups/{group['id']}/relationships/builds", json={"data": [{"type": "builds", "id": args.build}]})
        print("Processed build added to internal TestFlight group.")
        notes = api("GET", f"/v1/builds/{args.build}/betaBuildLocalizations")["data"]
        english = next((x for x in notes if x["attributes"].get("locale") == "en-US"), None)
        text = "First native release: responsive trackpad, tap/double-tap, two-finger scrolling and right-click, hold to drag, Unicode keyboard, shortcuts, media and volume controls, per-display brightness, secure QR/file pairing, and cancellable shutdown. This build was compiled and signed without automated tests as requested."
        if english:
            api("PATCH", "/v1/betaBuildLocalizations/" + english["id"], json={"data": {"type": "betaBuildLocalizations", "id": english["id"], "attributes": {"whatsNew": text}}})
        else:
            api("POST", "/v1/betaBuildLocalizations", json={"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": text}, "relationships": {"build": {"data": {"type": "builds", "id": args.build}}}}})
        print("Build notes saved.")


if __name__ == "__main__":
    main()
