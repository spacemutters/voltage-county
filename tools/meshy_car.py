"""Makes a realistic car model with Meshy (Davis, 2026-11-09: "as real as real ... like Greenville").

For one catalogue car: Meshy draws a studio photo of the original design (text to image), then turns it into a
detailed, textured 3D model with PBR maps (image to 3D), under Roblox's 20,000-triangle mesh limit. Everything lands in
build/meshy/<car id>/: the reference image, model.glb, model.fbx and the texture maps, plus task.json.

The car is drawn in plain white paint so the game can still repaint it (tools/blender_car.py splits paint from trim).
Original designs only (CLAUDE.md hard rule 4): the prompt says no logos, badges, text or plates, and every result is
checked by eye before it goes in the game.

Usage:
  python tools/meshy_car.py <car id> "<the look in a sentence>"     image, then 3D
  python tools/meshy_car.py <car id> --image-only "<the look>"       just the reference image (cheap, check it first)
  python tools/meshy_car.py <car id> --from-image                    3D from the image already in the folder
Needs %USERPROFILE%\\.voltage-county\\meshy_api_key (tools\\open_meshy_key_window.bat).
"""
import base64
import json
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "meshy"
API = "https://api.meshy.ai/openapi/v1"
KEY = (Path.home() / ".voltage-county" / "meshy_api_key").read_text(encoding="utf-8").strip()

STYLE = (
    "Professional automotive studio photograph, three-quarter front view from slightly above, the whole car in frame, "
    "photorealistic, real production car proportions and panel gaps, plain glossy white paint, dark tinted glass, "
    "black tyres, plain neutral light grey background, soft even studio lighting, sharp focus. An original design that "
    "is not any existing car model. No logos, no badges, no emblems, no text, no number plates."
)


def call(method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as reply:
        return json.loads(reply.read().decode("utf-8") or "{}")


def wait(kind: str, task_id: str, every: float = 8) -> dict:
    while True:
        task = call("GET", f"/{kind}/{task_id}")
        status = task.get("status")
        print(f"  {kind} {status} {task.get('progress', 0)}%", flush=True)
        if status == "SUCCEEDED":
            return task
        if status in ("FAILED", "CANCELED"):
            raise SystemExit(f"{kind} {status}: {task.get('task_error')}")
        time.sleep(every)


def download(url: str, path: Path):
    with urllib.request.urlopen(url, timeout=300) as reply:
        path.write_bytes(reply.read())


def image(car: str, look: str) -> Path:
    folder = OUT / car
    folder.mkdir(parents=True, exist_ok=True)
    task_id = call(
        "POST",
        "/text-to-image",
        {"ai_model": "gpt-image-2", "prompt": f"{look}. {STYLE}", "aspect_ratio": "4:3"},
    )["result"]
    task = wait("text-to-image", task_id, 4)
    path = folder / "reference.png"
    download(task["image_urls"][0], path)
    (folder / "image_task.json").write_text(json.dumps(task, indent=1), encoding="utf-8")
    print(f"image: {path} ({task.get('consumed_credits')} credits)")
    return path


def model(car: str) -> Path:
    folder = OUT / car
    picture = folder / "reference.png"
    data = "data:image/png;base64," + base64.b64encode(picture.read_bytes()).decode("ascii")
    task_id = call(
        "POST",
        "/image-to-3d",
        {
            "image_url": data,
            "ai_model": "latest",
            "should_texture": True,
            "enable_pbr": True,
            "texture_resolution": "2k",
            "should_remesh": True,
            "topology": "triangle",
            "target_polycount": 19000,
            "target_formats": ["glb", "fbx"],
            "origin_at": "bottom",
        },
    )["result"]
    task = wait("image-to-3d", task_id)
    (folder / "task.json").write_text(json.dumps(task, indent=1), encoding="utf-8")
    for fmt, url in task.get("model_urls", {}).items():
        if fmt in ("glb", "fbx"):
            download(url, folder / f"model.{fmt}")
    for maps in task.get("texture_urls", []) or []:
        for name, url in maps.items():
            if url:
                download(url, folder / f"{name}.png")
    print(f"model: {folder} ({task.get('consumed_credits')} credits)")
    return folder


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    car = args[0]
    if "--from-image" in args:
        model(car)
    elif "--image-only" in args:
        image(car, args[args.index("--image-only") + 1])
    else:
        image(car, args[1])
        model(car)
