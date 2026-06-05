# VikingVale Sprite Generation Checklist

> **Workflow:** Read this file, approve categories, then implement one category at a time.
> Mark items `[x]` when generated. Do NOT start generating until user approves each category.

---

## AUDIT: What Already Exists and Is Correct — DO NOT TOUCH

Everything below is programmatically drawn with Godot `draw_*` calls and looks correct.
These will **not** be regenerated unless the user explicitly asks.

| System | File | Status |
|--------|------|--------|
| World tiles (ocean, plains, forest, biomes) | `Ground.gd` | ✅ SKIP — full tile renderer, viewport-culled |
| All 27 resource nodes (trees, rocks, fish spots, buildings, forge, campfire, crafting bench, archery range, runestone, construction, stick/stone pickups) | `Interactable.gd` | ✅ SKIP — HP-staged draw variants, animated flames |
| All 21 monster sprites (rat, skeleton, goblin, draugr, nidhogg + 16 new types) | `Monster.gd` | ✅ SKIP — unique draw functions, bobbing/flash animation |
| Player character (viking with animated arms, axe/pickaxe/rod weapon variants) | `Player.gd` | ✅ SKIP — walking legs, helmet, beard, full outfit |
| NPC characters (quest-giver, worker, shopkeeper, banker, trainer, tutor variants) | `NPC.gd` | ✅ SKIP — colour variants per role, swing animation |
| Ground loot drop (pulsing coloured circles) | `LootDrop.gd` | ✅ DONE — replaced with icon+bob+shadow (user decision: icon directly on ground) |

**LootDrop note:** Currently draws a pulsing triple-circle in the item's color. This is
readable but not iconic — you can't tell a `wolf_pelt` from `copper_ore` by shape.
**Decision needed from you:** Should we (A) keep circles and layer an icon on top, or
(B) replace circles with a shape-only sprite? Marking as FLAG, not touching until decided.

---

## SCOPE: What Needs to Be Generated

**Approach:** One `@tool` GDScript (`res://tools/gen_icons.gd`) that:
1. Draws each icon pixel-by-pixel using `Image.create()` / `set_pixel()`
2. Saves `res://assets/icons/<item_id>.png` (24×24, inventory)
3. Saves `res://assets/icons/drop_<item_id>.png` (16×16, ground drop — same art scaled down + 1px shadow row)
4. Is run **once** from the Godot editor (Scene > Run Specific > gen_icons.gd), then deleted or kept as source-of-truth

**HUD change needed (after generation):** `_refresh_inventory()` in `HUD.gd` currently shows
a 10×10 `ColorRect` + 3-char text label per slot. After icons exist, each slot will load
`res://assets/icons/<item_id>.png` into a `TextureRect` instead.

---

## CATEGORY A — Raw Gathering Resources (24 icons)
*These drop from trees, rocks, fish spots, herb patches, and ground pickups.*

| # | item_id | Display Name | Design Notes | Status |
|---|---------|--------------|--------------|--------|
| 1 | `stick` | Stick | Two brown diagonal lines crossing, darker outline | [ ] |
| 2 | `stone` | Stone | Rounded gray blob, 3-facet highlight pixel | [ ] |
| 3 | `oak_log` | Oak Log | Light-brown rectangle, 2 darker wood-grain lines, rounded end rings | [ ] |
| 4 | `pine_log` | Pine Log | Medium-brown rectangle, knot circle detail, slightly darker than oak | [ ] |
| 5 | `cherry_log` | Cherry Log | Reddish-brown rectangle, small cherry-blossom pixel detail | [ ] |
| 6 | `ironwood_log` | Ironwood Log | Very dark brown / near-black rectangle, metallic highlight pixel | [ ] |
| 7 | `frost_log` | Frost Log | Pale blue-white rectangle, icy crystal sparkle pixels | [ ] |
| 8 | `ancient_log` | Ancient Log | Golden-brown rectangle, glowing amber pixel at center | [ ] |
| 9 | `copper_ore` | Copper Ore | Dark gray rock chunk, orange-brown ore vein pixels | [ ] |
| 10 | `iron_ore` | Iron Ore | Dark gray chunk, metallic silver-gray vein, no warmth | [ ] |
| 11 | `gold_ore` | Gold Ore | Gray rock, bright yellow vein pixels, shine dot | [ ] |
| 12 | `mithril_ore` | Mithril Ore | Gray rock, blue-silver vein with faint glow pixel | [ ] |
| 13 | `adamant_ore` | Adamant Ore | Dark gray chunk, deep green vein, dense look | [ ] |
| 14 | `runite_ore` | Runite Ore | Dark gray chunk, teal/cyan vein, rune-mark pixel | [ ] |
| 15 | `raw_fish` | Raw Fish | Blue-white fish silhouette (side view), eye dot, tail fin | [ ] |
| 16 | `raw_salmon` | Raw Salmon | Orange-pink fish silhouette, darker back, spots | [ ] |
| 17 | `lobster` | Lobster | Red-orange lobster body, claws out, antennae lines | [ ] |
| 18 | `raw_shark` | Raw Shark | Gray-blue shark silhouette, white belly strip, dorsal fin | [ ] |
| 19 | `abyssal_eel` | Abyssal Eel | Dark teal S-curve body, glowing purple eye pixel | [ ] |
| 20 | `herbs` | Herbs | Three small green leaf shapes on brown stem | [ ] |
| 21 | `mushrooms` | Mushrooms | Brown cap + white stem, two smaller caps beside | [ ] |
| 22 | `berries` | Berries | Three purple-pink circles in triangle, green leaf | [ ] |
| 23 | `moonbloom` | Moonbloom | White flower with lavender center, faint glow pixels | [ ] |
| 24 | `ancient_root` | Ancient Root | Twisted brown root shape, ochre highlight | [ ] |

---

## CATEGORY B — Special Training / Facility Drops (4 icons)
*Obtained from crafting bench, archery range, runestone, construction site.*

| # | item_id | Display Name | Design Notes | Status |
|---|---------|--------------|--------------|--------|
| 25 | `craft_kit` | Craft Kit | Small brown pouch with hammer silhouette on it | [ ] |
| 26 | `arrow_bundle` | Arrow Bundle | Three brown arrows bundled, gray tips, string wrap | [ ] |
| 27 | `magic_dust` | Magic Dust | Small open pouch, purple sparkle pixels spilling out | [ ] |
| 28 | `timber` | Timber | Stack of two small planks (light tan), nail head pixels | [ ] |

---

## CATEGORY C — Smelted Bars (6 icons)
*Each bar: flat ingot shape, top face brighter, front face darker, matching metal color.*

| # | item_id | Display Name | Colors | Status |
|---|---------|--------------|--------|--------|
| 29 | `copper_bar` | Copper Bar | Orange-brown `#C87830` top, `#8B5018` front | [ ] |
| 30 | `iron_bar` | Iron Bar | Mid-gray `#909098` top, `#606068` front | [ ] |
| 31 | `gold_bar` | Gold Bar | Bright yellow `#F0CC20` top, `#B89010` front | [ ] |
| 32 | `mithril_bar` | Mithril Bar | Blue-silver `#66A4E6` top, `#3070A8` front | [ ] |
| 33 | `adamant_bar` | Adamant Bar | Deep green `#33A44C` top, `#1A6030` front | [ ] |
| 34 | `runite_bar` | Runite Bar | Purple `#A433D0` top, `#6A1088` front, glow pixel | [ ] |

---

## CATEGORY D — Crafted Tools & Weapons (13 icons)
*Tools: brown handle always, head color matches metal tier. Weapons: blade color = metal tier.*

| # | item_id | Display Name | Design Notes | Status |
|---|---------|--------------|--------------|--------|
| 35 | `wooden_axe` | Wooden Axe | Brown handle + light-wood axe head (no metal), fan shape | [ ] |
| 36 | `wooden_pickaxe` | Wooden Pickaxe | Brown handle + wood pick-head, horizontal cross piece | [ ] |
| 37 | `wooden_fishing_pole` | Wooden Fishing Pole | Long thin brown diagonal, string line to bottom corner | [ ] |
| 38 | `fishing_pole` | Fishing Pole | Darker oak-toned pole, cleaner string arc | [ ] |
| 39 | `copper_axe` | Copper Axe | Brown handle + copper-orange axe blade | [ ] |
| 40 | `copper_pickaxe` | Copper Pickaxe | Brown handle + copper-orange pick head | [ ] |
| 41 | `iron_axe` | Iron Axe | Brown handle + gray iron blade | [ ] |
| 42 | `iron_pickaxe` | Iron Pickaxe | Brown handle + gray iron pick | [ ] |
| 43 | `ironwood_bow` | Ironwood Bow | Dark brown curved bow shape, string line, notch dots | [ ] |
| 44 | `gold_amulet` | Gold Amulet | Yellow circle (coin-like), engraved rune line, chain pixel | [ ] |
| 45 | `mithril_sword` | Mithril Sword | Blue-silver blade (diamond shape), brown grip, guard bar | [ ] |
| 46 | `adamant_axe` | Adamant Axe | Brown handle + deep-green axe head | [ ] |
| 47 | `runite_pickaxe` | Runite Pickaxe | Brown handle + purple pick head, faint glow | [ ] |

---

## CATEGORY E — Cooked Food (6 icons)
*Each food: recognisable shape, slightly warmer/browner than raw version.*

| # | item_id | Display Name | Design Notes | Status |
|---|---------|--------------|--------------|--------|
| 48 | `cooked_fish` | Cooked Fish | Same fish silhouette as raw but golden-brown, steam pixels | [ ] |
| 49 | `herb_tea` | Herb Tea | Small brown cup, green liquid, steam curl | [ ] |
| 50 | `cooked_salmon` | Cooked Salmon | Salmon silhouette, orange-browned, charred stripe | [ ] |
| 51 | `cooked_lobster` | Cooked Lobster | Deep red lobster (darker than raw), cooked shell shine | [ ] |
| 52 | `cooked_shark` | Cooked Shark | Darker gray fillet shape (not full shark), grill lines | [ ] |
| 53 | `eel_stew` | Eel Stew | Small brown bowl, dark green chunky contents, steam | [ ] |

---

## CATEGORY F — Construction Outputs (6 icons)
*These go to inventory after crafting. Top-down or front-facing furniture silhouettes.*

| # | item_id | Display Name | Design Notes | Status |
|---|---------|--------------|--------------|--------|
| 54 | `wooden_chair` | Wooden Chair | Side-view chair: seat, back, two legs — light oak | [ ] |
| 55 | `wooden_table` | Wooden Table | Front-view table: flat top, two legs — light oak | [ ] |
| 56 | `pine_bookshelf` | Pine Bookshelf | Front-view shelf: dark pine frame, colored book spines | [ ] |
| 57 | `cherry_chest` | Cherry Chest | Front-view chest: reddish-brown lid + body, metal clasp dot | [ ] |
| 58 | `ironwood_gate` | Ironwood Gate | Front-view gate: dark brown vertical planks, cross-bar, iron hinges | [ ] |
| 59 | `frost_cabin` | Frost Cabin | Tiny cabin: pale blue-white walls, white roof peak, door pixel | [ ] |

---

## CATEGORY G — Monster Drops & Combat Items (21 icons)
*Each drop should evoke its monster source — shape + color pair must be unique.*

| # | item_id | Display Name | Monster Source | Design Notes | Status |
|---|---------|--------------|----------------|--------------|--------|
| 60 | `rat_bone` | Rat Bone | Rat | Tiny white bone (T-shape), rounded knobs | [ ] |
| 61 | `bone` | Bone | Skeleton | Larger white bone, classic double-knob shape | [ ] |
| 62 | `goblin_ear` | Goblin Ear | Goblin | Green pointed ear silhouette, dark outline | [ ] |
| 63 | `draugr_shard` | Draugr Shard | Draugr | Blue-gray jagged crystal shard, rune scratch line | [ ] |
| 64 | `dragon_scale` | Dragon Scale | Níðhöggr | Iridescent dark-green/teal scale, teardrop shape | [ ] |
| 65 | `feather` | Feather | Chicken | White feather quill shape, brown rachis line | [ ] |
| 66 | `wolf_pelt` | Wolf Pelt | Wolf | Gray-brown fur patch, wavy edge pixels | [ ] |
| 67 | `bandit_hood` | Bandit Hood | Bandit | Dark gray hood silhouette, eye-hole cutouts | [ ] |
| 68 | `bear_claw` | Bear Claw | Bear | Tan curved claw shape, brown base | [ ] |
| 69 | `troll_hide` | Troll Hide | Troll | Olive-green rough hide patch, wart pixel | [ ] |
| 70 | `spirit_essence` | Spirit Essence | Forest Spirit | Swirling green-white orb, wisp trails | [ ] |
| 71 | `spider_silk` | Spider Silk | Spider | White/silver rolled thread spool, silk strands | [ ] |
| 72 | `ice_fang` | Ice Fang | Ice Wolf | Pale blue-white fang tooth, translucent tip | [ ] |
| 73 | `frost_crystal` | Frost Crystal | Frost Giant | Six-pointed snowflake crystal, icy blue | [ ] |
| 74 | `ice_shard` | Ice Shard | Ice Draugr | Light-blue jagged shard, crack line, frosty edge | [ ] |
| 75 | `imp_horn` | Imp Horn | Fire Imp | Small red curved horn, dark tip | [ ] |
| 76 | `lava_carapace` | Lava Carapace | Lava Crawler | Segmented dark-gray/orange plate, glowing seam pixel | [ ] |
| 77 | `giant_ember` | Giant Ember | Fire Giant | Orange-red glowing coal chunk, heat shimmer pixels | [ ] |
| 78 | `shadow_essence` | Shadow Essence | Shadow Draugr | Near-black orb, purple glow rim, void center | [ ] |
| 79 | `death_rune` | Death Rune | Death Knight | Glowing green rune carved in dark stone tablet | [ ] |
| 80 | `spectral_essence` | Spectral Essence | Spectral Warrior | Blue-white translucent orb, ghostly wisp streaks | [ ] |

---

## TOTALS

| Category | Count | Ready to Generate |
|----------|-------|-------------------|
| A — Raw Resources | 24 | ✅ In gen_icons.gd |
| B — Special Drops | 4 | ✅ In gen_icons.gd |
| C — Smelted Bars | 6 | ✅ In gen_icons.gd |
| D — Tools & Weapons | 13 | ✅ In gen_icons.gd |
| E — Cooked Food | 6 | ✅ In gen_icons.gd |
| F — Construction | 6 | ✅ In gen_icons.gd |
| G — Monster Drops | 21 | ✅ In gen_icons.gd |
| **TOTAL** | **80 icons** | |

Ground drop variants (16×16): 80 additional `drop_<id>.png` files = **160 PNG files total**

---

## DECISIONS NEEDED BEFORE STARTING

1. **LootDrop.gd** — Keep pulsing circles and layer icon on top, OR replace circles with icon-only?
2. **HUD inventory slot size** — Current slots are small (ColorRect is 10×10). Do you want to enlarge the slot to show a 24×24 icon, or keep the current grid density and use 16×16 icons instead?
3. **Category priority** — Which category should be implemented first? (Suggest: A → C → D, since those are the most frequently seen in early gameplay)
4. **Style confirmation** — 1px black outlines on all icons, max 4 colors per icon, confirmed?
