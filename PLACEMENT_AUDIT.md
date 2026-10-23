# VikingVale — Map / Monster / Node Placement Audit

_Rendered 2026-09-25 from `server/game_server.db` (the live admin placements): 482 overworld
entities (386 resources, 93 monsters, 16 NPCs, 9 farm plots), 2,703 height sculpts, 23,704
painted tiles. Maps: `docs/map_overview_full.png` (whole 300×520 world) and
`docs/map_overview_developed.png` (the built top band, zoomed)._

## Owner feedback / resolutions (2026-09-25)
The DB snapshot this was rendered from is now slightly behind live edits:
- **Kjelvik skeletons** = intentionally in the **Great Hall Cellars dungeon** (not overworld). Resolved.
- **Ironwood trees** = the loot existed but the placeable node was missing from `AdminCatalog.gd`;
  **added (Ironwood Tree, wc30)**. Owner will place **two ironwood forests flanking Ironwood**.
- **Bjorn's "danger creep"** = my bestiary table mislabeled the spectral_warrior as lv80; it was
  **lv30**, has been **deleted + replaced with goblins**, Kjelvik walls enlarged, some trees moved. Resolved.
- **Frostheim & Helheim are INTENTIONALLY flatlands** (mostly) — do NOT add ranges there. (Retracts
  my earlier "frame Frostheim with mountains" suggestion.)
- New **river stream added between Kjelvik and Frostheim**.
- **Hills now render at mountain height** in 3D (`_biome_height` hills 3.0→13.0) per owner call.
- Still open: high-tier mining coverage (adamant/runite), the Grove gate<req (wc20<30), and 2 new
  tree tiers + 2 new herb tiers (pending tier sign-off).

## The world at a glance
- **Developed content is the top ~55%** (tiles ty 0–~300 ≈ world y 0–9,600). The **entire
  southern half (ty ~300–520) is empty** — the North/South expansion space (Troll Town,
  Dragon Village, the other-god villages).
- **Difficulty gradient reads well radially:** starter-green around **Bjorn's Landing** (east
  coast), mid around Kjelvik/Ironwood (center), high in the **Ashlands** (south, fire) and
  around **Frostheim** (far north, ice). Good bones.
- **Regions painted & legible:** Bjorn's plains/coast (E), Kjelvik + Ironwood (center), Eastmark
  in the Ashlands (S-center), Frostheim snow (far N), Helheim purple (S of Ironwood), the big
  NE mountain range, and a branching river system down the west edge.

## Monsters by nearest town (93 placed)
| Town | Count | Mix | Verdict |
|---|--:|---|---|
| **Bjorn's** | 29 | shark×6, chicken×4, wolf×4, goblin×4, **fire_imp×4, lava_crawler×2, spectral_warrior×1** | starter mobs ✓ but **high-level mobs (lv55–80) too close** |
| **Eastmark** | 18 | fire_imp×5, fire_giant×4, bandit, troll, bear… | Ashlands fire theme ✓ (Ash Token mobs present) |
| **Frostheim** | 15 | ice_wolf×10, ice_troll×3, frost_wyrm×2 | ice theme ✓ (Frost Token ice_wolves present) |
| **Ironwood** | 11 | forest_spirit×8, ancient_troll×2, nidhogg×1 | woodland ✓ (Grove Token ancient_troll present) |
| **Kjelvik** | **3** | ice_wolf, drake, goblin | ⚠ **under-populated + WRONG mobs; no skeletons** |

## 🔴 Placement gaps to fix
1. **Kjelvik has no skeletons and almost no mobs.** The Iron Token = *kill 8 skeleton* + the
   Warrant = *kill 10 skeleton*, both at Kjelvik. The 13 placed skeletons are elsewhere (likely
   the Great Hall Cellars dungeon). **Place a skeleton field just outside Kjelvik** (lv15, so
   it doubles as the low-mid combat ramp between Bjorn's-green and the harder zones). This is the
   one gap already known.
2. **No `ironwood_log` TREES placed** (only Ironwood *walls/towers*). The Grove Token = *gather
   5 ironwood_log*. If procedural ironwood no longer spawns near Ironwood (you've been replacing
   procedural with placed nodes), the Grove Token can't be finished. **Verify or place ironwood
   trees near Ironwood** — and see the gate-vs-req note below.
3. **Frostheim has zero gatherable nodes** (frost trees, etc. rely on procedural). Fine only if
   procedural still covers frost_log (wc50) there; otherwise place some.
4. **High-tier mining is absent** — Adamant (lv70) and Runite (lv85) nodes are **NONE placed**
   anywhere; Mithril×2, Gold×~2 only. Mining past ~50 depends entirely on procedural spawns.
   Confirm they exist, or mining 99 dead-ends.
5. **Bjorn's danger creep:** fire_imp (lv55), lava_crawler (lv60) and a **spectral_warrior (lv80)**
   sit near the starter town (on the SE Ashlands fringe). Confirm they're gated behind water/
   mountain so a fresh player can't stumble into a one-shot; otherwise nudge them south.

## 🟡 Balance / consistency
- **Grove gate wc20 < ironwood harvest-req wc30** — a gate-passing player still can't gather
  ironwood_log until wc30 (see `BALANCE.md`). Raise the gate to 30 or lower the harvest req.
- Eastmark is well-supplied (oak/cherry/copper/iron/gold + crafting benches). Bjorn's is a rich
  starter (61 oak, fishing, shark waters). Good.

## Mountains & regions (you said you may add/reshape)
_"Mountains" here = all elevated terrain: hills + cliff + rocky + mountain. See
`docs/map_elevation.png` (bright = high ground, dark = lowland, red = 3D height sculpts)._
- **Elevation is the dominant terrain, well-distributed** (hills 6,926 + mountain 2,571 tiles vs
  flat 6,848 — not "one NE mass" as first stated). Breakdown: the **NE** is a large true
  cliff/mountain range (cliff 1,847 + mountain 724 + rocky 1,084); the **whole Ashlands is
  highland** (ashlands_hills 4,872 = 86% of the region — your biggest biome); **Helheim** is 89%
  hills; a **snow/cliff spine** runs NE→center; pine/oak hills dot Ironwood/Kjelvik. The
  **1.8 tunnel economy is already well-supported** by all this hill land.
- **Flatter zones** that could take more elevation if you want it: **Frostheim** (mostly flat
  snow — a snowy range would suit the far-north ancestor hold), the **west river valley** (flat
  banks — hills W of Ironwood), and the corridors. **Bjorn's plains stay flat** (correct for a
  starter harbor). The central snow spine already partly gates Bjorn's from the interior — extend
  it into a ridge between the **Ashlands and Bjorn's** to also fix gap #5 (the fire mobs).
- ⚠ **Biome-hills ≠ 3D height.** 289 tiles have real height sculpts (`terrain_heights`); the rest
  of the "hills" are biome PAINT only, so they read as hills in 2D but stay flat in the 3D client
  unless also sculpted. If the 3D relief matters, the painted-hill regions need matching sculpts.
- **Helheim** is a small central purple patch. The lore bible calls it the deathland with a
  **SW-corner island** underworld portal — the main Helheim here is center, not SW. Decide whether
  the central purple is "Helheim proper" and the SW island is the portal, or reconcile the two.
- **Frostheim is isolated** (far NW, one thin road). Intentional-feeling for an ancestor-worship
  frontier hold, but consider one more connection or a landmark on the long empty road up.

## Recommended next placements (priority order)
1. Skeleton field outside Kjelvik (unblocks Iron Token + Warrant + fills the lv15 ramp).
2. Ironwood trees near Ironwood (unblocks Grove Token) — or fix the gate.
3. Confirm/seed high-tier mining (adamant/runite) + frost trees for late gathering.
4. Gate or relocate the lv55–80 mobs off Bjorn's starter fringe (a ridge does double duty).
5. Fill one western region + start shaping the southern expansion when Troll/Dragon begin.
