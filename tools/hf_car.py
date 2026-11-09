"""Makes a realistic car model for free, with no account: Hugging Face's public demo apps (Davis, 2026-11-09: "as real
as real ... like Greenville"; the Meshy route needed a paid key).

Steps, for one catalogue car (everything lands in build/cars/<car id>/):
  1. reference.png  FLUX.1 schnell draws a studio photo of the original design, in plain white paint
  2. model.glb      Hunyuan3D 2.1 turns the photo into a textured 3D model
Then, run by hand or by tools/make_cars.ps1: blender_car.py (split), paint_mask.py (tint mask), roblox_upload.py.
Original designs only (CLAUDE.md hard rule 4): every reference photo is checked by eye before it becomes a model.

Usage:  python tools/hf_car.py <car id> [--image-only | --model-only] [--seed N]
"""
import shutil
import sys
from pathlib import Path

from gradio_client import Client, handle_file
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

STYLE = (
    "Professional automotive studio photograph, three-quarter front view from slightly above, the whole car in frame "
    "with space around it, photorealistic, real production car proportions and panel gaps, plain glossy white paint, "
    "dark tinted glass, black tyres, plain light grey seamless studio background, soft even lighting, sharp focus. "
    "An original design that is not any existing car model. No logos, no badges, no emblems, no text, no number plate."
)

LOOKS = {
    "ohm_vela": "an original two-seat open-top electric sports roadster, low and wide, smooth sculpted body with no rear "
    "wing, one slim straight full-width LED light strip across the nose, raked windscreen, two roll hoops behind the "
    "seats, broad rear haunches, large dark multi-spoke wheels",
    "kaze_zenji": "an original modern three-door hot hatchback, short boxy hatch body, pumped square wheel arches, a "
    "roof spoiler over the rear window, honeycomb lower grille, slim headlights, black lower bumper, sporty alloy wheels",
    "kaze_akeru": "an original modern front-engine two-door sports coupe, long hood, cabin set back, a fastback roof "
    "flowing into a glass hatch, slim angular LED headlights, a small ducktail, smooth sides with one crisp crease",
    "kaze_rokku": "an original 1970s two-door rally coupe, boxy square body with a flat roof, four square headlights in "
    "a black grille, thin chrome bumpers, slotted steel wheels, mud flaps, restored classic",
    "montevale_ostria": "an original modern mid-engine supercar, very low body, a smooth tinted canopy cabin, rounded "
    "front fenders, one thin horizontal light bar in a narrow nose, a louvred rear engine cover, organic curved surfaces",
    "montevale_varzo": "an original endurance-racing style road hypercar, a bubble cockpit, a very long smooth tapering "
    "tail with a tall stabiliser fin along the spine, covered rear wheels, a long rounded nose, giant rear diffuser",
    "brannock_mallet": "an original modern two-door performance coupe, long hood with two sharp raised air vents, a "
    "thin full-width LED light bar across a slim black grille instead of round headlights, angular faceted body panels, "
    "boxed fender flares, a short fastback roof, wide rear haunches, a full-width rear light bar",
    "brannock_warden": "an original large modern four-door sports sedan, long wheelbase, upright formal roofline, long "
    "flat hood, a wide dark mesh grille between slim rectangular headlights, square shoulders, quad exhaust",
    "aldermoor_esterly": "an original modern luxury estate wagon, long low body, a long roof sloping to the rear pillar, "
    "roof rails, a slim chrome window line, slim headlights, a wide low grille",
    "aldermoor_ormond": "an original modern luxury flagship sedan, long low body, a smooth sloping fastback roof, a tall "
    "narrow grille of fine vertical slats, very thin horizontal headlights, a straight shoulder line, big wheels",
    "aldermoor_solenne": "an original modern four-seat convertible grand tourer with the soft top folded down, long hood, "
    "a low windscreen in a chrome frame, tan leather seats, slim headlights, a long smooth rear deck",
    "aldermoor_graystone": "an original modern full-size luxury SUV, tall flat body sides, a floating roof with "
    "blacked-out pillars, upright tailgate, a wide grille of one thick horizontal metal band, thin headlights, running "
    "boards, big wheels",
    "ohm_pip": "an original tiny two-door electric city car, a short rounded cube body, wheels at the corners, a thin "
    "full-width light bar for a face, tall glass, flat roof, small aero wheels",
    "ohm_lumen": "an original modern three-row electric family SUV, long smooth body, a closed smooth front with no "
    "grille, a thin full-width light bar front and rear, flush door handles, flush glass, big aero wheels",
    "ohm_fieldline": "an original modern electric pickup truck, smooth rounded slab sides with soft edges, a closed "
    "front with a thin full-width light bar, crew cab, a hard tonneau cover over the bed, large aero wheels",
    "halden_ambit": "an original modern five-door compact crossover, a sleek low body with a sloping coupe-like roof, "
    "slim headlights joined by a light strip, grey plastic wheel-arch cladding, roof rails",
    "halden_ferro": "an original modern small single-cab work pickup truck, short open cargo bed, black plastic bumpers "
    "and wheel arches, plain steel wheels, simple rectangular headlights",
    "ironwood_talus": "an original modern two-door off-road truck, short wheelbase, angular faceted body panels, a flat "
    "hood, narrow LED headlights in a heavy tubular steel bumper, an open roll cage, a spare wheel on the back, huge "
    "knobbly tyres, high ground clearance",
    "ironwood_bulwark": "an original modern heavy-duty pickup truck, very tall square front with a grille of thick "
    "vertical bars, square headlights at the grille corners, towing mirrors, crew cab, long open bed, dual rear wheels",
    "northline_haulmate": "an original modern tall high-roof cargo van, short sloping nose, big windscreen, a sliding "
    "side door, a ladder rack on the roof, black plastic bumpers, steel wheels",
}


def image(car: str, seed: int) -> Path:
    folder = ROOT / "build" / "cars" / car
    folder.mkdir(parents=True, exist_ok=True)
    client = Client("black-forest-labs/FLUX.1-schnell", verbose=False)
    result, _ = client.predict(
        prompt=f"Studio photograph of {LOOKS[car]}. {STYLE}",
        seed=seed,
        randomize_seed=False,
        width=1024,
        height=768,
        num_inference_steps=4,
        api_name="/infer",
    )
    path = result if isinstance(result, str) else result.get("path")
    out = folder / "reference.png"
    Image.open(path).convert("RGB").save(out)
    print("image", out)
    return out


def model(car: str) -> Path:
    folder = ROOT / "build" / "cars" / car
    client = Client("tencent/Hunyuan3D-2.1", verbose=False)
    result = client.predict(
        image=handle_file(str(folder / "reference.png")),
        mv_image_front=None,
        mv_image_back=None,
        mv_image_left=None,
        mv_image_right=None,
        steps=30,
        guidance_scale=5.0,
        seed=1234,
        octree_resolution=256,
        check_box_rembg=True,
        num_chunks=8000,
        randomize_seed=False,
        api_name="/generation_all",
    )
    textured = result[1]["value"] if isinstance(result[1], dict) else result[1]
    out = folder / "model.glb"
    shutil.copy(textured, out)
    print("model", out)
    return out


if __name__ == "__main__":
    args = sys.argv[1:]
    car = args[0]
    seed = int(args[args.index("--seed") + 1]) if "--seed" in args else 7
    if "--model-only" not in args:
        image(car, seed)
    if "--image-only" not in args:
        model(car)
