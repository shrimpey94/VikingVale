# VikingVale — Project State Snapshot
_Generated 2026-05-30. Paste this whole file into a fresh AI conversation as cold-start context._

---

## 1. Identity

**VikingVale** (formerly VikingScape — old name was taken). Viking-themed top-down MMO built solo by a single developer ("Busterrdust" account, hardcoded admin) in **Godot 4.6**. Custom **Python WebSocket server** (`server/server.py`) on `0.0.0.0:8765` for multiplayer. Shipped as a Windows desktop build (`export_presets.cfg` → `VikingVale.exe`). Remote playtesting works via ngrok (`wss://shaft-expletive-voyage.ngrok-free.dev`).

300×300 tile world (TILE=32px → 9600×9600 px). All UI is built in code — no `.tscn` scenes are required for the gameplay UI; the project leans on programmatic `Control` building plus per-node `_draw()` for sprites.

GDScript runs with **strict mode + warnings as errors**. Common warnings you must respect: `INTEGER_DIVISION`, `SHADOWED_GLOBAL_IDENTIFIER`, `INFERRED_DECLARATION`, `UNUSED_PRIVATE_CLASS_VARIABLE`, `SHADOWED_VARIABLE_BASE_CLASS`. Use `@warning_ignore(...)` annotations when divisions are intentional.

---

## 2. Tech stack & layout

- **Client**: Godot 4.6 / GDScript. Project root `d:/viking-scape/`.
- **Server**: Python 3, `websockets` lib, SQLite (`game_server.db`, WAL mode) for persistent player data + auction house + clans + friendships + admin-placed world entities + entity edits. **Plus** a JSON file (`server/tile_overrides.json`) for the painted-tile map — that's a deliberate split (see §6).
- **Persistence**: server is canonical for player inventory, gold, skills, position, equipment, appearance, bank, task queue, tile overrides, world entities.
- **Autoloads** (`scripts/autoloads/`): `GameManager` (player state, inventory, XP, HP, equipment), `NetworkManager` (websocket, login, save, message routing), `Events` (signal bus — emit/listen from anywhere), `ThrallManager` (offline progression).
- **Hardcoded admin**: `ADMIN_USERNAME = "Busterrdust"` (server side) and the same string gates admin chat commands client side. Don't change without coordinating both ends.

### Directory landmarks
```
scripts/
  Player.gd            — controller, sailing, fishing, sea combat plumbing
  World.gd             — chunk streaming, monsters, NPCs, terrain
  Ground.gd            — biome cache, override map, shader-driven render
  Monster.gd           — land monsters (Area2D, server-managed HP)
  Boat.gd              — boat data table + hand-drawn boat sprite
  Fishing.gd           — bait + lure data (Phase 1 fishing rework)
  SeaMonsters.gd       — sea-monster encounter table
  HUD.gd               — chat, inventory, equipment, skills, minimap, modals
  Equipment.gd         — gear DB
  Interactable.gd      — resource nodes (tree, rock, etc.)
  LootDrop.gd          — world pickup items
  autoloads/
    GameManager.gd     — local state
    NetworkManager.gd  — client networking + receive switch
    Events.gd          — signal bus (lists every cross-script signal)
    ThrallManager.gd   — offline simulation
  ui/
    AdminPanel.gd      — admin overlay (F10), now tabbed (World / Items)
    UITheme.gd         — colors + stylebox factory used everywhere
    SkillsPanel.gd, CharPreview.gd, etc.
    ReelMinigame.gd    — fishing reel modal (Phase 2)
    BoatCombat.gd      — sea-monster encounter modal (Phase 3)
shaders/
  ground_noise.gdshader — legacy grain shader (still used pre-atlas-bake)
  terrain_blend.gdshader — atlas + lookup + per-pair blend + dither
server/
  server.py            — single-file Python server
  game_server.db       — SQLite (players, ah_listings, friendships, clans,
                         clan_members, world_entities, tile_overrides
                         (legacy/migrated), entity_edits)
  tile_overrides.json  — canonical store for painted tiles (after migration)
  profanity.py, start.bat, restart.bat
PROJECT_STATE.md       — this file
TODO_sprites.md        — icon backlog
export_presets.cfg     — Windows build target
```

---

## 3. Architecture decisions you must not regress

### 3.1 Shared world state is a **hybrid**, not "server spawns everything"

Resource and monster *positions/types* are identical across clients because they spawn from deterministic per-chunk RNG seeds in `World.gd._spawn_chunk_*` combined with `Ground.gd` biome noise. The Python server has **no world-gen** and **cannot** reproduce Godot's `FastNoiseLite` domain-warp byte-for-byte.

**Server owns only mutable state**: gather locks + depletion timers (resources), HP + participants + respawn (monsters), plus admin-placed entities and tile overrides.

Per-chunk IDs are derived identically client/server: `r:cx:cy:attempt_index` for resources, `m:cx:cy:i` for monsters (and `m:cx:cy:b` for the bridge monster). No handshake required.

Flow examples:
- **Gather**: click → `gather_request` → server locks → `gather_grant`/`gather_busy` → client swings → `gather_complete` → server broadcasts `node_depleted`; `_world_tick_loop` later broadcasts `node_respawned`.
- **Combat**: `monster_join` registers the monster from the first joiner's stats → `monster_damage` mutates shared HP → death broadcasts `monster_died` (XP split among participants, loot to top-damage dealer).

Both have a **2s fallback to local** if the server doesn't answer, so the game never breaks. **Do not port world-gen to Python.**

### 3.2 Login burst & WebSocket buffer (the "log in then disconnect" trap)

On login the server sends, in one burst: `login_ok` + online/idle `player_join`s + friends + clan info + `world_entities` + `tile_overrides` + `entity_edits`. A fully painted 300×300 map alone is ~3.6 MB.

Godot's `WebSocketPeer` defaults to a ~64 KB inbound buffer. Exceeding it makes the socket close immediately after login — the client silently falls back to OFFLINE/local mode (state is not LOGGED_IN; all admin sends become no-ops). This caused hours of confusion in past sessions.

**Fix already in `NetworkManager.connect_to_server`:**
```gdscript
_ws.inbound_buffer_size  = 1 << 24  # 16 MB
_ws.outbound_buffer_size = 1 << 22
_ws.max_queued_packets   = 32768
```
**Do not lower these.** If world data ever exceeds 16 MB, chunk the burst rather than shrinking the buffer.

### 3.3 Chunk streaming (the "1800-node lag" lesson)

`World._ready()` spawns nothing. Static stuff (town buildings, NPCs, bosses) lands in `_on_player_respawned` after first login/offline click. Procedural content streams in via chunks: **512×512px (16 tiles) per chunk, ACTIVE_RADIUS=3 → 49 active chunks max**, ~8 resource + 4 monster attempts per chunk = ~270 entities at any time. Updates throttled to 0.5s.

**Never** spawn large numbers of nodes unconditionally at scene load. Anything new world-content goes in `_spawn_chunk_resources` / `_spawn_chunk_monsters`, not `_ready`.

### 3.4 Tile override persistence

Per-tile SQLite writes were the biggest cost in the paint hot path. They're gone. The server holds `tile_overrides: dict` in memory; mutations set `tile_overrides_dirty = True`; an autosave coroutine flushes to `tile_overrides.json` every 30s (or immediately when the admin clicks Save Map / `admin_save_map`). Writes use atomic `tmp = path.with_suffix(".json.tmp"); tmp.replace(path)`. The legacy SQLite `tile_overrides` table is migrated once on first startup (the file becomes canonical after) — don't write to it.

### 3.5 Centralized tile mutation

`Ground.gd.apply_tile_change(tx, ty, biome_id)` is the **only** entry point that touches `_overrides` / `_biome_lookup_img` / collision / queue_redraw / `tile_changed` signal. The editor, network handlers, and bulk loader all route through it. Adding a multiplayer broadcast for tile paints later means connecting to the `tile_changed` signal — nothing else needs to change.

The bulk loader (`apply_tile_overrides`) deliberately **does not** emit per-tile signals — that path is data ingestion (login burst), not user action, so it doesn't echo to the network.

### 3.6 Ground rendering: per-biome atlas + biome lookup + fragment shader

Live since the rendering refactor. Pipeline:
1. `_ready` builds the 300×300 R8 `_biome_lookup_tex` from `_biome_cache`. Each pixel's R channel = biome id (0..15).
2. `_ready` then `await`s `_bake_biome_atlas()` — a one-shot `SubViewport` (32 × 16·32) renders one cell per biome via an inner `_AtlasBaker` Node2D that calls `_draw_biome_cell` (deterministic per-biome `hv = bid * 1009 + 37` so cells are reproducible).
3. After bake, `_activate_terrain_shader()` swaps in `terrain_blend.gdshader` with `atlas`, `biome_lookup`, `world_size_tiles`, `tile_px`, `atlas_rows` uniforms, sets `_atlas_ready = true`, calls `set_process(false)` (per-frame redraw cost gone), and triggers one `queue_redraw`.
4. `_draw()` is now one full-coverage `draw_rect(Rect2(0, 0, COLS*TILE, ROWS*TILE), white)` when `_atlas_ready`; the shader reads `VERTEX` via the `world_pos` varying and does per-fragment biome lookup, atlas sample, **per-pair edge blend** (path 2px@0.90 Bayer / water↔water none / water↔land 6px@0.30 soft / default 8px@0.85 Bayer), screen-pixel checkerboard, and the existing grain.
5. **Painting a tile = updating one R8 pixel.** Atlas never needs patching because it's keyed by biome id, not world position. Shader re-samples neighbors next frame, so edge blends "just work" without a per-tile atlas refresh.

`_draw_cpu()` (the previous per-tile dispatch + `_draw_tile` + `_blend_params` + `_biome_base_color`) is retained as the ~2-frame pre-bake fallback so there's no black flash at startup. Don't delete it unless you accept a brief startup flicker.

### 3.7 Login auto-minimap-refresh

After `apply_tile_overrides` finishes painting the server burst, it emits `Events.minimap_refresh` automatically so the minimap reflects the saved map without admin intervention. The Save Map button still emits manually on demand.

---

## 4. Player skills, combat, and HP

- Skills (per `GameManager.player_skill_xp`): `woodcutting, mining, fishing, foraging, smithing, crafting, cooking, construction, farming, melee, ranged, magic, defense, vitality, soul`.
- HP: `GameManager.current_hp` / `get_max_hp()` (= `vitality_lv * 10 + equipment_bonus("hp")`). Damage via `take_damage(amount)`; emits `player_hp_changed`. HP ≤ 0 emits `player_died`.
- XP API: `GameManager.add_xp(skill, amount)`. Levels capped at 99; XP curve in `_calc_level`.
- Inventory cap: **28 slots** (`INV_CAP = 28`, mirrored client + server). Stackable IDs: `arrows, feather, herbs, stick, stone, magic_dust, rune_essence`, plus ids ending in `_rune` / `_seed`, plus crops. Boats are **non-stackable** — one slot per boat.

---

## 5. Boats & sailing

`scripts/Boat.gd` defines `BOATS` dict (Phase 1 of fishing rework added combat stats):

| id | tier | speed | fish_bonus | req | hp | armor | cannon_dmg | harpoon_range |
|---|---|---|---|---|---|---|---|---|
| oak_rowboat       | 0 | 1.00 | 0.00 | 1  | 30  | 0 | 0  | 80  |
| pine_canoe        | 1 | 1.15 | 0.05 | 15 | 45  | 1 | 0  | 100 |
| cherry_sailboat   | 2 | 1.30 | 0.10 | 30 | 65  | 2 | 0  | 120 |
| ironwood_longship | 3 | 1.50 | 0.15 | 50 | 90  | 4 | 12 | 150 |
| frost_warship     | 4 | 1.70 | 0.20 | 70 | 130 | 6 | 18 | 180 |
| ancient_dragonship| 5 | 2.00 | 0.30 | 85 | 200 | 9 | 28 | 220 |

`req` = Construction level needed to build it. Top 3 tiers have cannons.

**Sailing flow** (`Player.gd`): launch removes boat from inventory and sets `GameManager.current_boat = bid`. Dock re-adds it via the inventory-full-safe path (see Bugs §10.2). `current_boat` is **client-only**, not persisted — so any uncontrolled session-end mid-sail leaves the boat in an unrecoverable state (the `/restore` admin command is the safety net; see §7).

---

## 6. Admin tooling

### 6.1 Admin Panel UI

`scripts/ui/AdminPanel.gd` — F10 to toggle. Now **tabbed**:

- **World tab**: existing place / delete / move / tile-paint controls + entity picker + biome picker + Save Map button.
- **Items tab** (added this session):
  - Online-player dropdown + ↻ refresh (auto-fetches first time the tab is shown).
  - Item ID `LineEdit` + qty `SpinBox` + Give / Take buttons.
  - Boat dropdown sourced from `Boats.BOATS` + Give-selected-boat button (auto-fills name + hull color).
  - Inventory `RichTextLabel` viewer.
  - "Restore last loss" button.

Toggles between tabs hide/show two `VBoxContainer` sections; tab buttons rebuild their stylebox to highlight the active one.

### 6.2 Admin chat commands

In `HUD.gd._try_admin_command` (only fires for `Busterrdust`):
- `/gold <name> <amount>` — adjust gold; can be negative.
- `/spawn <type> [level]` — spawn a monster at the player's position.
- `/give <name> <item_id> <qty>` — generic item give (gray color, id-as-display-name).
- `/giveboat <name> <boat_id>` — looks up name + hull colour from `Boats.data`.
- `/take <name> <item_id> <qty>`.
- `/restore <name>` — re-grants the most recent **unrestored** loss for that player.
- `/inv <name>` — request inventory; reply renders in the panel viewer.

### 6.3 Server-side admin handlers

All gated by `_is_admin(session)` and audited via `_admin_log(session, action)` → `[admin <ISO ts>] <username> <action>` to console.

- `_handle_admin_gold` (existing)
- `_handle_admin_place`, `_handle_admin_delete`, `_handle_admin_move`, `_handle_admin_spawn` (existing)
- `_handle_admin_tile_set`, `_handle_admin_tile_clear`, `_handle_admin_save_map` (existing)
- `_handle_admin_give_item` — uses `_inv_add_qty` (stackable-aware, respects `INV_CAP`)
- `_handle_admin_take_item` — uses `_inv_take_qty`
- `_handle_admin_view_inventory` — online from session, offline from DB
- `_handle_admin_list_players` — sorted online usernames
- `_handle_admin_restore_last_loss` — pops most-recent unrestored loss, re-grants, marks `restored: True`

When an admin mutates a target's inventory, the server updates `session["inventory"]` AND pushes `{type: "admin_inventory_set", inventory: [...]}` to the target's WS so their client view stays in sync (handled in `NetworkManager`'s receive switch — same shape as `clan_bank_result`).

### 6.4 Inventory loss audit log

Module state in `server.py`: `_inv_loss_log: dict[player_id, list]`, capped at `_LOSS_LOG_CAP = 20` per player. Each entry: `{ts, item_id, name, qty, color, restored: bool, reason: str}`. **Memory only** — losses across server restarts are not recoverable.

`_handle_save` calls `_detect_inventory_losses(session, prev_inv, new_inv)` before writing the DB. Comparison is naive sum-by-id: any item whose total quantity dropped between saves gets logged with `reason: "save_delta"`. False positives (legitimate consumption) are cheap — admin only acts on real losses via `/restore`.

---

## 7. Fishing rework (the big one)

5-phase rework. Scope was confirmed via `AskUserQuestion` on 2026-05-29:
- Combat style: **"all three layered"** (random sea-monster spawns + reel minigame + named bosses).
- Expansion: new deep-sea fish + tiered drops; **higher-tier boats with combat stats**; fishing skill rework with bait/lures/casts.
- Explicitly **rejected**: new biome-specific fishing zones (ice / helheim / ashlands water). Don't add biome-specific catch tables.

### Phase status

| Phase | Status | Date |
|---|---|---|
| 1 — data foundations | **DONE** | 2026-05-29 |
| 2 — reel minigame | **DONE** | 2026-05-30 |
| 3 — random sea-monster encounters | **DONE** | 2026-05-30 |
| 4 — named bosses at fixed tiles | **DONE** | 2026-05-30 |
| 5 — fishing skill rework (bait slot etc.) | **DONE** | 2026-05-30 |

### Phase 1 (DONE)
- `scripts/Fishing.gd` (new) — `BAIT` (earthworm, fatty_lard, kraken_bait) + `LURES` (runic_lure). Each entry: `catch_bonus`, `rare_bonus`, `monster_bonus`, `min_fishing`, `tier`, `color`. Static accessors: `is_bait`, `is_lure`, `bait_data`, `lure_data`, `tackle_data`.
- `scripts/SeaMonsters.gd` (new) — 16 entries: **4 shallow** (`shallow: true`, lv 1-5: crab_swarm, angry_seagull_flock, snapping_eel, river_serpent), **10 deep random**, **2 named bosses** (`spawn_weight: 0`, `boss: true`: jormungandr_spawn, drowned_god). `roll_encounter(fishing_lv, shallow)` does weighted pick filtered by `min_fishing_lv` AND `bool(m.shallow) != shallow`.
- `scripts/Boat.gd` — added `hp`, `armor`, `cannon_dmg`, `harpoon_range` to all 6 entries.
- `scripts/Player.gd` — `_DEEP_FISH` 3 → 11 entries, each with `min_lv` Fishing gate. `_pick_catch` now picks the highest-tier fish the player qualifies for (replaces `int(lv / 35.0)` formula).
- **Behavior change**: deep-sea catch variety expanded immediately. No combat/bait wiring yet — those landed in Phase 2/3.

### Phase 2 (DONE)
- `scripts/ui/ReelMinigame.gd` (new) — CanvasLayer modal: full-viewport ColorRect dim, centered gold-bordered panel with tension `ProgressBar` (red), stamina `ProgressBar` (blue), hint label, status label. **Hold SPACE or LMB to reel**; release to ease. Tuning constants at top of file.
  - `MAX_TENSION 100`, `REEL_STAMINA_PER_SEC 14`, `TENSION_RISE_PER_SEC 22`, `TENSION_FALL_PER_SEC 34`, `STAMINA_RECOVER_PER_SEC 4`, `BASE_STAMINA 60`, `STAMINA_PER_MIN_LV 1.2`, `OUTRO_SECS 1.0`.
  - Constant-reel snaps the line before draining stamina at any tier → forces reel/release cycles.
  - Stamina scales by catch `min_lv` so silverfin ≈ 5s, leviathan_eye ≈ 30s.
- `Events.gd` signals — `reel_minigame_start(catch_data)`, `reel_minigame_ended(catch_data, success)`.
- `Player.gd._attempt_boat_catch` — calls `_maybe_trigger_reel(catch, deep)`. If true, sets `_reeling = true` and defers grant. Trigger rules: **50% on any DEEP_FISH catch**, **30% on raw_shark/abyssal_eel**, never otherwise.
- `Player.gd._on_reel_minigame_ended` — success grants item + **2× XP** (active-play bonus) + "You landed the …" chat. Fail chats "The line snapped — the … escaped." Either way clears `_reeling`.
- `HUD.gd` — preloads `ReelMinigame`, listens for `reel_minigame_start`, spawns the modal as a HUD child so it dies with HUD on logout.

### Phase 3 (DONE)
- `scripts/ui/BoatCombat.gd` (new) — CanvasLayer modal. Real-time with per-action cooldowns:
  - **Harpoon**: 1.5s cooldown, base 6 + 0.4·melee_lv, ±20% randomization, reduced by monster `defense`.
  - **Cannon**: 4.0s cooldown, from `boat.cannon_dmg` (disabled for 3 low tiers).
  - **Flee**: chance `0.5 + 0.3·(boat.speed - 1.0)`, clamped 0.10..0.95. Failed flee → monster free hit.
  - **Monster auto-attack**: every 2.5s, `attack - boat.armor` (floor 1), ±20%.
  - Live cooldown timer text on buttons; bars and 5-line scrolling combat log.
- `Events.gd` signals — `sea_combat_start(monster_type)`, `sea_combat_ended(monster_type, outcome)`.
- `Player.gd._attempt_boat_catch` — after the cast-minigame win (Phase 5 removed the legacy cast-success roll), calls `_sea_encounter_chance(deep)` (0.08 deep / 0.05 shallow). On hit, calls `SeaMonsters.roll_encounter(lv, not deep)`. If a monster id is returned, sets `_in_sea_combat = true` and emits `sea_combat_start` **instead of** resolving a fish.
- `Player.gd._on_sea_combat_ended` (annotated `@warning_ignore("integer_division")`):
  - **"win"**: drops monster `loot` to inventory + half `xp_reward` to fishing + half to melee + chat "You defeated the …".
  - **"flee"**: no penalty, chat "You escaped from the …".
  - **"lose"**: clears `GameManager.current_boat` (boat is gone), 25% max-HP damage, calls `_force_dock_to_shore` (spiral-outward land-tile search) so player isn't stranded.
- `HUD.gd` — preloads `BoatCombat`, listens for `sea_combat_start`, spawns modal.
- **Decision recorded**: the original "wire Monster.gd to fall through to SeaMonsters" plan was **dropped**. Boat combat is its own UI system, not in-world Monster nodes — saves chunk-spawn complexity. If you ever want sea bosses visibly swimming, that decision can be revisited.

### Phase 4 (DONE)
- `scripts/SeaMonsters.gd` — `BOSS_SPAWNS` const lists each boss with `{id, tx, ty, radius, min_boat_tier}`. Jörmungandr at tx 6 / ty 180 / r3 / T3+, Drowned God at tx 8 / ty 110 / r3 / T4+ — both in Serpent Sea. `boss_spawn_at(world_pos, tile_px)` static returns the matching entry or `{}`.
- Boss entries in `SEA_MONSTERS` gained a `phases: Array` field. Each phase: `{trigger_pct, atk_mult, def_mult, msg}`. Jörmungandr has one 50% phase (1.5× atk, 0.7× def). Drowned God has two: 50% (1.4× atk, 0.7× def) and 20% (1.3× atk, 0.8× def).
- `BoatCombat.gd.setup` now does `(SeaMonsters.data(monster_type) as Dictionary).duplicate(true)` so mid-fight stat shifts don't mutate the const table. `_check_phase_triggers()` runs after every player hit and applies queued phases as the boss HP drops past each `trigger_pct`. Phase log lines are orange.
- **Boss flee is significantly harder**: `0.10 + 0.15·(speed - 1.0)` capped at 0.50 (vs random encounters' `0.50 + 0.30·(speed - 1.0)` capped at 0.95). Even a dragonship caps at 0.25.
- `Player.gd._attempt_boat_catch` now does the boss-tile check before the random-encounter roll. Off-tier boats get a chat warning ("your <boat name> is too small to face it") and the cast resolves as normal fishing. On boss-kill win, the id goes into `_defeated_bosses: Array[String]` so the spawn doesn't re-trigger every cast for the rest of the session.
- **Not server-persisted**: defeated state resets on login. Acceptable for v1 — bosses can be re-farmed each session, which is probably the right call.

### Phase 5 (DONE)
Built in three parts.

**Part 1 — bait slot in equipment UI**
- `Equipment.gd` — added `"bait"` to `SLOTS` and `"Bait"` to `SLOT_LABELS`. `def_for(item_id)` returns `{slot: "bait", name: ...}` for any item passing `Fishing.is_bait` or `Fishing.is_lure`, so the existing `is_equippable`/`target_slot`/`equip_item` flow handles bait with zero special-casing.
- `GameManager.gd` — new `equipped_bait()` returning `str(equipment.get("bait", ""))`. Swap-back tint is now `_swap_color_for(item_id)` — gear stays GRAY, bait keeps its real Fishing-table color.
- `HUD.gd` — bait slot added to the doll layout at `Vector2(128, 158)` (right of boots, waist line).
- Persists through the existing `set_appearance` save path — server-side just sees another key on the equipment dict.

**Part 2 — cast balance minigame**
- `scripts/ui/CastBalanceMinigame.gd` — CanvasLayer modal with full-viewport ColorRect dim, centered gold-bordered panel, speedometer arc ±90° drawn by an inner `_ArcDisplay` Control. Needle physics: sin(angle)·drift outward (scaled by elapsed time so the cast gets harder), small random perturbation, exponential damping. Hold SPACE/LMB or tap to push back toward center. Green zone in the middle accumulates held-time; red zones at ~±83° end the cast.
- **Difficulty scales by fishing level** (lerped on `_ready`):
  - Green half-width: 36° at lv 0 → 63° at lv 99.
  - Required held-green: 30s at lv 0 → 20s at lv 99.
- All tuning constants are at the top of the file.
- `Events.cast_minigame_start()` + `cast_minigame_ended(success)`.
- `HUD.gd` listens for `cast_minigame_start`, spawns the modal as a HUD child.
- `Player.gd._handle_sail_click` no longer waits 3.5s passively — it sets `_casting = true` and emits the start signal. The per-frame action-loop auto-fire of `_attempt_boat_catch` is gated on `not _casting` so the rod-swing animation continues during the minigame but no catch resolves underneath it.
- `Player.gd._on_cast_minigame_ended`: success → `_attempt_boat_catch()` (chains to boss check / sea encounter / reel trigger / instant catch). Fail → "The line snapped! Cast failed." + `player_stop_action`.
- **One-cast-per-click model**: all three modal-end handlers (`_on_cast_minigame_ended`, `_on_reel_minigame_ended`, `_on_sea_combat_ended`) now `Events.player_stop_action.emit()` so each cast requires a fresh click. The pre-Phase-5 "one click → continuous 3.5s casts" auto-loop is gone.

**Part 3 — lure rare_bonus + bait XP multiplier**
- `Player.gd._pick_catch` reads `_lure_data().rare_bonus` (lure-only — was any tackle in Part 1's first cut) to lift the deep-fish rare-pick chance above 0.40.
- Bait `catch_bonus` is now a **flat XP multiplier** at `add_xp` time, not a cast-success modifier. Applied in `_attempt_boat_catch` (instant catch) and `_on_reel_minigame_ended` (reel-success) via `_bait_xp_mult() := 1.0 + _bait_data().catch_bonus`.
- `_maybe_trigger_reel` still reads `_tackle_data().rare_bonus` (either bait or lure lifts reel trigger).
- `_sea_encounter_chance` still reads `_tackle_data().monster_bonus` (either bait or lure lifts encounter rate).
- New accessors: `_bait_data()` (returns {} if equipped item is a lure), `_lure_data()` (returns {} if it's a bait), `_bait_xp_mult()`.

**Catch guarantee (added 2026-05-30)**
- After a successful balance minigame, the catch is **guaranteed** — the legacy `chance := 0.55 + lv*0.003 + boat.fish_bonus` roll and the "the fish got away…" chat are gone. The only allowed failure after a successful balance is **inventory full**, pre-checked via `_has_inventory_room_for(item_id)` between `_pick_catch` and the reel-trigger branch, so the player doesn't fight a 30s reel for a fish they can't land. Sea-monster encounters and boss spawns still trigger on their own rolls before the fish-catch path runs — those are different outcomes, not "fish got away."
- `Boat.fish_bonus` is no longer read by anything. Left in `BOATS` as harmless data for a future passive-bonus surface.

**Side-effect fix forced by Part 1** (server-side)
- Equipping any gear removes it from inventory and writes to equipment. The `_inv_loss_log.save_delta` detector compared inventory snapshots only, so every equip was false-positive-logged as a loss. `_detect_inventory_losses(prev_inv, new_inv, prev_eq, new_eq)` now sums inventory + equipment on both sides — each occupied slot counts as +1 of its item id. True losses (boat mid-sail, save bug) still register. `_handle_save` passes the equipment snapshots.

---

## 8. Events bus (key signals)

`scripts/autoloads/Events.gd` is the cross-script signal hub. Highlights:

- **Action loop**: `player_start_action(type, target)`, `player_stop_action`, `node_hit`, `node_depleted`, `inventory_changed`, `equipment_changed`, `xp_gained`, `item_gained`.
- **Combat**: `open_combat(monster)`, `combat_ended`, `monster_targeted`, `monster_killed`, `player_hp_changed`, `player_died`, `player_respawned`.
- **Shared world**: `gather_granted`, `gather_denied`, `node_remote_*`, `node_states_received`. `mob_state`, `mob_hit`, `mob_died`, `mob_respawned`, `mob_dead_on_join`, `mob_full`, `mob_states_received`.
- **Sailing/fishing**: `boat_prompt`, `boat_toggle`, `reel_minigame_start/ended`, `sea_combat_start/ended`.
- **Admin**: `world_entities_received`, `world_entity_added/removed/moved`, `tile_overrides_received`, `tile_override_set/cleared`, `entity_edits_received`, `entity_edit_applied`, `minimap_refresh`, `admin_player_list_received`, `admin_inventory_view_received`.
- **Misc**: `chat_message`, `npc_dialogue`, `open_forge`, `open_cooking`, `open_crafting`, `open_construction`, `open_bank`, `bank_changed`, `idle_summary`, `thrall_*`, `quest_accepted`, `quest_updated`.

Every signal has `@warning_ignore("unused_signal")` so the file doesn't have to declare emitters and listeners in the same script.

---

## 9. Server message types (route via `_route_message`)

Auth: `register`, `login`, `ping`. After that, `session is None` → `error: Not authenticated`.

Gameplay: `move`, `skill_action`, `save`, `set_task_queue`, `set_appearance`, `lookup_player`, `chat`.

Auction house: `ah_browse`, `ah_my_listings`, `ah_list`, `ah_buy`, `ah_cancel`.

Trading: `trade_request`, `trade_accept`, `trade_offer`, `trade_lock`, `trade_confirm`, `trade_cancel`.

Friends: `friends_list`, `friend_request`, `friend_accept`, `friend_decline`, `friend_remove`, `whisper`.

Admin: `admin_place`, `admin_delete`, `admin_move`, `admin_gold`, `admin_spawn`, `admin_tile_set`, `admin_tile_clear`, `admin_save_map`, `admin_give_item`, `admin_take_item`, `admin_view_inventory`, `admin_list_players`, `admin_restore_last_loss`.

Clans: `clan_info`, `clan_create`, `clan_invite`, `clan_accept`, `clan_decline`, `clan_leave`, `clan_kick`, `clan_bank_deposit`, `clan_bank_withdraw`.

Farming: `build_farm_plot`.

Shared world: `gather_request`, `gather_complete`, `gather_release`, `node_states`, `monster_join`, `monster_damage`, `monster_leave`, `monster_states`.

Unknown types are ignored, and handler exceptions are caught — one bad message can't kick a player offline.

---

## 10. Known issues / things to be aware of

### 10.1 Flagged TODOs (intentional, not bugs)

- **Bait icons not baked**: `earthworm`, `fatty_lard`, `kraken_bait`, `runic_lure` have no PNG art in `assets/icons/`. The equipment bait slot renders the empty texture; the inventory falls back to the colored circle from the loot color. Sprite TODO from `TODO_sprites.md`, not a functional bug.
- **Hull HP persists within a sailing session, not across docks** (added 2026-05-30 alongside the floating HP bar). `GameManager.current_boat_hp` + `current_boat_max_hp` are seeded to max on `_launch_boat`, cleared to 0 on `_dock_boat` and on sea-combat "lose". Damage from Phase 3 monster attacks writes through and emits `Events.boat_hp_changed`. Player.gd draws a small floating bar below the hull only when `current < max`. Cross-dock persistence (per-boat-instance HP stored on the inventory item itself) is **not** implemented — boats are still tier-fungible. If you want a damaged boat to remain damaged after re-docking, you'd add a per-item HP field to inventory entries (server save schema unchanged otherwise).
- **`Monster.gd` not extended to dispatch sea-monster types**: the original Phase 3 plan involved a fall-through `match` branch reading `SeaMonsters.data(monster_type)`. We dropped it because boat combat is UI-only — Monster.gd doesn't need to know about sea types. If you ever do in-world sea-monster spawns (e.g. a boss visibly swimming), revisit this.
- **`_draw_cpu()` (CPU per-tile fallback) is still in `Ground.gd`** along with `_draw_tile`, `_blend_params`, `_biome_base_color`, and the 15 `_draw_<biome>` funcs. Active only during the ~2-frame window before the atlas bake completes. Could be deleted to accept a brief startup flicker.
- **`apply_tile_change` emits `tile_changed` even on bulk admin paints** — that's intentional for the future MP broadcast path; the bulk loader path uses `apply_tile_overrides` which deliberately skips the signal.
- **Inventory loss log is in-memory only** — losses across server restarts are gone. Acceptable since the typical loss scenario (sailing crash mid-flight) is recovered within the same session.
- **Boats are non-stackable** but inventory ops assume that. If you ever make them stackable, audit `_inv_add_qty` / `_inv_take_qty` / `_pick_catch`.

### 10.2 Known bugs

#### Fixed in this session
- **`_unload_chunk` "Trying to cast a freed object"** ([World.gd]): an admin delete (or any path that calls `queue_free()` on a chunk entity) left a stale reference in `_active_chunks[key]`. Fix: filter freed-object Variants with `is_instance_valid(node)` **before** the `as Node` cast. Same pattern exists at `_on_world_entity_moved` (line ~421) and `_reg_mob` (line ~427) — they haven't triggered the same crash historically, but they're vulnerable to the same class of bug.
- **Boat lost when docking with full inventory**: `GameManager.add_item` silently no-ops on a full bag, which would lose the boat permanently. `_dock_boat` now checks `GameManager.free_slots() > 0` first; if no slot, it spawns the boat as a `LootDrop` pickup at the dock point via the new `_spawn_boat_pickup` helper.
- **Boat lost on logout with full inventory**: same pattern as the dock case. `NetworkManager.logout` now uses the same `free_slots()` check, and spawns a `LootDrop` at the player's position via the new `_drop_boat_pickup` helper. Both helpers (Player's and NetworkManager's) duplicate the LootDrop-spawn boilerplate intentionally — refactoring to a shared utility is a candidate cleanup but the duplication is 6 lines.

#### Not yet fixed (you should be aware of)
- **Boat lost on uncontrolled session-end mid-sail** (force-quit, crash, server kill). Root cause: `current_boat` is client-only and not persisted, and `_launch_boat` strips the boat from inventory. The proper fix is to either:
  1. Not strip the boat on launch (mark "in use" instead, check launch eligibility differently), or
  2. Persist `current_boat` server-side as ephemeral state restored on next login.
  Loss-detection + `/restore` is the safety net, not the cure. Sea-combat "lose" outcome also clears `current_boat` — that's intentional and not part of this bug.
- **`_inv_add` server-side helper still hardcodes color `[0.7, 0.7, 0.7, 1.0]`** when adding a new slot (in legacy paths, not in the new `_inv_add_qty` which takes a real color). Idle-progression item grants therefore look gray in the inventory. Cosmetic; could be a follow-up.
- **Tile painting on a tile that has an entity** doesn't move/remove the entity. The entity stays at the original world position, may now overlap an "impassable" tile (water/cliff), and the player can get stuck or visually weird. Workaround: admin-delete the entity first.

### 10.3 Watch-outs

- **`name` is a Node base-class property** — local vars named `name` will get a SHADOWED_VARIABLE_BASE_CLASS warning that errors in strict mode. Use `uname`, `iname`, etc.
- **Integer division warnings** — `xp / 2` is intentional; annotate with `@warning_ignore("integer_division")` on the function.
- `as Node` on a freed-object Variant **throws** in current Godot — always `is_instance_valid()` first.
- `Control` does not have a `.color` property. Use `ColorRect` if you need a colored background, or apply `modulate` to a sub-`CanvasItem` that draws something.
- Default `add_item` is non-stackable for unknown ids — boats, gear, fish all take individual slots. Make sure the qty matches reality.

---

## 11. How to pick up work

- **Resume Phase 4**: extend `BoatCombat.gd` (or subclass) for multi-phase encounters; hardcode 2-3 boss spawn tiles; check tile coords against player pos in `Player.gd._attempt_boat_catch` before the normal encounter roll; spawn the boss directly by id.
- **Resume Phase 5**: add a bait slot to `Equipment.gd` (need a new slot type the equipment UI renders), persist via the existing equipment save path, read `equipped_bait` in `_maybe_trigger_reel` / `_sea_encounter_chance` / `_pick_catch` to apply bonuses.
- **Fix the logout-full-bag bug**: mirror the `_dock_boat` fix in `NetworkManager.gd.logout` — check `GameManager.free_slots()` first, spawn a `LootDrop` if no room. The drop point is the player's `global_position`.
- **Fix the launch-boat-loss class**: bigger refactor — choice point on whether to keep the boat in inventory while sailing (option 1) or persist `current_boat` server-side (option 2). Option 1 is simpler. Either choice needs a migration plan for boats currently lost.
- **Sprite icon backlog**: see `TODO_sprites.md` for icon items still to bake.

---

## 12. The user

The developer's account is `Busterrdust` (the hardcoded admin). Account email on file is `27k7rc78c8@privaterelay.appleid.com`. They're solo, they ship fast, they prefer terse responses, and they expect you to verify before claiming success on UI work (since type-checks don't catch feature correctness — they explicitly call this out). When in doubt about scope, ask via a focused question with 2-4 options rather than guessing; they'd rather be brief than redirected mid-build.

Don't bundle "while we're here" refactors with the asked-for task. Surgical fixes preferred; flag latent risks rather than touching them without permission.
