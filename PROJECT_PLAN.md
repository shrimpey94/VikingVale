# VikingVale — Master Plan (Past · Present · Future)
_Single source of truth for planning. Audited 2026-09-05. Shipped version: **v1.6.8**._
_Deep-dives live in their own files (see §8); this is the map that ties them together._

---

## 0. MVP verdict (the "do we have an MVP?" answer)
There is **no formal MVP doc** — and the project doesn't need one, because it's **well past MVP**. The minimum viable product effectively shipped at **v1.5.0** (multiplayer + chat + ranks + server persistence). Today (v1.6.8) VikingVale is a **mature, feature-complete MMO**: skilling, combat (melee/ranged/magic), PvP, warbands/territory, quests, dungeons, farming, fishing, thralls, caravans, an endgame (Seal of Kings), a full admin world-editor, and **two clients (2D + low-poly 3D)** sharing one server.

**So the real milestone is not "MVP" — it's "LAUNCH-READY."** The one hard blocker between here and a public/beta launch is **anti-cheat (v1.7.0)**: the client is currently authoritative over XP/inventory/combat, so a modified client can grant itself anything. Everything else is polish + content. See §2 for the launch-readiness audit.

---

## 1. What VikingVale is (identity)
- Viking-themed top-down MMO, **solo-built** in **Godot 4.6** (GDScript, strict mode / warnings-as-errors). Admin account: `Busterrdust`.
- **Custom Python WebSocket server** (`server/server.py`, SQLite `game_server.db` WAL + `tile_overrides.json`). Server is canonical for gold/bank/pvp-tokens/world-entities/reputation/kills (and, as of 1.7.0, combat damage).
- **300×300 tile world** (9600×9600 px), chunk-streamed. UI is built in code (no gameplay `.tscn`).
- **Two clients off one server:** 2D (`World.gd`) and low-poly 3D (`World3D.gd`), live-switchable, sharing all autoloads + server.
- **Deploy:** server box runs GitHub code only → any `server.py` change needs **push + restart**; client changes need a **Godot re-export**. `release.bat <ver>` bumps `version.txt` + publishes + posts the changelog to Discord.

---

## 2. LAUNCH-READINESS AUDIT (the checklist that matters now)
Ranked by what blocks a public/beta launch.

| # | Item | State | Blocker? |
|---|---|---|---|
| 1 | **Anti-cheat / server authority (v1.7.0)** — client owns XP/inventory/combat | 🔨 **In progress** — B1 (combat damage) built; B2/B3/B4 pending | **YES — hard blocker** |
| 2 | **Combat feels right after B1** (fresh server damage formula) | 🔨 built, needs live-tune | Soft — must feel good |
| 3 | **Monster/NPC placement complete** (world doesn't feel empty/broken) | ⏳ partial — `PLACEMENT_LIST.md`, some hand-placed | Soft |
| 4 | **Quests all completable** (no soft-locks) | ✅ audited + fixed (token/pledge restructure) | No |
| 5 | **New-player onboarding** (first-login flow, tutorial) | ✅ exists (auto-login, guides, backstory) | No |
| 6 | **Mobile access** (iPhone) | 🧊 hard (Apple wall); web-export/PWA is the escape hatch | No (desktop-first) |
| 7 | **Single-session-per-IP (B0)** | ❌ **skipped** — tunnel hides real IPs (playit.gg relay); per-account single-session already works | No |
| 8 | **Content pipeline / marketing** (YouTube devlogs) | 🔨 AutoContent exists; **bots likely being dropped** (manual recording) | No |

**Bottom line:** finish **1.7.0** (items 1–2) and you are launch-ready. Everything below #2 is polish you can ship into after launch.

---

## 3. PAST — Shipped (condensed, newest first)
- **1.6.8** — Auto-logins · **1.6.7** — camera fixes · **1.6.6** — skill mini-games (archery/runestone/melee-dummy)
- **1.6.5** — Guards/Walls (monster wall-respect) · **1.6.4** — Guards/Walls · **1.6.3** — Fishing overhaul (QTE reel, trophies, sea-combat depth)
- **1.6.2** — Town Walls & Farming (full Farming skill, attackable named walls) · **1.6.1** — 3D visual overhaul + caravans + Discord
- **1.6.0** — **3D mode (beta)** — parallel 2D/3D client
- **1.5.5** thralls/guides · **1.5.4** character customization + monster art · **1.5.3** Kjelvik castle + city watch + level rebalance · **1.5.2** caravans + reputation · **1.5.1** thralls · **1.5.0** — **Chat / live ranks / thralls (the de-facto MVP)**
- **≤1.4.x** — PvP, gear/progression, warband/territory, Seal-of-Kings endgame, core skilling.

---

## 4. PRESENT — Built this cycle, NOT yet shipped (pending deploy)
These are done + parse-clean but await a version bump / push / re-export. Likely ship as **v1.6.9 (editor + streaming)** then **v1.7.0 (anti-cheat)**.

### Admin World-Editor arc ✅ built (client + server) — see `ADMIN_EDITOR_AUDIT.md`
- **Inspect / Edit** placed entities (live property editor) + **`admin_edit_entity`** server handler.
- **Undo** (place/delete/move/rotate/edit, Ctrl+Z) + **separate Tile-paint Undo**.
- **Entity Browser** (search + Go/Edit) · **Minimap Teleport** (admins) · **World Validator** (broken-ref scan).
- **Procedural NPC/monster editing** — data-override in `entity_edits.data` (name/dialogue/level), preserves existing hand-edits.

### Streaming refactor ✅ built (both clients) — see `project_admin_editor_audit` memory
- Admin (`a:`) entities now **chunk-stream** at the same radius as procedural content (walls/stations/farm/seals/doors stay always-loaded). Fixes moved-node culling; scales entity count. Two follow-up bugs (move-snap-back, missing-on-login) fixed.
- **Decided NOT to do now:** full-cull of the always-loaded set (reverted — bad feel); 3D terrain streaming (map too small vs fog — no gain); server-side area-of-interest (premature, <1% of burst cap).

### v1.7.0 anti-cheat — **B1 (combat damage) ✅ built** — see `project_v170_server_authority` memory
- Server now **computes every hit** (fresh formula: combat level + weapon tier vs monster level, server-owned hit/miss/crit). Client sends an **attack intent**; injected-damage / one-shot cheat is dead.
- Range + attack-cooldown gates were **pulled out** (were false-rejecting legit swings on position-sync slop) — to be re-added as a tuned hardening pass.

---

## 5. FUTURE — Roadmap (ordered)

### 🔒 v1.7.0 — finish anti-cheat (LAUNCH BLOCKER) — slices
Each ships independently. Order matters (can't stop trusting client XP until the server computes it).
- **B1 — Combat damage** ✅ built. TODO: live-tune the formula; re-add range/cooldown hardening.
- **B2 — Gather/craft authority** ⏳ — server rolls success + grants item + XP; server-timed node regen.
- **B3 — Server-owned inventory** ⏳ — every add/remove validated; client stops sending its inventory in `save`. (Loot rolls move here.)
- **B4 — Server-computed XP** ⏳ — all XP from server-awarded actions; `save` stops accepting `skill_xp`. (Locks the per-swing/per-kill XP grants.)
- **B0 — Single-session-per-IP** ❌ skipped (tunnel hides IPs; revisit only with PROXY-protocol on the tunnel).

### 🗺️ World & content (post-launch polish)
- Monster/NPC **placement pass** (`PLACEMENT_LIST.md`).
- **Dungeon** fixes/expansion (cave retheme, wall-respecting AI, room editor — flagged).
- Worldbuilding: Eastmark ashlands territoriality; Helheim dragon-folk; Northern troll raid-bands; more dungeons/terrain.
- **Convert fixed NPCs/bosses → admin-placed** (optional; now perf-safe via streaming — makes them first-class editable). Data-override already covers editing.
- Quest voice-over (`VO_SCRIPT.md` ready; user has a voice-acting group).

### 🎬 Content pipeline / marketing — **DECISION PENDING**
- **Likely dropping in-game bots** → manual recording only (NPCs are the only "bots"). If dropped, AutoContent simplifies to the record/clip/template/YouTube half. See `project_autocontent_direction` memory.

### 🧊 Bigger bets (backlog)
- **Infinite / edge-expanding world (late-game, v2)** — Minecraft-like but server-persistent: the map auto-generates new **300×300 regions ("big chunks")** at the edges (loading-screen-gated), saved permanently, revealed per-player by discovery, with a server-RAM cap so it can't grow unbounded. **Full design + prerequisites in `INFINITE_WORLD_DESIGN.md`.** This is the **trigger** for — and hard-requires — **server-side AoI (C)** + **3D terrain streaming (B)** + a **region-aware coordinate refactor**, all on top of **1.7.0**. Biggest single feature after launch; supersedes the old "enlarge the single grid" note.
- **Terraform-from-ship** endgame (claim/sculpt ocean → sea strongholds) — pairs with the world-expansion work above.
- **Mobile**: web-export/PWA path (no Apple tax) as the way onto phones — for the owner first, players later.
- Endless/Quickplay modes (`ENDLESS_MODE_DESIGN.md`, `QUICKPLAY_DESIGN.md`), pets depth, weather/dynamic events, PvP arena, dungeon instancing.

---

## 6. Invariants — don't regress (read before touching these)
- **`players.id` is a TEXT hex token** — never `int()` it (collapses to 0, broke PvP once).
- **Gold / pvp_tokens / bank_gold are server-authoritative** — never grant client-side. (XP/inventory/combat move server-side in v1.7.0.)
- **Login sends full world state in one burst** — client WS buffer must stay ≥16MB or it drops to offline.
- **Chunk streaming is the perf-critical "never regress" system.** Admin entities now stream through a parallel layer; don't entangle it with procedural chunk lists.
- **Every admin/map edit is server-stored + broadcast** — never client-local.
- Kjelvik castle bounds live in **three synced places**; interiors at y≈12000+.

---

## 7. Deploy quick-reference
- **Server change** (`server.py`) → **push + restart the box** (it runs GitHub code only).
- **Client change** → **Godot re-export**.
- **Both** for a normal release; `release.bat <ver>` bumps `version.txt` + Discord changelog.
- Current **pending deploy:** the whole §4 batch (editor + streaming + B1) — server push + re-export, version bump to 1.6.9 / 1.7.0.

---

## 8. Doc map (where the deep-dives live)
| File | Covers |
|---|---|
| **PROJECT_PLAN.md** (this) | The master past/present/future plan |
| `ADMIN_EDITOR_AUDIT.md` | Admin editor audit + the arc built this cycle |
| `CONTENT_AUDIT.md` | Everything doable in-game; content gaps |
| `PLACEMENT_LIST.md` | Monster/NPC placement to-do |
| `VO_SCRIPT.md` | Actor-ready quest voice-over script |
| `PROJECT_STATE.md` | Cold-start context dump (dated 2026-05-30) |
| `INFINITE_WORLD_DESIGN.md` | Edge-expanding infinite world (late-game v2) — design + prerequisites |
| `ENDLESS_MODE_DESIGN.md` / `QUICKPLAY_DESIGN.md` | Mode design sketches |
| `ICON_AUDIT.md` / `TODO_sprites.md` | Art/icon gaps |
| Memory (`~/.claude/.../memory/`) | Living notes: `project_v170_server_authority`, `project_admin_editor_audit`, `project_autocontent_direction`, etc. |
