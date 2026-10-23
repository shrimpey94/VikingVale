# Infinite / Edge-Expanding World — Design Plan
_Design only — NOT built. Late-game / v2. Drafted 2026-09-08._
_This is the single biggest architectural change in the backlog; it breaks the "one 300×300 grid" assumption that the entire codebase currently rests on. Read §4 (prerequisites) before scoping._

---

## 1. The spec (what the user asked for)
- The map **auto-generates at the edges** when a **player** comes within **1 tile of the world edge**. **NPCs do NOT trigger expansion** (decided — see §5).
- **Late-game** feature.
- **Minecraft-like but server-persistent:** generated land is **saved to the server permanently**.
- **Discovery-gated visibility:** newly generated land is **NOT seen instantly by everyone** — only by players who have **discovered** it.
- **A limit before growth**, gated by a **quick loading screen** at the region boundary that then registers a new **300×300 region ("big chunk")** — so the world can't grow infinitely-in-RAM and **crash the server**.
- **A region does NOT all generate/reveal at once** — it reveals like **FOG OF WAR** as the player explores *within* it (see §3d).
- **Frontier regions are mostly OCEAN with small sparse islands** (see §3b) — thematically Viking, cheap to generate, and makes islands the discoverable content.

---

## 2. Core model — a GRID OF REGIONS ("big chunks")
Don't think "infinite tile plane" — think **a grid of large REGIONS**, each the size of the familiar world.

- A **REGION** = one 300×300-tile block (the user's "big chunk"). **Region (0,0) IS the current hand-built world** (Kjelvik, towns, tile overrides) — untouched. New regions (1,0), (0,1), (-1,0)… are **procedurally generated** blocks stitched onto the edges.
- **Why region = 300×300:** it reuses the exact size/streaming/terrain code the game already has, keeps the crafted home world as-is, and makes "a new big chunk" a familiar unit. Expansion = adding procedural regions on demand.
- **Position becomes region-aware:** a player/entity position is `(region_x, region_y, local_x, local_y)` — OR a global `(gx, gy) = (region*300 + local)`. Either way, **coordinates gain a region dimension.** This is the refactor that touches everything (see §4).

---

## 3. How each piece works

### 3a. Edge trigger + loading-screen gate (the throttle)
- When a player is within **1 tile of a region edge that borders an UN-generated region**, fire a **quick loading screen**.
- Behind it, the server **generates + loads the adjacent region** into memory and populates it, then places the player just inside the new region.
- The loading screen is deliberate — expansion is **per-region, gated**, NOT seamless-per-tile. That gate is what bounds growth and prevents a runaway map.
- Within an already-loaded region, movement is seamless (existing chunk streaming).

### 3b. Deterministic terrain — mostly ocean + sparse islands (cheap to store)
- Region terrain is **generated deterministically from `(world_seed, region_x, region_y)`** — the existing noise-based biome generator, fed global coords. Any client/server computes the same tiles.
- **Frontier regions are OCEAN-DOMINANT:** a high water threshold (start ~85–90% ocean) with a second island-noise pass carving **small, sparse landmasses**. Benefits: (1) thematically Viking — you **sail** to explore and islands are the reward; (2) **cheap** — open water is empty, so a region loads/streams almost free; (3) **content = the islands** (resources/monsters/POIs concentrate there), keeping entity density (and server load) low per region.
- So terrain itself is **NOT stored** — it's regenerable. Only **DIFFS** are stored: admin edits, tile paints, placed/persistent entities, terraform. (Mirrors today's `tile_overrides` + `world_entities` + `entity_edits`, now tagged by region.)
- The **home region (0,0)** keeps its hand-built land/towns; only **generated** frontier regions use the ocean-dominant rule.

### 3c. Server persistence + the RAM cap (crash-prevention)
- A **`regions` table**: `region_id, first_generated_at, ... ` — marks a region as "exists / has been generated."
- **Only a bounded set of regions is LOADED IN SERVER RAM at once** (e.g., a 3×3 around each active player cluster, capped at N total). Distant regions **unload**: their live entity/state flushes to the DB; they stop ticking. This is **the limit** — the world is huge on disk, bounded in RAM. No infinite-memory crash.
- The "quick loading screen" covers **loading a region into RAM + spawning its persistent entities** (from DB) + first-time procedural population.

### 3d. Fog-of-war reveal — a region does NOT pop in all at once
- **A region is not fully generated/revealed on entry.** Crossing the boundary (§3a) is a quick loading screen that just *registers* the region + activates its terrain seed. From there it reveals **progressively, like FOG OF WAR**, as the player explores *within* it:
  - **Terrain** streams in around the player (the existing chunk streaming) — mostly open water, so it's near-free.
  - **The map/minimap** reveals only the sub-area the player has actually seen; the rest of the region stays **fogged**.
  - **Content** (island resources/monsters/POIs) **populates + persists per sub-chunk on FIRST discovery** — you don't spawn a whole 300×300 region up front; you fill only what gets explored, then it's saved. Lighter on the server and matches the fog-of-war feel.
- Per-player **`discovered_regions`** (+ a per-region revealed-tile mask for fog) extends the existing `discovered_towns`. A region one player opened is **not on everyone's map instantly** — each player reveals the world as they go.
- **In-world**, terrain is shared/deterministic, so anyone physically present sees the same water/islands. "Discovery" governs the **map reveal** + **first-time content population**, not whether the ground exists.

### 3e. Area-of-interest streaming (the enabler)
- The server sends each player **only the entities in their nearby regions/chunks**, and streams more as they move. This is the **banked "C" slice (server-side AoI)** — it becomes a **hard requirement** here, because an infinite world **cannot** send all entities in the login burst (16MB cap).

---

## 4. HARD prerequisites (build these FIRST, in order)
This feature is **not buildable** until these land:
1. **v1.7.0 anti-cheat** — never build an infinite persistent world on a client-authoritative (cheatable) base.
2. **Server-side Area-of-Interest (the "C" slice)** — per-player spatial streaming of entities + world state. Without it the login burst and broadcasts explode. **Hard blocker.**
3. **Region-aware coordinate model** — add a region dimension to positions + entities + saves + minimap + PvP + caravans + territory. Pervasive refactor; the single riskiest piece. **Hard blocker.**
4. **3D terrain streaming (the "B" slice)** — the 3D client builds the whole terrain mesh up front (fine for 300×300, impossible for many regions). Must stream terrain-mesh regions. 2D is shader-based and far easier. **Hard blocker for the 3D client.**

Only after 1–4 does the edge-generation + loading-gate + discovery layer sit on a stable base.

---

## 5. Key design decisions
- **NPC expansion — DECIDED: NPCs do NOT expand the world.** Only players trigger generation (loading-gated); NPCs are **leashed to already-generated regions**. (NPC-triggered expansion would balloon the world unattended — the exact crash we're avoiding.)
- **Frontier ocean ratio + island density** — tuning params: start ~85–90% water; island-noise threshold controls how many/large the islands are. Sparse enough that regions stay cheap, dense enough that exploration is rewarded.
- **Region size** — 300×300 (reuse everything). Recommend keep.
- **RAM cap N** — how many regions stay loaded server-side (start ~9–25; tune to the box).
- **Procedural content** — island content (monsters/resources/POIs) needs a procedural population system, or islands are barren. Overlaps with `ENDLESS_MODE_DESIGN.md` — that design should drive what fills the islands.
- **PvP / territory / caravans across regions** — TBD (recommend: frontier regions are lawless at first).
- **Home region stays special** — towns/banks/quests live in region (0,0); frontier regions are ocean-and-island wilderness.

---

## 6. Honest scale + relationship to the old note
- This **supersedes** the old backlog line ("do NOT build a multi-chunk/portal system; enlarge the single grid instead"). The **region-grid-on-demand** approach here is the refined answer: it's not portals, and it's not one giant pre-allocated grid — it's **familiar 300×300 regions generated + streamed on demand**, which is the only shape that stays within the 16MB burst + server-RAM limits.
- **This is a v2-scale, multi-slice project** — realistically the largest single feature after 1.7.0. It should be built **on top of** the AoI + terrain-streaming + coordinate refactor, each shipped and stabilized first.

---

## 7. Build order (once prerequisites §4 are met)
1. Region coordinate model + `regions`/`discovered_regions` tables + region-tagged entities/edits.
2. Deterministic region terrain gen (extend the noise generator to any region offset).
3. Server region load/unload + RAM cap + DB flush (the crash-prevention core).
4. Edge detection + loading-screen-gated expansion (player-only).
5. Discovery-gated map reveal.
6. Procedural region population (ties to endless-mode content).
7. Cross-region systems pass (minimap, PvP, caravans, territory decisions from §5).
