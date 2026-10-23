# VikingVale — Progression & Balance (time-to-milestone)

_Computed 2026-09-25 from the live data: the XP curve (`GameManager._build_xp_table`),
per-action XP + timing (`server.py` SKILL_ACTIONS), the full bestiary, and the damage
formula (`_compute_player_hit`). These are **efficient-play lower bounds** — casual real
play (map travel, gear gaps, imperfect targeting, AFK) runs roughly **1.5–3× longer**._

## The XP curve
Exact RuneScape table (`points += floor(lv + 300·2^(lv/7))`, `/4`). **Level 99 = 13,034,431 XP.**
Early levels are trivial; 90→99 is ~9.7M XP (74% of the whole grind).

| Level | Cum. XP | | Level | Cum. XP |
|--:|--:|---|--:|--:|
| 5 | 388 | | 45 | 61,512 |
| 15 | 2,411 | | 50 | 101,333 |
| 20 | 4,470 | | 60 | 273,742 |
| 25 | 7,842 | | 70 | 737,627 |
| 32 | 16,456 | | 85 | 3,258,594 |
| 40 | 37,224 | | 99 | 13,034,431 |

## Time to 99 (efficient play)
| Skill | Hours to 99 | @ 3 h/day |
|---|--:|---|
| **Melee** (kills) | ~80 | ~4 weeks |
| Foraging | ~210 | ~2.5 months |
| Woodcutting | ~215 | ~2.5 months |
| Mining | ~250 | ~3 months |
| **Fishing** | ~200 | ~2.2 months |

- Combat is by far the fastest 99 (high kill-XP/time). Defense + Vitality ride along at
  ~30% of melee XP, so 99 melee leaves them low-80s.
- **Fishing REBALANCED 2026-09-26** from ~405 h → **~200 h** (higher xp, tighter swings,
  + an `abyssal_eel` lv80 top tier so 80–99 isn't stuck on shark). Now in line with the
  other gatherers; still comfortably longer than combat, per owner intent.

## Time to the main-quest milestones
Gates are **low**; the fights are **hard** — the intended "warband recommended" split.

| Milestone | Efficient time | Notes |
|---|--:|---|
| Reach the Token **gates** (m45 · f32 · wc20 · smith5 · vit25) | **~2 h** | trained one skill at a time |
| **Solo-complete all 5 Tokens** | **~3 h** | the binding fights are now `ancient_troll` lv44 (Grove) & `fire_giant` **lv45** (Ash, lowered from 65 on 2026-09-26) — solo-doable around melee ~45, easy with 1–2 others |
| With a warband carrying the hard fights | ~2–4 h | back down near the gate grind |
| **Warband can claim open land** (Warrant → found warband → banner) | **~token time + minutes** | this is when land-control opens |
| Reach the **Pledge** (Act 3) gates (m60 · wc50 · f56 · smith50 · vit35) | **~15 h** | + actually out-sieging defenders for a town conquest |

## ⚠ Design decisions this surfaces
1. **Pacing gap (the big one):** land-control unlocks in **~5 h**, but a single 99 takes
   **200–400 h**. Fine if land-grab *is* the core loop (99s = long-tail prestige). If skill
   mastery should *gate* territory, the Token gates (melee 45 in ~1 h) are far too low.
2. ~~The Ash Token is a solo wall.~~ **RESOLVED 2026-09-26** — `fire_giant` lowered lv65 → **45**
   (hp/atk kept, so still hard, easy with 1–2 others). Planned: a repeatable lv60–70 giant boss
   in an Ashlands dungeon for the harder fight.
3. ~~Gate < gather-requirement (Grove Token).~~ **RESOLVED 2026-09-26** — Grove gate raised to
   woodcutting **30** (matches `ironwood_log`'s harvest req) in both `QuestData.gd` + `server.py`.
4. `raw_shark` for the Sea Token is obtainable at fishing 32 because the **shark monster drops
   it** (`Monster.gd`), not only from fishing (which needs fishing 60). Verified OK.
