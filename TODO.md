# To-do

One phase at a time from PLAN.md. Standing go from Davis (2026-10-19): keep going phase to phase without stopping
for an OK; stop only for things that are his.

## Now
- Phase 11 (AI Car Designer): built, reviewed and committed on `phase-11`; backend live at
  voltage-county-designer.vercel.app (answers "not set up yet" until its keys are in). Finishing the Studio checks.

## Next, in order
1. Phase 12: monetization, credit sales, limited drops, live-ops (`docs/phase-12-contracts.md`)
2. Phase 13: houses and social roleplay (`docs/phase-13-contracts.md`)
3. Phase 14: performance, security, soft launch (`docs/phase-14-contracts.md`)
4. **Art pass: realistic, high-poly cars** (Davis, 2026-10-20: "good and real looking and like teslas and real
   cars ... high poly models"). Replace every catalog car's greybox Body with high-detail MeshParts made with
   Studio's mesh generation, within 20,000 triangles per mesh; Ohm Motors gets the clean modern EV look. Original
   designs only: no real carmaker names, logos or signature shapes (CLAUDE.md hard rule 4).

## Waiting on Davis
- AI Car Designer keys: run `tools\open_designer_setup.bat`, paste the database key, click Save and go live, then
  copy the game password into the experience's Secrets as `designer_key` (and Studio's Local Secrets).
- Check the touch controls and phone screens on a real phone.
- Plate filtering needs a live private-server check.
- Light-show music and the thruster hiss are silent until sounds are uploaded.
- Streaming radii are set by hand in Workspace properties (StreamingMinRadius 256, StreamingTargetRadius 2048,
  StreamOutBehavior Opportunistic).
