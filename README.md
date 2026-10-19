# Voltage County (working title)

An original open-world driving and roleplay game for Roblox: a small Texas county, a garage of original cars
across eight fictional brands, jobs for every car, and an AI Car Designer.

- The build plan is `PLAN.md`. Work goes one phase at a time, and each phase ends with a stop and a report.
- The rules are in `CLAUDE.md`.
- What has shipped, and how to try it, is in `docs/PROGRESS.md`. What's next is in `TODO.md`.

## One-time setup in Roblox Studio (Davis)

Already done on this laptop: Git, Roblox Studio, the Rojo plugin, Studio's AI connection (from Steal a Snack),
and the build tools (Rokit installed them into `%USERPROFILE%\.rokit`).

1. Open Roblox Studio and start a new **Baseplate**.
2. **File > Publish to Roblox**. Make it a new experience called "Voltage County" and keep it private.
3. **Home > Game Settings > Security**: turn on **Enable Studio Access to API Services**, then **Save**.
   Saving player data needs this.
4. Check that **Assistant > ... > Manage MCP Servers > Enable Studio as MCP server** is still on.
5. Double-click **`Sync to Studio.bat`** in this folder and leave its window open.
   In Studio, click **Plugins > Rojo > Connect**.

## Trying it

- Press **Play**. The Output window should show `[Server] booted 0 services` and
  `[Client] booted 0 controllers` with no red errors. The counts grow as phases add systems.
- Run the tests: press **Stop**, then paste this into the command bar (**View > Command Bar**) and press Enter:

  ```lua
  require(game.ReplicatedStorage.Shared.Testing.Harness).runFolder(game.ServerStorage.Tests)
  ```

  The last line should read `TESTS: passed=N failed=0`.

## Commands (for Claude)

| What | Command |
|---|---|
| Install tools and packages | `rokit install`, then `wally install` |
| Sync to Studio | `rojo serve` (or `Sync to Studio.bat`) |
| Quality gate, before every commit | `scripts/check.ps1` (or `scripts/check.sh`) |
| Tests | the harness line above, through Studio MCP `execute_luau` in the Edit datamodel |

The quality gate runs, in order:
1. every Luau file starts with `--!strict`
2. no real carmaker or model name appears in game code (`scripts/banned-names.txt`)
3. StyLua formatting check
4. Selene lint
5. Rojo build

## Layout

| Folder | Becomes in Studio | Holds |
|---|---|---|
| `src/shared` | ReplicatedStorage.Shared | Config, Net, Types, Util, Testing (later Vehicle, Road) |
| `src/server` | ServerScriptService.Server | the service loader, Services, Vendor (ProfileStore), Dev tools |
| `src/client` | StarterPlayerScripts.Client | the controller loader, Controllers, UI, Dev tools |
| `tests` | ServerStorage.Tests | `*.spec` modules for the harness |
| `Packages` | ReplicatedStorage.Packages | react-lua from Wally (not in git; `wally install`) |
| `backend` | (Vercel) | the AI Car Designer service, from Phase 11 |
| `docs` | | progress log, security table, drop template, art brief, third-party licenses |

Third-party code: ProfileStore by loleris (Apache 2.0) is vendored at commit `9580f7c` in
`src/server/Vendor/ProfileStore.luau`. Its license is in `docs/licenses/`.
