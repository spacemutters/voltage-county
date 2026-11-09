"""Overnight runner for the realistic cars (tools/hf_car.py), waiting out Hugging Face's free GPU allowance.

For each car still missing a step, in order: reference photo, 3D model, Blender split (blender_car.py), paint mask
(paint_mask.py), Roblox upload (roblox_upload.py). When the free allowance runs out it waits and tries again. A car
whose photo is waiting for an eye check (build/cars/<id>/HOLD) is skipped until the file is removed.
Progress goes to build/cars/runner.log; a car is done when build/cars/<id>/asset.json exists.

Usage:  python tools/make_cars.py [car ids...]     (default: every car in hf_car.LOOKS)
"""
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CARS = ROOT / "build" / "cars"
LOG = CARS / "runner.log"
BLENDER = Path.home() / "tools" / "blender" / "blender.exe"
sys.path.insert(0, str(ROOT / "tools"))
import hf_car  # noqa: E402

WAIT_SECONDS = 600


def log(text: str):
    line = f"{time.strftime('%H:%M:%S')} {text}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def run(args: list[str]) -> bool:
    done = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if done.returncode != 0:
        log(f"  failed: {' '.join(map(str, args[:3]))}: {(done.stderr or done.stdout)[-400:]}")
    return done.returncode == 0


def quota(error: Exception) -> bool:
    text = str(error)
    return "quota" in text.lower() or "ZeroGPU" in text


def step(car: str) -> str:
    """Does the next missing step for `car`; returns 'done', 'hold', 'waiting' or 'progress'."""
    folder = CARS / car
    folder.mkdir(parents=True, exist_ok=True)
    if (folder / "asset.json").exists():
        return "done"
    if (folder / "HOLD").exists():
        return "hold"
    try:
        if not (folder / "reference.png").exists():
            hf_car.image(car, 7)
            # Held until the photo is checked by eye for any likeness to a real car (CLAUDE.md hard rule 4).
            (folder / "HOLD").write_text("check the reference photo, then delete this file", encoding="utf-8")
            log(f"{car}: photo ready, held for the eye check")
            return "hold"
        if not (folder / "model.glb").exists():
            hf_car.model(car)
            log(f"{car}: 3D model ready")
            return "progress"
    except Exception as error:  # noqa: BLE001 - the demo apps raise their own error types
        if quota(error):
            return "waiting"
        log(f"{car}: {type(error).__name__}: {str(error)[:300]}")
        return "waiting"
    if not (folder / "parts.fbx").exists() or (folder / "parts.fbx").stat().st_mtime < (folder / "model.glb").stat().st_mtime:
        ok = run([str(BLENDER), "-b", "--factory-startup", "--python", "tools/blender_car.py", "--", str(folder)])
        log(f"{car}: split {'ok' if ok else 'FAILED'}")
        if not ok:
            (folder / "HOLD").write_text("blender_car.py failed: see runner.log", encoding="utf-8")
            return "hold"
    ok = run([sys.executable, "tools/paint_mask.py", str(folder)]) and run(
        [sys.executable, "tools/roblox_upload.py", str(folder)]
    )
    log(f"{car}: mask and upload {'ok' if ok else 'FAILED'}")
    return "done" if ok else "hold"


def main():
    cars = sys.argv[1:] or list(hf_car.LOOKS)
    while True:
        states = {}
        waiting = False
        for car in cars:
            state = step(car)
            while state == "progress":
                state = step(car)
            states[car] = state
            if state == "waiting":
                waiting = True
                break
        left = [c for c in cars if states.get(c) not in ("done", "hold")]
        if not left and not waiting:
            log("all cars done or held: " + ", ".join(f"{c}={states.get(c)}" for c in cars))
            return
        log(f"free GPU allowance used up; waiting {WAIT_SECONDS // 60} min ({len(left)} cars left)")
        time.sleep(WAIT_SECONDS)


if __name__ == "__main__":
    main()
