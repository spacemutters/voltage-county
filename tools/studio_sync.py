"""Fallback code sync for when the Rojo plugin can't be connected (for example overnight, with nobody to click
Connect). It serves the repo's code once, exactly as Rojo maps it, and tools/StudioSync.luau (run through the
Studio connector with execute_luau) pulls it into the open place.

Only the four code roots Rojo manages are touched: ReplicatedStorage.Shared, ServerScriptService.Server,
StarterPlayer.StarterPlayerScripts.Client and ServerStorage.Tests. Packages and everything Studio owns
(Workspace, ServerStorage.VehicleModels) are left alone. When Rojo reconnects it reconciles as usual.

Usage:  python tools/studio_sync.py [--port 34991] [--timeout 120]
Serves GET /manifest once (JSON), then exits. Needs "Allow HTTP Requests" on in the place.
"""
import argparse
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANAGED = [
    ["ReplicatedStorage", "Shared"],
    ["ServerScriptService", "Server"],
    ["StarterPlayer", "StarterPlayerScripts", "Client"],
    ["ServerStorage", "Tests"],
]
SCRIPT_CLASSES = {"ModuleScript", "Script", "LocalScript"}


def sourcemap() -> dict:
    env = dict(os.environ)
    env["PATH"] = str(Path.home() / ".rokit" / "bin") + os.pathsep + env.get("PATH", "")
    out = subprocess.run(
        ["rojo", "sourcemap", "default.project.json", "--include-non-scripts"],
        cwd=ROOT, env=env, capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def luau_literal(value, indent: int = 0) -> str:
    """JSON value -> Luau table literal (how Rojo turns a .json file into a ModuleScript)."""
    pad = "\t" * (indent + 1)
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, list):
        if not value:
            return "{}"
        items = ",\n".join(pad + luau_literal(v, indent + 1) for v in value)
        return "{\n" + items + ",\n" + "\t" * indent + "}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = ",\n".join(f"{pad}[{json.dumps(k)}] = {luau_literal(v, indent + 1)}" for k, v in value.items())
        return "{\n" + items + ",\n" + "\t" * indent + "}"
    raise TypeError(type(value))


def source_for(node: dict) -> str | None:
    paths = [p for p in node.get("filePaths", []) if not p.endswith(".meta.json")]
    for p in paths:
        full = ROOT / p
        if full.suffix in (".luau", ".lua"):
            return full.read_text(encoding="utf-8")
        if full.suffix == ".json" and not full.name.endswith(".project.json"):
            return "return " + luau_literal(json.loads(full.read_text(encoding="utf-8")))
    return None


def build_manifest() -> dict:
    tree = sourcemap()
    items = []

    def walk(node: dict, path: list[str], managed: bool):
        here_managed = managed or any(path == root for root in MANAGED)
        if here_managed:
            entry = {"path": path, "className": node["className"]}
            if node["className"] in SCRIPT_CLASSES:
                src = source_for(node)
                if src is None:
                    raise RuntimeError(f"no source for {'.'.join(path)}")
                entry["source"] = src
            items.append(entry)
        for child in node.get("children", []):
            walk(child, path + [child["name"]], here_managed)

    for child in tree.get("children", []):
        walk(child, [child["name"]], False)
    return {"roots": MANAGED, "items": items}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=34991)
    ap.add_argument("--timeout", type=int, default=120)
    args = ap.parse_args()
    body = json.dumps(build_manifest()).encode("utf-8")
    served = {"done": False}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/manifest":
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            served["done"] = True

        def log_message(self, *a):
            pass

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    server.timeout = 1
    print(f"serving {len(body)} bytes on {args.port}", flush=True)
    waited = 0
    while not served["done"] and waited < args.timeout:
        server.handle_request()
        waited += 1
    print("served" if served["done"] else "timed out", flush=True)
    sys.exit(0 if served["done"] else 1)


if __name__ == "__main__":
    main()
