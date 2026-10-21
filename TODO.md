# To-do

One phase at a time from PLAN.md. Standing go from Davis (2026-10-19): keep going phase to phase without stopping
for an OK; stop only for things that are his.

## Now
- All 15 phases (0–14) are built and checked. Next is the soft launch: Davis's steps in `docs/LAUNCH.md`.

## Done (see docs/PROGRESS.md)
- Phases 0–14, the art pass (realistic bodies on every car and trailer) and the two new Montevale supercars.

## Waiting on Davis
- The launch steps in `docs/LAUNCH.md` marked "Only you" (account, icon upload, title, questionnaire, Managed
  Pricing, DevEx, store items, designer keys, streaming and chat settings, beta, public).
- Studio settings scripts can't change (LAUNCH step 10): Workspace StreamingMinRadius 512, StreamingTargetRadius 2048,
  StreamOutBehavior Opportunistic, StreamingIntegrityMode Disabled (from Config/Perf.streaming; scripts/check keeps
  default.project.json the same), and TextChatService ChatVersion = TextChatService (it still reads Legacy).
- Decisions:
  - keep the one free redesign that comes with a paid design, or drop it (docs/COMPLIANCE.md section 2);
  - a contact address for the privacy page (it says the game follows COPPA but only offers a Roblox message);
  - under-16 access: two months of Roblox Plus/Premium, or the refundable 1,000 Robux fee (LAUNCH step 13);
  - the suggested starting prices (LAUNCH step 8);
  - the privacy page names the services behind the designer (Vercel, Supabase, Anthropic): fine to keep?
- Paid and earned wraps on the new realistic cars: stripes can't sit on their curved bodies, so each exclusive wrap
  (Starter Pack, Voltage Club, launch week, season rewards) now goes on those cars as a full-body color in the wrap's
  main color, and keeps its stripes on designed cars. Say if those looks should work differently.
- AI Car Designer keys: run `tools\open_designer_setup.bat`, paste the database key, click Save and go live, then
  copy the game password into the experience's Secrets as `designer_key` (and Studio's Local Secrets). Then Claude
  runs the live 90-prompt suite (about 5 cents, already OK'd).
- Check the touch controls, phone screens and frame rate on a real phone.
- Plate filtering needs a live private-server check.
- Light-show music and the thruster hiss are silent until sounds are uploaded.
- The shared Supabase project (vantage-terminal) has security warnings from its other apps, not the designer's.

## Later (Claude)
- `meshes.rejectUncounted` back on once a real-backend playtest shows no "takes its generated look uncounted" line.
