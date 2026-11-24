# PROJECT_SPEC.md — PLANET FORGE: Cosmic Evolution

Status: **Architecture v0.1 (Phase 0)**. Nothing in this document is implemented yet unless marked ✅.

## 1. Vision
Each of up to **8 players per server** owns a fully spherical planet suspended in space. All 8 planets
sit in a fixed ring around a central station. Every new player starts with a **barren grey rocky sphere**.
By harvesting cosmic meteors, combining elements in **Planet DNA** experiments and applying evolutionary
reactions, the player permanently transforms the planet along distinct branches: forests, oceans,
crystals, volcanoes, ice, floating structures, orbital rings and rare cosmic phenomena.

Core loop: Claim → Harvest meteors → Collect Matter/Energy/Catalysts → Experiment with DNA →
Transform & Discover → Expeditions → Customize & Showcase → New goals.

## 2. Current place inventory (inspected 2026-11-20, read-only)
| Item | Value | Action |
|---|---|---|
| Workspace | `Baseplate` (+Texture), `SpawnLocation` (+Decal), `Terrain` (empty), `Camera` | Keep. Baseplate/SpawnLocation get moved to `ServerStorage.PF_Deprecated` in M2 (not deleted). |
| Lighting | `Sky`, `SunRays`, `Atmosphere`, `Bloom`, `DepthOfField`; ClockTime 14.5 | A replaces the Sky with a space skybox in M2. The originals are kept in `PF_Deprecated`. |
| Scripts | **0** user scripts in any service | Nothing to migrate |
| Teams service | present, no teams | Unused |
| StreamingEnabled | `true`, TargetRadius 1024 | Keep on (ADR-006) |
| Gravity | 196.2 | See ADR-004 (spherical gravity spike) |
| FallenPartsDestroyHeight | **-500** | The whole solar system sits at Y = +3000 (ADR-005), so this setting doesn't need to change |
| Players.MaxPlayers | **60** | **The human must set this to 8** in Game Settings > Places (a publishing setting) |
| HttpEnabled | false | Keep false |
| Place status | Published, user-owned | Never publish from Claude sessions |

MCP capabilities available: scene inspection (`search_game_tree`, `inspect_instance`), `execute_luau`
(Edit/Server/Client), `multi_edit`, script read/grep/search, playtest control (`start_stop_play`,
`get_console_output`, simulated keyboard/mouse input, `character_navigation`), `screen_capture`,
asset search/insert, AI generation (mesh, material, texture, procedural model, scene),
`store_image`/`upload_image`. No filesystem link to a Git repository is configured yet.

## 3. Architecture overview
```
                ┌──────────── SERVER (authoritative) ────────────┐
 Player ──join──► DataService ─► PlayerStateService ─► (patches) ─┼─► Client ClientState store
                │      ▲            │                              │        │
                │  MockStore/      ├─ EconomyService               │        ├─► UI (A)
                │  DataStore       ├─ InventoryService             │        ├─► PlanetRenderController (A)
                │                  ├─ PlanetService ─ PublicPlanetState ──► all clients
                │                  ├─ MeteorService ─ MeteorDTOs ──► owner client ─► MeteorVisualController (A)
                │                  ├─ EvolutionService (EvolutionRules, pure)
                │                  ├─ ExpeditionService
                │  WorldService(A) ─ builds station + 8 slot cores at boot
                │  Net + RemoteGuard ◄── intents (RemoteEvents) ◄── HarvesterController / UI (A)
                └─────────────────────────────────────────────────┘
```
Principles:
1. **The server owns all state.** Clients send intents (`*_Request`-style RemoteEvents with a `requestId`)
   and get back `Action_Result`.
2. **State is data, visuals are derived.** B produces serializable state (`PublicPlanetState`,
   `MeteorDTO`, `PrivateState`), and A renders it deterministically. B never creates decorative Instances.
   A never mutates gameplay state.
3. **Planet decoration is client-rendered.** The server replicates only the planet core (sphere,
   atmosphere shell, warp gate). Each client builds decorations locally from `PublicPlanetState` with LOD.
   This minimizes replication and memory, so 8 detailed planets stay viable.
4. **Pure logic is separated** (rules, formulas, migrations, validators) and unit-tested in Edit mode.
5. **Bounded everything**: per-player meteor cap, per-planet feature cap, decoration instance budgets,
   rate limits.

## 4. Explorer hierarchy (target)
`(A)`, `(B)` and `(J)` mark the owner: Developer A, Developer B, or Joint.
```
ReplicatedStorage
  PF_Shared                              (J) Folder  ← src/shared
    Contracts                            (J)
      Types.luau                         (J)  Luau type exports (PrivateState, PublicPlanetState, MeteorDTO…)
      Remotes.luau                       (J)  remote contract table (names, direction, validators, rate limits)
      ResultCodes.luau                   (J)
      Version.luau                       (J)  CONTRACT_VERSION, SCHEMA_VERSION
    Config
      GameConfig.luau                    (B)  economy constants, caps, data flags
      WorldLayout.luau                   (A)  station centre, planet radius, 8 slot positions
      ElementDefs.luau                   (B)
      CatalystDefs.luau                  (B)
      ReactionDefs.luau                  (B)  DNA recipes → outcomes
      BranchDefs.luau                    (B)  evolution branches & stage thresholds
      FeatureDefs.luau                   (B)  planet features (each has visualId)
      DiscoveryDefs.luau                 (B)
      UpgradeDefs.luau                   (B)
      ExpeditionDefs.luau                (B)
      VisualRegistry.luau                (A)  visualId → asset path + LOD info
      IconRegistry.luau                  (A)  iconId → image asset
    Logic                                (B)  pure, Instance-free
      EvolutionRules.luau
      EconomyMath.luau
      DnaMath.luau
    Util                                 (J)
      Signal.luau, Trove.luau, Validate.luau, Seed.luau (deterministic RNG wrapper over Random.new)
    Net.luau                             (J)  creates (server) / resolves (client) remotes from Contracts.Remotes
  PF_Remotes                             runtime Folder, created by server Net — never authored by hand
  PF_Assets                              (A)  ← assets/*.rbxm  (Features/, Meteors/, VFX/, Station/, UI/)

ServerScriptService
  PF_Server                              ← src/server
    Main.server.luau                     (J)  boot order: Init all → Start all
    Services
      WorldService.luau                  (A)  builds station + 8 slot cores, warp gates
      DataService.luau                   (B)  load/save/session-lock, MockStore in Studio
      PlayerStateService.luau            (B)  in-memory state, patch emission
      PlanetService.luau                 (B)  slot assignment, PublicPlanetState, ownership checks
      MeteorService.luau                 (B)  per-player meteor simulation (data only)
      HarvestService.luau                (B)  validates Harvest_Collect
      InventoryService.luau              (B)
      EconomyService.luau                (B)
      EvolutionService.luau              (B)
      ExpeditionService.luau             (B)
      UpgradeService.luau                (B)
      TravelService.luau                 (A)  warp teleports within the place (CFrame moves, server-validated)
      MonetizationService.luau           (B)  stub only until approved (ADR-012)
    Security
      RemoteGuard.luau                   (B)  validation + token-bucket rate limiting
    Data
      Schema.luau                        (B)  default PrivateData v1
      Migrations.luau                    (B)  vN → vN+1 pure functions
      MockStore.luau                     (B)
      StoreAdapter.luau                  (B)  wraps DataStoreService / ProfileStore (ADR-008)

ServerStorage
  PF_Tests                               (J)  ← tests/  (TestRunner.luau + *.spec.luau)
  PF_ServerAssets                        (A)  station/planet core templates
  PF_Deprecated                          (J)  moved-aside legacy objects (never delete)

StarterPlayer
  StarterPlayerScripts
    PF_Client                            ← src/client
      Main.client.luau                   (J)
      ClientState.luau                   (B)  applies Snapshot/Patch; Observe(path, fn) API
      Controllers
        GravityController.luau           (A)  spherical gravity + orientation (ADR-004)
        CameraController.luau            (A)
        PlanetRenderController.luau      (A)  PublicPlanetState → decorations, LOD
        MeteorVisualController.luau      (A)
        HarvesterController.luau         (A)  input, beam VFX, sends Harvest_Collect
        TravelController.luau            (A)
        FxController.luau                (A)
        UIController.luau                (A)
      UI                                 (A)  Hud, DnaLab, Inventory, Expeditions, PlanetCodex, Settings
      Render                             (A)  PlanetRenderer.luau (pure-ish builder), Lod.luau, SurfacePlacer.luau
  StarterCharacterScripts                (A)  (empty unless gravity spike needs it)

Workspace
  PF_World                               runtime (A/WorldService)
    Station                              Model, ModelStreamingMode = Persistent
    Planets
      Slot_1 … Slot_8                    Model (Core sphere, AtmosphereShell, WarpGate, Attributes)
  PF_ClientFX                            client-local Folder (created by each client; never replicated)
```

## 5. Server / client / shared responsibilities
- **Shared** contains definitions, contracts, pure logic, and utilities. It has no side effects at require time.
- **Server** holds all state and persistence, validates every intent, simulates meteors as data,
  builds the world skeleton and handles moves between station and planets.
- **Client** handles input, the character controller, camera, rendering of decorations, meteors and VFX,
  UI, and a read-only mirror of state (`ClientState`).

## 6. File ownership (exact)
| Path (Rojo) | Owner | Reviewer |
|---|---|---|
| `src/shared/Contracts/*` | Joint | both must approve |
| `src/shared/Net.luau`, `src/shared/Util/*`, `tests/TestRunner.luau` | B | A |
| `src/shared/Config/WorldLayout.luau`, `VisualRegistry.luau`, `IconRegistry.luau` | A | B |
| `src/shared/Config/*Defs.luau`, `GameConfig.luau` | B | A |
| `src/shared/Logic/*` | B | A |
| `src/server/Services/WorldService.luau`, `TravelService.luau`, `CharacterService.luau` ✅, `src/server/World/PlanetBuilder.luau` ✅ | A | B |
| `src/shared/Gravity/GravityFields.luau` ✅ | A | B |
| `src/client/Controllers/GravityController.luau` ✅, `CameraController.luau` ✅, `CharacterAnimator.luau` ✅, `src/client/UI/GravityDebugPanel.luau` ✅ | A | B |
| `src/server/Services/*` (all others), `src/server/Security/*`, `src/server/Data/*` | B | A |
| `src/server/Main.server.luau`, `src/client/Main.client.luau` | Joint | both |
| `src/client/ClientState.luau` | B | A |
| `src/client/Controllers/*`, `src/client/UI/*`, `src/client/Render/*` | A | B |
| `assets/*.rbxm` | A | — |
| `tests/*.spec.luau` | author of the module under test | — |
| `docs` (`*.md`) | Joint | — |

## 7. World layout (WorldLayout.luau v1, owned by A)
- `STATION_CENTER = Vector3.new(0, 3000, 0)`. This keeps the whole system far above FallenPartsDestroyHeight (-500).
- `PLANET_RADIUS = 160` studs (ADR-014 revised 2026-11-23; was 96 in the prototype). 180 would make neighbouring gravity fields overlap at `ORBIT_RADIUS = 1100` (2 × 2.5R = 900 > 842), so it would need the orbit at ≥ 1180 or a weaker reach. The core is a Ball Part. Props are built at real scale (`FormationDensity.TIER_SCALE`), and the count of repeatable formations follows DNA (CHANGELOG 2026-11-23).
- `ORBIT_RADIUS = 1100`. Slot *i* sits at angle `(i-1) * 45°` in the XZ plane, at the station's height.
  Neighbouring planet centres are about 842 studs apart, leaving a gap of about 482 studs between surfaces.
- Slot core models use `ModelStreamingMode = Persistent`, so all 8 planets stay visible from anywhere.
  Decorations are client-local and LOD-gated.
- Travel in MVP uses warp gates: Station ↔ any planet. Free flight (jetpack/ship) is a later milestone (M8).

## 8. Naming standards
- Modules: PascalCase. Server modules end in `Service`, client modules in `Controller`. Defs end in `Defs`.
- Scripts: `Main.server.luau`, `Main.client.luau`. No other top-level Scripts. Everything else is a ModuleScript.
- Runtime-created top-level instances: `PF_` prefix.
- Remotes: `Domain_Action` (e.g. `Harvest_Collect`, `State_Patch`).
- Ids in defs: lowercase snake (`element_iron`, `reaction_first_moss`, `feature_crystal_spires`).
  Ids are **permanent** once shipped, because they are stored in player data. Rename display names, never ids.
- Attributes on instances: PascalCase with a `PF` prefix: `PFSlot`, `PFOwnerUserId`, `PFMeteorId`.
- Assets: `PF_<Category>_<Name>_<Variant>[_LOD<n>]`, for example `PF_Feature_CrystalSpire_A_LOD0`,
  `PF_Meteor_Iron_Small`, `PF_VFX_HarvestBeam`. Categories: Feature, Meteor, VFX, Station, Planet, UI, Icon, Sfx.
- visualId and iconId: `vis_<name>` and `ico_<name>`. They map through VisualRegistry and IconRegistry, so a
  def never contains a raw asset id.
- Git branches: `a/<topic>`, `b/<topic>`, `joint/<topic>`. Commits: `[A]`, `[B]` or `[J]` prefix plus a short imperative.

## 9. Budgets and caps (initial targets, to be measured in M9)
| Thing | Cap |
|---|---|
| Live meteors per player (server data) | 12 |
| Planet features per planet (persisted) | 64 |
| Decoration instances, own/near planet (LOD0) | ≤ 1500 |
| Decoration instances, far planet (LOD2 impostor) | ≤ 20 |
| Discoveries stored | bounded by DiscoveryDefs count |
| Processed purchase receipts kept | last 50 |
| PrivateData serialized size | < 100 KB (DataStore limit is 4 MB; alert at 200 KB) |
| Client memory target (mid phone) | < 1.2 GB total, measured with the Developer Console |

## 10. Persistence (owned by B)
- One key per player, `u_<UserId>`. The store name comes from `GameConfig.Data.StoreName`:
  - Studio default: **MockStore** (in-memory), so nothing is written.
  - Dev: `PF_PlayerData_DEV`, only if `UseRealDataStore = true` and the human has enabled Studio API access.
  - Prod: `PF_PlayerData_PROD`. This store doesn't exist until launch and needs approval (ADR-009).
- Session locking: ProfileStore is recommended (ADR-008, pending approval). The fallback is a hand-rolled
  `UpdateAsync` lock with `lockServerJobId` and a 30-minute stale timeout.
- Saving: autosave every 120 s with jitter, on `PlayerRemoving`, and on `game:BindToClose`
  (budget under 30 s total).
- Saves never replace data with defaults. If a load fails, the player is kicked with a retry message
  and **no save is ever issued for that session**.
- The schema is versioned through `schemaVersion`. `Migrations` runs pure step functions in order, and every migration has a test.
- Data with an unknown future `schemaVersion` is loaded read-only and never saved, which protects against rollbacks.

## 11. Evolution model (owned by B, rendered by A)
- **Elements** (collected from meteors): `element_rock`, `element_iron`, `element_ice`, `element_carbon`,
  `element_magma`, `element_crystal`, `element_plasma`, `element_aether` (rare).
- **Currencies**: `matter` (common, used for upgrades) and `energy` (charged by harvesting, used to fuel reactions).
- **Catalysts** (rare drops and expedition rewards): `catalyst_spark`, `catalyst_frost`, `catalyst_seed`,
  `catalyst_void`.
- **DNA Experiment**: combine 2–3 distinct elements plus an optional catalyst. If the combination matches a
  `ReactionDef`, it unlocks a **reaction** (a discovery). If it doesn't, it produces a "failed fusion" that returns 50% of the inputs and gives a hint.
- **Reaction**: applying it costs energy, adds affinity to one or more **branches**, and may add a **feature**.
- **Branches**: `verdant` (forests), `oceanic`, `crystalline`, `volcanic`, `glacial`, `aetheric`
  (floating structures). Branches are not exclusive. Affinities combine and create hybrid looks.
  Some features require two branches, for example *Steam Geysers* need volcanic and oceanic.
- **Stages** 0–5 per planet come from total affinity. The stage gates tiers of reactions.
- **Rare phenomena** (orbital rings, aurora, twin moon, nebula halo) are special features with
  low-probability triggers and expedition-only catalysts.
- Planet appearance is fully determined by `(seed, branchAffinity, features[], cosmetics)`.

## 12. Testing strategy
- **Unit** (Edit mode, via MCP): `EvolutionRules`, `DnaMath`, `EconomyMath`, `Migrations`, `Validate`,
  `RemoteGuard` (rate limiter), the `Remotes` contract self-check, and a consistency test that confirms
  every `FeatureDefs.visualId` exists in `VisualRegistry` and every `iconId` exists in `IconRegistry`.
- **Integration** (playtest): scripted checks run through `execute_luau` in the Server datamodel during Play,
  for example spawning a fake intent and asserting the state patch.
- **Multiplayer**: Test > Clients and Servers with 2 clients first, then 8 clients in M9.
- **Performance**: MicroProfiler and Developer Console memory snapshots at each milestone, recorded in CHANGELOG.

## 13. Source control and integration workflow
Recommended toolchain (ADR-002). **The human installs it; Claude never installs it.** Use Git with a private
GitHub repo, **Rojo 7** for file↔Studio sync, Rokit or Aftman as the toolchain manager, and optionally
StyLua and Selene.
```
repo/
  default.project.json      Rojo tree mapping (below)
  src/shared/  src/server/  src/client/
  tests/                    → ServerStorage.PF_Tests
  assets/                   *.rbxm authored models (A)
  CLAUDE.md PROJECT_SPEC.md INTERFACES.md TASKS.md CHANGELOG.md
  .github/CODEOWNERS
```
`default.project.json` sketch:
```json
{
  "name": "PlanetForge",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "PF_Shared": { "$path": "src/shared" },
      "PF_Assets": { "$path": "assets/replicated" }
    },
    "ServerScriptService": { "PF_Server": { "$path": "src/server" } },
    "ServerStorage": {
      "PF_Tests": { "$path": "tests" },
      "PF_ServerAssets": { "$path": "assets/server" }
    },
    "StarterPlayer": {
      "StarterPlayerScripts": { "PF_Client": { "$path": "src/client" } }
    }
  }
}
```
Workflow:
1. `main` must always boot with a clean console. Each change gets a feature branch and a PR,
   and the other developer reviews it.
2. **Contract-first**: any change to `Contracts/` lands in its own PR before the code that uses it.
3. Each developer syncs Rojo into **their own local copy** of the place (File > Save to File).
   Nobody syncs into the published place.
4. At integration points (end of each milestone), one developer syncs `main` into a staging place
   (separate placeId, decision U-3), and both developers playtest together in Team Create.
5. The first integration step for every milestone is the MCP test run plus a two-client playtest.

Fallback without Rojo: use Team Create with Collaborative Editing. Scripts live only in Studio, and Claude
exports script sources to the repo through MCP (`script_read`) at the end of each session. This is weaker,
because there is no real diffing.

## 14. Roadmap (independently testable milestones)
| M | Name | A delivers | B delivers | Exit test |
|---|---|---|---|---|
| M0 | Skeleton | folder hierarchy, empty controllers, `WorldLayout` | `Net`, `Contracts` v1, `RemoteGuard`, TestRunner, `Validate`, `Signal`/`Trove` | Boots with no errors; contract self-test passes |
| M1 | Spikes | **Spherical gravity spike** on one test sphere (walk, jump, orbit the full planet, no jitter) | `DataService` + `MockStore` + `Schema` v1 + `Migrations` + tests | Spike demo video/screenshots; data tests pass, including the failed-load-never-saves test |
| M2 | Space & slots | Space skybox, station, 8 slot cores, warp gates, `TravelService` | `PlanetService` slot assignment, `PublicPlanetState` broadcast | 2 clients each get their own slot and can warp home and back |
| M3 | Harvest loop | Meteor visuals, harvester beam, HUD counters | `MeteorService`, `HarvestService`, `InventoryService`, `EconomyService` | Collect a meteor; the counter increases; server rejects out-of-range and spammed collects |
| M4 | DNA & first evolution | `PlanetRenderer` for verdant + crystalline, DNA Lab UI | `DnaMath`, `ReactionDefs` (≈10), `EvolutionService`, Discoveries | Experiment → reaction → planet visibly changes for both clients |
| M5 | Responsive UI pass | Phone/tablet/PC/console layouts, settings | Settings persistence | UI is usable at 4 device emulator presets |
| M6 | Real persistence (dev) | — | `StoreAdapter` on `PF_PlayerData_DEV`, autosave, BindToClose | **Needs human approval**. Data survives a rejoin; the kill-server test shows no data loss |
| M7 | Expeditions | Expedition UI and timers | `ExpeditionService`, defs, offline completion | Start → wait → claim; reward granted exactly once |
| M8 | Content breadth | Oceanic/volcanic/glacial/aetheric visuals, rings, rare phenomena, optional flight | Remaining reactions, hybrid features, upgrades | All 6 branches are reachable in a test save |
| M9 | Scale & perf | LOD tuning, VFX budgets | Load/save soak, rate-limit tuning | 8-client test within the §9 budgets |
| M10 | Social & showcase | Visit mode, planet cards | Likes/visits stats, leaderboard (OrderedDataStore) | 2 players can visit and like each other's planets |
| M11 | Monetization design | Store UI mock | Receipt flow against **test products** only | **Human creates the products**; design reviewed |
