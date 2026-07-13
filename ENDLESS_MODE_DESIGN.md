# Endless Mode — Design Document

A roguelite wave-survival mode. Player drops into a small arena at max
level, fights ever-harder waves of monsters, picks one of three random
perks after each wave, and tries to survive as long as possible. Map
expands every 10 waves. Run ends on death; only cosmetics + starting
weapon blueprints carry forward.

---

## Core Loop

Spawn → Build Phase → Wave → Reward → Build Phase → Wave → repeat forever.

---

## Starting State — MMO Character Snapshot

Endless does **not** hand you a fresh max-level character. It snapshots
your MMO character at run start. See how far your levelled build can go
with only the gear you've actually earned. This is Endless's core
identity: progression-friendly, uses what you've built, rewards MMO
investment.

### Snapshot rules

- **Levels**: snapshot from the player's MMO row at run start. If your
  MMO character is level 42 Attack / 60 Woodcutting, the run begins at
  those levels. No auto-max.
- **Inventory + equipment**: bank contents + current inventory +
  equipped gear at run start. Only items you have **crafted, personally
  earned (drops/gathering), purchased from a vendor, or bought from the
  Auction House** carry in. Admin-granted items count only if the admin
  flagged them as such.
- **Snapshot semantics**: it's a COPY, not a transfer. Items are
  **not** consumed from the MMO bank when the run starts. Run ends →
  whatever the Endless character had is discarded; the MMO bank is
  untouched.
- **Naked-fresh accounts** enter with no gear — they haven't earned
  anything yet, so there's nothing to snapshot. Fair.
- **Loot during the run** is available only inside the run. Nothing
  carries back to MMO.
- **Meta-progression unlocks** (see below) are ADDITIVE to the
  snapshot: your unlocked starting weapon blueprint replaces the empty
  weapon-chest fallback for players whose snapshot didn't include a
  weapon.
- **Nearby world**: empty plot of land to build your base on. Ammo /
  rune chest nearby for consumables the snapshot didn't include.

---

## Wave System

Monsters spawn from the edges of the current map area in scaling waves.
Difficulty is tied to **wave number, not player level** (since everyone
starts max). Later waves mix enemy types — melee + ranged + magic
together. A boss appears every 5th wave.

### Wave composition table

Threat budget per wave = `30 + wave * 8`. Server picks monster types
that fit the budget; the table below shows the intended composition.

| Wave | Composition | Threat | Notes |
|---|---|---|---|
| 1 | 6× rat (lv 3) | 18 | Warm-up |
| 2 | 8× rat (lv 4) + 2× wolf (lv 5) | 42 | |
| 3 | 4× wolf (lv 6) + 6× rat (lv 5) | 54 | |
| 4 | 6× wolf (lv 7) + 4× rat (lv 6) | 66 | Last warm-up |
| **5** | **Mountain Pass Goblin Captain (lv 12) + 4× goblin (lv 7)** | **40 + 28 boss** | First boss |
| 6 | 6× skeleton (lv 8) + 4× rat (lv 8) | 80 | Skeletons enter |
| 7 | 8× skeleton (lv 9) | 72 | |
| 8 | 6× skeleton (lv 10) + 4× wolf (lv 9) | 96 | |
| 9 | 10× skeleton (lv 10) | 100 | |
| **10** | **Frost Wyrm (lv 25) + 6× ice draugr (lv 12)** | **72 + 25 boss** | First MAP EXPANSION |
| 11 | 4× goblin archer (lv 11) + 6× skeleton (lv 11) | 110 | Ranged enters |
| 12 | 8× goblin archer (lv 12) + 4× skeleton (lv 13) | 148 | |
| 13 | 6× skeleton (lv 14) + 6× goblin archer (lv 13) | 162 | |
| 14 | 4× troll (lv 15) + 6× goblin archer (lv 13) | 138 | Trolls = HP sponges |
| **15** | **Ancient Troll (lv 30) + 4× troll (lv 14)** | **56 + 30 boss** | Second boss |
| 16 | 4× draugr necromancer (lv 16) + 6× skeleton (lv 14) | 148 | Magic enters |
| 17 | 6× spectral warrior (lv 15) + 4× necromancer (lv 15) | 150 | |
| 18 | 4× necromancer (lv 17) + 4× spectral warrior (lv 16) + 4× troll (lv 15) | 192 | |
| 19 | 8× spectral warrior (lv 17) + 4× troll (lv 17) | 204 | |
| **20** | **2× Lava Crawler (lv 25) + 8× spectral warrior (lv 17)** | **136 + 50 boss** | DUAL BOSS — second MAP EXPANSION |
| 21-29 | Full mix scaling — all monster types weighted by threat budget | 198-262 | Drift mid-game |
| **30** | **Frost Giant (lv 40) + 5× elite skeleton (lv 22)** | **110 + 40 boss** | Third MAP EXPANSION |
| 31-49 | Hyperscale — all types, +1 level per wave | 270-422 | Punishing |
| **50** | **Níðhöggr (lv 60)** — single appearance | **boss** | Same boss as MMO endgame |
| 51+ | Procedural — pick from all enemy types weighted by total threat budget that ramps +5% per wave forever | — | Endless |

Boss spawns are pre-baked at waves 5/10/15/20/30/50. Boss arena tiles
unlock at wave 30 (via the third map expansion) so Níðhöggr at wave 50
has room.

---

## Build Phase

Between waves, a 60-90 second timer counts down. Player has three
choices:

- **Build** — place walls, traps, towers, defensive structures.
- **Fix** — repair damaged structures, heal yourself, restock ammo from
  the resupply chest near base.
- **Skip** — end build phase early, next wave starts immediately
  (hardcore players hunting fastest-clear records).

---

## Roguelite Reward System

After each wave, pick ONE of three random perks. Permanent for the run.
Rarity weights per pick: **60% common / 25% uncommon / 12% rare / 3% legendary**.

### Common (8 perks)

1. **Sharpened Steel** — +5% melee damage
2. **Quick Hands** — +10% attack speed (all styles)
3. **Trail Rations** — +5% XP from kills
4. **Salvager** — +10% gold from kills
5. **Iron Skin** — +5% damage reduction
6. **Light Feet** — +8% movement speed
7. **Reinforced Quiver** — +20% arrow capacity
8. **Steady Hand** — +5% projectile accuracy

### Uncommon (6 perks)

9. **Bloodthirst** — 3% lifesteal on melee hits
10. **Loot Goblin** — double drops on every 5th kill
11. **Frost Touch** — magic hits apply a 1.5s slow (-30% speed)
12. **Field Medic** — +2 HP/sec out of combat
13. **Stone Skin** — +15% damage reduction vs ranged
14. **Auto-Repair** — your structures regen 1 HP/sec

### Rare (4 perks)

15. **Echo Strike** — 15% chance for melee hits to deal a second smaller hit
16. **Chain Lightning** — magic hits jump to 1 nearby enemy at 50% damage
17. **Vengeful Spirits** — when you die, summon 3 spectral warriors for 30s before respawn
18. **Champion's Charge** — entering combat gives +20% damage for 5s

### Legendary (2 perks)

19. **Pet Wolf Companion** — summon a permanent wolf pet that follows + attacks
20. **Phantom Turret** — place a stationary arrow turret near your base that auto-fires (10s cooldown to redeploy)

All perks are stackable — picking the same perk twice doubles its effect.

Implementation-wise, each perk is one `PlayerMods.add(source="endless_perk", field, mult)` call. The hook already exists from the backstory system; Endless just uses a different `source` string so a death cleanly removes all perks at once via `remove_source("endless_perk")`.

---

## Map Expansion

The play area starts at **40×40 tiles** (1280×1280 px) centered on the
player's spawn. Three expansions happen during a session:

**Trigger:** every 10 waves (waves 10/20/30). Predictable cadence so the
player can plan around it; simpler to balance than control-percentage
gates. Map reaches its final 100×100 size by wave 30.

| Expansion | Wave | New size | Adds |
|---|---|---|---|
| Start | 1 | 40×40 | 8 monster spawn points along edges, 4 chests, 1 base plot |
| First | 10 | 60×60 | +4 spawn points, +3 chests, 1 resource node cluster |
| Second | 20 | 80×80 | +4 spawn points, +3 chests, 1 ancient structure (relic chest) |
| Third | 30 | 100×100 | +4 spawn points, +3 chests, the boss arena tile for Níðhöggr |

**Camera handling:** expansion widens the max zoom-out cap each stage.
Player view stays player-centered (existing behavior); they can scroll
out further as the map grows. No mid-game camera teleport.

**Expansion direction:** all 4 cardinal directions equally — base stays
centered. New tile rings unveil with a 1.5s fade-in animation. New
monster spawn points placed at the outer edge of each new ring.

**Spawn point handling:** the server-side wave spawner reads the current
expansion stage and picks spawn points from the active list (stored as
a `(tx, ty)` array per stage). Old spawn points stay active so waves
can come from any direction throughout the run.

**Permanence:** expansions are per-session only — the next Endless run
starts fresh at 40×40. The meta-progression system below is the only
persistent layer between sessions.

---

## Meta-Progression

Small but real persistence across Endless sessions. Unlocked by hitting
specific milestones in a single run:

| Milestone | Reward |
|---|---|
| Survive wave 5 | Unlocks **"Bone Flute Charm"** decoration for base plot |
| Survive wave 10 | Unlocks **"Iron Hand-Axe" starting weapon blueprint** (replaces the empty weapon chest at run start) |
| Survive wave 20 | Unlocks **"Bear Pelt Cloak"** cosmetic (visible on your character in any mode) |
| Survive wave 30 | Unlocks **"Hunter's Bow" starting weapon blueprint** + **"Hearthstone" decoration** |
| Kill Níðhöggr (wave 50) | Unlocks **"Crown of Embers"** cosmetic + **"Runesteel Sword" starting weapon blueprint** |

**Persistence:** `players.endless_unlocks TEXT` JSON array. One schema
migration adds the column. Each entry is a string id like
`"weapon_iron_hand_axe"` / `"decoration_bone_flute"` /
`"cosmetic_bear_pelt"`.

**Pre-run picker:** before starting a run, player picks one of their
unlocked starting weapons. Default = whatever weapon their MMO snapshot
already includes (see Snapshot rules above). If the snapshot has no
weapon AND no meta-unlocked blueprint is picked, the empty weapon chest
falls back. Picker appears as a small modal on the Endless mode select.

**Additive to snapshot:** meta-progression unlocks LAYER on top of the
snapshot — they don't replace it. Snapshot brings your levels + your
earned inventory; the blueprint picker adds an extra starting weapon on
top. So a mid-progression MMO player entering Endless still benefits
from wave-10 unlocks even though their snapshot already had gear.

**Decorations** are placeable inside the base plot during build phase.
Cosmetic only — no stats, no gameplay effects.

**Cosmetics** appear on the player's character in any mode (MMO + Quick
Play + Endless) as visual props.

This is **small by design** — Endless is meant to be loose / replayable,
not a grind to permanent power. Cosmetics + decorations give flavor
without breaking the "snapshot-then-run" feel.

---

## Difficulty Modes

- **Lone Wolf** — solo only. Standard difficulty.
- **Warband** — up to 5 players cooperative endless. Threat budget
  scales as `(30 + wave * 8) * (1 + 0.5 * (player_count - 1))` so
  4-player co-op is 2.5× harder than solo.
- **Nightmare** — waves never stop between build phases. Constant
  pressure. Boss waves still appear at the 5/10/15/etc. cadence but
  there's no breather. Roguelite picks happen mid-combat (modal pauses
  the wave for 5 seconds).

---

## Stat Card

Per-player Endless leaderboard, separate from MMO + Quick Play
leaderboards.

Tracked:
- **Highest wave reached**
- **Total monsters killed** across all runs
- **Favorite weapon type** (argmax of kills with each style)
- **Best bonus combo achieved** (string of 3 perks picked in the same run)
- **Total time survived** (sum of all run durations)
- **Runs completed** (made it past wave 50)

Stored in a new `endless_stats` SQLite table, one row per player_id.

---

## Dependencies (must exist before building)

- ❌ Defensive structure types (walls, traps, towers)
- ❌ Wave spawner system (server-side timer + monster spawn from edge tiles)
- ❌ Build phase timer / UI
- ❌ Roguelite perk picker modal UI
- ✅ Perk / player-modifier stack — **already exists** as `PlayerMods.gd` autoload (from backstory work)
- ❌ **Character snapshot service** — server-side, on Endless entry: reads the MMO row, copies levels + bank + inventory + equipped gear into an ephemeral run character. Must respect the "only crafted / earned items" rule — needs an `item_source` (or `acquired_via`) tracking field on the inventory schema, OR a grandfathering heuristic for existing items.
- ❌ Cooperative endless lobby
- ❌ Endless leaderboard panel
- ❌ Meta-progression unlock store + pre-run picker

The perk hook is the only existing prereq. Everything else is greenfield. Recommend building the wave spawner + build-phase UI first since they're the load-bearing core; perks layer on top without any architectural risk.

---

## Entry Points

Two ways in, both ship:

1. **Main menu button** — the login screen grows an "∞ Endless" button
   next to "Enter World" and "Quick Play". Pick post-authentication so
   the account exists before mode selection. Clicking opens the pre-run
   modal (snapshot summary + weapon blueprint picker + difficulty
   toggle) then drops the player into a fresh Endless world.
2. **In-world portal** — an `endless_portal` interactable (ancient
   runestone visual) admin-placed in MMO towns. Right-click → "Enter
   Endless" opens the same pre-run modal. Clicking it cleanly ends the
   MMO session; the player's MMO character bank + gear stay untouched
   (snapshot is a copy). Coming back = a normal relog.

Both entry paths use the same server handler and the same modal. The
portal is a convenience shortcut for players already inside the MMO;
neither is mechanically different.

---

## What Crosses Between Modes

| Thing | MMO | Endless | Quick Play |
|---|---|---|---|
| Cosmetics unlocked | earnable + visible | earnable + visible | earnable + visible |
| Levels / XP | primary source | snapshot IN (read-only) | max-everything |
| Crafted items | primary source | snapshot IN (read-only) | ignored |
| Achievements | earnable | earnable | earnable |
| Stat card / leaderboard | MMO leaderboard | Endless leaderboard | Quick Play leaderboard |
| Meta-progression unlocks | — | Endless-only | — |

**Cosmetics** and **achievements** cross freely. A skin unlocked from
an Endless wave-20 milestone is wearable on the MMO character. An
achievement fired in Endless credits the MMO account.

**Stat cards stay independent** — three separate leaderboards, three
separate "here's your record" views. No composite score.

**Endless meta-unlocks** (starting weapon blueprints, decorations) are
scoped to Endless runs only. They don't clutter the MMO inventory or
affect QP loadouts.
