"""Uploads a car's parts.fbx to Roblox as a Model asset with the saved Open Cloud key, waits for it, prints its id.

Usage:  python tools/roblox_upload.py build/cars/<car id>
Writes asset.json next to parts.fbx. Needs %USERPROFILE%\\.voltage-county\\roblox_api_key (Assets: write).
"""
import json
import sys
import time
import uuid
import urllib.request
from pathlib import Path

CREATOR = "11270924960"  # Davis (Vollex300)
KEY = (Path.home() / ".voltage-county" / "roblox_api_key").read_text(encoding="utf-8").strip()
folder = Path(sys.argv[1]).resolve()
car = folder.name

request = {
    "assetType": "Model",
    "displayName": f"VC art {car}",
    "description": "Voltage County car art",
    "creationContext": {"creator": {"userId": CREATOR}},
}
boundary = uuid.uuid4().hex
body = b"".join(
    [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n".encode(),
        json.dumps(request).encode(),
        f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; filename=\"parts.fbx\"\r\n"
        f"Content-Type: model/fbx\r\n\r\n".encode(),
        (folder / "parts.fbx").read_bytes(),
        f"\r\n--{boundary}--\r\n".encode(),
    ]
)
post = urllib.request.Request(
    "https://apis.roblox.com/assets/v1/assets",
    data=body,
    method="POST",
    headers={"x-api-key": KEY, "Content-Type": f"multipart/form-data; boundary={boundary}"},
)
with urllib.request.urlopen(post, timeout=300) as reply:
    operation = json.loads(reply.read())["operationId"]
for _ in range(60):
    poll = urllib.request.Request(f"https://apis.roblox.com/assets/v1/operations/{operation}", headers={"x-api-key": KEY})
    with urllib.request.urlopen(poll, timeout=60) as reply:
        state = json.loads(reply.read())
    if state.get("done"):
        response = state.get("response", {})
        (folder / "asset.json").write_text(json.dumps(response, indent=1), encoding="utf-8")
        print(response.get("assetId"), response.get("moderationResult", {}).get("moderationState"))
        break
    time.sleep(5)
else:
    raise SystemExit("upload did not finish")
