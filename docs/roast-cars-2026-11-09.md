# Car roast, 2026-11-09

## Verdict
- **Vela pipeline: no, not yet.** The silhouette is the first one that reads as a real car, but the surface is a smeared photo bake with torn arches and white blotches. Right now it looks like a damaged scan, not a car.
- **19 Studio-generator cars: no, and they never will.** They are melted, low-detail blobs in toy colours with opaque navy glass. Better glass and gloss won't save that geometry. It is the Roblox-free-model look Davis is trying to get away from.

## The 6 worst problems (worst first)

1. **Studio lighting baked into the Vela's albedo, so the tint mask makes camo** (01, 02 right). Hunyuan baked the reference photo's white highlights and grey shadows into the colour map. Tinting red leaves white slashes all over the nose and dark smears on the hood. *Fix (pipeline):* in Blender, de-light before tinting. Bake the texture's luminance, divide out a blurred version of it (high-pass), and keep only small detail. For paint regions, throw the bake away: assign a flat base colour plus a separate grime/AO map, and let SurfaceAppearance (MetalnessMap 0, Roughness about 0.25) and the sun do the shading. Generate references on a **mid-grey** car under soft, even light, not glossy white under a key light.
2. **Broken geometry: torn wheel arches, flapping fender skins, missing wheels** (02 left: open shell, arch fragments, no wheels; 01: ragged rear arch). *Fix (pipeline):* a headless Blender cleanup pass: voxel remesh (about 8 mm) then decimate to budget, delete loose islands under N faces, fill holes, recalculate normals. Then **boolean-cut real arch openings** from a cylinder sized to the wheel spec and delete the AI-generated wheels outright. Add a gate that fails the export if non-manifold edges are over a threshold.
3. **Wheels are the cheapest-looking part of every car.** There are solid grey discs (pink coupe, white SUV), blurry baked spokes, and no tyre sidewall or brake detail. *Fix (pipeline):* stop letting generators make wheels. Build 6-8 hand-scripted wheel kits in Blender (rim, tyre with sidewall bevel and lettering normal map, caliper, disc) and mount them through the vehicle model contract. This is the single fastest realism gain across all 20 cars.
4. **Glass is opaque navy plastic with no interior** (every Studio car, 05, 07). Real cars read through the glass: seats, headrests, a dark cabin. *Fix:* swap the glass to Transparency 0.35-0.45 with a dark smoky tint, Reflectance about 0.25, and drop in a generic low-poly interior proxy (two seats, dash slab, wheel) per body class. For the Vela pipeline, mask the cabin out of the mesh and use the same proxy.
5. **Melted, panel-less bodies with toy paint** (Talus 06, Haulmate 07, orange coupe 04). There are no shut lines, no grille depth, lamps are painted smudges, bumpers fuse into the body, and colours are saturated pastels (bubblegum, peach, teal). *Fix:* regenerate these through the Vela pipeline. Studio text-to-mesh is a dead end. Meanwhile, use a shared NormalMap with procedural panel-gap lines from a UV-space mask, separate black-trim parts (grille, lower intake, window surround) through a dark-plastic material mask, and a restrained real-world paint palette (darker, desaturated, with metallic flake on a few).
6. **Cars float and don't sit** (01, 03 white hatch, 04 orange coupe, 06 front wheel). Shadows are offset from the bodies, and nothing has ride height or tyre squash. *Fix (pipeline):* auto-align each body so the wheel centres sit at tyre radius, add an AO contact-shadow decal under the floorpan, and gate the export on the lowest wheel point being within 1 cm of ground.

**Look-alikes in the current Studio bodies (worth fixing too):** the orange coupe is a 2018 Mustang GT nose, the white winged hatch is a Civic Type R, the Haulmate is a Sprinter, the Talus is a Land Cruiser 70/Hilux with a snorkel, the white SUV is a Land Cruiser/Lexus GX, the big white pickup reads as a Ram, and the teal box (Pip) is a Nissan Cube/Scion xB.

## Reference photos in 08 (brannock_mallet already rejected: Challenger)
- **kaze_zenji: redraw.** It's a Honda Jazz/City hatch with a VW-style badge and grille. Too close.
- **kaze_akeru: redraw.** Tesla Model S fastback profile with a Polestar/Taycan-like light bar. Instantly reads as a Tesla.
- **kaze_rokku: redraw.** Datsun 510 / early Corolla rally coupe with quad round lamps. Hard look-alike.
- **montevale_ostria: OK with tweaks.** It's a generic teardrop hypercar with faint Speedtail echoes. Change the badge and keep it.
- **montevale_varzo: borderline.** Shark fin plus open wheels evokes the Valkyrie/Le Mans prototypes, so change the fin shape.
- **All of them, and the Vela:** the AI invents Mercedes/VW-like roundel badges. Prompt "no badge, no logo" and paint the badge area out in the mask.

## Two things that work
1. **The Vela's proportions and stance**: long hood, cab-back roll hoops, tight overhangs. It's the first car in the game whose silhouette would pass in a real photo. The pipeline idea is right; the surface handling is wrong.
2. **The blue Studio GT (03, front-left)**: the glossy paint picks up a believable sky reflection, and the bronze multi-spoke wheels are the best wheels on the slab. Use it as the bar for the shared paint material.
