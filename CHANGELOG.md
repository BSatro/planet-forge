# CHANGELOG.md — architectural decisions and project history

Format: newest first. ADR = Architecture Decision Record (Accepted / Proposed / Pending-human).

## 2026-11-23 — Planet scale rework: bigger planets, real-scale props, DNA-driven density
### Safety
- Checkpoint saved before any change: place version 142. Work saved as versions 148–149 (Team Create). **Nothing was published.**
- All live checks ran in Studio Play against the in-memory mock store (`store=mock(shared)`, `persistent=false`). No DataStore was read or written.

### ADR-014 revised (Accepted): `PLANET_RADIUS = 160` (was 96; 180 was earmarked)
- 180 does not fit the current system without moving other things. 8 slots on `ORBIT_RADIUS = 1100` put neighbouring centres 842 studs apart. Gravity reaches `INFLUENCE_FACTOR × R` = 2.5R. At R = 180 two fields would reach 900 > 842 and overlap. That would need the orbit at ≥ 1180 or a weaker reach.
- At R = 160: reach 400, so 2 × 400 = 800 < 842. The on-planet range is 2.6R = 416 < 421 (half the spacing). Surface area grows ×2.78.
- Radius-dependent items were re-checked (see Tested): spawn, warp pad, harvester placement (`HarvestConfig.PLACEMENT` is angle-based, unchanged), the near-LOD distance (now `R + 424` = 584; was 520) and the exclusion zones (now stud-preserving: spawn, pad and harvester lane keep their stud size).
- `PlanetBuilder`: craters stay at 18. Boulders go 22 → 34 (one part each), so the barren surface isn't emptier. Maria spread scales with R.

### Real-scale props (`FormationDensity.TIER_SCALE`, `GENERIC_PROP_SCALE`)
- Each formation is built at authored size on a *virtual* sphere of radius R/s that touches the real surface at its site, then `Model:ScaleTo(s)` about the site pivot. Scaled art hugs the real sphere: a spec checks tree bases sit within −1.5..+1 stud of the surface.
- Tier scales: 1–2 → 0.60, 3–4 → 0.66, 5 → 0.74, 6 → 0.82. Generic decorator props → 0.62. Hierarchy holds: every formation is ≤ R/4 tall, and the World Tree is > 3× a forest tree.

### Density follows DNA (`PF_Shared.Planet.FormationDensity`, the only copy of the formula)
- `count = purchases × (lo + (hi − lo) × g)`, with `g = sqrt(clamp((DNA − from) / (100 − from), 0, 1))`. Monotonic, bounded and capped, never exponential.
- "cluster" formations fill one site before starting the next, and clusters never shrink. "spread" formations put one site per element.
- Element positions use a golden-angle spiral with a per-element rng. Growth only ever **adds** elements; existing ones never move.
- Variety unlocks with DNA: trees TreeDefault → TreePine → TreeVariant; crystals Red/Green/Ice.
- Unique / landmark formations still use `maxCount`. The repeatable ones (FirstForest, GrassPatches, IceSpikes, CrystalCluster, the seas, lakes, cracks, pools, veins and fissures) use DNA-driven counts. Final SPEC: ShallowOcean max 4 sites and PlasmaFissures max 2. These two were one lower than the first draft (see Budget), because they are branch-less and repeat on every planet.
- Measured live, one vegetation purchase: Life 27 → 3 trees, Life 60 → 6 (3 kinds), Life 100 → 8. Two purchases at Life 100 → 16 trees on 3 sites (6 + 6 + 4).
- **Contract unchanged.** `PFFormations` still carries purchase counts. Clients derive element counts from the published `PFDna_*` with the shared module, via `spec.dna`. Same attributes → same visuals.

### Per-instance cost cuts (done before any count was lowered)
- Satellite copies of spread formations (2nd sea, 3rd crack…) have no particles, no lights and one shared anchor. They also use less geometry: sea 3 lobes, steam 2 terraces, lava 8 wide rim blocks, lake 3 cracks / 2 boulders, grass 3 moss / 4 tufts.
- Lean (scaled) art: veins and cracks use half the segments at twice the length, and one basalt bed instead of two lips. Celestial Flora has 6 stalks and 3 flowers of 3 petals with one FX anchor. Ice Impact has 8 shards and 3 crystals. Joints are stripped from cloned templates (everything is anchored). Decorator `Prop` wrapper models are dissolved after scaling.

### Budget: measured in Studio Play, client at the station, all 8 planets developed (stage 6)
| | Workspace parts | Workspace instances | Emitters | Semi-transparent | Stats.InstanceCount |
|---|---|---|---|---|---|
| Baseline R 96, undeveloped → developed | 1775 → 6553 (**+4778**) | 2590 → 7918 (**+5328**) | +72 | 3214 | 66922 |
| First draft R 160 (8 developed planets, before cost cuts) | +6597 | +7343 | +100 | 3500 | 69780 |
| After per-instance cuts only (all DNA 100) | +4849 | +5499 | +64 | 3172 | 67936 |
| **Final, worst case** (all 4 DNA = 100) | 2540 → 7222 (**+4682**) | 3427 → 8746 (**+5319**) | **+64** | **3116** | 67752 |
| Final, branch-typical DNA | 2540 → 7010 (+4470) | 3427 → 8520 (+5093) | +64 | 2996 | — |
- The planet-visual layer (what this rework changes) is **inside the old budget** in the worst case, on parts, instances, emitters and semi-transparent parts.
- **Open:** the *undeveloped* world grew by +765 parts at the station (1775 → 2540). 1008 of the 2540 are server-built barren detail (`PlanetDetail`, Atomic streaming) for 4 of the 8 slots, which the engine streamed in at the station on every run. The models themselves only grew by 12 boulders each. The only other server-side change is boulders, so the rest is streaming bringing in more detail models. The streamed count in the baseline run wasn't recorded, so this split is an inference. As a result **total** Workspace counts are still ~10% above the old total (7222 vs 6553 parts; 8746 vs 7918 instances). Fix options for the owner: non-atomic streaming for `PlanetDetail` (the client tint hook would then need `DescendantAdded`), or fewer craters on the barren layer.

### Tested
- Specs: 14 spec files, **150 passed, 0 failed** (149 before + PlanetScale `COST`). PlanetScale has 7 cases: radius invariants, scale hierarchy, density (monotonic, bounded, clusters never shrink), variety, sites (deterministic, no overlaps, zones clear), render (deterministic, add-only growth, art on the surface), and a new case that checks every DNA-grown formation builds at every site and that satellites are lean.
- Compile sweep: 157 scripts, 0 errors. Console clean during every rebuild.
- Live at R = 160: travel home lands 3.0 studs up and upright. A walk from spawn to the harvester stayed grounded (height 3.00 throughout). The harvester sits on the surface. **Two live captures** (tutorial Ice + Iron meteor) went through the real remotes. LOD: own planet near (particles on); a planet 838 studs away mid; the station sees all planets at mid.
- Screenshots: the surface view captured. A station view could not be captured, because the tooling can't steer the game camera in Play.

### Found (not caused by this change; not fixed)
- **Slot 1 only:** the harvester is at azimuth 180°, straight across the pole from the spawn (azimuth 0). The direct walk passes 0.3 studs from the north-pole return pad and warps the player back to the station (reproduced). Same geometry at R = 96. Every other slot's direct path clears the pad by ≥ 12 studs. Suggested fix: skip harvester azimuths within ±30° of spawn+180 in `HarvestLayout.getAzimuthDeg`. This is a gameplay/layout decision, so it's left to the owner.
- From the surface, the third-person camera sits above the atmosphere shell (R × 1.035–1.055 ≈ 6–9 studs up). The shell's rim reads as a blue band around the horizon. This was already the case at R = 96 (3–5 studs). An option is to fade the shell while in near LOD.

## 2026-11-22 (evening) — Private-test readiness pass (release blockers)
### Safety
- Place 79132282456701, universe 10778085398, owner user 8319150623, **visibility PRIVATE** (Open Cloud read). Team Create is on.
- The checkpoint was saved **before** any change: place version 126. All earlier audit fixes (D3–D7, telemetry) and today's quest work were already in version 125.
- Nothing was published. No real DataStore was read or written. The Open Cloud data-store list call was refused (scope not granted), and nothing was done to work around it.

### D1: production data prepared, NOT active (owner decision)
- A parallel session had set `PRODUCTION_UNIVERSE_IDS = { 10778085398 }` this morning without the owner's confirmation. It is reverted to `{}`, and the verified id is kept in `DataConfig.PRODUCTION_UNIVERSE_ID_PENDING`.
- **Why the environment is non-production:** `DataEnvironment.decide(isStudio, universe)` returns "production" only on a live server whose universe is in `PRODUCTION_UNIVERSE_IDS`. Studio is always "studio" (in-memory mock), and any other live universe is "test" (`PF_TEST_Profiles_v1`, `test_u_` keys).
- **To activate:** set `PRODUCTION_UNIVERSE_IDS = { PRODUCTION_UNIVERSE_ID_PENDING }`, run D1.spec, save, publish. This happens only after confirmation plus the private DataStore pass.
- **Developer commands:** on live servers they now also require the universe to be in `TEST_UNIVERSE_IDS`. Pure rule `DevCommandService.decideEnabled`. The real game's live servers never get them, whether production is active or not.
- D1.spec was updated: config pending, environment decisions tested against the activation config, and a new dev-command allowlist case. It has 7 cases.

### D2: server size
- Open Cloud place read: `serverSize: 8` (updateTime 2026-11-22 18:48 UTC).
- Studio's `Players.MaxPlayers = 60` is an unsaved local default. The engine docs say it can only be set from the place settings on the Creator Dashboard (Creations → experience → Places → place → Access → Server Size).

### Fixed
- **Skybox:** all six images are moderation-**Approved** (Open Cloud Assets read). The real bug was SkyActivator's string-based `PreloadAsync`, which reported Failure for every asset, known-good meshes and sounds included. It now preloads through a probe Sky instance, and the log shows "[PF] baked skybox active". The look still needs a visual check, because the 3D view doesn't render while Studio is unfocused.
- **Store (I6):** with nothing on sale, the Passes page says so plainly. Appearance previews and the free design preset still work, so the Store stays visible.
- **Cosmic Events panel (I3):** gamepad focus starts on its action button.

### Added
- `ServerStorage.PF_PersistenceProbe`: an end-to-end real-persistence check for the private test experience. It covers save, leave/rejoin, planet reconstruction, a two-server session conflict, shutdown release, transient-failure recovery, and a persistent failure leaving data untouched. Mock mode: 12/12. Test mode refuses unless it is running in Studio on a universe listed in `TEST_UNIVERSE_IDS` that is not the pending production universe. It uses throwaway `probe_` keys and fake user ids, and removes them afterwards.

### Tested
- **Specs:** 13 specs, 143 passed, 0 failed. Compile check: 153 scripts, 0 errors.
- **Live solo Play:** baked sky applied (StarCount 0, faces set); store notice shown; Dev_Command present in Studio; console clean; all 7 checked panels fit at 740×360 and 1280×720.
- **Not run (not supported by the automation):** real multi-client sessions, a real DataStore, devices, real gamepad input. A manual plan (M1–M12) is in the QA doc.

## 2026-11-22 — Fixes from the automated Studio session + daily/weekly quests
### Findings that differed from the report
- `rbxassetid://81504106` is the texture of **Hat1 on the developer's own avatar** (an old Roblox accessory), not the game. Nothing to fix in the place.
- `rbxassetid://125921838360800` is **not in the place** (Edit, Server or Client scan); it comes from a Studio plugin's toolbar icon. Players never load it. Plugins were not modified.
- Rifts already support co-op (1–8). The disabled flag is `HarvestConfig.COOP` (co-op *harvesting*). There are no "Anomaly" targets, and comet `redirect` exists only as a comment.
- A unit suite already exists. Today it runs 142 cases across 13 specs. Only `RiftRules` has no spec.
- D1 was resolved by another session (`PRODUCTION_UNIVERSE_IDS = { 10778085398 }`, D1.spec), so Studio must never be pointed at this universe's data stores.

### Fixed
- **SkyActivator:** the six uploaded sky images still fail to load. The native night sky is now the documented default, and the baked images get **one** attempt per session (it used to retry 40 × 90 s), failing silently. To retry the images, check moderation in Creator Hub → Development Items → Images, or upload new ones and update the `PFPending_*` attributes on `Lighting.PF_Sky`.
- **Performance (PlanetDecorator):** far-LOD rings went from 2 × 48 to 2 × 32 semi-transparent segments (24 at reduced/minimal effects). Measured with 7 developed planets: +1,280 → +1,058 client parts (−17 %), and far folders went from 177–234 to 145–202 instances each. The rest of the analysis held up: StreamingEnabled is on (a client holds 1 planet's detail, about 267 instances), and all 1,356 client FX parts have CanCollide, CanTouch and CanQuery off. Remaining risk for the device pass: far-LOD parts are almost all semi-transparent (~150 per developed planet).
- **Real DataStore test:** the code path exists (DataConfig.TEST_UNIVERSE_IDS + STUDIO_BACKEND = "test" + Studio API access on a separate private experience). It is blocked on the owner creating that experience (TASKS Q-7.8a).

### Added — daily/weekly quests (INTERFACES §11)
- QuestConfig/QuestRules (pure), QuestService, the `Quest_Action` remote, `profile.quests` (additive; reconciled by ProfileSchema), `Profile_Snapshot.quests`, QuestPanel (dock "Quests", Y), QuestNotifier toasts, a dock badge, and the TelemetryService `QuestClaimed` event (quest credits use the economy source type `TimedReward`).
- `WorldEventService.RewardGranted` signal. The first version counted every *running* event; the live test caught it (a scheduler-started Solar Storm was credited by a shower capture), and it was fixed.
- **Periods roll forward only.** The live clock test caught a rollback, which would let a server hop at midnight re-issue already-claimed quests. Fixed and covered by Quests.spec.

### Tested
- **Specs:** 13 specs, 142 passed, 0 failed (Quests 7 new). Compile check: 152 scripts, 0 errors.
- **Live, Studio solo Play:**
  - Level 1 gets no rift quests.
  - Selling 10 matter (real remote) completes D_Sell and counts credits toward D_Earn.
  - 3 real, server-validated perfect harvester captures complete D_Perfect.
  - 2 showers with a Solar Storm running give W_Event 1 then 2 (once per event).
  - The client claim gives +60 credits and streak 1. A second claim returns ALREADY_CLAIMED; index 7 returns UNKNOWN_QUEST; a bad action returns INVALID_PAYLOAD.
  - Clock +8 h: finished quests are paid once (+400 weekly, +70 daily), and a second check pays nothing. Clock back: no rollback.
  - Telemetry logged QuestClaimed Manual/Auto and economy Quest sources.
  - The panel renders, and the dock badge shows 2.
  - The 9-button dock stays inside the screen at 1080p, 768p, 720p, tablet and phones.
  - The console stays clean.

## 2026-11-21 (night) — QA, security and release audit (report: Claude Doc "PLANET FORGE — QA Audit & Release Checklist")
### Verdict
**Not production-ready.** Open blockers, both owner decisions:
- **D1 (Critical):** `DataConfig.PRODUCTION_UNIVERSE_IDS` is empty, so a live server saves to the TEST store and keeps developer commands on for the owner.
- **D2 (High):** Max Players is 60 for 8 planet slots, so players 9+ are kicked with SERVER_FULL.

Nothing published; no paid products created; no live data touched.

### Fixed during the audit (all tagged `QA-2026-11-21`)
- **D3 (High), EventInteract:** errors every frame and a lost reticle after a respawn during a Meteor Shower. Cause: PlayerGui BillboardGuis had ResetOnSpawn on. Fix: ResetOnSpawn = false, plus nil guards.
- **D4 (Medium), Social.PlanetInfo:** the Planets panel crashed on unspecialized planets, because branch `None` has no colour. Fix: neutral fallback.
- **D5 (Low), HarvestController:** the "Your harvester" marker was lost after a respawn. Same cause and fix as D3.
- **D6 (Low), CharacterService:** a `Travel_Warp` "home" request resolved to slot 1 for everyone. Fix: it now resolves the player's own slot (NO_PLANET otherwise). Closes J-4.5's "home" item.
- **D7 (Low), layout:**
  - Hud.layout keeps the 8-button dock inside 720p/768p screens (compact buttons when needed).
  - EventHud.placeChips keeps event chips clear of the left HUD column (it stacks them on phones).
  - UIRoot.toast keeps toasts clear of the dock.
  - Earlier: chips moved below the Core Hunt banner; the intro card moved clear of the convergence card.

### Added
- **TelemetryService** (INTERFACES §10): onboarding funnel, milestones, discovery counts, Store funnel and Credits economy events through AnalyticsService. It is server-only and sends minimal data; the store session id is a random GUID.
- **`MonetizationService.StoreFunnel` signal:** an analytics hook only. Purchase logic is unchanged.

### Tested (Studio solo Play + Edit-mode specs; details in the report)
- **Specs after the final fixes:** 109 passed, 0 failed (Gravity 9, World 5, Backend 17, ProfileStore 10, Harvest 9, Evolution 18, EvolutionService 9, Events 16, Monetization 12, Audit 4). Compile check: 141 scripts, 0 errors.
- **Live:**
  - Movement; respawn and warps; evolution idempotency and ownership; harvest validation probes; a real capture.
  - A solo rift with a single reward grant.
  - All three events, plus a mid-event join view.
  - Cleanup and leak cycles: instance counts unchanged, lighting restored.
  - DataStore failure injection.
  - Fake-marketplace purchases and duplicate receipts.
  - A 9-viewport layout matrix.
  - The analytics mirror log.
- **Not tested:** real multi-client sessions, real devices, a live DataStore, AnalyticsService dashboards. These are listed as manual tests in the report and in TASKS Phase 7.

## 2026-11-21 (evening) — Cosmic world events + lightweight social
### Built
- **Three server-authoritative events** (INTERFACES §9):
  - Meteor Shower: bounded meteors in occupied orbital zones; first valid capture wins.
  - Solar Storm: energy reactions refund 50 % of their matter, capped; catalysts are never refunded.
  - Cosmic Convergence: co-op reactor stabilization at THE FORGE (conduits + flux cells), with fair, capped, proportional shares.
- **Scheduling and safety:** a scheduler with cooldowns, a concurrency cap (2) and a compatibility matrix. Phases go incoming → active → ending → cleanup. There are no forced teleports and planets are never modified. Rewards are granted once through EconomyService.
- **Lightweight social, no trading:**
  - Visits are player-initiated.
  - Presence and visitor notifications.
  - Reactions (Stellar / Wow / Inspiring) with abuse protection.
  - A Planet Showcase orbit camera (CameraController `setShowcase` / `clearShowcase` / `isShowcase`).
  - A read-only Planets panel (P).
- **Client:**
  - EventClient mirror and the EventInteract capture reticle.
  - EventHud: chips, intro card, convergence card, summary, and the Studio F3 dev strip.
  - The Cosmic Events panel (J).
  - The EventFx registry with replaceable default effects for Developer A (guide: INTERFACES §9.1).
- **Developer test mode:** the Studio-only `Event_Dev` remote, the `PF_EventHook` / `PF_SocialHook` BindableFunctions, and test-mode scheduler scaling.
- **Edits to existing modules:** Hud dock "Planets" button, UIController registrations, the DnaPanel SOLAR SURGE tag, RiftHud `PFInRiftLocal`, CameraController showcase.
- **Later work:** a parallel session extended WorldEventService and the Events.spec (16 cases). The QA audit above covers the result.

## 2026-11-21 (21:10) — COSMIC RIFTS: "The Fractured Nebula" co-op expedition (playable MVP)
### Built
- **Mission:** station portal → 8 s lobby (solo or up to 8, others join by stepping in, "Launch now") → procedurally generated arena.
  The objectives run strictly in order: collect fragments, stabilize 3 nodes, seal the core in the stabilization chamber, then escape through the portal. A reward summary follows.
- **Data-driven variation** (seeded RiftLayout):
  - node sites and order (6 sites, pick 3)
  - stepping-stone paths with jitter, plus crumble / sweeper hazard placement
  - fragment spots and how many there are (scaled by explorers)
  - secondary objectives: 2 solo / 3 co-op from 6, including the co-op-only Synchronized Pulse and Resonance Relay
  - the hidden prism islet, resonance pads, decoration, and reward rolls (catalyst, component, matter cache)
- **Scaling:** node cost 3 + floor((n−1)/2), fragments 12 + 3·(n−1) (max 30), node and core channel up to 2.5× faster with more explorers inside, co-op reward bonus.
- **Hazards:** crumbling stones (amber warning glow, fall after 0.7 s, return after 4 s); sweeping energy beams (knockback, client-applied impulse); the void (back to the team checkpoint);
  and in the final phase, two chamber sweepers to jump.
- **Art (prototype):** shattered asteroid stones with shard undersides, crystal-pylon node islands, the stabilization chamber
  (core, orbiting arcs, three pylons lit by node beams), swirling portals, an asteroid shell, neon energy spires, nebula mist, and a local violet colour grade.
- **Client:** a mission HUD (objective, channel ring, node pips, fragment pool, timer, bonus objectives, team contributions, Leave), the lobby card,
  world markers, toasts/sounds, the summary (Run again / My planet / Close), and an expedition briefing panel (the dock button now appears).
- **My modules extended:** CharacterService (PlaceAt, WarpToCFrame with stream-in, SpawnOverride), GravityFields (arena boxes), TravelFX labels,
  StationBuilder sign ("COSMIC RIFT · The Fractured Nebula · 1–8 explorers"). Main ORDER gains RiftService. B's modules are untouched.

### Tested
- **Pure (mock explorers):**
  - 40 seeds gave 35 node arrangements and 24 secondary combos. The worst stone gap is 7.0 studs and the worst rise 3.9.
  - Never two hazards in a row, and every layout has enough fragments.
  - Solo / duo (co-op relay done, +8 %) / 8 explorers complete.
  - Node without fragments makes no progress; duplicate and non-member pickups are rejected.
  - A fall fails Flawless. A disconnect during escape still completes, and late explorers auto-escape.
  - Timeout fails with partial pay. Abandoned runs pay nothing, and an AFK member (10 s active) gets nothing.
  - Rewards are deterministic, with 16 combinations across 30 runs.
- **Live solo (Studio Play, mock store):**
  - Launched in slot 1 (401 parts); 3 nodes in order (4 s channels), 12/12 fragments, core, escape after 71 s with instant test moves.
  - Rewards: +248 credits, +120 XP, +3 Plasma Matter, energy clipped to 0 at a full cap. The level-up also paid B's +100. Expeditions went 0→1. The summary screen renders.
- **Repeated rewards:** 6 claims gave 5×OK (summary only) + RATE_LIMITED, credits unchanged; a forged runId returns NOT_FOUND.
- **Run again:** a new run with a new layout.
- **Exploits:** a client-side 150-stud teleport was detected and snapped back. Starting from the planet returns OUT_OF_RANGE, and "home" mid-run returns IN_RUN.
- **Death** in the rift respawns at the checkpoint. **Leave** returns to the station with no reward (a second leave returns NOT_IN_RUN). **Home** lands on the owned planet.
- **Timeout:** failed, 1 node → +20 credits, back at the station, arena torn down.
- **Stress:** 8 concurrent 8-player arenas total 2,724 parts (4.1 ms worst build). The animation step is 0.75 ms per 1/20 s, and rules for 8 runs × 8 explorers cost 0.03 ms per tick.
- **Fixed during tests:** intruder false positive during the exit warp, the Core Hunt hint showing in the rift, and a stale summary over a new run.

### Not yet verified
- Real multi-client sessions (2 and 8 humans) and a real disconnect. These paths share the code exercised by the mocks and by leave.
- The arena visuals and the real jump feel: Studio's 3D view was not rendering during these tests.

## 2026-11-21 (19:40) — PLANET FORGE interface: HUD, DNA Lab, inventory, codex, harvester, settings, evolution screen, onboarding, world UI
### Architecture (all Developer A, `PF_Client.UI`)
- `Kit/Theme` (design tokens: colour, alpha, fonts Michroma + Titillium Web, type scale, spacing, radius, motion, layers, canvas).
- `Kit/Prefs` (session preferences mirrored to `PF<Key>` player attributes), `Kit/Motion` (the only tween entry point; honours reduced motion; cancels per channel, so spam never stacks).
- `Kit/Icons` (30+ procedural vector icons from Frames; no uploaded images), `Kit/Components`:
  glass panel with holographic brackets, button styles with hover/press/focus/disabled states, hex dock button, value bar with preview ghost, tabs, toggle, slider operable by gamepad, tooltip, chip, scroll, row pool.
- `UIRoot`: one ScreenGui, a responsive design canvas (1280×740 scaled; min scale 0.72, or 0.9 on touch-only devices; modes wide / narrow / short), layers, a panel manager (lazy build, one open, scrim), hotkeys, gamepad back, toasts, confirm dialog.
- `UIData` (one coalesced refresh per frame from ProfileClient/EvolutionClient), `Hud`, `Panels/*`, `EvolutionScreen`, `Onboarding`, `WorldUI`, `SettingsApplier`, `UIController` (isolated boot).
- Small changes to my own modules: CameraController (`SensitivityScale`, `InvertY`), PlanetVisualController (evolution captures API, reduced motion), TravelFX (no FOV push under reduced motion).
  Main boots the UI in place of PlanetLabUI, with a fallback. The gravity debug panel is Studio-only, hidden, toggled with F2.

### Honest scope
- **Expeditions:** no backend exists, so the panel is dormant and there is no dock button. Expedition history shows in Codex → Progress.
- **Settings:** there is no settings store yet (session-only, stated in the panel). There is no music in the game, so there is no music slider.
- **"Claim a planet":** slots are auto-assigned on join, so onboarding step 1 is "Reach your planet" (warp + world marker).

### Tested in Studio Play (mock data store)
- Boot: no errors. PlanetLabUI is not created. The debug panel is hidden.
- HUD shows live values (PLANET 01, Barren World, 250 credits, energy 100/100, LV 1, 6 matter pills, DNA badge 4). The layout avoids the Cosmic Core Hunt banner and Roblox's player list.
- **Real data path:** R01 changed credits 250→280, stage progress 0/2→1/2, onboarding step 1→4, and showed a discovery card ("Ice Impact Site").
  R03 brought stage 0→1 and the evolution screen: before/after viewports render (grey barren → primordial with formations), plus Thermal Crack, +100 credits · +60 XP, Continue. Onboarding then hands over to the stage objective.
- **Panels:** DNA Lab, Inventory, Codex, Harvester and Settings all screenshot with real data.
- **Clipping scan** (every visible TextLabel, HUD + 5 panels): 1 caption clipped, then fixed.
- **Spam:** 60 toggles in 0.65 s, descendants 2616 → 2616, clean closed state afterwards.
- **Respawn:** same single PF_UI, descendants 760 → 760.
- **Gamepad:** every panel button is Selectable with the shared focus ring, the first selection works, and selection clears on close.
- **Responsive:** forced 390×844 portrait gives the narrow layout (compact DNA strip, stacked detail). 844×390 touch gives the short layout (horizontal dock, stacked panels). Desktop 1280×793 gives wide.
- **Bugs found and fixed:**
  - corner brackets inside list layouts inflated the evolution card and the confirm dialog
  - disabled solid buttons looked active
  - the UI drew below the Core Hunt banner
  - the energy micro-bar overlapped its caption
  - ViewportFrames inside a CanvasGroup (switched to a Frame)
- **Not tested by a human yet:** the mouse hover card on planets, custom prompts on a real touch device, real controller hardware, and an actual phone.

## 2026-11-21 (18:10) — Sounds and meshes wired in, key light, future-branch stubs
### Assets (inserted by the user into Workspace, now in `ReplicatedStorage.PF_Assets`)
- **Safety check:** none of the 11 inserted objects contains a script.
- Moved and renamed, not deleted. The original name is kept as `PFSourceName`. Templates get bottom-centre pivots and non-colliding, non-queryable parts; mapping in INTERFACES §7.5.
- `Model` turned out to be a **conifer** (trunk + foliage, 40 studs tall). It is now `TreePine`, used on Frozen planets and in cold polar bands, instead of being removed.
- Default tree: `LowPolyTree` (2 parts, cheaper). Variant: `Low Poly Tree` (3 parts, 1 in 3 trees, plus the World/Ancient Tree landmark).
  The **primitive placeholder trees, volcano cones and box crystals were removed** from `PlanetDecorator`.
- The base crystal (`Crystal`, with Poison emitters) is the Crystal-theme crystal: tinted to the accent and given a soft neon glow, because its dark magenta glass was
  black at night. Its emitters count against the budget (rate ≤ 10). Red → Volcanic, Green → Primordial/Living, Ice → ice spikes and Crystal accents.
- **Bugs found while testing and fixed:**
  - Template pivots had stayed at the bbox centre, so meshes were sunk half their height. Fixed via PrimaryPart.PivotOffset.
  - `Ice Crystal` ships pre-scaled (×2.26) and `ScaleTo` is absolute. It now scales by `tpl:GetScale() * factor`.
  - Verified: tree pivot up · surface normal = 1.000, and the side-view screenshot shows trees standing radially.

### Audio
- New `PF_Client.Audio.Sfx` with a `PF_SFX` SoundGroup.
  - Transformation plays at the start of the stage-up cinematic, Power_Up when the stage lands (or on Skip).
  - Whoosh plays on warp departure and on arrival.
  - Owner hears 2D; visitors hear it positionally from the planet.
- **Play test:** all 3 sounds load. Real path (B's PF_DevHook, mock store): 4 stage-ups gave 4 × Transformation + 4 × Power_Up, all loaded and playing. A warp to the station gave 2 × Whoosh.

### Dark themes — decision (user delegated it): moon key light
- `Lighting.Brightness` 3 → 10. ClockTime 20.5 (native stars) is unchanged.
  - The A/B screenshots show the lit hemispheres of Living/Frozen planets and the tree meshes clearly readable, with no visible change to the sky or station.
- Volcanic: the stage-4 surface material is no longer CrackedLava, which rendered pitch black. It now uses Rock with the dark-brown palette, and the lava glow carries the theme.
- Limitation: the moon direction is fixed, so every planet has a shadowed hemisphere. Option for later: make the moon higher (GeographicLatitude) so the lit side is the top for all 8. That would change the sky, so it needs your OK.
- Alternative kept in reserve: once the baked skybox passes moderation, the stars are in the texture, so the scene could move to a daylight sun key.

### Future branches
- `PlanetVisualProfile.ART_STUBS` for astral/void/desert/mechanical: placeholder palettes on existing builder sets, with `artStub = true` and `themeLabel` (INTERFACES §7.7).

### Measured (Edit preview, full effects; Crystal planet heaviest)
- Build ms per planet: Primordial 0.7 / Terraforming 1.1 / Frozen 5.2 / Volcanic 7.0 / Crystal 15.1 / Living 5.7 / Living st.3 2.6.
  Builds run only when a planet's state changes. Crystal is the outlier because of ~270 cloned mesh parts.
- Part counts (near/far): Frozen 186/47, Volcanic 286/196, Crystal 376/182, Living 173/172. Emitters ≤ 10 per planet.
- Real-path stage-4 Living planet in Play: near 325 / far 212 parts, 10 emitters. Models: 20 TreePine (that planet was cooled to Temperature 8), 10 TreeDefault,
  5 TreeVariant, 17 CrystalIce, 11 CrystalBase.
- FPS: still not measured by a human (TASKS A-3.6).

## 2026-11-21 (16:10) — Planet visual evolution: adapted to B's v2 model and tested
### Changed (my files only. B's modules were read and called through their public/dev APIs, never edited)
- `PlanetVisualProfile`: reads DNA v2 (Water → water/atmosphere, Life → vegetation and atmosphere, CosmicEnergy → glow, Temperature 0..100 → caps/heat).
  Theme comes from `PlanetConfig.BRANCHES[branch].theme`; `None` and future themes get the primordial look. Stage ≤ 4. Uses EvolutionConfig.VISUAL.
  Surfaces are lighter for night readability, and a `rock` tint is added.
- `PlanetVisualContract`: formations as `{id=count}`. Accepts a list, a map, or B's `{n=…}`. Adds `PFLastEffect` (optional).
- `PlanetDecorator`: the **29 FormationRegistry archetypes**, each mapped to a builder. Placement uses zones, footprint, maxCount and dormantOutsideBranch,
  with seed = owner + id + index. The player's own formations are placed first, and generic dressing thins to 60 % when 3 or more exist.
  The atmosphere is now a ForceField rim; the old SmoothPlastic shell made a dark veil at night. Rings are 2 thin neon lines.
  Clouds are lower, self-lit white. Particle budget per planet: 10 full / 6 reduced / 0 minimal.
- `PlanetVisualController`: tints the barren-era detail (boulders, crater rims, spires) to the theme, including detail that streams in later. Originals are weak-keyed.
  The owner's stage-up overlay is compact (Skip only), because B's `PF_TransformationBanner` shows the text.
- `PlanetVisualMock.SHOWCASE`: v2 ids.
- Lighting: tried brighter ambient → no visible effect, so it was **reverted to the approved values**.

### Measured (Studio, Edit preview with PlanetBuilder geometry + Play)
| Planet (showcase) | full near/far parts | reduced | minimal | emitters full | build ms full |
|---|---|---|---|---|---|
| 2 Primordial | 76 / 0 | 52 / 0 | 43 / 0 | 6 | 0.6 |
| 3 Terraforming | 73 / 39 | 59 / 27 | 54 / 23 | 5 | 1.1 |
| 4 Frozen (st.3) | 122 / 47 | 81 / 39 | 50 / 35 | 0 | 1.4 |
| 5 Volcanic (st.4) | 313 / 162 | 193 / 158 | 128 / 158 | 10 (was 22) | 4.4 |
| 6 Crystal (st.4) | 374 / 136 | 240 / 128 | 140 / 124 | 1 | 4.3 |
| 7 Living (st.4) | 235 / 142 | 174 / 130 | 126 / 122 | 1 | 3.6 |
| 8 Living (st.3) | 133 / 37 | 96 / 25 | 68 / 21 | 0 | 1.4 |
- These counts are from the first full pass, before the last fixes (rings 2×48 thin lines, emitter budget). After those fixes only the emitter count was re-measured.
- Total decoration parts, all 8 planets: full 1889 / reduced 1402 / minimal 1092. Only the near folder of the planet you stand on is parented
  (LOD verified in Play: near detail appears at < 520 studs, far only elsewhere).
- Unit tests: Contract round-trip, clamps, all input forms, theme mapping and Profile determinism: **0 failures**. A rebuilt planet is identical (position checksum).
- **Real path (no mock):** B's `PF_DevHook` → reactions R01..R18 → stage 1 → R02 → stage 2 → `branch Living` → stage 3 → R21/R22 (WorldTree capstone) → stage 4.
  Published attributes followed every step, and the client rebuilt each time. At stage 4: 23 registry instances, 0 skipped, near 377 / far 230 parts, 1 emitter.
- **Not measured:** FPS. Studio was unfocused, so it throttled to 15 fps (66.7 ms frames) for every planet. Skip has not been clicked by a human (A-3.6).

### Visual findings (screenshots)
- Frozen reads well. Living / Volcanic / Crystal read **dark from orbit** under the night lighting, and their detail shows mainly at the limb (A-3.7).
- The first pass looked bad and was fixed: a loud cyan ring band, lavender "ball" clouds, and a dark atmosphere veil.

## 2026-11-21 (12:30) — Planet visual evolution system: implemented, NOT yet tested (Studio connection lost)
### Built in Studio (my files only; nothing of Developer B's was modified)
- `PF_Shared.Planet.PlanetVisualContract`: the public visual state as slot attributes (INTERFACES §7, proposal v1.3).
- `PF_Shared.Planet.PlanetVisualProfile`: pure state → visual spec. Stages 0–5 (supports B's new 0–4). Themes barren, primordial, living, frozen,
  volcanic, crystal. Seed comes from ownerUserId, so a planet looks the same in every server.
- `PF_Server.Services.PlanetVisualPublisher` (+1 entry in Main ORDER): production adapter over B's PlanetDataService (read-only use).
- `ServerStorage.PF_DevTools.PlanetVisualMock`: Studio-only mock, writes unclaimed slots only, with an 8-planet showcase. Not used by production.
- `PF_Client.Planet.PlanetDecorator`: everything placed on the true sphere (normal frames, sagitta sinking), deterministic, with an overlap test and exclusions for
  the pole pad, spawn, Gravity Harvester (HarvestLayout) and the spawn→harvester corridor. Layers: atmosphere shell, polar caps, water,
  clouds, vents, glowing fissures, spires, biome patches, formations (trees, glowing mushrooms, flowers, ice clusters, glaciers, volcanoes with lava rivers,
  crystal clusters with neon cores), 4 landmarks (World Tree + waterfall Beam, Glacier Spire, Mega Volcano, Prism Heart + energy ring), aurora Beams,
  rings, moonlet, ForceField aura, sparkle/smoke particles. Primitives and built-in materials only (Grass, Glacier, Ice, Snow, Basalt, CrackedLava,
  Glass, Neon, ForceField) and built-in particle textures. **No external assets.** All parts are non-colliding and non-queryable, so movement is unaffected.
- `PF_Client.Planet.PlanetVisualController`: re-renders on `PFVisualRevision`. Far/near LOD (near < 520 studs). Local recolour of Core/maria.
  Transformation on a stage increase: light pulse, surface colour tween, formations emerging, atmosphere fade-in, banner with a **Skip** button.
  Effects levels full / reduced / minimal (touch-only devices default to reduced). The debug panel has a new "Effects:" button. Labels and dock signs show owner and stage.
- Every PF script compiled (loadstring check) **except B's `ReactionRegistry`** (Q5).

### What happened during the work
- Developer B changed the data model **while this was being built**: DNA is now Temperature/Water/Life/CosmicEnergy (0..100), branches are
  None/Living/Frozen/Volcanic/Crystal (+ future), max stage is 4, formations are counts with a `FormationRegistry` (29 archetypes), and EvolutionConfig.VISUAL
  was added. My modules still run (unknown values fall back to defaults; old branch ids are also mapped), but they **don't yet use** the new DNA names or
  FormationRegistry. See TASKS A-3.x.
- The Studio connection dropped before any playtest. **Nothing in this section has been run or screenshotted yet.**

## 2026-11-21 (01:40) — Black sky fixed, self-activating skybox
- **Cause of the black sky (from the user's screenshot):** Lighting contained TWO Skies: `PF_Sky` and a `Sky` with Zalthen's PurpleNebula
  decals (the Creator Store model had been inserted again). Roblox picked the Zalthen one, whose images don't load, so the sky was black. That Sky was moved to
  `ServerStorage.PF_Deprecated` as `Sky_ExtraSky_MovedAside`, not deleted. No script recreates Skies (checked).
- **The PF_Sky images had never been uploaded.** The Asset Manager showed only Zalthen assets. The 6 PNGs were saved to
  `C:\Users\satro\Downloads\PlanetForge_Skybox\` and imported by the user. A real-client probe shows the new IDs exist (failure without
  "not found", consistent with moderation pending), while the earlier IDs were typos ("asset not found").
- **New `Environment/SkyActivator` (client):** reads `PF_Sky` attributes `PFPending_*`, applies the 6 faces locally only when **all** load,
  then sets StarCount to 0. Otherwise it keeps the native night sky and retries every 90 s (max 40 attempts). The sky can't go black or grey from a broken image.
  Verified: currently "not loadable yet", native sky active, no errors.

## 2026-11-21 (later) — Phase 2 fixes
- **Camera jump after warp fixed.** Added `CameraController.snapBehind()` and `GravityController.resetFacing()`, called from
  `TravelFX.onArrive` while the overlay is opaque, and 0.4 s after every respawn. Measured over 4 warps: camera behind the character (dot 1.000),
  pitch 20°, total rotation during the fade-in ≤ 0.3°.
- **Sky disappearing / nebula balls: root cause.** Roblox's automatic graphics quality changes the client render distance at runtime, so any sky
  made of far geometry can drop out. **ADR-022: the backdrop is a baked skybox** (6 × 1024² PNGs generated procedurally by
  `tools/gen_skybox.py`: a seamless function of direction with a nebula band, dust lanes, 9000 stars, 3 galaxies, moon glow and a lit ringed gas giant).
  The images are uploaded from the owner's account, so the rights are clean and they always load in the owner's experience. With
  `PF_Sky:SetAttribute("PFBakedBackdrop", true)` the client skips the nebula, gas giant and silhouette geometry. Asteroids, dust and shooting stars remain.
- **Status:** the owner imported the 6 images (IDs stored as `PF_Sky` attributes `PFPending_Ft..Dn`). A real-client probe reported
  *"Request asset was not found"* for all 6, which means moderation is pending or an ID was copied wrong. **Current fallback:** native night sky
  (StarCount 5000) with `PFBakedBackdrop = true`, so the ball nebulae no longer appear. To activate: copy each `PFPending_*` attribute into
  `Skybox*`, set StarCount to 0, and verify with a client probe.

## 2026-11-21 — Phase 2: visual foundation of the 8-planet world (Developer A scope)
### Built in Studio (place NOT published; code lives only in the place, so save it with File > Save)
- **8 barren planets** (`WorldLayout.ACTIVE_SLOTS = 1..8`, ring radius 1100, R = 96). PlanetBuilder now splits each planet into:
  - `PF_World.Planets.Slot_n` (Persistent, about 46 parts): core Ball, maria basins (clusters of ≤14-stud discs so no edge lifts),
    north-pole return pad + sparkles, invisible `SpawnPoint` (`PFSpawnFor`), BillboardGui label (`Title`/`Owner`), and the ownership
    attributes `PFOwnerUserId=0`, `PFOwnerName=""`, `PFClaimState="unclaimed"`, `PFTheme="barren"`, `PFStage=0`.
  - `PF_World.PlanetDetail.Slot_n_Detail` (Atomic, streamed, ~260 parts): craters with irregular rims, 6 rock formations, 22 boulders.
  - Materials are Rock, Slate and Basalt only. No biome content (enforced by a unit test).
- **THE FORGE** (`World/StationBuilder`, 680 parts, Persistent, primitives only, no toolbox assets):
  - plaza Ø170 with cyan/violet inlay rings and 8 slot-coloured floor guide lines
  - fusion reactor (core, ForceField shell, 3 containment rings, cage pylons with beams, cap, spire)
  - stepped hull with neon bands and fins
  - 8 docks (bridge, glass rails, gate with "PLANET 0n / UNCLAIMED" sign, coloured warp pad at r=106)
  - Planet Lab (glass dome + globe), Meteor Research terminal (containment frame + sample), Planet Network hologram (8 slot-coloured mini planets)
  - Rift Expeditions portal (offline), Cosmetics kiosk ("opening soon"), 3 double-sided directory pylons
  - 7 PointLights, all with shadows off
- **Teleport network**: dock pad → planet spawn; planet pole pad → that planet's dock arrival (`WorldLayout.getStationArrival`).
  Server sends `Travel_Transition` out → 0.35 s → one PivotTo → `Fx_Play` arrive → `Travel_Transition` in. The client (`Environment/TravelFX`)
  does a cyan/violet flash, an FOV push and "WARPING · PLANET 0n" text, then fades back in, with a 2.5 s failsafe. Arrival rings are pooled (4).
- **Client animation** (`Environment/StationFX`): models with `PFSpin` rotate via one `BulkMoveTo` per frame, only within 450 studs of the station.
- **Background** (`Environment/SpaceBackdrop`) and **lighting**, see ADR-019. Lighting values approved by the user in a live session:
  ClockTime 20.5, Latitude 35, Brightness 3, Exposure 0.25, Ambient (46,42,76), OutdoorAmbient (74,66,116), EnvDiffuse 0.15,
  EnvSpecular 0.35, ColorCorrection contrast 0.14 / saturation 0.18 / brightness 0.02, Bloom 0.5 / 24 / 1.7.
  `PF_Sky`: StarCount 5000, CelestialBodiesShown true, MoonAngularSize 4.
- `Workspace.StreamingTargetRadius` 1024 → **640**, so only the nearest planet's detail streams in.
- Moved aside (not deleted): original Sky, Atmosphere, DepthOfField and SunRays are in `ServerStorage.PF_Deprecated` (`*_OriginalDefault`).
- Two Creator Store skyboxes by "Zalthen" were inserted into a quarantine folder for inspection. They were Sky instances only, with no scripts.
  Their textures failed to load, so they were **removed**. **No external assets are used.**

### Decisions
- **ADR-019 Accepted: the background has no external images and stays inside the client render distance.** In order:
  1. Creator Store skybox textures failed to load in this session (11 of 12 in a real client LocalScript; Roblox's own default ids also failed).
  2. A 24-tile SurfaceGui sky cube at 2040 studs looked right in Edit but **was not drawn by the play client**.
  3. Decals at 2300 studs: not drawn either.
  4. Measured cause: **the play client stops drawing geometry somewhere between 1500 and ~2000 studs.** Nebulae at 1500 became visible; the gas giant at ~1970 was on the edge.
  The final design: the base layer is the native night sky (always rendered). The enhancement layer is a **camera-locked shell at 1400 studs**
  (nebula glow balls, galaxies, moon glow, the gas giant system and a silhouette world scaled to 70%). An asteroid belt follows at 0.35 parallax.
  **Consequence for gameplay:** with 8 planets at radius 1100, a player on one planet is up to ~2300 studs from the farthest planet. That planet
  may not render on some devices or quality levels. This must be measured on real phones (task A-2.6).
- **ADR-020 Accepted: LOD by streaming.** Planet core, pads, labels and station are Persistent. Planet detail is Atomic and streams with
  radius 640 (measured: only the visited planet's detail is present).
- **ADR-021 Accepted (A↔B contract v1.2):** new S→C `Travel_Transition {phase, destination, duration}`. `Fx_Play` (UnreliableRemoteEvent)
  payload is now `{fxId: "warp_depart"|"warp_arrive", position: Vector3}`.

### Verification performed (MCP, single client; the user confirmed the visuals by eye where screenshots failed)
| Test | Result |
|---|---|
| Unit tests (TestRunner now loads nested modules fresh): 9 gravity + 5 world specs | **14/14 pass** |
| Planet count / ownership slots (server) | 8 × `Slot_n`, all owner=0, theme=barren, SpawnPoint present |
| Round trip to **all 8 planets** (warp → planet → walk onto the pole pad → station) | 8/8. Arrival altitude 3.00, upright 1.000, fade out>in, detail streamed; returned to dock n within 0.6–1.9 studs |
| Walk from the reactor along each floor line to **every dock pad** | 8/8 warped after 5.8–6.1 s, 0 s stuck (routes are clear) |
| Standing at 24 points (8 planets × 3, including bottom hemispheres) | max \|alt−3\| = 0.00, upright 1.000, all grounded |
| Plaza railing / walking into a district | stopped at r=83.6 (edge 85) / stopped at the Planet Lab sign, never launched |
| Leak check after ~30 warps | effect pool stays at 4, no growth in PlayerGui or ClientFX |
| Server | physics 60 Hz; world = 680 + 368 + 2080 parts; build time 23 ms (edit-mode measurement) |
| Streaming | at the station only 1 detail model streamed; on planet n its detail was present on arrival |
| Console | no PF errors after fixing a Luau parse error found in testing (`;` at the start of a block) |
| Screenshots (Edit) | station overview and plaza at eye level, planet orbit and surface views, gas giant and backdrop. Found and fixed: gas-giant "lid", sky seams, sun-halo clipping, plates sticking out of the planet silhouette, bright plaza floor, stray spawn plate, one-sided directory pylons |
| Lighting in play | tuned live with the user over 4 rounds: washed out → too dark → still dark → **approved** |

**Not done / not verified:**
- Two simultaneous players.
- Real phones. A Device Simulator run failed: the orientation call errored, and play-mode screenshots were blank.
- Gamepad.
- The final camera-locked sky: the user reported it is visible but **"nebulae look like balls"**.
- The warp arrival: the user reported **"camera jumps / looks wrong after arrival"**.
- **The Studio connection dropped before these two issues could be fixed. A playtest may still be running in Studio, so stop it.**
- Studio's `screen_capture` with camera parameters doesn't move the camera, and the viewport stops rendering when the window loses focus.

## 2026-11-20 — Phase 1: spherical planet + gravity controller prototype (Developer A scope)
### Changes made in Studio (place not published)
- Moved `Workspace.Baseplate` and `Workspace.SpawnLocation` into `ServerStorage.PF_Deprecated`. Nothing was deleted.
- `StarterPlayer.EnableMouseLockOption = false`. Shift-lock fights the custom camera.
- New code (all `--!strict`):
  - `ReplicatedStorage.PF_Shared.Config.WorldLayout` (A)
  - `ReplicatedStorage.PF_Shared.Gravity.GravityFields` (A, pure)
  - `ServerScriptService.PF_Server.Main` (J)
  - `PF_Server.Services.WorldService` (A)
  - `PF_Server.Services.CharacterService` (A)
  - `PF_Server.World.PlanetBuilder` (A)
  - `StarterPlayerScripts.PF_Client.Main` (J)
  - `PF_Client.Controllers.GravityController`, `CameraController` and `CharacterAnimator` (A)
  - `PF_Client.UI.GravityDebugPanel` (A)
  - `ServerStorage.PF_Tests.TestRunner` and `Gravity.spec`
- The runtime world is built at boot as `Workspace.PF_World/{Station, Planets/Slot_1}`. Nothing world-related is stored in the place file.

### Decisions
- **ADR-004 Accepted (was Pending spike): custom force-based controller, not ControllerManager.**
  - `Humanoid.EvaluateStateMachine = false`.
  - One world-space `VectorForce` cancels Workspace.Gravity, adds field gravity, a clamped hover spring and the move acceleration.
  - One `AlignOrientation` (OneAttachment) keeps the up direction on the surface normal.
  - Jump is a single `ApplyImpulse`. Ground detection is a raycast along -up.
  - Limbs are non-colliding; only the root collides.
  - Why not ControllerManager: AirController has documented UpDirection bugs, and every force here is our own math, so it can be tested.
- **ADR-014 Accepted: prototype planet radius 96** (the task asked for 85–100). Spec §7's radius of 180 gets revisited after perf tests. The planet is a Ball part, so collision is mathematically exact.
- **ADR-015 Accepted: input comes from the 2026 PlayerModule's Input Action System.** The new `StarterPlayer.PlayerModule` has
  no `GetControls()`, and it does not write `Humanoid.Jump` while the state machine is off. We read
  `StarterPlayer.PlayerModule.InputContexts.CharacterContext.MoveAction` / `JumpAction` with `GetState()`, plus a
  `JumpAction.Pressed` jump buffer of 0.15 s. The legacy `PlayerScripts.PlayerModule:GetControls()` path is kept as a fallback.
  **Risk:** this is Roblox-owned internal structure, and the instance names could change in an engine update. Only the
  `resolveInput()` function in GravityController depends on it.
- **ADR-016 Accepted: the server owns spawning.** `Players.CharacterAutoLoads = false` is set at runtime by CharacterService.
  Respawn happens exactly once per character after `Players.RespawnTime`. The Roblox menu "Reset" is routed through `ResetButtonCallback` to a
  server-authoritative `Character_Recover{mode="respawn"}`.
- **ADR-017 Accepted: recovery is layered.** The server returns a character to its spawn target after 2.5 s in space (no field), on NaN positions,
  or below the safety floor. The client requests recovery if it is clipped more than 1.5 studs into a planet or airborne for more than 8 s.
  Warp pads are distance-polled on the server at 4 Hz rather than Touched-based, because hover characters barely touch the ground.
- **ADR-018 Accepted (temporary): prototype networking.** CharacterService creates `PF_Remotes` with inline validation and a 1 s cooldown.
  It gets replaced by Net/RemoteGuard in M0. The contract is added in INTERFACES.md v1.1.

### Verification performed (all through MCP in this session; single local client)
| # | Test | Result |
|---|---|---|
| 1 | Unit tests (TestRunner, 9 cases): layout, frames at the poles, field sampling top/side/bottom/space/NaN, spawn on surface, PlanetBuilder determinism and budget (≤260 parts), queryability | **9/9 pass** |
| 2 | Edit-time screenshot of the planet | Full sphere with crater detail, confirmed visually |
| 3 | Idle on the top, side and bottom hemisphere (2 s each) | Altitude 3.00 ±0.00, upright 1.000, 0 drift |
| 4 | Walk on the side, bottom and diagonal (5 s), 12 s loop | Altitude 3.00–3.01, 100% grounded, 16 studs/s |
| 5 | Walk over the **south pole** (latitude -89.7°) and a full **367° loop** | Altitude 3.00, upright 1.000, grounded 301/301 and 586/586, camera max turn 2.09°/frame (no flip) |
| 6 | Jumps on the top, side, bottom and while running | Peak 8.89 studs, landing in about 0.7 s, upright after landing |
| 7 | Station jump (uniform gravity) | Peak 7.33 studs, lands cleanly |
| 8 | **Real keyboard input** via MCP: W, D, Space (150 ms) | Moved 51.6 studs; jump peak 9 studs. A 0 ms synthetic tap was missed, so the jump buffer was added and re-verified |
| 9 | Boulders (the 3 tallest) | Character is blocked, no launch (max altitude 3.05). The first version launched the character, fixed with the spring clamp |
| 10 | Flung at 400 studs/s / walking off the deck edge | Returned to the spawn target by the server in under 4.6 s / 6 s |
| 11 | Clipped 10 studs inside the planet | Recovered within 1.5 s |
| 12 | Dropped upside-down 25 studs above the side | Upright after 0.45 s, landed at 0.76 s |
| 13 | Sit, PlatformStand, 40 rad/s spin | No effect on the controller; upright 1.000 |
| 14 | Death (Health = 0) → respawn; remote respawn | New character after 3.5 s / 0.43 s, controller re-attached, spawns at the last warp target |
| 15 | Travel_Warp OK / inactive slot / spam / garbage | OK / INVALID_PAYLOAD / RATE_LIMITED / silently dropped |
| 16 | Station warp pad walked onto | Arrives on the planet |
| 17 | Orbit view (O key) and back | Distance 326.4 studs (3.4R), looking at the centre (dot 1.0000), auto-spin; follow mode restored |
| 18 | Server view of the character on the lower hemisphere | Upright 1.000, altitude 3.00, network owner = player |
| 19 | Animations idle/walk/jump/fall | Correct; a stray Animate idle track was found and fixed |
| 20 | Console in every playtest | Only `[PF] server booted` / `[PF] client booted`. The first run caught an infinite yield on the old PlayerModule path, which is fixed |

**Not tested:**
- Two simultaneous clients. MCP can only start a single-client Play session. The server-side replication check (#18) is the proxy for now.
- Touch input on a real device or the emulator. The thumbstick and jump button feed the same MoveAction/JumpAction as the keyboard, but this hasn't been observed.
- Gamepad.
- Visual camera feel. `screen_capture` only works in Edit mode, so the camera was verified numerically only.
- Station-to-planet transition by walking. They are 1100 studs apart, so the transition only happens through warps or by drifting into space.

## 2026-11-20 — Phase 0: architecture
### Verification performed
- Connected to Roblox Studio through MCP. Instance "PLANET FORGE: COSMIC EVOLUTION", placeId 79132282456701,
  GameId 10778085398, user-owned. Note: the Studio session id changed mid-session and the instance title
  changed from "PLANET FORGE" to the full name. The placeId matched, so it is the same place.
- Read-only inspection with `search_game_tree` and `execute_luau`. Workspace holds Baseplate, SpawnLocation and an empty Terrain.
  Lighting has Sky, SunRays, Atmosphere, Bloom and DepthOfField. There are **0 user scripts**. StreamingEnabled is on with radius 1024,
  Gravity is 196.2, FallenPartsDestroyHeight is -500, MaxPlayers is 60, and HttpEnabled is false.
- **No changes were made to the place.** Nothing was published, created or deleted.
- The documents were not tested as code, because no code exists yet. Contracts are cross-checked by hand for name consistency.

### Decisions
- **ADR-001 Accepted: server-authoritative, intent-based networking.** Clients send intents with a requestId
  and the server replies with `Action_Result`. There are no RemoteFunctions in v1.
- **ADR-002 Proposed (needs human install): Git + Rojo 7 is the source of truth for code.** The repo is canonical.
  Studio-authored assets are exported to `assets/*.rbxm`. The fallback is Team Create plus manual export.
- **ADR-003 Accepted: state is data, visuals are derived.** B emits serializable state and A renders it
  deterministically from `(seed, affinity, features, cosmetics)`. Planet decorations are client-local
  with LOD. Only the slot core is replicated.
- **ADR-004 Pending spike (M1): spherical gravity.** Roblox gravity is a single global vector, so walking on
  spheres needs a custom controller. The primary candidate is the `ControllerManager` character controller
  (documented `UpDirection`), with a fallback of `VectorForce` + `AlignOrientation` on the HumanoidRootPart.
  Neither has been tested in this place yet. **This is the #1 technical risk.**
  Verified on 2026-11-20 against create.roblox.com: `ControllerManager.UpDirection: Vector3` exists. Per
  DevForum, UpDirection only orients the RootPart, so radial gravity must still be applied manually, for example
  with a VectorForce. There are also open bug reports that `AirController` ignores UpDirection during jumps and falls.
  The spike must test jumping specifically. A known workaround is to reset `ActiveController` after
  changing UpDirection.
- **ADR-005 Accepted: world anchored at Y = +3000.** The station is at (0, 3000, 0), the 8 slots are on a ring with
  radius 1100, and planet radius is 180. This stays clear of FallenPartsDestroyHeight -500 without changing it.
- **ADR-006 Accepted: keep StreamingEnabled.** Slot core models and the station use ModelStreamingMode
  Persistent. Everything else streams.
- **ADR-007 Accepted: meteors are server data, not server parts.** Each player has a cap of 12. The server validates
  harvest range against its own kinematics and the server-side character position.
- **ADR-008 Pending human: persistence library.** ProfileStore (third-party, MIT) is recommended for
  session locking. The fallback is a hand-rolled UpdateAsync lock behind the same `StoreAdapter`.
- **ADR-009 Accepted: data safety.** MockStore is the Studio default. Real stores are suffixed `_DEV` / `_PROD`.
  A failed load means no save for that session, and data from a future schema is read-only.
- **ADR-010 Accepted: ids are permanent.** Def ids are stored in player data, so they are never renamed.
- **ADR-011 Accepted: no third-party UI framework in v1.** Use vanilla Instances plus UIScale/constraints.
  This can be revisited in M5.
- **ADR-012 Accepted: monetization is stub-only.** No products or passes get created by Claude. M11 works against
  test products that the human creates.
- **ADR-013 Accepted: MVP travel uses warp gates.** Free flight is deferred to M8.

### Open decisions (need the human)
- **U-1** Install Rojo/Rokit and create a Git repo? Who hosts it?
- **U-2** Approve ProfileStore (third-party code) or use the in-house lock?
- **U-3** Create a separate **staging/dev experience** so dev DataStores are fully isolated from production
  (strongly recommended before M6). This is an account action.
- **U-4** Enable "Studio Access to API Services" for the dev experience in M6. Leave it off until then.
- **U-5** Set MaxPlayers to 8 (Game Settings).
- **U-6** Is the planet name shown to others in M10? That requires TextService filtering and age/policy checks.
- **U-7** Which device tiers are the minimum targets (low-end Android included)? This sets the LOD budgets.
- **U-8** Monetization philosophy: cosmetic-only (recommended) or progression boosts?
