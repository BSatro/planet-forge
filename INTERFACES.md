# INTERFACES.md — stable contracts between Developer A and Developer B

`CONTRACT_VERSION = 1`, `SCHEMA_VERSION = 1`. Status: **specified, not yet implemented**.
Any change to this document follows the rule in CLAUDE.md §2.8 (a contract PR first, both developers approve,
and a CHANGELOG entry). Additive changes such as a new optional field or a new remote bump the minor
version, which is noted in the change log at the bottom. Removing or renaming anything is a breaking
change that needs a `CONTRACT_VERSION` bump.

---
## 1. Shared types (`PF_Shared/Contracts/Types.luau`)
```lua
--!strict
export type ElementId = string      -- "element_*"  (ElementDefs keys)
export type CatalystId = string     -- "catalyst_*"
export type ReactionId = string     -- "reaction_*"
export type BranchId = "verdant" | "oceanic" | "crystalline" | "volcanic" | "glacial" | "aetheric"
export type FeatureType = string    -- "feature_*"  (FeatureDefs keys)
export type DiscoveryId = string    -- "discovery_*"
export type UpgradeId = string      -- "upgrade_*"
export type ExpeditionId = string   -- "expedition_*"
export type SlotIndex = number      -- integer 1..8

-- One feature placed on a planet. Anchor is deterministic: the renderer derives surface points from
-- Seed.derive(planet.seed, feature.anchorSeed). No CFrames are persisted.
export type PlanetFeature = {
	uid: number,             -- unique per planet, monotonically increasing
	featureType: FeatureType,
	level: number,           -- 1..FeatureDefs[featureType].maxLevel
	anchorSeed: number,      -- integer 0..2^31-1
}

export type PlanetCosmetics = {
	paletteId: string?,      -- "palette_*" (A-owned visual palettes, validated server-side against a list)
	ringStyleId: string?,
	atmosphereTint: string?, -- palette key, never a raw Color3 from the client
}

-- Replicated to ALL clients in the server. Contains nothing private.
export type PublicPlanetState = {
	slot: SlotIndex,
	ownerUserId: number,
	planetName: string,         -- already filtered by TextService on the server (M10); default "<DisplayName>'s World"
	seed: number,
	stage: number,              -- 0..5
	branchAffinity: { [BranchId]: number }, -- 0..1000 each
	features: { PlanetFeature },-- ≤ 64
	cosmetics: PlanetCosmetics,
	revision: number,           -- increments on every change; renderers skip stale revisions
}

-- Private, owner only. Mirrors persisted data minus internal bookkeeping.
export type PrivateState = {
	currencies: { matter: number, energy: number },
	elements: { [ElementId]: number },
	catalysts: { [CatalystId]: number },
	discoveries: { [DiscoveryId]: number },   -- value = unix time unlocked
	knownReactions: { [ReactionId]: boolean },
	upgrades: { [UpgradeId]: number },        -- level
	expedition: ActiveExpedition?,
	settings: { [string]: boolean | number },
	planet: PublicPlanetState,                -- the owner's own planet (same shape)
}

export type ActiveExpedition = { expeditionId: ExpeditionId, startedAt: number, endsAt: number }

-- Meteors are DATA on the server. The client renders them.
export type MeteorDTO = {
	id: string,          -- "m<serverCounter>", unique within the server
	kind: string,        -- MeteorDefs key, e.g. "meteor_iron_small"
	position: Vector3,   -- world space, near the owner's planet surface/orbit
	velocity: Vector3,   -- studs/s for client interpolation (server checks range using the same kinematics)
	spawnedAt: number,   -- workspace:GetServerTimeNow()
	expiresAt: number,
}
```

## 2. Remote contracts (`PF_Shared/Contracts/Remotes.luau`)
Server `Net` creates `ReplicatedStorage.PF_Remotes/<Name>` at boot, using `RemoteEvent` or
`UnreliableRemoteEvent`. Clients resolve remotes through `Net.get(name)`, which waits with a 10 s timeout and then errors.
**No RemoteFunctions in v1.** Every request is a RemoteEvent carrying `requestId`, and the server answers
with `Action_Result`. This avoids server-yield hazards and lets the client show pending states.

Every client→server handler is wrapped by `RemoteGuard`, which applies these checks in order:
1. The player's data is loaded (`DATA_NOT_LOADED` if not).
2. Token-bucket rate limit per player per remote (`RATE_LIMITED`, silently dropped after 3×burst).
3. Payload shape matches the validator: types, integer-ness, no NaN or inf, string length ≤ 64,
   table length ≤ 8, and ids exist in defs (`INVALID_PAYLOAD`).
4. The handler runs, and any error it raises is caught and reported as `INTERNAL` (logged with requestId and never shown to the client).

`requestId`: integer 1..2^31, chosen by the client and echoed back. The server doesn't trust it for anything.

### 2.1 Client → Server (RemoteEvent)
| Name | Payload | Rate (burst / refill per s) | Owner (handler) | Success `data` |
|---|---|---|---|---|
| `Planet_Claim` | `{requestId}` | 2 / 0.2 | B PlanetService | `{slot}` |
| `Travel_Warp` | `{requestId, destination: "station" \| "home" \| SlotIndex}` | 3 / 0.5 | A TravelService (prototype: CharacterService ✅) | `{}` |
| `Character_Recover` *(v1.1)* | `{requestId, mode: "recover" \| "respawn"}` | 1 / 1 (prototype: 1 s cooldown) | A CharacterService ✅ | `{}` |
| `Harvest_Collect` | `{requestId, meteorId: string}` | 10 / 5 | B HarvestService | `{gains: {[string]: number}}` |
| `Dna_Experiment` | `{requestId, elements: {ElementId} (2..3 distinct), catalystId: CatalystId?}` | 4 / 1 | B EvolutionService | `{reactionId?: ReactionId, hint?: string, refunded?: table}` |
| `Evolution_Apply` | `{requestId, reactionId: ReactionId}` | 4 / 1 | B EvolutionService | `{featureUid?: number, stage: number}` |
| `Upgrade_Buy` | `{requestId, upgradeId: UpgradeId}` | 4 / 1 | B UpgradeService | `{level}` |
| `Expedition_Start` | `{requestId, expeditionId: ExpeditionId}` | 2 / 0.5 | B ExpeditionService | `{endsAt}` |
| `Expedition_Claim` | `{requestId}` | 2 / 0.5 | B ExpeditionService | `{rewards: table}` |
| `Planet_Customize` | `{requestId, key: "paletteId" \| "ringStyleId" \| "atmosphereTint", value: string}` | 4 / 1 | B PlanetService | `{}` |
| `Settings_Update` | `{requestId, key: string (whitelisted), value: boolean \| number}` | 6 / 2 | B PlayerStateService | `{}` |

### 2.2 Server → Client (RemoteEvent unless noted)
| Name | Target | Payload | Producer | Consumer |
|---|---|---|---|---|
| `Action_Result` | requester | `{requestId, ok: boolean, code: ResultCode, data: table?}` | RemoteGuard | ClientState / UI (A) |
| `State_Snapshot` | owner | `{schemaVersion, contractVersion, state: PrivateState}` | PlayerStateService | ClientState |
| `State_Patch` | owner | `{changes: {{path: {string}, value: any}}}` (`value == nil` deletes) | PlayerStateService | ClientState |
| `Planet_AllStates` | joining player | `{states: {PublicPlanetState}}` | PlanetService | PlanetRenderController (A) |
| `Planet_StateChanged` | all | `{slot, state: PublicPlanetState?}` (nil = slot freed) | PlanetService | PlanetRenderController (A) |
| `Meteor_Spawned` | owner | `{meteors: {MeteorDTO}}` | MeteorService | MeteorVisualController (A) |
| `Meteor_Removed` | owner | `{ids: {string}, reason: "collected" \| "expired"}` | MeteorService | MeteorVisualController (A) |
| `Discovery_Unlocked` | owner | `{discoveryId}` | EvolutionService | UI / FxController (A) |
| `Notify` | owner or all | `{key: string, args: {[string]: string \| number}?}` (key is a localization key) | any B service | UIController (A) |
| `Fx_Play` *(UnreliableRemoteEvent)* | all | `{fxId: string, slot: SlotIndex, featureUid: number?}` | EvolutionService | FxController (A) |

### 2.3 ResultCodes (`Contracts/ResultCodes.luau`)
`OK`, `RATE_LIMITED`, `INVALID_PAYLOAD`, `DATA_NOT_LOADED`, `NOT_OWNER`, `NOT_FOUND`, `OUT_OF_RANGE`,
`INSUFFICIENT_FUNDS`, `LOCKED`, `ALREADY_ACTIVE`, `NOT_READY`, `CAP_REACHED`, `INTERNAL`.

## 3. Module APIs that cross the A/B boundary

### 3.1 Shared (both read)
```lua
Net.server(name): RemoteEvent                         -- server only
Net.get(name): RemoteEvent                            -- client only, yields ≤10s
Net.onRequest(name, handler: (player, payload) -> (ResultCode, table?))  -- server; RemoteGuard wraps it
WorldLayout.STATION_CENTER: Vector3
WorldLayout.PLANET_RADIUS: number
WorldLayout.getSlotCenter(slot: SlotIndex): Vector3   -- pure
Seed.derive(seed: number, salt: number): Random       -- deterministic RNG, used by A and B
```

### 3.2 Server: B exposes, A consumes
```lua
PlanetService:GetSlotOf(player): SlotIndex?
PlanetService:GetOwnerOf(slot): Player?
PlanetService:GetPublicState(slot): PublicPlanetState?
PlanetService.SlotAssigned: Signal<(player, slot)>        -- WorldService activates the gate/visual state
PlanetService.SlotReleased: Signal<(slot)>
PlayerStateService:IsLoaded(player): boolean
```

### 3.3 Server: A exposes, B consumes
```lua
WorldService:GetSlotModel(slot): Model          -- Workspace.PF_World.Planets.Slot_<n>
WorldService:GetCharacterSlot(player): SlotIndex?  -- which planet the character currently stands on/near
                                                   -- (nearest centre within PLANET_RADIUS + 60), used by HarvestService
TravelService:WarpTo(player, destination): ResultCode   -- B may call it (e.g. after Planet_Claim)
```

### 3.4 Client: B exposes, A consumes
```lua
ClientState:Get(path: {string}): any            -- read-only deep-frozen copy (table.freeze)
ClientState:Observe(path: {string}, fn: (newValue, oldValue) -> ()): () -> ()  -- returns disconnect
ClientState:Request(remoteName, payload): Promise-like { await(): (ok, code, data) }   -- assigns requestId,
                                                   -- times out after 10s with code "INTERNAL"
ClientState.Ready: Signal<()>                    -- fired after the first State_Snapshot
Defs (read-only): ElementDefs, CatalystDefs, ReactionDefs, BranchDefs, FeatureDefs, DiscoveryDefs,
                  UpgradeDefs, ExpeditionDefs  — each entry has displayKey, descriptionKey, iconId
```

### 3.5 Client: A owns (B never calls these; listed for clarity)
```lua
PlanetRenderer.apply(slotModel: Model, state: PublicPlanetState, lod: 0|1|2)  -- idempotent; diff by feature uid
MeteorVisualController (consumes Meteor_* events directly)
HarvesterController -> ClientState:Request("Harvest_Collect", {meteorId})
```

### 3.6 Def ↔ registry contract (enforced by a unit test)
- Every `FeatureDefs[x].visualId` has an entry in `VisualRegistry`, and every `*.iconId` has an entry in `IconRegistry`.
- `VisualRegistry[visualId] = { asset: string (path under PF_Assets), lod: {[0|1|2]: string?},
  placement: "surface" | "orbit" | "atmosphere" | "floating", footprint: number (studs) }`.
- B adds a def with a new visualId. A must register it, and a placeholder entry `vis_placeholder` is
  allowed until A's art lands. Tests fail if any id is missing, so a placeholder must be explicit.

## 4. Persisted data schema v1 (`src/server/Data/Schema.luau`, owner B)
```lua
{
	schemaVersion = 1,
	createdAt = 0, lastSaveAt = 0, totalPlaySeconds = 0,
	currencies = { matter = 0, energy = 0 },
	elements = {},            -- [ElementId] = integer ≥ 0, each ≤ GameConfig.Caps.ElementMax (1e9)
	catalysts = {},           -- [CatalystId] = integer ≥ 0
	discoveries = {},         -- [DiscoveryId] = unix seconds
	knownReactions = {},      -- [ReactionId] = true
	upgrades = {},            -- [UpgradeId] = level
	expedition = nil,         -- ActiveExpedition?
	planet = {
		planetName = "",      -- "" = use default display name
		seed = 0,             -- assigned once on first load: Random.new():NextInteger(1, 2^31-1)
		stage = 0,
		branchAffinity = { verdant = 0, oceanic = 0, crystalline = 0, volcanic = 0, glacial = 0, aetheric = 0 },
		features = {},        -- {PlanetFeature}, ≤ 64
		nextFeatureUid = 1,
		cosmetics = {},
	},
	settings = {},
	purchases = { receipts = {}, receiptOrder = {} },  -- receipts[purchaseId]=true, order capped at 50 (M11)
	stats = { meteorsCollected = 0, experiments = 0, reactionsApplied = 0, expeditionsDone = 0 },
}
```
Rules:
- `slot` and `ownerUserId` are **not** persisted. They are assigned per server session.
- `Migrations[n]` is a pure function `(dataVn) -> dataVn+1`. Never edit a shipped migration; add a new one.
- On load, fill defaults for keys that are missing (reconcile). Unknown extra keys are preserved, never dropped.
- If `schemaVersion > SCHEMA_VERSION`, the data is read-only for the session and no saves happen.

## 5. Contract change log
| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-11-20 | Initial contract (Phase 0). Not yet implemented. |
| 1.2 | 2026-11-21 | Added S→C `Travel_Transition {phase: "out"\|"in", destination, duration?}`. `Fx_Play` payload is `{fxId: "warp_depart"\|"warp_arrive", position: Vector3}`. Planet ownership attributes on `PF_World.Planets.Slot_n`: `PFOwnerUserId` (0 = unclaimed), `PFOwnerName`, `PFClaimState`, `PFTheme` ("barren"), `PFStage`. Label TextLabels `PlanetLabel.Title`/`Owner` and dock sign `Dock_n.GateBeam.Sign` may be updated by PlanetService (B). `SpawnPoint` part per slot (`PFSpawnFor`). |
| 1.1 | 2026-11-20 | Added `Character_Recover`. Implemented in the prototype: `Travel_Warp`, `Character_Recover`, `Action_Result` (without RemoteGuard; see ADR-018). Added the gravity interfaces in §6. |

- **v1.11 (2026-11-23)** §7 planet scale: no attribute changes. New shared pure module `PF_Shared.Planet.FormationDensity` (only copy of the DNA → element-count formula, tier scales, site counts, variants); `PlanetVisualProfile.build` adds `spec.dna = {Life, Water, Temperature, CosmicEnergy}`; formation models carry `PFElements` (client-side, informational). `WorldLayout.PLANET_RADIUS = 160` (ADR-014 revised); `PFRadius` slot attribute is authoritative for renderers.
- **v1.10 (2026-11-22)** DataConfig: `PRODUCTION_UNIVERSE_IDS = {}` + `PRODUCTION_UNIVERSE_ID_PENDING` (production prepared, not active); `TEST_UNIVERSE_IDS` now also gates developer commands on live servers (`DevCommandService.decideEnabled`). Tool: `ServerStorage.PF_PersistenceProbe.run({mode = "mock" | "test"})`.
- **v1.9 (2026-11-22)** §11 Daily/weekly quests (`Quest_Action`, `profile.quests`, `Profile_Snapshot.quests`, QuestService signals). §9: `WorldEventService.RewardGranted(player, instanceId, key)`. §10: custom event `QuestClaimed`.
- **v1.8 (2026-11-21)** §10 Analytics (TelemetryService, server-only AnalyticsService events). `MonetizationService.StoreFunnel` signal (analytics hook only).
- **v1.7 (2026-11-21)** §9 Cosmic world events + lightweight social (Event_Action/Event_Notify/Event_Dev, Social_Action/Social_Notify, `PF_WorldEvents`/`PF_Social` replication, EventFx registry for Developer A).
- **v1.6 (2026-11-21)** §8 Cosmic Rifts (expedition backend, remotes, CharacterService/GravityFields hooks).
- **v1.5 (2026-11-21)** §7.9 interface (PF_UI) — consumers of ProfileClient/EvolutionClient; requests to B for Settings_Update, expeditions, reduced motion.
- **v1.4 (2026-11-21)** §7.5 asset library (`ReplicatedStorage.PF_Assets`), §7.6 audio, §7.7 future-branch art stubs, §7.8 lighting key. No change to the attribute contract.
- **v1.3 (2026-11-21)** Planet visual contract (§7) accepted in code: A = attribute producer, B = `Planet_Transformation` events; `PFFormations` = `"Id:count"`.

## 6. Gravity and character interfaces (v1.1, owner A)
```lua
-- Shared, pure: ReplicatedStorage.PF_Shared.Gravity.GravityFields
GravityFields.buildDefault(): {Field}                     -- station + WorldLayout.ACTIVE_SLOTS
GravityFields.sample(fields, position): Sample            -- {id, kind: "planet"|"uniform"|"space", up, strength, altitude, center?, radius?, slot?}
GravityFields.planetField(slot, center, radius): Field    -- B may use this to reason about "on which planet is this player"
-- Server: PF_Server.Services.CharacterService
CharacterService:WarpTo(player, "station" | slot): ResultCode
CharacterService:PlaceCharacter(player, target): boolean  -- single CFrame move + velocity reset
CharacterService:GetSpawnTarget(player): ("station" | number)?
-- Character attributes written by the owning client at 10 Hz (debug/telemetry, NOT authoritative):
--   PFState, PFField, PFGrounded, PFAltitude, PFUpDot, PFSpeed
-- Studio-only test hooks on the character (ignored outside Studio):
--   PFTestMove (Vector3, camera-relative), PFTestMoveWorld (Vector3), PFTestGreatCircleAxis (Vector3), PFTestJump (bool)
```
B rule: never trust `PF*` character attributes for gameplay. Use the server-side root position with `GravityFields.sample`.


## 7. Planet visual contract (v1.3 — ACCEPTED in code by both sides, 2026-11-21; Q2/Q3 confirmations still welcome)
Purpose: every client renders the evolution of all 8 planets from ONE public, replicated state per planet.

### 7.1 Transport
Attributes on `Workspace.PF_World.Planets.Slot_n`. This is a Persistent model, so it replicates to all clients, including late joiners, and no new remote is needed.
| Attribute | Type | Source (B's model as of 2026-11-21) |
|---|---|---|
| `PFOwnerUserId` | number (0 = unclaimed) | PlanetSlotService owner |
| `PFOwnerName` | string | owner DisplayName |
| `PFClaimState` | "unclaimed" \| "claimed" | derived |
| `PFBranch` | string | `profile.planet.branch`: None \| Living \| Frozen \| Volcanic \| Crystal (\| future Astral/Void/Desert/Mechanical) |
| `PFStage` | int 0..`PlanetConfig.MAX_EVOLUTION_STAGE` (now 4) | `profile.planet.stage` |
| `PFDna_<Param>` | number | one per `PlanetConfig.DNA_PARAMS` (now Temperature, Water, Life, CosmicEnergy; 0..100) |
| `PFFormations` | string `"Id:count,Id:count"` | `GetPlanetState().formations` = `{[id]=count}` (verified 2026-11-21), ids from `Evolution.FormationRegistry`. A bare `Id` still parses as count 1 |
| `PFLastEffect` | string (optional) | effect id of the reaction/stage that caused the last change ("ocean", "volcanic", ...), used to pick the transformation FX |
| `PFTheme` | string | `PlanetConfig.BRANCHES[branch].theme` (informational) |
| `PFVisualRevision` | int, +1 per publish | consumers re-render when it changes |

Code: `PF_Shared.Planet.PlanetVisualContract` (pure: `defaultState`, `normalize`, `toAttributes`, `fromInstance`).

### 7.2 Producer (RESOLVED: Q1)
- **Single attribute producer: A's `PF_Server.Services.PlanetVisualPublisher`.** It reads only B's public `PlanetDataService` API
  (`PlanetReady`, `PlanetChanged`, `GetPlanetState`, `PlanetSlotService.SlotReleased`) and writes 7.1. B's `PlanetVisualAdapter` header confirms
  this and writes **no** planet attributes.
- **Once-only events: B's `PlanetVisualAdapter`** fires `PF_Remotes.Planet_Transformation` `{slot, ownerUserId, revision, transformation={id, kind,
  reactionId?, effect, formations, stageFrom, stageTo, newStages, branch, branchFrom?}}`. Its consumer is B's `PF_Client.Evolution.TransformationFX`
  (overlay plus the owner banner `PF_TransformationBanner`).
- Division of the stage-up moment: B draws the owner's text banner. A draws the planet geometry cinematic (pulse, recolour, growth) and the
  **Skip** control. On the owner's own planet A's overlay is compact (Skip only, top-right). Visitors see A's full banner.

### 7.3 Consumer (A, client)
`PF_Client.Planet.PlanetVisualController` → `PF_Shared.Planet.PlanetVisualProfile` (pure state→spec) → `PF_Client.Planet.PlanetDecorator`.
- Uses `FormationRegistry` fields as the placement authority: `zones` (polar bands), `footprint`, `maxCount`, `landmark` (kept in far LOD),
  `dormantOutsideBranch`, `archetype`. Each instance's position is deterministic from seed(ownerUserId) + formationId + index, independent of the slot.
  Also respects `EvolutionConfig.VISUAL` (POLAR_EXCLUSION_DEG, PATCHES_BY_STAGE, ATMOSPHERE_FROM_STAGE, RING_FROM_STAGE).
- Development mock: `ServerStorage.PF_DevTools.PlanetVisualMock` (Studio-only, unclaimed slots only, writes 7.1). Never required by production code.

### 7.4 Questions for Developer B (status 2026-11-21)
- **Q1 resolved:** A publishes attributes, B fires transformation events (7.2).
- **Q2 implemented, renderer-side:** `"Id:count"` is live. The renderer drops a formation when `dormantOutsideBranch` is true and its branch ≠ the planet's branch.
  It caps instances at `maxCount`. Please confirm, or tell us if B would rather filter.
- **Q3 open (low priority):** A still triggers its cinematic from the PFStage increase (works for late joiners and the mock). A could listen to
  `Planet_Transformation.effect` instead, to theme the cinematic per effect. `PFLastEffect` is optional and currently unused.
- **Q4 resolved:** `GetPlanetState().formations` returns `{[id]=count}`.
- **Q5 resolved:** ReactionRegistry compiles.

### 7.5 Asset library (v1.4, owner A) — `ReplicatedStorage.PF_Assets`
Replicated, so every client can clone the templates. Only the renderer (`PlanetDecorator`) and `Sfx` read it. **B never needs to require it.**
| Template (`PF_Assets.Models`) | Source asset (as inserted by the user) | Used for |
|---|---|---|
| `TreeDefault` | `LowPolyTree` (Trunk + Leaves) | default broadleaf tree (2 of 3 picks) |
| `TreeVariant` | `Low Poly Tree` (Trunk + Leaves1 + Leaves2) | variant tree (1 of 3), World Tree / Ancient Tree landmark (scaled) |
| `TreePine` | `Model` (2 MeshParts, identified as a conifer) | trees on Frozen planets and in polar bands of capped planets (frosted needles) |
| `Volcano` | `Valcano` (textured MeshPart) | `volcano` builder (VolcanicMountain, EternalCore, Mega Volcano landmark) + neon caldera + lava rivers |
| `CrystalBase` | `Crystal` (Union + Poison/PoisonSparkles emitters) | Crystal theme crystals, tinted to the accent colour, soft neon; emitters kept inside the budget |
| `CrystalIce` | `Ice Crystal` | ice spikes / ice clusters, every 3rd crystal on Crystal worlds, Astral/Mechanical stubs |
| `CrystalRed` | `Red Crystal` | crystals on Volcanic worlds |
| `CrystalGreen` | `Green Crystal` | crystals on Primordial/Living worlds |
Rules for templates (checked when they were imported):
- A Model with a PrimaryPart and **pivot = bottom centre**, upright (+Y). Attributes `PFHeight`, `PFWidth` and `PFSourceName`.
- All parts are Anchored, with CanCollide, CanQuery and CanTouch false (movement and gravity probes are unaffected).
- **No scripts.** The importer verified that none of the inserted assets contained any.
- `placeAsset` scales with `ScaleTo(tpl:GetScale() * h / PFHeight)`, seats the clone with `PivotTo(surface frame)`, registers parts for the emergence FX,
  and keeps ParticleEmitters only within the per-planet budget (rate capped at 10).
- To swap art: replace a template under the same name and re-run the pivot/flag prep. No code change is needed.
- The original Workspace objects were **moved and renamed, not deleted**. The primitive placeholder trees, volcano cones and box crystals were removed from the decorator code.

### 7.6 Audio (v1.4, owner A) — `ReplicatedStorage.PF_Assets.Sounds` + `PF_Client.Audio.Sfx`
| Sound | When | How |
|---|---|---|
| `Transformation` | start of A's stage-up cinematic | 2D for the owner, positional at the planet core for visitors (roll-off 40–900 studs) |
| `Power_Up` | the stage "lands": end of the cinematic, or immediately on Skip | same as above |
| `Whoosh` | warp departure (full) and arrival (0.3 vol, 0.8 pitch) in `TravelFX` | 2D |
- Every sound goes through the `SoundService.PF_SFX` SoundGroup, which will become the hook for a future volume setting. A missing template is silent and never errors.
- B's `TransformationFX` plays no sounds, so nothing doubles. If B adds audio for reaction events (no stage change), use `Sfx.play` with another template.

### 7.7 Future branches — art stubs (v1.4)
`PlanetVisualProfile.ART_STUBS` covers astral, void, desert and mechanical. Each has a placeholder palette plus an existing builder set (`base`):
astral/void/mechanical → crystal builders, desert → primordial builders. The spec carries `themeLabel` (shown in the banner) and `artStub = true`.
Replacing a stub with real art means adding a real theme. **The attribute contract does not change.** The branches stay disabled in B's PlanetConfig.

### 7.8 Lighting key (v1.4, owner A)
Native stars need night, so `ClockTime` stays 20.5 and the sky is unchanged. The key light is the **moon**: `Lighting.Brightness` went from 3 to 10.
Screenshots: Living and Frozen surfaces and the tree meshes became readable on the lit hemisphere, and the station looks the same.
The moon direction is fixed, so each planet has a lit and a shadowed hemisphere.

### 7.9 Player interface (v1.5, owner A) — `PF_Client.UI`
One persistent ScreenGui `PF_UI` (ResetOnSpawn = false, ScreenInsets = CoreUISafeInsets, DisplayOrder 25). It is built once and reused.
**Data/actions consumed (Developer B's client contracts, read-only):**
| Screen | Reads | Sends |
|---|---|---|
| HUD | `ProfileClient.get()` (currencies, energyCap, level/xp), `EvolutionClient.stage()/materials()/reactions()` | — |
| DNA Lab | `EvolutionClient.dna()/materials()/reactions()/branches()/stage()/isOnOwnPlanet()` | `EvolutionClient.react(id)`, `EvolutionClient.commit(id)` (after a confirm dialog), `Travel_Warp {destination = slot}` |
| Inventory | snapshot materials/catalysts, `ItemCatalog`, `EconomyFormulas.sellValue` | `ProfileClient.sellMaterial(id, n)` |
| Harvester | snapshot energy/upgrades/stats, `EconomyConfig`, `EconomyFormulas` | `ProfileClient.purchaseUpgrade(id)`, `Travel_Warp` |
| Codex | `EvolutionClient.codex()`, `FormationRegistry`, `EvolutionConfig.STAGES`, snapshot stats/expeditions | — |
| Evolution screen | `EvolutionClient.Transformation` (own slot; stage-up / branch → full screen, formations → card) | — |
| Onboarding | snapshot stats.harvests / reactions / planet.formations / stage, `isOnOwnPlanet()` | `Travel_Warp` |
- **B's PlanetLabUI** is no longer started; the new DNA Lab replaces it, as its header allows. Main falls back to PlanetLabUI if the interface fails to boot. The B module file is untouched.
- **Harvest mode:** while `PF_HarvestHUD.Enabled` is true (Cosmic Core Hunt operating), the HUD hides and the hotkeys are off.
- **Prompts:** every ProximityPrompt is set to `Style = Custom` on the client and rendered by WorldUI. Behaviour, keys and hold duration are unchanged.
- **Hotkeys:** L DNA Lab · H Harvester · I Inventory · K Codex · O Settings · X Expedition (once available).
  Gamepad: DPad Up / Left / Right = DNA / Codex / Inventory, B = back.
**Requests to Developer B (blocking honest features, not UI work):**
- **Settings persistence:** add a `Settings_Update` remote plus `profile.settings`. Until then Settings are session-only, and the panel says so.
  The keys come from Prefs: EffectsVolume, ReducedMotion, UiScale, CameraSensitivity, InvertY.
- **Expeditions:** ExpeditionService plus the `Expedition_Start` / `Expedition_Claim` remotes and `snapshot.expeditions.active = {id, name, objective, startedAt, endsAt, team = {{name, contribution}}, rewards = {text}}`.
  The Expedition panel is built but dormant. Its dock button appears automatically when the remotes exist.
- **Reduced motion:** TransformationFX reads only `GuiService.ReducedMotionEnabled` / PFEffects. Please also honour the player attribute `PFReducedMotion` (set by Settings).
- **`Travel_Warp {destination = "home"}`** maps to the first active slot, not the player's slot (CharacterService prototype). The UI sends the slot number instead.

### 7.10 Planet scale and DNA-driven density (v1.11, 2026-11-23, owner A)
- `PFFormations` keeps meaning **purchases** (`"FirstForest:1"`). How many elements a purchase shows (trees in a forest, seas, cracks...) is
  derived on every client from the published `PFDna_*` by `PF_Shared.Planet.FormationDensity` — the only copy of the formula; servers and B
  never compute it. Same attributes → same visuals on every client.
- `FormationDensity` API (pure): `SPEC[id]` ({mode "cluster"|"spread", dna, from, lo, hi, perCluster?, maxSites}), `isDensity(def)`,
  `scaleFor(def)`, `footprintStuds(def)`, `siteCount(def)`, `growth(spec, dnaValue)`, `elements(def, owned, dna) -> (n, g)`,
  `layout(def, owned, dna) -> {{elements, level}}` per site, `variants(kind, level)`, `maxElements(def)`; constants `TIER_SCALE`,
  `GENERIC_PROP_SCALE`, `REFERENCE_RADIUS = 96` (zone sizes authored there are kept in studs).
- Formations not in `SPEC` (uniques / landmarks) still use `maxCount` as the hard cap.
- B impact: none (no new remotes, no attribute changes). If B ever wants to show element counts in UI, require the same module.

## 8. Cosmic Rifts — expedition system (v1.6, owner: Mission Systems; uses B's economy APIs read-only/through public methods)
**Files:** `PF_Shared/Rift/RiftConfig` (all tuning), `PF_Shared/Rift/RiftLayout` (pure seeded generator),
`PF_Server/Rift/RiftRules` (pure objective + reward rules), `PF_Server/Rift/RiftBuilder` (prototype art),
`PF_Server/Services/RiftService` (runtime; Main ORDER after HarvestService), client `PF_Client/UI/RiftHud` + `Panels/ExpeditionPanel`.

**Flow:** station portal (ProximityPrompt on `Station…RiftPortal.RiftSurface`, or `Expedition_Start`) → forming lobby (8 s; others within
34 studs of the portal may join; max 8) → arena in a free slot (max 8 concurrent, 1400 studs apart) → fragments → nodes 1→2→3 (in order) → core →
escape portal → rewards at escape.

**Remotes** (RemoteGuard, Action_Result, NetConfig default rate limit):
| Name | Payload | Codes |
|---|---|---|
| `Expedition_Start` | `{requestId}` | OK, ALREADY_IN_LOBBY, ALREADY_ACTIVE, OUT_OF_RANGE, BUSY, LOBBY_FULL, NOT_READY |
| `Expedition_Action` | `{requestId, action = "launch" \| "leave" \| "restart" \| "home"}` | OK, NOT_IN_LOBBY, NOT_IN_RUN, NO_RECENT_RUN, IN_RUN, NO_PLANET |
| `Expedition_Claim` | `{requestId, runId?}` | OK + `{summary, alreadyGranted = true}` (never grants), NOT_FOUND |
| `Expedition_State` (S→C) | forming: `{phase, endsAt, members, max}`; run: `RiftRules.publicState` (phase, timeLeft, nodes, pool/cost, secondaries, team…) | |
| `Expedition_Event` (S→C) | `{kind, …}`: fragment, node_done, final_open, core_sealed, fall, need_fragments, secondary_done/failed, knockback, escaped, summary, detached, error, left, ended | |
Portal attributes (public): `PFRiftLobbyCount`, `PFRiftLobbyEndsAt` (server time), `PFRiftActiveRuns`.

**Rewards** (server-only, `RiftRules.rewardsFor`, seeded per run+player, granted once per run+player at escape through
`EconomyService:Transact(…, "Expedition")` (fallback per-line `Grant`), `GrantXp`, `InventoryService:RecordExpedition` for completed runs).
Credits, Harvest Energy (clipped to the player's cap), XP, catalyst (chance), rift component = `CosmicCatalyst` (Hidden Prism or rare roll), matter cache.
Co-op bonus +8 %/extra explorer (max +24 %). Failure: 20 credits per stabilized node. Participation: ≥ 45 s active in the arena + escaped.

**Security:** objectives observed server-side only (10 Hz root sampling, server Touched for pickups, zone checks); node order enforced by the rules;
speed check (80 studs/s horizontal/up + tolerance) snaps back, 6 violations → removed; leaving the arena without a server move (e.g. a warp request) = leaving
the run; non-members inside an arena are sent to the station; claims are idempotent.

**Hooks in Developer A modules:** `CharacterService:PlaceAt`, `:WarpToCFrame(player, cf, label, onArrive)` (streams first), `CharacterService.SpawnOverride`
(respawn/recovery → rift checkpoint); `GravityFields.riftFields()` included in `buildDefault()`; TravelFX labels `rift` / `rift_exit`.

**Requests to Developer B:** (1) optional rift discovery ids in `ItemCatalog.DISCOVERIES` (components currently use `CosmicCatalyst`);
(2) `RecordExpedition` increments `totalCompleted` for any outcome — rifts only record completed runs; (3) consider a `NetConfig.RATE_LIMITS` entry
for `Expedition_*` (default 5 / 2 per s is used).

## 9. Cosmic world events + lightweight social (v1.7, owner: Live Gameplay; effects: Developer A)
**Files.**
- Shared: `PF_Shared/Events/EventConfig` (all tuning: scheduler, events, SHOWER/STORM/CONVERGENCE/SOCIAL, FX budgets and palette), `ShowerMath` (meteor paths, shared by client and server).
- Server rules (pure, Events.spec 16 cases): `EventScheduler`, `ShowerRules`, `StormRules`, `ConvergenceRules`, `SocialRules`.
- Server runtime: `Services/WorldEventService`, `Events/ConvergenceRig`, `Services/SocialService`.
- Client: `PF_Client/Events/EventClient` (state mirror), `EventFx` (effects registry), `Fx/<EventId>Fx` (default effects), `EventInteract` (capture input, reticle, markers), `UI/EventHud`, `Panels/EventsPanel` (J), `Panels/SocialPanel` (P, dock "Planets"), `Social/PlanetInfo`, `Social/Showcase`.

**Events** (EventConfig; durations in s, cooldown per event, global gap 210–420 s between events, max 2 concurrent, compatibility matrix):
| Id | Duration / cooldown | What players do | Reward path |
|---|---|---|---|
| `MeteorShower` | 150 / 540 | capture glowing meteors in occupied orbital zones (first valid capture wins, per-player cap) | matter at capture, `EconomyService` once per meteor |
| `SolarStorm` | 180 / 660 | complete energy reactions during the storm | 50 % of the reaction's matter refunded (floored, capped per player; catalysts never refunded) |
| `CosmicConvergence` | 240 / 780 | stabilize conduits (hold E) and carry flux cells into the reactor at THE FORGE | proportional, capped shares at the end; a leaver's settlement never exceeds a finisher's |
Phases: `incoming` (announced, 20 s) → `active` → `ending` (6 s wrap-up) → cleanup. No forced teleports, nothing touches player planets.

**Remotes** (RemoteGuard → `Action_Result`):
| Name | Payload | Notes |
|---|---|---|
| `Event_Action` | `{requestId, action = "capture" \| "sync", ...}` | rate 6 burst / 3 per s; captures validated against ShowerMath server-side |
| `Event_Notify` (S→C) | `{kind, ...}` feedback (captures, surges, tasks, catalyst info, summaries) | toasts + summary card |
| `Event_Dev` | `{requestId, action = "start" \| "stop" \| "testMode", eventId?, skipIncoming?, value?}` | **bound only in Studio** (F3 developer strip) |
| `Social_Action` | `{requestId, action = "react" \| "showcase" \| "visit" \| "mine", slot?, kind?}` | rate 4 burst / 1 per s; reactions Stellar / Wow / Inspiring |
| `Social_Notify` (S→C) | visitor / reaction notifications (throttled) | |

**Replication.** `ReplicatedStorage.PF_WorldEvents/<EventId>` (Configuration) attributes: `EventId, InstanceId, Name, Phase, PhaseEndsAt, ActiveAt, EndsAt, Outcome, TestMode, Version` + event-specific counters (late joiners get the state for free). Convergence rig: `Workspace.PF_Events.PF_Convergence` (conduit `PFState`, folder `PFStage`). Player attribute `PFConvCarrying` while carrying a flux cell. Social: `ReplicatedStorage.PF_Social/Slot_<n>` attributes (session-only counts; nothing persisted).

**Server signal (v1.9):** `WorldEventService.RewardGranted(player, instanceId, rewardKey)` fires after every event reward grant (used by quests: the rewarding instance counts, not every event that happens to be running).

**Studio test hooks** (ServerStorage, Studio only, not archivable): `PF_EventHook:Invoke("start", id, {force, skipIncoming})`, `("stop", id, outcome?)`, `("state", id)`, `("pickup", player, cellIndex)`; `PF_SocialHook`.

### 9.1 Developer A — replacing the event visuals (VFX integration guide)
1. **Never touch gameplay.** Capture input, the reticle and markers live in `EventInteract`; rewards, phases and timing are server-side. Effects are local and optional — the game must play identically with every handler removed.
2. **Register a handler** from any client module after `EventHud.init` (e.g. your own `EventArt` module required by `UIController`):
   ```lua
   local EventFx = require(PF_Client.Events.EventFx)
   EventFx.register("SolarStorm", {
       start = function(ctx) ... end,            -- event became visible (incoming or active)
       phase = function(ctx, phase) ... end,     -- "incoming" | "active" | "ending"
       update = function(ctx, dt) ... end,       -- per frame while running (keep it cheap)
       notify = function(ctx, msg) ... end,      -- Event_Notify payloads for this event
       meteorAdded = function(ctx, meteor) ... end,              -- MeteorShower only
       meteorRemoved = function(ctx, id, capturedByUserId, pos) ... end,
       stop = function(ctx) ... end,             -- optional: everything tracked is cleaned anyway
   })
   ```
   `register` stops the current handler and starts yours immediately if the event is running.
3. **Use the ctx helpers so cleanup is guaranteed:** `ctx.track(instance)`, `ctx.connect(signal, fn)`, `ctx.tween(obj, t, props, style?, dir?)`, `ctx.setLighting({Prop = value})` (restored to `ctx.original(prop)` at the end), `ctx.onCleanup(fn)`, `ctx.folder` (local Workspace folder), `ctx.data` (scratch). Everything tracked is destroyed, every connection/tween cancelled and Lighting restored when the event ends, the handler is replaced, or the handler errors.
4. **Respect the budgets and settings:** `ctx.quality` ("full" | "reduced" | "minimal"), `ctx.budget` (EventConfig.FX: max particles, render distance), `ctx.palette`, `ctx.reducedMotion()` (skip flashes/shake), `ctx.inRift()` (suspend inside a Cosmic Rift).
5. **Asset hooks without code:** a Model at `ReplicatedStorage.PF_Assets.Events.Meteor` (PrimaryPart required; `PivotTo` is used) replaces the default meteor. Meteor positions must come from `ShowerMath` (the same path the server validates), so do not animate meteors along your own paths.
6. **Convergence:** read the rig's attributes (`PFState` per conduit, `PFStage` on the folder) for authoritative state; add polish only.
7. **Verify:** Studio Play → F3 (Event_Dev strip) → start each event (Shift = skip the incoming phase) → end it; check the output for errors, that `Workspace.PF_ClientEvents` is empty and Lighting is restored afterwards, and repeat once with Settings → Effects = Minimal and Reduced motion on.

## 10. Analytics (v1.8, owner: Release / Live Ops)
**File:** `PF_Server/Services/TelemetryService` (Main ORDER after MonetizationService). Server-only, through Roblox `AnalyticsService`; every call is `pcall`-wrapped and logged only **after** the server committed the state change. Built-in dashboards already cover DAU, retention, session length, revenue and sales — not re-logged.

| Metric | Event | Fields |
|---|---|---|
| Tutorial completion | Onboarding funnel (`LogOnboardingFunnelStepEvent`): 1 Joined · 2 ReachedOwnPlanet · 3 FirstMeteorCapture · 4 FirstReaction · 5 TutorialComplete (second discovery or first stage-up) | — (earlier steps back-filled in order; returning players pre-marked from saved progress) |
| First meteor capture / evolution / expedition, second session | Custom `Milestone` | CF01 = FirstMeteorCapture \| FirstEvolution \| FirstExpedition \| SecondSession |
| Discovery counts | Custom `ReactionDiscovered` (value 1) | CF01 = reaction id, CF02 = "Total - N" |
| Monetization funnel | Funnel `Store` (`LogFunnelStepEvent`, session id = random GUID per store visit): 1 StoreOpened · 2 PurchasePrompted · 3 PurchaseCompleted | CF01 = "Item - <key>" |
| Economy health | `LogEconomyEvent`, currency "Credits", Source/Sink, ending balance after the change | CF01 = "Reason - <reason>"; Dev grants excluded |
| Quest completion | Custom `QuestClaimed` (value 1) | CF01 = "Daily - <questId>" \| "Weekly - <questId>", CF02 = "Manual" \| "Auto" (paid at period rollover); quest credits are economy Source type `TimedReward` |

**Hooks used:** `HarvestService.CaptureCompleted`, `EvolutionService.ReactionCompleted` / `StageChanged`, `ProfileService.ProfileLoaded` / `ProfileChanged`, `EconomyService.TransactionCompleted` / `LevelUp`, `MonetizationService.StoreFunnel (player, "opened" | "prompted" | "completed", kind?, key?)`, `PlanetDataService:IsOnOwnPlanet` (1 Hz).
**Privacy:** no names, chat, free text or device data; only fixed ids, small counts and enum-like labels; the player is attached by AnalyticsService itself. Limits used: 2 custom event names (of 100), 1 custom funnel + onboarding, 1 currency (of 10).
**Studio:** AnalyticsService records nothing from Studio; calls are mirrored into a bounded (300) Studio-only log: `ServerStorage.PF_TelemetryHook:Invoke("log" | "clear" | "stats")`.

## 11. Daily and weekly quests (v1.9, owner: Live Gameplay)
**Files:** `PF_Shared/Quests/QuestConfig` (pool + tuning), `PF_Shared/Quests/QuestRules` (pure rules, Quests.spec),
`PF_Server/Services/QuestService` (Main ORDER after MonetizationService), client `UI/Panels/QuestPanel` (dock "Quests", hotkey **Y**),
`UI/QuestNotifier` (toasts), Hud dock badge = claimable count.

**Rules.** 3 daily quests (reset 00:00 UTC) and 3 weekly quests (reset Monday 00:00 UTC), picked deterministically per player and period
(seed = user id + period index), one quest per metric, rift quests from level 3. Every daily quest is solo-completable in one session
(no events, no other players). A quest finished but not claimed when its period ends is **granted automatically** at rollover (nothing is lost).
Periods only roll **forward** (a lagging server clock never re-issues yesterday's quests). Rewards: credits (EconomyService reason `Quest`,
overflow clamp) + XP (`GrantXp`, reason `Quest`); a failed credit grant undoes the claim. Display-only daily streak (consecutive days with a claimed daily).

| Metric | Source (server only) |
|---|---|
| capture / perfect | `HarvestService.CaptureCompleted` (info.quality == "perfect") |
| reaction | `EvolutionService.ReactionCompleted` |
| sell | `EconomyService.TransactionCompleted` reason `Sell` (matter units) |
| earn | any positive Credits change except reasons `Quest` / `Dev` |
| rift | `expeditions.totalCompleted` increase (completed runs only) |
| event | `WorldEventService.RewardGranted` — each event instance counts once |

**Persisted** (`profile.quests`, additive, repaired by `ProfileSchema.reconcile` → `QuestRules.reconcile`; no schema bump):
`{ v, day = { p, q = { {id, n, c} } }, week = {…}, ev = {instanceId…≤8}, streak = { d, n }, claimed }`. Unknown quest ids are kept but never shown/paid.

**Snapshot** (`Profile_Snapshot.quests` = `QuestRules.view`): `{ claimable, streak, claimed, day = { endsAt, list = { {index, id, title, detail, target, progress, complete, claimed, credits, xp} } }, week = {…} }`.

**Remote:** `Quest_Action {requestId, action = "claim", period = "day" | "week", index = 1..3}` → `Action_Result` OK `{id, credits, xp}` |
NOT_COMPLETE | ALREADY_CLAIMED | UNKNOWN_QUEST | INVALID_PAYLOAD | NOT_READY. RemoteGuard default rate limit (5 burst / 2 per s).

**Signals:** `QuestService.QuestCompleted(player, kind, questId)`, `QuestService.QuestClaimed(player, kind, questId, auto)` (TelemetryService logs `QuestClaimed`).
**Studio hook:** `ServerStorage.PF_QuestHook:Invoke("state" | "raw" | "reset", userId)`, `("progress", userId, {metric, amount})`, `("offset", nil, seconds)` (test clock).
