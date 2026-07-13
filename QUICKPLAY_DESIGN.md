# Quick Play — Design Document

A fast-paced ephemeral match mode. Fresh max-level character every
match, full best-tier gear, fight on a small procedural-or-handcrafted
map until one warband controls 89% of the territory for 10 continuous
seconds. New character every match; only a stat card persists.

---

## Win Condition

- **Control 89% of map for 10 continuous seconds → Victory**
- **Control 98% → Instant win**

Map control is tracked by the banner / territory system (see Expansion
3 below for the precise math + UI).

---

## Map

- **Procedurally generated** from real geological data (coastlines,
  elevation, rivers — see Expansion 1).
- **OR** curated premade maps based on real Norse-relevant places (see
  Expansion 2 for three hand-crafted maps).
- Small — **80×80 tiles max** for fast sessions.

### Expansion 1 — Procedural map generation from real geological data

**Data source recommendation:** [NASA SRTM](https://www2.jpl.nasa.gov/srtm/)
(Shuttle Radar Topography Mission) 30-m resolution heightmap tiles, OR
[OpenTopography](https://opentopography.org/) for free 1° × 1° world
coverage. Both are public domain, downloadable as GeoTIFF files.

**Pipeline:**

1. **Pick a real-world region** at random — or from a curated whitelist
   of Norse-relevant geography (Iceland, Faroe Islands, Norway,
   Scotland, Greenland). Region size = 8 km × 8 km.
2. **Download SRTM heightmap** for that bounding box → 256×256 16-bit
   elevation grid.
3. **Quantize elevation to biome** via thresholds:
   - elevation < 0m → ocean
   - 0-2m → coast
   - 2-30m → plains / oak_forest (random per tile)
   - 30-150m → pine_forest / dark_forest (random)
   - 150-400m → mountain
   - >400m → cliff / snow (random; snow above 600m)
4. **Apply coastline polish** — find ocean → land boundaries, ensure
   single-tile coast strip everywhere (matches existing `Ground.gd`
   biome logic).
5. **Place 6 resource chests** along the elevation-30m contour line
   (where most playable land lives).
6. **Place 2 rare chests** at the local elevation maxima (mountain
   peaks = treasure).
7. **Cache the result** to `user://quickplay_maps/<region_hash>.json`
   so the same seed gives the same map (deterministic, fair for
   tournaments).

**Why not use Godot's noise generators directly:** they look fine but
lack the macro-shape (peninsulas, river deltas, archipelagos) that real
coastline data gives for free.

**Alternative for offline-first builds:** ship 50 pre-baked region maps
as JSON in `assets/quickplay_maps/`, randomize selection at match
start. ~5 MB total. Avoids HTTP calls during matchmaking and means the
game works without internet at all (great for mobile).

### Expansion 2 — Three hand-crafted premade maps

#### Map A — "Geirangerfjord" (Norwegian fjord)

- **Size**: 80×80 tiles
- **Layout**: vertical S-curve fjord (ocean) splitting the map into
  left and right peninsulas. Steep cliff walls rise on both sides of
  the water; a narrow stone bridge at the midpoint is the only land
  crossing.
- **Biome distribution**: 30% ocean, 25% cliff/mountain (impassable),
  25% pine_forest (playable), 15% coast, 5% snow on the highest peaks.
- **Chokepoints**: the bridge; two coastal beachheads at the fjord
  mouth.
- **Strategic features**: each peninsula has 2 resource chests + 1
  rare chest at the cliff peak. The bridge is a contested 3-tile-wide
  chokepoint perfect for banner placement.
- **Best for**: **1v1** (intimate), **5v5** (peninsula vs peninsula
  warband battles).

#### Map B — "Eldfell" (Icelandic volcanic island)

- **Size**: 80×80 tiles
- **Layout**: round island, ringed by coast and ocean. Central volcano
  peak (mountain biome). Three "lava flow" strips (ashlands biome)
  radiate outward from the peak, dividing the island into 6 pie-slice
  plains regions.
- **Biome distribution**: 20% ocean (rim), 15% coast, 35% plains, 15%
  ashlands (slow movement, no building), 12% mountain, 3% helheim near
  the volcano peak.
- **Chokepoints**: the 6 pie slices each share narrow gaps with
  neighbors; the volcano peak is the highest ground = best banner spot.
- **Strategic features**: peak chest contains rare loot. Six "outlying"
  chests, one per pie slice. Ashlands strips force fighters to detour
  or commit to slow crossings.
- **Best for**: **FFA** (the pie-slice geometry creates natural 6-way
  territory layouts), **5v5** (one team starts on opposite sides).

#### Map C — "Glen Coe" (Scottish highland)

- **Size**: 80×80 tiles
- **Layout**: U-shaped valley running east-west, flanked by mountain
  ridges on both sides. A river (coast biome strip, 2 tiles wide)
  snakes down the valley floor. Two villages (town biome clusters) sit
  at the east + west valley mouths.
- **Biome distribution**: 30% mountain (ridge walls), 25% plains
  (valley floor), 15% oak_forest (foothills), 10% coast (river), 10%
  road (between villages), 5% pine_forest, 5% rocky.
- **Chokepoints**: the road bridge over the river at center; two
  village entrances.
- **Strategic features**: river splits the valley — to cross you use
  the bridge or wade through coast tiles (slow). Each village has 1
  chest at its center + 2 rare chests in the ridge caves (accessible
  only by climbing past mountain tiles).
- **Best for**: **5v5** (village vs village symmetrical warfare),
  **1v1** (linear ridge-to-ridge chase).

---

## Starting State — Max Everything, Ephemeral

Quick Play is the end-game showpiece. Everyone's dropped in maxed and
fully geared — no MMO progression matters here. Skill and tactics are
the only variables. Fresh identical character every match; nothing
carries in.

- **Fresh character every match** — no MMO reads at match start. The
  server allocates a max-level ephemeral character; no inventory,
  levels, or gear from the MMO character is consulted.
- Max level (99) all skills instantly.
- Full best-tier armor and weapons equipped (top-tier by default).
- No food, no ammo, no runes — find them in chests.
- **Chests scattered across map** containing:
  - Arrow bundles, rune essence, food ingredients
  - Some pre-cooked food and pre-made ammo too
  - Rare chests with better quantities near map center

Contrast with **Endless**: Endless snapshots your MMO character
(current levels, only your crafted/earned items). QP does the
opposite — everyone equalised at max, competitive skill test.

---

## Combat

- **Full open-world PvP** — attack anyone.
- Structures can be built AND destroyed.
- **Alliances toggleable during match** — form and break them
  strategically (the existing `/ally` command from the MMO carries over,
  but with no 1-pact-per-warband cap during Quick Play matches).
- **No safe zones.**

---

## Modes

- **1v1** — pure skill test
- **5v5** — team warband battle
- **FFA** — everyone for themselves, last warband/player controlling
  map wins

### Expansion 4 — Match lobby + matchmaking

**Lobby model:** persistent open lobbies, not skill-based matchmaking.
Each lobby is a server-side room with a max player count tied to mode.

**Flow:**

1. Player clicks "Quick Play" from the main menu → opens lobby browser.
2. Lobby browser lists all open rooms: mode, players (e.g., "5v5 — 7/10"),
   map, time-since-open.
3. Player joins by clicking a room. If room fills up, the match starts
   automatically after a 30s "all ready" countdown.
4. OR: player clicks "Create Room" → picks mode + map → room shows in
   browser, waits for others.

**Mode selection:**

- **1v1**: 2-player rooms, single map pick. Match starts when 2
  players join.
- **5v5**: 10-player rooms. Players auto-split into 2 warbands of 5
  (or pick teams pre-match). Match starts when 10 join + countdown
  elapses.
- **FFA**: 8-player rooms, no warbands at start (each player is solo).
  Players can `/ally` mid-match to form temporary warbands.

**Match start sequence:**

1. Server allocates a fresh ephemeral world id (Quick Play matches
   don't touch the MMO world).
2. Spawns the chosen map's biome layout.
3. Drops each player at a spread-out spawn point.
4. Auto-creates a temporary warband per team (1v1 / 5v5) or per player
   (FFA).
5. Starts the 1Hz territory-control poll.
6. Sends `match_started` event to all players in the room.

**Disconnect handling:**

- If a player DCs mid-match, their character stays in the world for
  60s as an inert "ghost" (NPCs and other players can still loot their
  drops). After 60s, if they haven't reconnected, the character is
  removed.
- For **1v1**: if either player DCs > 60s, the other player wins by
  forfeit. Match ends.
- For **5v5 / FFA**: match continues, just with one fewer player.

**Match end:** the winning warband + losing warbands all see a
victory/defeat screen with the final territory % bars, kill counts,
and "Return to lobby" / "Find new match" buttons.

---

## Expansion 3 — Territory Control Math + UI

**Calculation:** server polls every 1 second, runs a 4-connected flood
fill from each warband's nearest banner. A tile is "controlled by
warband X" if X's banner is the nearest banner AND the tile is not
blocked by a different warband's banner radius. Result: per-warband
tile count. Percentage = `count / total_walkable_tiles * 100`.

**Walkable tiles only:** ocean, coast, mountain, cliff don't count
toward total. A typical 80×80 map = ~4500 walkable tiles average.

**89% threshold:** ~4000 walkable tiles. Achievable with 5-7
well-placed banners on most maps.

**98% instant win:** ~4400 walkable tiles. Requires near-total banner
saturation. Practical floor for a real "domination" finish.

**10-second hold timer:** when a warband first crosses 89%, server
starts a `victory_pending` timer with the warband id. If they drop
below 89% before 10s, timer resets. If they hold the full 10s, server
broadcasts `victory_declared` + ends the match.

**Display to all players:** the unified Combat / Target panel grows a
third section at the top of the HUD during Quick Play matches:

- A 5-bar stack (one per warband, color-coded by warband sigil)
- Each bar shows the warband's territory percentage and warband name
- When a warband crosses 89%, their bar shifts to **gold** + the timer
  "10... 9... 8..." counts down inside the bar
- 98% bar fills completely + instant-win banner

---

## Persistence + Stat Card

- New character each match (no carryover gear/levels).
- BUT a **stat card** carries forward (see Expansion 5).
- **Cosmetics unlocked anywhere show up in Quick Play too.** A skin
  unlocked from an Endless wave-20 milestone or an MMO achievement is
  wearable on your QP character. Cosmetics are the only cross-mode
  carry — they're purely visual, so they don't affect the "everyone
  equalised" competitive baseline.
- **Achievements** earnable during QP fire against the MMO account —
  a "kill 100 players" achievement counts whether you did it in MMO
  PvP or QP matches.

### Expansion 5 — Stat card detail

**Stored in SQLite** as a new `quickplay_stats` table, one row per
player:

```sql
CREATE TABLE quickplay_stats (
    player_id            TEXT PRIMARY KEY,
    matches_played       INTEGER NOT NULL DEFAULT 0,
    matches_won          INTEGER NOT NULL DEFAULT 0,
    matches_lost         INTEGER NOT NULL DEFAULT 0,
    total_kills          INTEGER NOT NULL DEFAULT 0,
    total_deaths         INTEGER NOT NULL DEFAULT 0,
    max_territory_pct    REAL    NOT NULL DEFAULT 0,
    fastest_win_seconds  REAL    NOT NULL DEFAULT 0,
    favorite_mode        TEXT    NOT NULL DEFAULT '',
    matches_1v1          INTEGER NOT NULL DEFAULT 0,
    matches_5v5          INTEGER NOT NULL DEFAULT 0,
    matches_ffa          INTEGER NOT NULL DEFAULT 0,
    structures_built     INTEGER NOT NULL DEFAULT 0,
    structures_destroyed INTEGER NOT NULL DEFAULT 0,
    chests_opened        INTEGER NOT NULL DEFAULT 0,
    last_match_at        REAL    NOT NULL DEFAULT 0
)
```

**Displayed as a card** in the main menu ("Stats" tab) with:

- **Top section**: matches played / win-rate as a big percentage /
  favorite mode badge
- **Middle section**: K/D ratio, fastest win, max territory %
- **Bottom section**: per-mode breakdown (1v1 W/L, 5v5 W/L, FFA top-3
  finishes)
- **Leaderboard link**: button that opens the Quick Play leaderboard
  (separate from MMO)

**Server-side update on match end:** atomic transaction increments the
relevant counters for every player who participated. `favorite_mode`
recomputed as `argmax(matches_1v1, matches_5v5, matches_ffa)`.
`max_territory_pct` only updates if current match's peak > stored.
`fastest_win_seconds` only updates on a victory if current < stored
(or stored is 0).

**Leaderboard query:**

```sql
SELECT username, matches_won, matches_played,
       CAST(matches_won AS REAL) / NULLIF(matches_played, 0) AS win_rate
FROM quickplay_stats QS
JOIN players P ON P.id = QS.player_id
WHERE matches_played >= 10
ORDER BY win_rate DESC, matches_won DESC
LIMIT 100
```

The `matches_played >= 10` filter prevents one-and-done 100% players
from dominating the leaderboard.

---

## Dependencies (must exist before building Quick Play)

- ✅ Territory / banner system (**partially exists** — banners + banner
  raids ship; map-control percentage calculation does not)
- ❌ Structure destruction (not built — banners take damage but other
  structures don't)
- ❌ Map control percentage tracking (the 4-connected flood fill from
  Expansion 3)
- ❌ Match start / end logic (ephemeral world allocation, victory
  detection, post-match results screen)
- ❌ Instant max-level character creation (currently character creation
  builds up XP from scratch)
- ❌ Chest spawning system (no chest entity exists yet)
- ❌ Stat card persistence (new SQLite table per Expansion 5)
- ✅ Alliance system (**partially exists** — single `/ally` per warband
  ships from MMO; Quick Play needs to drop the 1-pact cap for FFA
  alliance-flipping)
- ❌ Quick Play lobby / matchmaking (Expansion 4)

The map-control flood fill is the biggest single piece of new
server-side work; structure destruction is the biggest client-side
piece. Everything else is well-bounded. The territory system that
already exists is the foundation — Quick Play extends it with the
match lifecycle around the top.

---

## Entry Points

Two ways in, both ship:

1. **Main menu button** — the login screen grows a "⚡ Quick Play"
   button next to "Enter World" and "Endless". Clicking opens the
   lobby browser (see Expansion 4). Pick post-authentication so the
   account exists before mode selection.
2. **In-world altar** — a `quickplay_altar` interactable (warband
   banner monument visual) admin-placed in MMO towns. Right-click →
   "Enter Quick Play" opens the same lobby browser. Clicking it
   cleanly ends the MMO session with zero gear transfer — QP never
   reads anything from the MMO character regardless of entry path.
   Coming back = a normal relog.

Both entry paths open the same lobby browser and hit the same match
lifecycle. The altar is a convenience shortcut for players already
inside the MMO; neither is mechanically different.

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

**Cosmetics** and **achievements** cross freely across all three modes.

**Stat cards stay independent** — three separate leaderboards.

**QP reads nothing from MMO** — the "snapshot IN" column above only
applies to Endless. QP starts every match at max, ignoring your MMO
progression entirely.
