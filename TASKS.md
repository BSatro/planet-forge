# TASKS.md — work queue

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `(H)` needs the human (not Claude)

## Phase 0 — Architecture (this phase)
- [x] Read-only inspection of the place and the MCP capabilities (2026-11-20)
- [x] PROJECT_SPEC.md, INTERFACES.md, CLAUDE.md, TASKS.md, CHANGELOG.md drafted
- [ ] (H) Both developers review and accept the contracts (INTERFACES.md v1)
- [ ] (H) Decide U-1…U-8 in CHANGELOG.md "Open decisions"

## Human setup (blocking M0 with Rojo)
- [ ] (H) Create a private GitHub repo `planet-forge` and commit these 5 docs
- [ ] (H) Install Rokit (or Aftman) + Rojo 7 + the Rojo Studio plugin on both machines
- [ ] (H) Save a local copy of the place (File > Save to File) for Rojo sync. Don't sync into the published place.
- [ ] (H) Game Settings: set Max Players to 8 (publishing setting, so the human does it)
- [ ] (H) In the Claude desktop app, connect the repo folder ("Add folder") so Claude can edit files directly

## M0 — Skeleton
Repo bootstrap (2026-11-24, see CHANGELOG)
- [x] M0.0a `default.project.json` (Rojo 7.5.1 via rokit.toml): code containers only; every other instance stays place-owned
- [x] M0.0b Extracted all 163 scripts from `place/planet-forge.rbxl` (saved 2026-11-24 18:54) into `src/` + `tests/`, verified byte-for-byte
- [ ] (H) M0.0c First `rojo serve` + Studio plugin Connect against the **local** place copy: the initial diff should show 0 changes. Then commit
- [ ] (H) M0.0d Export `ReplicatedStorage.PF_Assets` to `assets/*.rbxm` (ADR-002) — still place-owned for now
- [ ] M0.0e Reconcile B-0.x / A-0.x below with the code that already exists (no `Contracts/`, `Net`, `Trove`, `Validate`, `Seed` yet; `RemoteGuard` lives in `src/server/Net/`)
Developer B
- [ ] B-0.1 `Contracts/Types`, `Remotes`, `ResultCodes`, `Version` exactly as in INTERFACES.md
- [ ] B-0.2 `Util/Signal`, `Util/Trove`, `Util/Validate`, `Util/Seed`
- [ ] B-0.3 `Net` (server creates remotes from the contract, client resolves) + `RemoteGuard` (token bucket)
- [ ] B-0.4 `tests/TestRunner` (clone-before-require, describe/it/expect minimal API) + specs for Validate, RemoteGuard, and the contract self-check
- [ ] B-0.5 `Main.server.luau` boot (Init → Start, with errors isolated per service)
Developer A
- [ ] A-0.1 `WorldLayout` + spec (8 distinct slots, no overlap, all above Y = 0)
- [ ] A-0.2 `Main.client.luau` boot + empty controllers with Init/Start
- [ ] A-0.3 `VisualRegistry`/`IconRegistry` with `vis_placeholder`/`ico_placeholder`
Exit: Play shows 0 errors; the TestRunner passes; `PF_Remotes` contains every contract name.

## Phase 1 — Spherical planet prototype (done 2026-11-20, see CHANGELOG)
- [x] A-1.1 Gravity controller (ADR-004 accepted): walk, jump and the poles verified numerically through MCP
- [x] A-1.2 Camera with parallel-transported up, plus orbit view
- [x] Spawn, respawn and recovery (CharacterService); warp pads; debug panel; PlanetBuilder; 9 unit tests
- [ ] (H) **Manual check by a human**: play on PC and check the camera feel. Open the Device Emulator (phone) and check the
      thumbstick and jump button. Run Test > Clients and Servers with 2 players and watch each other on the lower hemisphere.
- [ ] A-1.3 Gamepad test (right stick camera, ButtonY orbit)
- [ ] A-1.4 Step-up onto small boulders (currently they block; decide whether ≤2-stud boulders should be walk-over)
- [ ] A-1.5 Camera: pull-in on collision is instant; add a smooth return

## Phase 2 — Visual foundation (2026-11-21, see CHANGELOG)
- [x] 8 barren planets with LOD split, metadata, spawn points and labels; THE FORGE; teleport network; lighting; client backdrop
- [ ] (H) **File > Save** the place. All Phase 1–2 code exists only inside the place, and no repo is connected yet.
- [x] A-2.1 (done 2026-11-21, measured: camera exactly behind the character on arrival, ≤0.3° rotation during fade-in) **Fix "camera jumps after arrival"**: add `CameraController.snapBehind()` (align `ref` to the new up instantly and set yaw so the
      camera is behind the root's LookVector) and `GravityController.resetFacing()` (facing = root.CFrame.LookVector). Call both from
      TravelFX on `Travel_Transition{phase="in"}` while the screen is still white.
- [~] A-2.2 (images uploaded; SkyActivator switches automatically once moderation approves them; then check Up/Dn orientation and seams) **Fix "nebulae look like balls"**: replace the glow balls in the camera-locked shell with ParticleEmitters (bundled
      smoke texture, LockedToPart = true, large sizes, Rate = count/Lifetime). Particles are made for soft clouds. Keep the shell within 1400 studs.
- [ ] A-2.3 Smooth planet horizon: the Ball tessellation shows as a polygonal horizon at player height. Option: a high-poly sphere MeshPart
      uploaded by the team (owned asset) as the visual layer, with the Ball kept as invisible exact collision.
- [ ] A-2.4 Decide whether ≤2-stud boulders should be walk-over instead of blocking (carried over from A-1.4).
- [ ] A-2.5 Device Simulator check on a phone, after fixing the orientation call (only call SetOrientationAsync after SetDeviceAsync on a phone).
- [ ] A-2.6 **Measure render distance on a real low-end phone**: are all 8 planets visible from the far side? If not, either shrink
      ORBIT_RADIUS (e.g. 750, which keeps the gravity fields 480+ apart) or add camera-locked impostors for far planets.
- [ ] J-2.7 Integration check with Developer B's new profile/dev-command scripts (seen in the console: `[PF][Profile] ... -> slot 1`).
      Confirm PlanetService writes `PFOwnerUserId`/`PFOwnerName` and the label/dock sign texts.

## Phase 10 — Planet scale rework (2026-11-23, see CHANGELOG)
- [x] S-10.1 ADR-014 revised: `PLANET_RADIUS = 160` (180 would overlap gravity fields at ORBIT_RADIUS 1100)
- [x] S-10.2 Real-scale props: virtual-sphere build + `ScaleTo` by tier; decorator props 0.62
- [x] S-10.3 `FormationDensity`: DNA-driven, bounded, deterministic counts + variety; contract unchanged (`spec.dna`)
- [x] S-10.4 Per-instance cost cuts (lean / satellite art), then ShallowOcean 5→4 and PlasmaFissures 3→2 sites; planet visuals inside the old budget (worst case +4682 parts / +5319 instances vs +4778 / +5328)
- [x] S-10.5 PlanetScale.spec (7 cases); full suite 150/150; compile 157/0; live walk, harvester capture, LOD
- [ ] (H) S-10.6 Decide on barren-detail streaming (total Workspace still ~10% over the old total because 4 `PlanetDetail` models stream in at the station): non-atomic streaming vs fewer craters
- [ ] (H) S-10.7 Slot 1: harvester straight across the pole from spawn — the direct walk crosses the return pad (pre-existing); approve the azimuth rule change
- [ ] S-10.8 Visual pass from the station and the surface on a focused Studio (station screenshot not possible from tooling); consider fading the atmosphere shell in near LOD

## Phase 9 — Controlled private test (2026-11-22, see QA doc "Private-test readiness pass")
- [x] P-9.1 Checkpoint version 126; identity + visibility verified (PRIVATE)
- [x] P-9.2 D1 prepared-not-active; dev commands on live need TEST_UNIVERSE_IDS; D1.spec updated
- [x] P-9.3 Skybox loader fixed (images Approved); store notice (I6); Cosmic Events gamepad focus (I3)
- [x] P-9.4 PF_PersistenceProbe (mock 12/12; refuses on the production universe)
- [ ] (H) P-9.5 Create the private test experience (Publish As → new experience), list it in TEST_UNIVERSE_IDS, set STUDIO_BACKEND="test" in that copy, enable Studio API access there, run the probe in test mode (expect 12 PASS)
- [ ] (H) P-9.6 Multiplayer plan M1–M12 with 2 then 8 clients
- [ ] (H) P-9.7 Visual check of the baked sky; rift final-phase playtest; device + gamepad pass
- [ ] (H) P-9.8 After P-9.5–9.7: owner confirms → activate production (one line) → D1.spec → save → owner publishes

## Phase 8 — Retention and content (2026-11-22, priority list from the automated session)
- [x] F-8.1 Skybox: native night sky default, single attempt for the baked images (no retry loop)
- [x] F-8.2 "Plugin icon" 125921838360800: not in the place (Studio plugin), nothing to fix in the game
- [x] F-8.3 Scene/performance analysis + far-LOD ring segments 96 → 64 per ringed planet (−17 % client parts with 7 developed planets)
- [ ] (H) Q-7.8a **Real DataStore test** needs a separate PRIVATE test experience (owner action):
      1. File → Publish to Roblox As… → *new* experience (e.g. "PLANET FORGE TEST"), keep it private
      2. Put its universe id in `DataConfig.TEST_UNIVERSE_IDS` and set `DataConfig.STUDIO_BACKEND = "test"` *in that copy only*
      3. Its Game Settings → Security → enable Studio Access to API Services (never on the production universe)
      4. Play: the console must say `environment=test … store=PF_TEST_Profiles_v1`. Then run Q-7.8: load/save/rejoin, slot allocation, migration (seed an old profile with the DataStore editor), shutdown save, a two-server session lock (published test experience, same account on 2 devices)
- [x] L-8.4 **Daily/weekly quests** (INTERFACES §11): config, pure rules + spec, QuestService, panel, notifier, badge, telemetry
- [ ] L-8.5 Friend planet visits + leaderboards (server leaderboards first; global OrderedDataStore boards after the real-DataStore test)
- [ ] (H) L-8.6 Badges: the owner creates the badges on Creator Hub; then BadgeService wiring with ids in config (like monetization: nothing advertised while unconfigured)
- [ ] L-8.7 Co-op harvesting (`HarvestConfig.COOP.ENABLED`): wire + test (rifts are already co-op)
- [ ] L-8.8 Harvest expansions: the comet `redirect` behaviour and "Anomaly" targets are design-only today (no code yet)
- [ ] C-8.9 Future branches Astral / Void / Desert / Mechanical; C-8.10 music layer; C-8.11 wire the PF_Assets models + Transformation / Power_Up / Whoosh sounds
- [ ] Q-8.12 Device Simulator + real-device pass (Q-7.7); Q-8.13 add `Rift.spec` (RiftRules is the only untested rules module)

## Phase 7 — QA, security and release (2026-11-21, report: Claude Doc "PLANET FORGE — QA Audit & Release Checklist")
- [x] Q-7.1 Full audit: world, evolution, harvesting, rifts, events, interface, security, persistence, performance, monetization
- [x] Q-7.2 Fixed and retested D3–D7. Specs 109/109, compile check 141/0
- [x] Q-7.3 Analytics: TelemetryService (onboarding funnel, milestones, discoveries, Store funnel, Credits economy)
- [~] (H) Q-7.4 **D1:** production PREPARED, not active (`PRODUCTION_UNIVERSE_ID_PENDING = 10778085398`). Activate only after owner confirmation + Q-7.8 pass: set `PRODUCTION_UNIVERSE_IDS = { PRODUCTION_UNIVERSE_ID_PENDING }`, run D1.spec, save, publish
- [x] Q-7.5 **D2:** server size is 8 on Roblox (Open Cloud place read, 2026-11-22). Re-check: Creator Dashboard → Creations → PLANET FORGE → Places → start place → Access → Server Size = 8
- [ ] (H) Q-7.6 Multi-client pass (Studio Test → Clients and Servers, 2 then 8): own planets, home warp (D6), co-op rift, convergence, reactions, rejoin
- [ ] (H) Q-7.7 Real devices (low-end Android, iPhone, iPad, PC, gamepad): layout, controller navigation, MicroProfiler with 8 developed planets + an event
- [ ] (H) Q-7.8 Live DataStore pass in a separate private test experience (never production): leave/rejoin, shutdown, two-server session lock, crash recovery
- [ ] (H) Q-7.9 Create passes/products on Creator Hub, enter their IDs in MonetizationConfig, then repeat the purchase tests. Otherwise hide the Store until something is for sale (I6)
- [ ] Q-7.10 After a private publish: check the analytics dashboards (onboarding + Store funnels, custom events, economy)
- [ ] Q-7.11 Polish: Cosmic Events panel first controller selection (I3); skybox moderation (I2); human playtest of the rift final-phase sweepers (I5)

## Phase 6 — Cosmic world events + social (2026-11-21)
- [x] L-6.1 Meteor Shower, Solar Storm, Cosmic Convergence: config, pure rules, scheduler, server runtime, client mirror/HUD/panel
- [x] L-6.2 Visits, presence, reactions (abuse-protected), Planet Showcase camera, read-only Planets panel. No trading (needs scam protection + economy review)
- [x] L-6.3 Developer test mode (F3 strip, PF_EventHook, test-mode scaling) and the Developer A VFX guide (INTERFACES §9.1)
- [ ] A-6.4 Developer A: production effects via `EventFx.register` (meteor model at `PF_Assets.Events.Meteor`)
- [ ] L-6.5 Multi-client checks of events and social (covered by Q-7.6)

## Phase 5 — Cosmic Rifts (2026-11-21)
- [x] M-5.1 The Fractured Nebula: config, seeded layout, rules, builder, RiftService, HUD/summary/briefing
- [x] M-5.2 Tests: pure sims (1/2/8), live solo, claims, restart, exploit, death, leave, timeout, home, 8-arena stress
- [ ] M-5.3 Human checks: 2-player and 8-player sessions (Studio Test → Clients), jump feel on real stones, the arena look
- [ ] A-5.4 Production art pass on the arena (Developer A): asteroid meshes, portal VFX, chamber
- [ ] J-5.5 B: rift discovery ids, RecordExpedition outcome semantics, Expedition_* rate limits

## Phase 4 — Player interface (2026-11-21)
- [x] A-4.1 Design system (Theme, Components, Icons, Motion, Prefs) + UIRoot (responsive canvas, panels, input, toasts, confirm)
- [x] A-4.2 HUD, DNA Lab (replaces PlanetLabUI), Inventory (+sell), Codex, Harvester (+upgrades), Settings (session), Expedition (dormant)
- [x] A-4.3 Evolution screen (before/after), onboarding (state-derived), world UI (waypoints, hover cards, owner avatars, custom prompts)
- [ ] A-4.4 Human checks: phone + controller hardware, mouse hover card, prompt look in the world
- [ ] J-4.5 B: Settings_Update + profile.settings; ExpeditionService + remotes; honour PFReducedMotion in TransformationFX (Travel_Warp "home" → player's slot: done in the QA audit, D6)

## Phase 3 — Planet visual evolution (tested 2026-11-21)
- [x] A-3.1 Profile on B's DNA v2 (Water/Life/CosmicEnergy/Temperature 0..100), `None` → primordial, stages 0..4, EvolutionConfig.VISUAL respected.
- [x] A-3.2 FormationRegistry: all 29 archetypes → builders. Zones, footprint, maxCount, landmark (far LOD), dormantOutsideBranch; seed = owner + id + index.
- [x] A-3.3 Mock SHOWCASE on the v2 ids (slot 1 = real owner is refused by the mock, as designed).
- [x] A-3.4 Tests: unit (0 failures), deterministic rebuild, all 8 planets built at full/reduced/minimal (part counts, build ms), LOD near/far,
      the real path through B's `PF_DevHook` (reactions → stages 1, 2, branch → 3, capstone → 4) with the client re-render and cinematic.
- [ ] A-3.6 **User check (needs a focused Studio window):** look at the planets in Play, press Skip during a stage-up, and read the FPS (Shift+F5) at each Effects level.
      FPS could not be measured: an unfocused Studio throttles to 15 fps.
- [x] A-3.8 Sounds + meshes wired (PF_Assets), future-branch stubs, moon key light (Brightness 10). See CHANGELOG 18:10.
- [ ] A-3.7 Art pass (partly done by A-3.8): under the night lighting (ClockTime 20.5) dark themes (Volcanic, Living, Crystal) read dark from orbit. Options:
      a dedicated key light / ClockTime decision with the user, or authored textures/meshes (see "needs source assets" in the CHANGELOG).
- [ ] J-3.5 Q2/Q3 confirmation from B (INTERFACES §7.4).

## M1 — Spikes (original plan)
- [ ] A-1.1 **Gravity spike**: one test sphere with R = 180 in a scratch place or `ServerStorage.PF_Spikes`.
      Evaluate `ControllerManager` with `UpDirection` against VectorForce plus AlignOrientation.
      Watch out for AirController ignoring UpDirection (see ADR-004).
      Pass criteria: walk around the whole sphere, jump at the equator AND the "south pole", no camera flip at the poles, works on phone touch controls,
      and the other client sees smooth motion. Record the result as an ADR.
- [ ] A-1.2 Camera prototype for a spherical surface (up vector follows the surface normal)
- [ ] B-1.1 `Schema` v1, `Migrations` (identity v1), and reconcile, with tests
- [ ] B-1.2 `MockStore` + `DataService` (load, session lock simulation, autosave, BindToClose) with tests,
      including: a failed load never saves, and a future schemaVersion is read-only
- [ ] B-1.3 `PlayerStateService` snapshot/patch + `ClientState` (Get/Observe/Request)

## Later milestones
See PROJECT_SPEC.md §14 (M2–M11). Tasks get broken out here when a milestone starts.
