# Car roast, 2026-11-08

## Verdict
Right now these are soap carvings with a paint bucket emptied over them: matte, lumpy, lightless, and half the lot is unpainted white. Next to the best-looking Roblox car games they read a tier below, and next to a real car they read as toys. But most of the gap is one shared material, glass and light pass, not 34 rebuilds.

## The 10 worst problems (worst first)

**1. Paint is dead clay.** Every close-up (10–16). There are no highlights, no reflections and no clearcoat, so the red muscle car (15) looks like modelling wax. *Fix, all cars at once:* give the body a SurfaceAppearance with a neutral white ColorMap, roughness about 0.25, metalness 0 (solid) or 0.4 (metallic), and a faint orange-peel NormalMap. Drive the colour through `SurfaceAppearance.Color` so recolouring still works. Fallback: SmoothPlastic with Reflectance 0.12–0.2.

**2. No working lights.** The Arc (10) has two brown smudges where its headlights should be. The Current (13) has a black scar on one side and a sliver on the other. The pickup, muscle car and classic (12, 15, 16) have matte white egg shapes. *Fix, all cars:* the light parts already exist, so set headlights to Neon (warm white 255,244,230) under a Glass lens part at Transparency 0.25. Tail lights go Neon deep red (170,10,10) and brighter on the brake, with a SpotLight per headlight only at night. *Per car:* Ohm needs a separate thin Neon light-bar part front and rear as its brand signature.

**3. The windows are opaque navy slabs.** Every image. There is no depth, no tint gradient and no interior, so every car looks unoccupied and fake. *Fix, all cars:* window part Material Glass, Color (18,22,28), Transparency 0.35, Reflectance 0.25. Add a dark blocker shape inside (seat backs plus a dash) so you see shapes rather than the far side of the car.

**4. Melted, lumpy surfaces.** The Arc's nose (10) sags like warm icing, with drooping strakes hanging off the splitter. The Vorrena's hood (11) is crumpled foil. The Current's front (13) looks like a car under a dust sheet. There are no crisp creases or shut lines anywhere. *Fix, per car:* regenerate (section 3) and ask for "crisp character lines, sharp panel gaps, taut surfaces". Use the full 20k triangles on the body.

**5. One body colour for chrome, grilles and trim.** The classic's bumper and overriders (16) are body blue. The pickup's bull bar (12) is body green. The muscle car's grille (15) is body red. Real cars are about 40% black plastic, chrome and mesh. *Fix:* split trim with segment_mesh, or add separate parts: a black SmoothPlastic lower intake, grille insert, mirror caps and window surrounds, plus Metal or high-Reflectance chrome on classic and muscle bumpers. Add a plate part with a SurfaceGui (text filtered) and a small badge part on every car.

**6. Wheels are toy wheels.** The pickup's tyres (12) are tucked far inside narrow arches, with a narrow track. The Kaze (14) has flat grey dish rims. The Halden city car (02) has orange hubs. *Fix, all cars:* set track width flush to the arch lip and fill the arch gap to about one finger. Add a brake disc (Metal) and a caliper part behind the spokes, a Metal rim with roughness 0.3, and a matte tyre with a sidewall normal map. *Per brand:* give each brand its own rim set.

**7. Half the lot is unpainted white.** The top view (00) shows 15 of the 34 cars in default white, and 01/02 are a white-out. Paired with flat paint, white turns into featureless putty. *Fix:* give every car a curated default and randomise the spawn colour per instance.

**8. Each brand is locked to one crayon colour.** Every Halden is baby blue, every Kaze highlighter yellow, every Montevale traffic-cone orange (00). It looks like a toy set. *Fix:* give each brand a 6–8 colour palette of real automotive tones (graphite metallic, deep wine, racing green, pearl white, gunmetal, midnight blue, satin black, one loud hero colour). Pastels only as rare options.

**9. No underside or stance.** Bodies end in a same-colour skirt with daylight under them (13, 15). *Fix, all cars:* add a near-black underbody plane and black wheel-arch liners, then drop ride height 10–20% on cars and supercars. Add a little negative camber on sport classes.

**10. Broken mesh seams at glass edges.** The muscle car's windscreen top (15) has a torn, jagged edge where body bleeds into the glass, and the Vorrena's side vents (11) are black rips. *Fix, per car:* regenerate or re-segment. A dark window-surround trim part hides the leftovers.

**Shared pass (one script, all 34 cars):** 1, 2, 3, 6, 7, 8 and 9. **Per car:** 4, 5 and 10, plus the Ohm light bars.

## Regenerate first

1. **Ohm Arc (hypercar).** It's the hero brand's halo car and it's a melted blob with no face. Cues: *low two-seat electric hypercar, forward-set canopy, sealed smooth nose with a full-width hairline light bar and two small vertical intakes at the corners, deep scoop behind the doors, tall rear haunches, full-width tail light blade, large black diffuser, crisp creases, aero-disc wheels.*
2. **Ohm Current (SUV).** It's the car under a sheet. Cues: *midsize electric crossover, smooth closed front with a slim full-width light bar and a black lower band, flush door handles, floating roof with blacked pillars, black wheel-arch cladding, short overhangs, big wheels pushed to the corners, crisp shoulder line.*
3. **Montevale Vorrena (supercar).** Crumpled hood, torn vents. Cues: *mid-engine wedge supercar, sharp nose with a deep black splitter, narrow swept headlight slits, single deep intake behind the doors, louvred engine cover, wide hips, one slim tail light across the rear, taut faceted surfaces.*

Runner-up: the Ironwood Brakken (12): the goggle-eye headlights read as a cartoon face.

Append to every prompt: *original design, production quality, crisp panel gaps, separate light clusters, dark grille insert, black lower trim, no badges, no text.*

## 20 new cars

1. **Hot hatch, Kaze Zenji:** stubby three-door. *Short boxy hatch, pumped square arches, roof spoiler, centre twin exhaust, honeycomb lower grille.*
2. **Sports coupe, Kaze Akeru:** front-engine fastback. *Long hood, cab set back, slim swept lamps, ducktail rear, 2+2.*
3. **Supercar, Montevale Ostria:** cab-forward wedge. *Low wedge, single intake blade, slatted rear deck, flying buttresses.*
4. **Track hypercar, Montevale Varzo:** longtail. *Stretched tail with a shark fin, roof scoop, giant diffuser, centre-lock wheels.*
5. **Muscle fastback, Brannock Mallet:** brawny coupe. *Long hood with a raised power bulge, recessed twin-bar grille, wide rear haunches, short deck.*
6. **Muscle sedan, Brannock Warden:** four-door bruiser (also a police base). *Upright four-door, flat hood, mesh grille, quad exhaust, steel-look wheels option.*
7. **Wagon, Aldermoor Esterly:** luxury long-roof. *Long low estate, sloping D-pillar, roof rails, slim chrome window line.*
8. **Luxury saloon, Aldermoor Ormond:** flagship. *Long dash-to-axle, wide low horizontal-bar grille, coach line along the body, thin lamps.*
9. **City EV, Ohm Pip:** tiny two-door. *Short rounded cube, wheels at the corners, light-bar face, tall glass.*
10. **Compact crossover, Halden Ambit:** starter SUV. *Small upright crossover, grey cladding, roof rails, friendly round-corner lamps.*
11. **Three-row EV SUV, Ohm Lumen:** family hauler. *Long smooth SUV, closed front, full-width light bars front and rear, flush glass.*
12. **Full-size luxury SUV, Aldermoor Graystone:** boxy and imposing. *Tall flat sides, upright tailgate, wide chrome-band grille, running boards.*
13. **Off-roader, Ironwood Talus:** two-door brute. *Short wheelbase, rectangular lamps in a tubular steel bumper, flat clamshell hood, rear spare, 35-inch tyres, rock sliders.*
14. **Compact pickup, Halden Ferro:** cheap and useful. *Small unibody pickup, short bed, black plastic bumpers, steel wheels.*
15. **Heavy-duty pickup, Ironwood Bulwark:** dually. *Tall slab grille, towing mirrors, dual rear wheels, cab-roof marker lamps.*
16. **Electric pickup, Ohm Fieldline:** soft-edged EV truck. *Rounded slab sides, light-bar face, frunk seam, tonneau cover, no hard angular wedge.*
17. **Van, Northline Haulmate:** tall cargo van. *High roof, sliding side door, ladder rack, barn rear doors, black bumpers.*
18. **Convertible, Aldermoor Solenne:** four-seat soft-top GT. *Long hood, fabric roof, low windscreen, chrome windscreen frame, deep doors.*
19. **Classic, Kaze Rokku 74:** 1970s rally coupe. *Boxy two-door, square quad lamps, thin chrome bumpers, slotted steel wheels, mud flaps.*
20. **Flying roadster, Ohm Driftwing:** two-seat electric skimmer. *A narrow central tub with two open pod seats side by side and low wind deflectors, no windscreen frame. Four wheels in separate outboard aero pods on short struts, like a catamaran. Two ducted-fan thruster nacelles on the rear flanks with glowing rings, small canards at the nose, twin fin headrests.* Not a low smooth wedge coupe and no removable glass roof, so it can't be mistaken for any real roadster.

## Three things that work: don't break them

1. **The two white Ohm sedans (02, left).** Believable proportions, sensible ride height, and dark multi-spoke wheels that fill the arches. They set the bar every car should hit.
2. **The work fleet (01/02).** The box truck, ladder-rack van, crane utility truck and cab-over each read their job instantly, and the roof slats and crane detail are the most "real" geometry in the game.
3. **The parts split (body / windows / lights / wheels) and the class silhouettes.** Because glass and lights are already separate parts, the shared pass above is a script, not a rebuild. The top view (00) also reads by class at a glance. Keep the split contract when regenerating.
