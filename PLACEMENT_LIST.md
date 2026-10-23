# VikingScape — Quest Placement List & Recording Run-Sheet
_For the restructured Token chain + Pledge ladder + daily bounties · updated 2026-08-29_

**How targets are credited:** quests credit a kill by **monster TYPE**, so a "named boss" is just that monster type placed in the right spot with a custom display name. Quantity-1 bosses only need **one** placed (they respawn on the normal timer). Give the bosses the display names in **bold** so the quest text lines up.

Legend: ✅ = you said it's already placed · ⬜ = still to place

---

## ▶ Before you record — DEPLOY FIRST
So you're placing against the NEW content, not the old:
1. ⬜ **Server push + restart** — quest restructure, Great Hall Cellars dungeon, bestiary stats, road graph, Seal fix.
2. ⬜ **Godot re-export → rebuild `VikingVale.exe`** — new quests, Roads tab, stick→wc/stone→mining, soul drops, token art.
3. ⬜ Log in as admin (Busterrdust) and follow the route below town-to-town.

## 🎥 Suggested recording route (one clean loop)
A logical path so the video flows and you're not criss-crossing the map:

**① Kjelvik** → verify the **Great Hall Cellars** entrance sits at the hall (skeletons auto-seed inside).
**② Frostheim (+ glacier)** → **Frost Warden** (1 ice_draugr) at the glacier · goblins + ice wolves at the high passes.
**③ Ironwood (dark grove)** → **Grove Guardian** (1 ancient_troll) · a pack of wolves · a few bears.
**④ Bjorn's Landing (eastern waters + coast road)** → a **shark** in the water · up to 8 bandits on the coast road · wolves in the hills.
**⑤ Eastmark (ashland rim)** → fire imps + the **Emberlord** (1 fire_giant) beyond the rim · draugr on the patrol route · 2 trolls at the pass.
**⑥ Helheim shore** → drag **Captain Sten** to a clean shore spot (the Warrant giver).

_(Details for each stop are in the region sections below.)_

---

## Captain Sten (reposition)
- ⬜ Move **Captain Sten** to a clean **Helheim-shore** spot (he's the `q_warrant` giver — bring all 5 Tokens). He's currently at a placeholder (~3456, 6528).

---

## Token bosses (one each — the world-tour capstones)
| Boss (display name) | Monster type | Where | For quest |
|---|---|---|---|
| ⬜ **Frost Warden** | `ice_draugr` | Frostheim glacier shrine (north, ~1300,880 area) | q_token_frost |
| ⬜ **Grove Guardian** | `ancient_troll` | Ironwood dark grove (~3500,4900 area) | q_token_grove |
| ⬜ **(shark)** | `shark` | Bjorn's Landing eastern waters (~7800,4400, in water) | q_token_sea |
| ⬜ **Emberlord** | `fire_giant` | Eastmark ashland rim (~5900,5800, beyond the rim) | q_token_ash |

---

## Regular monsters by region (token steps + pledges + dailies)

### Kjelvik (~2600, 3600)
- ✅ **Skeletons** — now **auto-seeded inside the new "Great Hall Cellars" dungeon** (entrance ~2688,3600 under the Great Hall). q_token_iron / q_pledge_kjelvik / q_daily_kjelvik_skeletons all credit these. ⬜ *Just verify the cellar entrance sits nicely at the Great Hall in-game (it's draggable).*

### Frostheim (~1300, 880 + glacier north)
- ⬜ **Goblins** (~12+) at the high passes — q_pledge_frostheim (12).
- ⬜ **Ice Wolves** (~5+) at the high passes — q_pledge_frostheim (5), q_daily_frostheim_icewolves (4).

### Ironwood (~3500, 4900, dark grove)
- ⬜ **Wolves** (~10–12) in the dark grove — q_pledge_ironwood (10). ✅ *(wolves placed on Eastmark road — also want a pack in the Ironwood grove.)*
- ⬜ **Bears** (~3) in the grove — q_daily_ironwood_bears (3). ✅ *(1 bear placed on the road; grove wants its own.)*
- (Ironwood trees for `ironwood_log` gather — confirm the grove has ironwood nodes.)

### Bjorn's Landing (~7800, 4400 + coast road)
- ⬜ **Bandits** (~8) on the coast road — q_pledge_bjorn (8), q_daily_bjorn_bandits (5). ✅ *(2 bandits placed on the road — needs up to 8 for the pledge.)*
- ⬜ **Wolves** in the Bjorn hills — q_daily_bjorn_wolves (5). ✅ *(wolves placed.)*
- (`raw_shark` comes from a **fishing** spot in Bjorn's cold waters — confirm a shark-tier fishing node exists.)

### Eastmark Post (~5900, 5800, ashland rim)
- ⬜ **Fire Imps** (~6) beyond the rim — q_token_ash (6), q_pledge_eastmark (5).
- ⬜ **Draugr** (~10) on the Ashlands patrol route — q_pledge_eastmark (10), q_ashlands (5). ✅ *(you may have draugr here already — confirm 10.)*
- ⬜ **Trolls** (~2) at the mountain pass above Eastmark — q_daily_eastmark_trolls (2). ✅ *(1 troll placed — needs 2.)*

---

## Gather targets to confirm exist (nodes, not monsters)
- `iron_bar` — smithed by the player (no placement; needs a smithing station + iron access). Used by q_token_iron (5) + q_pledge_kjelvik (15).
- `ironwood_log` — Ironwood trees (grove). q_token_grove (5) + q_pledge_ironwood (12).
- `frost_log` — Frost trees (Frostheim). q_pledge_frostheim (10).
- `raw_shark` — shark-tier fishing spot (Bjorn cold waters). q_token_sea (1) + q_pledge_bjorn (5).

---

## Quick sanity after placing
1. Talk to **Bjarne** → the chain should start (`q_token_iron`), then flow Iron→Frost→Grove→Sea→Ash→Warrant (Sten)→Pledge ladder.
2. Each token boss dies once → its token drops as a **quest reward** (not a monster drop), so the boss just needs to be killable in the right region.
3. The 5 tokens (Iron/Frost/Grove/Sea/Ash) are also what the **Seal of Kings** endgame checks — collecting all 5 enables that too.
