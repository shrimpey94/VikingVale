extends Node2D

const TILE := 32
const COLS := 300
# ROWS covers exterior + interior band; exterior clamps + border walls use
# EXTERIOR_ROWS so players can't wander south past the exterior into the
# reserved interior tiles. Interior mode un-clamps the camera explicitly.
const EXTERIOR_ROWS := 300
const ROWS := 520

# Chunk streaming
const CHUNK_SIZE    := 16    # tiles per chunk side
const CHUNK_PX      := 512   # CHUNK_SIZE * TILE
const ACTIVE_RADIUS := 3     # chunks in each direction (= 48 tiles)
const RES_ATTEMPTS  := 8     # resource spawn attempts per chunk
const MON_ATTEMPTS  := 4     # monster spawn attempts per chunk
# Kill switch for the deterministic chunk monster generator + bridge-monster
# rolls. When false, only admin-placed monsters exist. Flip back to true to
# restore the original procedural population. Kept as code (not deleted) so
# the world-populate math is preserved for future use.
const PROCEDURAL_MONSTERS := false

const _Interactable := preload("res://scenes/Interactable.tscn")
const _Monster      := preload("res://scripts/Monster.gd")
const _NPC          := preload("res://scripts/NPC.gd")
const _Farming      := preload("res://scripts/Farming.gd")
const _Caravan      := preload("res://scripts/Caravan.gd")
const _WorldThrall  := preload("res://scripts/WorldThrall.gd")
const _LoadingScreen := preload("res://scripts/LoadingScreen.gd")
const _OpeningPrologue := preload("res://scripts/ui/OpeningPrologue.gd")
var _loading_scr: CanvasLayer   # shown during a live 2D↔3D switch rebuild

# Monster-free buffers around each town (pixel bounds + 15-tile margin)
const _SAFE_ZONES: Array = [
	Rect2(1984, 3008, 1376, 1376),   # Kjelvik
	Rect2( 704,  256, 1376, 1376),   # Frostheim
	Rect2(2880, 4288, 1376, 1376),   # Ironwood Keep
	Rect2(5248, 5184, 1376, 1376),   # Eastmark Post
	Rect2(7200, 3744, 1376, 1376),   # Bjorn's Landing
]

# ── Kjelvik castle ring ───────────────────────────────────────────────────────
# Kjelvik is the CAPITAL: a walled castle city. The ring is ~100 segments, far
# too many to hand-list as data rows, so _kjelvik_castle_nodes() generates it.
#
# ⚠ CRITICAL: every type in Interactable._STRUCTURE_SIZES gets a blocking
# StaticBody2D — INCLUDING `gate`. A gate laid across a road would seal the city
# shut with no way in. So the road approaches are REAL GAPS (no node at all) and
# the gaps are flanked by corner towers set well clear of the road corridors.
# Bounds MUST stay in sync with Ground._is_town's Kjelvik range.
const _KC_LEFT_TX  := 71
const _KC_RIGHT_TX := 96
const _KC_TOP_TY   := 105
const _KC_BOT_TY   := 128
## Un-walled tile indices where the roads pass through (see Ground._is_road).
const _KC_GAP_N: Array = [77, 78, 79]                     # N road → Frostheim
const _KC_GAP_S: Array = [84, 85, 86]                     # S road → Ironwood
const _KC_GAP_E: Array = [109, 110, 111, 112, 113, 114, 115]  # both E roads
const _KC_WALL_COL  := Color(0.55, 0.55, 0.58)
const _KC_TOWER_COL := Color(0.46, 0.46, 0.50)

func _tile_center(tx: int, ty: int) -> Vector2:
	return Vector2(tx * TILE + TILE * 0.5, ty * TILE + TILE * 0.5)

## Generates the castle wall ring + corner watchtowers as _TOWN_NODES-shaped
## rows: [pos, type, name, skill, level, action, color].
func _kjelvik_castle_nodes() -> Array:
	var out: Array = []
	# Top + bottom runs (these also lay the four corner tiles).
	for tx in range(_KC_LEFT_TX, _KC_RIGHT_TX + 1):
		if not _KC_GAP_N.has(tx):
			out.append([_tile_center(tx, _KC_TOP_TY), "fortified_wall",
				"Castle Wall", "soul", 1, "Inspect", _KC_WALL_COL])
		if not _KC_GAP_S.has(tx):
			out.append([_tile_center(tx, _KC_BOT_TY), "fortified_wall",
				"Castle Wall", "soul", 1, "Inspect", _KC_WALL_COL])
	# Left + right runs, excluding the corners already placed above.
	for ty in range(_KC_TOP_TY + 1, _KC_BOT_TY):
		out.append([_tile_center(_KC_LEFT_TX, ty), "fortified_wall",
			"Castle Wall", "soul", 1, "Inspect", _KC_WALL_COL])
		if not _KC_GAP_E.has(ty):
			out.append([_tile_center(_KC_RIGHT_TX, ty), "fortified_wall",
				"Castle Wall", "soul", 1, "Inspect", _KC_WALL_COL])
	# Corner watchtowers (128×128). Inset 2 tiles in X but only 1 in Y: at inset
	# 2 the east towers' 128px box clipped the top of the east-gate corridor
	# (y 3488-3712), and the north-west one reached the old town's first
	# building row. Y-inset 1 keeps all four clear of every corridor.
	for corner: Array in [
			[_KC_LEFT_TX + 2,  _KC_TOP_TY + 1], [_KC_RIGHT_TX - 2, _KC_TOP_TY + 1],
			[_KC_LEFT_TX + 2,  _KC_BOT_TY - 1], [_KC_RIGHT_TX - 2, _KC_BOT_TY - 1]]:
		out.append([_tile_center(int(corner[0]), int(corner[1])), "watchtower",
			"Castle Watchtower", "soul", 1, "Inspect", _KC_TOWER_COL])
	# Mid-west guard tower — the west wall has no road, so this is safe ground.
	out.append([_tile_center(_KC_LEFT_TX + 2,
			int((_KC_TOP_TY + _KC_BOT_TY) * 0.5)),
		"guard_tower", "Gate Watch", "soul", 1, "Inspect", _KC_TOWER_COL])
	return out

## Town buildings and fixed structures (static, always active once world starts)
const _TOWN_NODES: Array = [
	# ══ KJELVIK ══════════════════════════════════════════════════════════════════
	[Vector2(2528, 3520), "building",     "House",             "soul",         1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(2720, 3520), "building",     "House",             "soul",         1, "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(2816, 3552), "building",     "Tavern",            "soul",         1, "Inspect", Color(0.70, 0.48, 0.22)],
	[Vector2(2624, 3552), "building",     "Great Hall",        "soul",         1, "Inspect", Color(0.35, 0.22, 0.12)],
	[Vector2(2528, 3680), "building",     "Warehouse",         "soul",         1, "Inspect", Color(0.50, 0.44, 0.32)],
	[Vector2(2752, 3680), "building",     "Chapel",            "soul",         1, "Inspect", Color(0.75, 0.72, 0.66)],
	[Vector2(2848, 3744), "building",     "House",             "soul",         1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(2624, 3744), "forge",        "Smithing Forge",    "smithing",     1, "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(2720, 3744), "fire",         "Campfire",          "cooking",      1, "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(2464, 3616), "bank",         "Bank",              "soul",         1, "Access",  Color(0.75, 0.65, 0.20)],
	[Vector2(2528, 3808), "crafting",     "Crafting Bench",    "crafting",     1, "Craft",   Color(0.55, 0.38, 0.18)],
	[Vector2(2848, 3616), "archery",      "Archery Range",     "ranged",       1, "Train",   Color(0.80, 0.22, 0.10)],
	[Vector2(2848, 3808), "runestone",    "Runestone",         "magic",        1, "Study",   Color(0.58, 0.25, 0.82)],
	[Vector2(2720, 3808), "construction", "Construction Site", "construction", 1, "Build",   Color(0.55, 0.40, 0.20)],
	[Vector2(2464, 3808), "auction_house","Auction House",     "soul",         1, "Browse",  Color(0.45, 0.60, 0.85)],
	# ── Kjelvik castle quarter (capital expansion) ──────────────────────────────
	# Placed in the bands opened up by the wall ring. The old town core occupies
	# x 2414-2898, y 3475-3853, so everything here sits SOUTH (y>3870) or EAST
	# (x>2930) of it. The south-gate road corridor (x 2688-2784) and the east-gate
	# corridor (y 3488-3712) are deliberately left clear — a 128px hall dropped in
	# either would block the only way in.
	# Big row (y3960, each 128px → ±64): keep west of the south-gate corridor,
	# barracks east of it. Second row (y4060) holds the 64px utilities.
	[Vector2(2560, 3960), "grand_hall",   "Kjelvik Keep",      "soul",         1, "Inspect", Color(0.42, 0.40, 0.46)],
	[Vector2(2860, 3960), "large_house",  "Barracks",          "soul",         1, "Inspect", Color(0.52, 0.42, 0.30)],
	[Vector2(2480, 4060), "well",         "Castle Well",       "soul",         1, "Inspect", Color(0.58, 0.60, 0.64)],
	[Vector2(2620, 4060), "armory_rack",  "Armory",            "soul",         1, "Inspect", Color(0.60, 0.55, 0.40)],
	[Vector2(2860, 4060), "market_stall", "Market Stall",      "soul",         1, "Browse",  Color(0.72, 0.50, 0.28)],
	# East band is only ~140px wide, so exactly one 128px hall fits — kept below
	# the east-gate corridor (y 3488-3712).
	[Vector2(3000, 3800), "clan_hall",    "Hall of Warbands",  "soul",         1, "Inspect", Color(0.40, 0.34, 0.44)],
	# ══ FROSTHEIM ════════════════════════════════════════════════════════════════
	[Vector2(1312, 768),  "auction_house","Auction House", "soul",     1, "Browse",  Color(0.45, 0.60, 0.85)],
	[Vector2(1216, 768),  "building", "House",             "soul",     1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(1408, 768),  "building", "House",             "soul",     1, "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(1312, 896),  "building", "Tavern",            "soul",     1, "Inspect", Color(0.70, 0.48, 0.22)],
	[Vector2(1216, 992),  "building", "Great Hall",        "soul",     1, "Inspect", Color(0.35, 0.22, 0.12)],
	[Vector2(1344, 992),  "forge",    "Smithing Forge",    "smithing", 1, "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(1440, 992),  "fire",     "Campfire",          "cooking",  1, "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(1184, 896),  "crafting", "Crafting Bench",    "crafting", 1, "Craft",   Color(0.55, 0.38, 0.18)],
	[Vector2(1440, 896),  "archery",  "Archery Range",     "ranged",   1, "Train",   Color(0.80, 0.22, 0.10)],
	[Vector2(1184, 992),  "bank",     "Frost Vault",       "soul",     1, "Access",  Color(0.75, 0.65, 0.20)],
	# ══ IRONWOOD KEEP ════════════════════════════════════════════════════════════
	[Vector2(3680, 5024), "auction_house","Auction House",       "soul",         1, "Browse",  Color(0.45, 0.60, 0.85)],
	[Vector2(3392, 4800), "building",     "House",               "soul",         1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(3584, 4800), "building",     "Great Hall",          "soul",         1, "Inspect", Color(0.35, 0.22, 0.12)],
	[Vector2(3680, 4832), "building",     "House",               "soul",         1, "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(3424, 4928), "building",     "Warehouse",           "soul",         1, "Inspect", Color(0.50, 0.44, 0.32)],
	[Vector2(3456, 5024), "forge",        "Smithing Forge",      "smithing",     1, "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(3584, 5008), "fire",         "Campfire",            "cooking",      1, "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(3680, 4944), "bank",         "Bank",                "soul",         1, "Access",  Color(0.75, 0.65, 0.20)],
	[Vector2(3360, 5024), "construction", "Construction Site",   "construction", 5, "Build",   Color(0.55, 0.40, 0.20)],
	[Vector2(3520, 4960), "runestone",    "Ancient Runestone",   "magic",        5, "Study",   Color(0.58, 0.25, 0.82)],
	# ══ EASTMARK POST ════════════════════════════════════════════════════════════
	[Vector2(6048, 5984), "auction_house","Auction House", "soul",     1, "Browse",  Color(0.45, 0.60, 0.85)],
	[Vector2(5760, 5696), "building", "House",             "soul",     1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(5952, 5696), "building", "House",             "soul",     1, "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(5856, 5792), "building", "Tavern",            "soul",     1, "Inspect", Color(0.70, 0.48, 0.22)],
	[Vector2(5760, 5888), "forge",    "Smithing Forge",    "smithing", 1, "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(5888, 5888), "fire",     "Campfire",          "cooking",  1, "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(6048, 5760), "archery",  "Archery Range",     "ranged",   1, "Train",   Color(0.80, 0.22, 0.10)],
	[Vector2(5760, 5984), "crafting", "Crafting Bench",    "crafting", 1, "Craft",   Color(0.55, 0.38, 0.18)],
	[Vector2(5952, 5984), "bank",     "Outpost Vault",     "soul",     1, "Access",  Color(0.75, 0.65, 0.20)],
	# ══ BJORN'S LANDING ══════════════════════════════════════════════════════════
	[Vector2(7936, 4480), "auction_house","Auction House",     "soul",         1,  "Browse",  Color(0.45, 0.60, 0.85)],
	[Vector2(7712, 4256), "building",     "House",             "soul",         1,  "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(7872, 4256), "building",     "House",             "soul",         1,  "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(7808, 4384), "building",     "Great Hall",        "soul",         1,  "Inspect", Color(0.35, 0.22, 0.12)],
	[Vector2(7936, 4352), "building",     "Warehouse",         "soul",         1,  "Inspect", Color(0.50, 0.44, 0.32)],
	[Vector2(7744, 4480), "forge",        "Smithing Forge",    "smithing",     1,  "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(7872, 4480), "fire",         "Campfire",          "cooking",      1,  "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(8000, 4352), "bank",         "Bank",              "soul",         1,  "Access",  Color(0.75, 0.65, 0.20)],
	[Vector2(7712, 4480), "construction", "Construction Site", "construction", 10, "Build",   Color(0.55, 0.40, 0.20)],
	[Vector2(8032, 4448), "runestone",    "Sea Runestone",     "magic",        10, "Study",   Color(0.58, 0.25, 0.82)],
	# ── Melee sparring dummies (v1.6.6, APPENDED — one per town) ─────────────────
	[Vector2(2912, 3552), "training_dummy", "Sparring Dummy", "melee", 1, "Spar", Color(0.55, 0.42, 0.24)],
	[Vector2(1120, 896),  "training_dummy", "Sparring Dummy", "melee", 1, "Spar", Color(0.55, 0.42, 0.24)],
	[Vector2(3520, 4880), "training_dummy", "Sparring Dummy", "melee", 1, "Spar", Color(0.55, 0.42, 0.24)],
	[Vector2(6016, 5888), "training_dummy", "Sparring Dummy", "melee", 1, "Spar", Color(0.55, 0.42, 0.24)],
	[Vector2(7648, 4400), "training_dummy", "Sparring Dummy", "melee", 1, "Spar", Color(0.55, 0.42, 0.24)],
]

## NPC spawn data: [pos, npc_type, npc_name, quest_text, wander_radius]
const _NPCS: Array = [
	# ── Kjelvik ──────────────────────────────────────────────────────────────────
	[Vector2(2672, 3648), "quest",      "Elder Bjarne",
		"Prove your worth, warrior — clear the rats nesting near our walls.", 32.0],
	# Castle quarter (capital expansion) — placed in the southern courtyard,
	# clear of the south-gate road corridor (x 2688-2784).
	[Vector2(2560, 4040), "quest",      "Castellan Halvdan",
		"The keep stands because we hold the walls. Earn your place on them.", 28.0],
	[Vector2(2940, 4020), "shopkeeper", "Quartermaster Ase",
		"Arms and provisions for the capital garrison. Coin first.", 24.0],
	[Vector2(2680, 3890), "trainer",    "Shieldmaster Ulf",
		"A wall is only as strong as the arms behind it. Train, then stand watch.", 22.0],
	[Vector2(2576, 3680), "worker",     "Karl",   "", 56.0],
	[Vector2(2784, 3664), "worker",     "Sigrid", "", 64.0],
	[Vector2(2496, 3744), "shopkeeper", "Trader Hroar",
		"Rope, string, provisions — if you need it, I have it.", 24.0],
	[Vector2(2464, 3616), "banker",     "Gunhild the Treasurer",
		"Your gold is safe with me. Deposit or withdraw — the choice is yours.", 16.0],
	[Vector2(2848, 3680), "tutor",      "Valgerd the Craftswoman",
		"Gather sticks and stones from the forest floor. Lash them together at the workbench.", 20.0],
	[Vector2(2848, 3744), "trainer",    "Eirik Ironarm",
		"Train at the archery range daily. Combat is the fastest path to strength.", 20.0],
	[Vector2(2720, 3808), "quest",      "Torsten the Wanderer",
		"The Ironwood to the east holds great treasure — and greater danger.", 48.0],
	[Vector2(2624, 3808), "shopkeeper", "Merchant Dalla",
		"Potions, tools, and curiosities from every corner of the realm.", 20.0],
	[Vector2(2560, 3616), "worker",     "Hakon the Farmer", "", 80.0],
	# ── Frostheim ────────────────────────────────────────────────────────────────
	[Vector2(1312, 880),  "quest",      "Hunter Ragnhild",
		"A frost wolf prowls the northern peaks. Bring back its pelt!", 32.0],
	[Vector2(1216, 880),  "worker",     "Leif",   "", 48.0],
	[Vector2(1408, 912),  "worker",     "Astrid", "", 48.0],
	[Vector2(1184, 992),  "banker",     "Sigvard the Frost Keeper",
		"Cold as the vault, steady as the mountain. Your wealth is secure here.", 16.0],
	[Vector2(1408, 768),  "shopkeeper", "Merchant Bera",
		"Furs, cold-weather gear, and the finest brews north of Kjelvik.", 24.0],
	[Vector2(1312, 992),  "trainer",    "Gunnar Coldhand",
		"The cold sharpens the warrior. Train here and grow stronger.", 20.0],
	# ── Ironwood Keep ────────────────────────────────────────────────────────────
	[Vector2(3520, 4896), "quest",      "Blacksmith Ulfr",
		"I need ironwood logs to forge a legendary blade. Gather what you can.", 32.0],
	[Vector2(3392, 4960), "worker",     "Gorm",   "", 64.0],
	[Vector2(3680, 4976), "worker",     "Brynja", "", 48.0],
	[Vector2(3680, 4944), "banker",     "Armgard the Treasurer",
		"The keep's vault is yours to use. What do you need?", 16.0],
	[Vector2(3456, 4960), "shopkeeper", "Trader Thorvald",
		"Deep forest supplies — lanterns, rope, antidotes. You'll need them.", 24.0],
	[Vector2(3584, 4960), "tutor",      "Runa the Herbalist",
		"The ironwood holds rare plants. Pick mushrooms and moonbloom.", 32.0],
	# ── Eastmark Post ────────────────────────────────────────────────────────────
	[Vector2(5888, 5760), "quest",      "Scout Halfdan",
		"Strange creatures roam the ashlands. Investigate and report back.", 32.0],
	[Vector2(5760, 5760), "worker",     "Vigdis", "", 48.0],
	[Vector2(6016, 5760), "worker",     "Olaf",   "", 64.0],
	[Vector2(5952, 5984), "banker",     "Outpost Treasurer Hrodgar",
		"We keep a small vault here for travellers passing through the ashlands.", 16.0],
	[Vector2(5856, 5888), "shopkeeper", "Wandering Merchant Freyja",
		"Fire resistance potions are my specialty.", 20.0],
	# ── Bjorn's Landing ──────────────────────────────────────────────────────────
	[Vector2(7840, 4400), "quest",      "Merchant Eydis",
		"Bring me rare fish from the eastern waters and I will reward you generously.", 32.0],
	[Vector2(7712, 4448), "worker",     "Sturla",   "", 64.0],
	[Vector2(7968, 4416), "worker",     "Hallgerd", "", 48.0],
	[Vector2(8000, 4352), "banker",     "Harbor Master Ingolf",
		"Everything of value that passes through this port, I account for.", 16.0],
	[Vector2(7808, 4480), "shopkeeper", "Fish Trader Knud",
		"The finest catch from these waters.", 24.0],
	# Sea Captain Valdis — Jarl of Bjorn's Landing in the lore. Quest-giver
	# type so the `!` / `+` markers render on her for the Token + Pledge
	# chain. Her dialogue/shop functions still work via name lookup.
	[Vector2(7936, 4256), "quest",      "Sea Captain Valdis",
		"The ocean depths hold monsters unlike any you've seen on land.", 32.0],
	# ── Wilderness outposts ──────────────────────────────────────────────────────
	[Vector2(2080, 1600), "worker", "Mountain Pass Guard Bjork",
		"Turn back, traveller. The peaks ahead are treacherous.", 48.0],
	# Skade's hermitage — central plains, the empty zone in the world map.
	# Quest-load-bearing for q_old_bjarnes_letter (she reveals the Five Tokens on
	# delivery), so she must be a "quest" NPC to render the ! / + markers.
	[Vector2(4800, 4800), "quest", "Ironwood Hermit Skade",
		"I have walked between the burning ones for forty years. Sit. Speak only what you must.", 32.0],
	[Vector2(6400, 4200), "worker", "Coastal Scout Hafi",
		"The eastern road is clear — for now. Keep your sword ready.", 64.0],
	# Captain Sten — giver + turn-in of q_warrant: bring all five Tokens and he
	# grants the Warrant of the High Seat (the warband unlock + start of the town
	# Pledge ladder). Placed at the Helheim approach (south of the central plains).
	# ⚠ VERIFY/REPOSITION in-game to a clean Helheim-shore spot.
	[Vector2(3456, 6528), "quest", "Captain Sten",
		"Five Tokens, and the High Seat is yours to claim. Bring them to me here on the Helheim shore.", 32.0],
	# ── Missing daily-quest givers (v1.6.5) — APPENDED so existing n:i ids don't
	# shift. These are giver_npc for daily bounties (QuestData) but were never in
	# the seed, so their dailies soft-locked until manually admin-placed. Positions
	# are a sensible default in their town; fine-tune in-game if desired.
	# (Sigrid the Fishmonger is intentionally NOT seeded — she's already admin-
	# placed in the live world; seeding would duplicate her.)
	[Vector2(2400, 3808), "quest", "Old Brynjar",
		"My forge sits cold, warrior. Bring me copper ore and I'll see it lit again.", 20.0],
	[Vector2(1216, 800), "shopkeeper", "Brynhildr the Apothecary",
		"Tinctures, salves and cures for the northern cold. Herbs keep my stock full.", 20.0, "apothecary"],
]

## Níðhöggr boss spawns — static positions in helheim
const _BOSS_SPAWNS: Array = [
	[Vector2(1792, 6656), "nidhogg"],
	[Vector2(2560, 6912), "nidhogg"],
	[Vector2(1344, 7168), "nidhogg"],
	[Vector2(3072, 6784), "nidhogg"],
	[Vector2(2048, 7424), "nidhogg"],
	[Vector2(2816, 7680), "nidhogg"],
	[Vector2(1600, 7296), "nidhogg"],
	[Vector2(3456, 7168), "nidhogg"],
	[Vector2(2304, 6528), "nidhogg"],
]

# ── Chunk streaming state ─────────────────────────────────────────────────────
var _active_chunks: Dictionary = {}   # Vector2i → Array of Node
var _player:        Node2D     = null
## True while the "thralls need attention" quit-confirm is up (Phase 10b) so a
## second window-close press quits instead of stacking dialogs.
var _close_prompt_open: bool   = false
var _last_chunk:    Vector2i   = Vector2i(-9999, -9999)
var _world_ready:   bool       = false
var _chunk_timer:   float      = 0.0

# Server-authoritative world state: maps a stable entity_id → live node.
var _node_registry:    Dictionary = {}   # resource nodes (Interactable)
var _monster_registry: Dictionary = {}   # monsters
var _admin_registry:   Dictionary = {}   # admin-placed entities (id → node)
## Raw wire dict per admin entity (id → {kind,subtype,x,y,data}). The Inspect
## editor reads this to seed its property form with the entity's current values.
var _admin_entity_data: Dictionary = {}
# Stage 2 server-side AI — per-monster in-flight position tween. Stored so
# the next position update (every ~0.5s) can `.kill()` the previous tween
# before starting a fresh one, instead of stacking parallel tweens that
# would race for the same property.
var _monster_pos_tweens: Dictionary = {}   # monster_id (String) → Tween

# Phase 5 of the gold economy — server-broadcast gold pile world nodes,
# keyed by pile_id so a `gold_pile_remove` from the server can find and
# free the visual without a scan.
var _gold_pile_nodes: Dictionary = {}     # pile_id (String) → LootDrop Area2D
# Admin edits to pre-existing entities, loaded from the server on login.
var _deleted_ids: Dictionary = {}        # edit_id → true (don't spawn / despawn)
var _moved:       Dictionary = {}         # edit_id → Vector2 (override spawn pos)
## edit_id → data-override dict (name/dialogue/level) for pre-existing NPCs/bosses.
## Applied at spawn + live via entity_data_edited, so procedural entities are editable.
var _edits_data:  Dictionary = {}
## Procedural entities that were admin-MOVED are pulled OUT of chunk streaming so
## their home chunk can't cull them (they'd vanish in front of the player). They
## become persistent like admin (a:) entities. edit_id → node. Prevents the home
## chunk from re-spawning a duplicate too (see _register_editable).
var _promoted_ids: Dictionary = {}

# ── Unified streaming for admin (a:) entities ────────────────────────────────
## The NUMEROUS admin types (trees/rocks/herbs/fish/monsters/NPCs) stream by
## chunk exactly like procedural content — keyed by their CURRENT position, at
## the same render distance. The FEW semi-permanent types (walls/stations/farm
## plots/seals/doors) stay always-loaded so their live state is never disturbed.
const _ADMIN_GATHER_TYPES := ["tree", "rock", "herb", "fish", "essence", "stick", "stone"]
## chunk Vector2i → Array of streamable admin entity wire-dicts (persists across
## unload so a re-entered chunk can respawn them).
var _admin_index: Dictionary = {}
## id → chunk Vector2i, for move/remove lookups.
var _admin_id_chunk: Dictionary = {}
## chunk Vector2i → Array of ids currently spawned for that chunk.
var _admin_loaded: Dictionary = {}

func _ready() -> void:
	# Intercept the window-close (X) so we can warn about neglected thralls
	# before quitting (Phase 10b). Every quit path below still ends in quit(),
	# so the app always closes.
	get_tree().auto_accept_quit = false
	_player = get_node_or_null("Player") as Node2D
	_create_border_walls()
	_setup_camera_limits()
	Events.player_respawned.connect(_on_player_respawned)
	Events.replay_prologue.connect(_on_replay_prologue)
	# Server-driven resource-node state (shared world)
	Events.gather_granted.connect(_on_gather_granted)
	Events.gather_denied.connect(_on_gather_denied)
	Events.node_remote_locked.connect(_on_node_remote_locked)
	Events.node_remote_unlocked.connect(_on_node_remote_unlocked)
	Events.node_remote_depleted.connect(_on_node_remote_depleted)
	Events.node_remote_respawned.connect(_on_node_remote_respawned)
	Events.node_states_received.connect(_on_node_states_received)
	# Server-driven monster state (shared combat)
	Events.mob_state.connect(_on_mob_state)
	Events.mob_hit.connect(_on_mob_hit)
	Events.mob_died.connect(_on_mob_died)
	Events.loot_fallback.connect(_on_loot_fallback)
	Events.mob_respawned.connect(_on_mob_respawned)
	Events.mob_states_received.connect(_on_mob_states_received)
	# Stage 2 server-side AI — batched monster position updates every 0.5s.
	Events.mob_positions_updated.connect(_on_mob_positions_updated)
	# Phase 5 — server-tracked gold piles broadcast on monster death + claim.
	Events.gold_pile_spawn.connect(_on_gold_pile_spawn)
	Events.gold_pile_remove.connect(_on_gold_pile_remove)
	# PvP death piles — same visual mechanism as gold piles but each pile
	# carries an item stack instead of a gold amount.
	NetworkManager.pvp_pile_spawn.connect(_on_pvp_pile_spawn)
	NetworkManager.pvp_pile_remove.connect(_on_pvp_pile_remove)
	NetworkManager.pvp_pile_pickup_ok.connect(_on_pvp_pile_pickup_ok)
	# Farming — server-authoritative plot stages routed to the matching
	# Interactable node's set_farm_stage method.
	NetworkManager.farm_plot_state.connect(_on_farm_plot_state)
	NetworkManager.farm_plot_burst.connect(_on_farm_plot_burst)
	NetworkManager.farm_harvest_ok.connect(_on_farm_harvest_ok)
	NetworkManager.farm_harvest_fail.connect(_on_farm_harvest_fail)
	# Ranged/magic monster projectile visual — server broadcasts on
	# every non-melee attack; damage still lands via monster_attack.
	NetworkManager.monster_projectile.connect(_on_monster_projectile)
	NetworkManager.farm_reject.connect(func(reason: String, seed_id: String) -> void:
		# Refund the seed the plant popup removed optimistically when the server
		# rejects the plant (level too low / plot already planted).
		GameManager.refund_farm_seed(seed_id)
		Events.chat_message.emit(reason))
	# Trade caravans (Phase 5c) — server-driven wagons on the road circuit.
	Events.caravans_updated.connect(_on_caravans_updated)
	Events.caravan_hit.connect(_on_caravan_hit)
	Events.caravan_removed.connect(_on_caravan_removed)
	# Visible thralls (V1.5.5) — reconcile the map view whenever the roster changes.
	Events.thralls_updated.connect(_on_thralls_updated)
	# Admin-placed persistent entities (shared world)
	Events.world_entities_received.connect(_on_world_entities_received)
	Events.world_entity_added.connect(_ingest_admin_entity)
	Events.world_entity_removed.connect(_on_world_entity_removed)
	Events.entity_data_edited.connect(_on_entity_data_edited)
	Events.world_entity_moved.connect(_on_world_entity_moved)
	Events.world_entity_rotated.connect(_on_world_entity_rotated)
	Events.monster_attacked.connect(_on_monster_attacked)
	# Admin-painted persistent terrain overrides
	Events.tile_overrides_received.connect(_on_tile_overrides_received)
	Events.tile_override_set.connect(_on_tile_override_set)
	Events.tile_override_cleared.connect(_on_tile_override_cleared)
	Events.tile_overrides_bulk_received.connect(_on_tile_overrides_bulk_received)
	Events.tile_tints_bulk_received.connect(_on_tile_tints_bulk_received)
	Events.tile_passability_bulk_received.connect(_on_tile_passability_bulk_received)
	# Admin edits (delete/move) to pre-existing entities
	Events.entity_edits_received.connect(_on_entity_edits_received)
	Events.entity_edit_applied.connect(_on_entity_edit_applied)
	# The admin toolbox is created on login (world.tscn loads before login, so
	# my_username is still empty here). Handles re-login too via the signal.
	NetworkManager.login_ok.connect(_on_login_spawn_admin)
	NetworkManager.login_ok.connect(_on_login_check_backstory)
	NetworkManager.login_ok.connect(_on_login_check_interior)
	NetworkManager.admin_rank_changed.connect(_on_admin_rank_changed)
	# Interior scene swap — doors send enter_interior; server replies with
	# interior_entered (with the target interior_id + return coords). We
	# swap the exterior for an InteriorScene instance; walking on the door
	# mat (or right-click Exit) sends exit_interior and we swap back.
	Events.interior_entered.connect(_on_interior_entered)
	Events.interior_exited.connect(_on_interior_exited)
	Events.dungeon_entered.connect(_on_dungeon_entered)
	Events.interior_error.connect(_on_interior_error)
	_spawn_admin_panel_if_admin()
	# Read-only recording observer (auto_studio): hide the HUD + local avatar and
	# turn the player node into a silent camera rig that follows the target.
	if NetworkManager.spectating:
		_enter_spectator_mode()
	# Autoplay: spawn the in-client AI that drives the REAL player (it waits for
	# login + the player node before it acts). Recording this window = a real player.
	if NetworkManager.autoplay:
		add_child(preload("res://scripts/AutoPlay.gd").new())
	# Deferred so Ground._ready() and Player._ready() finish first. On a live 2D↔3D
	# switch, spawn at the carried position (P7) instead of Bjorn's; fresh boot uses
	# RESPAWN_POS and the real login pos overrides it a moment later.
	var start_pos: Vector2 = GameManager.switch_pos if GameManager.switch_pos.x >= 0.0 else GameManager.RESPAWN_POS
	GameManager.switch_pos = Vector2(-1, -1)
	Events.player_respawned.emit.call_deferred(start_pos)
	NetworkManager.reattach_other_players.call_deferred()   # rebuild others after a 2D↔3D switch

# ── Spectator mode ───────────────────────────────────────────────────────────
## Framing for screen-recording: a touch wider than the 2.5 gameplay zoom so
## the followed character's surroundings read on camera.
const SPECTATE_ZOOM   := 2.0
const SPECTATE_SMOOTH := 5.0   # gentler camera glide than the 8.0 gameplay value

## Window-close guard (Phase 10b). Quits immediately UNLESS the player is
## in-game with a thrall that needs attention (idle, or a combat thrall with no
## food) — then it confirms first. Fails safe: any unexpected state just quits.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	if _close_prompt_open or NetworkManager.spectating \
			or NetworkManager.state != NetworkManager.NetState.LOGGED_IN:
		get_tree().quit()
		return
	var warn: Array = ThrallManager.attention_notes()
	if warn.is_empty():
		get_tree().quit()
		return
	_close_prompt_open = true
	var dlg := ConfirmationDialog.new()
	dlg.title = "Thralls Need Attention"
	dlg.dialog_text = ("⚠ Before you close:\n• " + "\n• ".join(warn)
		+ "\n\nQuit anyway?")
	dlg.ok_button_text = "Quit"
	dlg.confirmed.connect(func() -> void: get_tree().quit())
	dlg.canceled.connect(func() -> void:
		_close_prompt_open = false
		dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()

func _enter_spectator_mode() -> void:
	# Keep the REAL HUD up so the recording looks exactly like a normal player's
	# screen. A read-only SpectatorDirector feeds the watched player's server-
	# pushed state (skills/inventory/gear) into GameManager so the HUD renders it,
	# minimises the chat log on sit-down, and pops the Inventory / Equipment tabs
	# open at the right moments (a new craft / a new wield) — never on a timer.
	# See scripts/ui/SpectatorDirector.gd.
	add_child(preload("res://scripts/ui/SpectatorDirector.gd").new())
	if _player != null:
		# Invisible puppet: Player._draw early-returns (so the avatar renders
		# nothing) and its physics/input are gated off in Player.gd. We keep the
		# node itself visible-in-tree so its child Camera2D stays active — we're
		# only borrowing the camera + transform. We do NOT set _player.visible =
		# false, which would take the camera down with it.
		var cam := _player.get_node_or_null("Camera2D") as Camera2D
		if cam != null:
			cam.zoom = Vector2(SPECTATE_ZOOM, SPECTATE_ZOOM)
			cam.position_smoothing_speed = SPECTATE_SMOOTH
			cam.make_current()

# ── Interior scene swap ────────────────────────────────────────────────────
## Interiors live at large Y offsets (12000+) well outside the exterior
## 300×300 tile grid. Entering spawns an InteriorScene node ANCHORED at
## the server-provided coord — its walls, floor, decorations, and exit
## door all draw around that anchor. The player teleports into the room
## and the camera follows; the exterior shader clips at y=9600 so nothing
## exterior is visible from inside. Exit door on the south wall (walk
## through OR click) fires exit_interior which teleports the player back.
##
## Saved return coords so a relog inside still knows the exit position.
var _interior_scene: Node2D = null
var _interior_return_pos: Vector2 = Vector2.ZERO

func _on_interior_entered(interior_id: String, x: float, y: float,
		return_x: float, return_y: float) -> void:
	# Double-fire (shouldn't happen — server rejects nested entries).
	if _interior_scene != null and is_instance_valid(_interior_scene):
		_interior_scene.queue_free()
	_interior_return_pos = Vector2(return_x, return_y)
	# Decouple the minimap + biome music from the far-off interior position:
	# consumers read this exterior anchor while inside so the local biome shows.
	GameManager.in_interior = true
	GameManager.overworld_anchor = Vector2(return_x, return_y)
	GameManager.current_interior_id = interior_id
	# Re-evaluate who's visible now that we're inside (hide outsiders, show
	# same-building occupants).
	NetworkManager.refresh_interior_visibility()
	var script := load("res://scripts/InteriorScene.gd")
	if script == null:
		return
	_interior_scene = script.new() as Node2D
	_interior_scene.name = "InteriorScene"
	# Anchor the interior AT the teleport coord so walls/door surround
	# the player. All of InteriorScene's drawing is in its local space
	# centered on Vector2.ZERO — global_position offsets the whole room.
	_interior_scene.global_position = Vector2(x, y)
	add_child(_interior_scene)
	# Move to the first child slot so this node renders BEFORE Player (and
	# anything else already in the World tree). Ensures the player sprite
	# sits on top of the floor even if a decoration ends up at equal z.
	move_child(_interior_scene, 0)
	_interior_scene.call("setup", interior_id)
	# Fetch the exterior biome at the return coord — used by InteriorScene to
	# color a small border around the walls in the biome the player just left,
	# so the interior reads as "you're inside a building AT this location"
	# rather than a disconnected black void.
	var ext_biome := "plains"
	var ground := get_node_or_null("Ground")
	if ground != null:
		var v: Variant = ground.call("biome_at_world", Vector2(return_x, return_y))
		if typeof(v) == TYPE_STRING:
			ext_biome = v
	_interior_scene.set("exterior_biome", ext_biome)
	_interior_scene.call("apply_exterior_backdrop")
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player != null:
		# Spawn near room center with a small random horizontal jitter so two
		# people entering the SAME building don't stack on the exact same pixel
		# (they'd read as one). Horizontal-only + slight north bias keeps clear
		# of the south door mat so the walk-through exit doesn't retrigger.
		player.global_position = Vector2(x + randf_range(-70.0, 70.0),
			y + randf_range(-30.0, 5.0))
		# Bump player z above InteriorScene so the sprite draws over the
		# floor + walls. Reset to 0 on exit.
		player.z_index = 100
		# Un-clamp the camera from the exterior 300×300 grid so it can
		# follow the player into the far-Y interior island.
		var cam := player.get_node_or_null("Camera2D") as Camera2D
		if cam != null:
			cam.limit_left   = -10000000
			cam.limit_top    = -10000000
			cam.limit_right  =  10000000
			cam.limit_bottom =  10000000
	Events.chat_message.emit(
		"[Interior] Entered %s. Walk through or click the EXIT door to leave."
		% interior_id)

## Dungeon entry (v1.5.3) — same anchoring model as interiors (far band, camera
## un-clamp, co-op decouple) but the layout comes from the server payload and we
## build a DungeonScene instead. Stored in `_interior_scene` so the existing
## interior EXIT path frees it and restores the camera unchanged.
func _on_dungeon_entered(dungeon_id: String, interior_id: String, layout: Dictionary,
		x: float, y: float, return_x: float, return_y: float) -> void:
	if _interior_scene != null and is_instance_valid(_interior_scene):
		_interior_scene.queue_free()
	_interior_return_pos = Vector2(return_x, return_y)
	GameManager.in_interior = true
	GameManager.overworld_anchor = Vector2(return_x, return_y)
	GameManager.current_interior_id = interior_id
	NetworkManager.refresh_interior_visibility()
	var script := load("res://scripts/DungeonScene.gd")
	if script == null:
		return
	_interior_scene = script.new() as Node2D
	_interior_scene.name = "DungeonScene"
	# Anchor at the region origin so the scene's cell-local drawing/collision
	# lands at the same world coords the server used for monster/ore spawns.
	var rtx := int(layout.get("region_tx", 0))
	var rty := int(layout.get("region_ty", 0))
	_interior_scene.global_position = Vector2(float(rtx) * TILE, float(rty) * TILE)
	add_child(_interior_scene)
	move_child(_interior_scene, 0)
	_interior_scene.call("setup", layout)
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player != null:
		# Spawn a couple tiles clear of the exit portal (which sits on the entry
		# cell) so we don't instantly re-trigger the exit on arrival.
		player.global_position = Vector2(x, y - 72.0)
		player.z_index = 100
		var cam := player.get_node_or_null("Camera2D") as Camera2D
		if cam != null:
			cam.limit_left   = -10000000
			cam.limit_top    = -10000000
			cam.limit_right  =  10000000
			cam.limit_bottom =  10000000
	Events.chat_message.emit("[Dungeon] You enter %s. Return via the glowing portal."
		% str(layout.get("name", dungeon_id)))

func _on_interior_exited(return_x: float, return_y: float) -> void:
	GameManager.in_interior = false
	GameManager.current_interior_id = ""
	NetworkManager.refresh_interior_visibility()
	if _interior_scene != null and is_instance_valid(_interior_scene):
		_interior_scene.queue_free()
		_interior_scene = null
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player != null:
		player.global_position = Vector2(return_x, return_y)
		# Reset the z_index bump applied on entry.
		player.z_index = 0
		# Restore the exterior grid clamp on the camera.
		var cam := player.get_node_or_null("Camera2D") as Camera2D
		if cam != null:
			cam.limit_left   = 0
			cam.limit_top    = 0
			cam.limit_right  = COLS * TILE
			cam.limit_bottom = EXTERIOR_ROWS * TILE
	Events.chat_message.emit("[Interior] You step back outside.")

func _on_interior_error(reason: String) -> void:
	Events.chat_message.emit("[Interior] %s" % reason)

## Client-side lookup of each interior's teleport center — MUST match the
## server's `_INTERIOR_ROOMS` in server.py. Used for relog restoration
## where the server ships back `interior_id` but not the coord; we fall
## back to this table so the InteriorScene spawns in the same place it
## did during the original entry. On fresh entries the server sends the
## coord directly and this table isn't touched.
const _INTERIOR_ROOM_CENTERS: Dictionary = {
	"great_hall": Vector2(500.0, 12000.0),
	"tavern":     Vector2(500.0, 13000.0),
	"chapel":     Vector2(500.0, 14000.0),
	"warehouse":  Vector2(500.0, 15000.0),
	"house":      Vector2(500.0, 16000.0),
}

## Auto-restore an interior on relog. If the player last logged out
## while inside a building, the server still has interior_id set and
## ships it in the login_ok payload. Re-spawn the InteriorScene locally
## so the player wakes up in the same room they left — otherwise they'd
## spawn at their persisted exterior coords which no longer match server
## state and the server would reject their next enter_interior attempt
## with "You're already inside."
func _on_login_check_interior(player_data: Dictionary) -> void:
	var iid: String = str(player_data.get("interior_id", ""))
	if iid == "":
		return
	# Defer one frame so Player._ready has finished + is in-scene before
	# the interior teleport tries to move it.
	var rx: float = float(player_data.get("interior_return_x", 0.0))
	var ry: float = float(player_data.get("interior_return_y", 0.0))
	# Prefer the per-building interior coord shipped in login_ok (server
	# now allocates a unique plot per door/building instance). Fall back
	# to the shared theme table for legacy sessions that predate the
	# per-building allocation.
	var ix: float = float(player_data.get("interior_x", 0.0))
	var iy: float = float(player_data.get("interior_y", 0.0))
	if ix == 0.0 and iy == 0.0:
		var center: Vector2 = _INTERIOR_ROOM_CENTERS.get(iid, Vector2.ZERO)
		ix = center.x
		iy = center.y
	call_deferred("_on_interior_entered", iid, ix, iy, rx, ry)

## Pops the backstory picker the first time a character logs in without a
## chosen backstory. Reads from `player_data` directly so this works
## regardless of whether GameManager.populate_from_server_data has run
## yet (signal-ordering between login_ok subscribers is fragile). Server
## enforces single-set, so once the player picks the column is non-empty
## forever and this skips. SettingsPanel exposes a manual "Choose
## backstory" button as a fallback in case the auto-pop ever fails.
func _on_login_check_backstory(player_data: Dictionary) -> void:
	if str(player_data.get("backstory", "")) != "":
		return
	# First login → the opening intro plays first; defer character creation until the
	# end of it (the prologue director shows the picker once the cinematic lands).
	if _prologue_seen().is_empty():
		GameManager.intro_need_backstory = true
		return
	var existing := get_node_or_null("BackstorySelectScreen")
	if existing != null:
		return
	var script := load("res://scripts/BackstorySelectScreen.gd")
	if script == null:
		return
	var screen: Node = script.new()
	screen.name = "BackstorySelectScreen"
	add_child(screen)

# ── Admin toolbox ──────────────────────────────────────────────────────────────
var _admin_panel: Node = null

func _on_login_spawn_admin(_player_data: Dictionary) -> void:
	_spawn_admin_panel_if_admin()

func _on_admin_rank_changed(rank: String) -> void:
	# Promoted mid-session — spawn the panel right now. Demoted mid-session
	# — tear it down so the now-non-admin can't keep pressing F10.
	if rank == "":
		if _admin_panel != null and is_instance_valid(_admin_panel):
			_admin_panel.queue_free()
			_admin_panel = null
	else:
		_spawn_admin_panel_if_admin()

func _spawn_admin_panel_if_admin() -> void:
	if _admin_panel != null and is_instance_valid(_admin_panel):
		return
	# Multi-admin: any rank ('admin' or 'owner') gets the F10 panel. The
	# server is the source of truth for the rank value, set on login_ok.
	if NetworkManager.my_admin_rank == "":
		return
	_admin_panel = (load("res://scripts/ui/AdminPanel.gd") as GDScript).new() as Node
	add_child(_admin_panel)
	Events.chat_message.emit("[Admin] Tools loaded — press F10 or click the ⚙ ADMIN button (top-left).")

func _on_tile_overrides_received(overrides: Array) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("apply_tile_overrides", overrides)

func _on_tile_override_set(tx: int, ty: int, biome: String) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("set_tile_override", tx, ty, biome)

func _on_tile_override_cleared(tx: int, ty: int) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("clear_tile_override", tx, ty)

func _on_tile_overrides_bulk_received(entries: Array) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("apply_tile_overrides_bulk", entries)

func _on_tile_tints_bulk_received(entries: Array) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("apply_tile_tints_bulk", entries)

func _on_tile_passability_bulk_received(entries: Array) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("apply_tile_passability_bulk", entries)
	# Repaint the red overlay if it's visible (admin in PASSABILITY mode).
	if _pass_overlay != null:
		_pass_overlay.queue_redraw()

# ── Passability red overlay (admin edit mode only) ─────────────────────────
## Drawn as a child of World so it sits under HUD but above Ground. Walks
## Ground.impassable_tile_indices and stamps a semi-transparent red square
## per blocked tile. Visibility is toggled by AdminPanel via
## set_passability_overlay_visible.
var _pass_overlay: Node2D = null

func set_passability_overlay_visible(vis: bool) -> void:
	if vis and _pass_overlay == null:
		_pass_overlay = Node2D.new()
		_pass_overlay.name = "PassabilityOverlay"
		_pass_overlay.z_index = 100   # over ground, under HUD
		_pass_overlay.draw.connect(_draw_pass_overlay)
		add_child(_pass_overlay)
	if _pass_overlay != null:
		_pass_overlay.visible = vis
		_pass_overlay.queue_redraw()

func _draw_pass_overlay() -> void:
	var g := get_node_or_null("Ground")
	if g == null or not g.has_method("impassable_tile_indices"):
		return
	const COLS_LOCAL := 300
	const TILE_LOCAL := 32.0
	var col := Color(0.95, 0.20, 0.20, 0.35)
	var indices: Array = g.call("impassable_tile_indices") as Array
	for v: Variant in indices:
		var idx: int = int(v)
		var tx := idx % COLS_LOCAL
		@warning_ignore("integer_division") var ty := idx / COLS_LOCAL
		var pos := Vector2(float(tx) * TILE_LOCAL, float(ty) * TILE_LOCAL)
		_pass_overlay.draw_rect(Rect2(pos, Vector2(TILE_LOCAL, TILE_LOCAL)),
			col, true)

# ── Road-network overlay (admin Roads tab only) ────────────────────────────
## Draws the admin-drawn road graph (GameManager.road_nodes/road_edges) as thick
## lines between nodes + dots at each node, with the selected node ringed gold.
## A child of World so it sits in world space; visibility toggled by AdminPanel
## via set_road_overlay_visible. The autoplay bot reads the same graph to travel.
var _road_overlay: Node2D = null
var _road_selected_node: int = -1

func set_road_overlay_visible(vis: bool) -> void:
	if vis and _road_overlay == null:
		_road_overlay = Node2D.new()
		_road_overlay.name = "RoadOverlay"
		_road_overlay.z_index = 101   # just above the passability overlay
		_road_overlay.draw.connect(_draw_road_overlay)
		add_child(_road_overlay)
		Events.road_graph_updated.connect(func() -> void:
			if _road_overlay != null and is_instance_valid(_road_overlay):
				_road_overlay.queue_redraw())
	if _road_overlay != null:
		_road_overlay.visible = vis
		_road_overlay.queue_redraw()

## Highlight one node (the editor's current selection); -1 clears it.
func set_road_selected_node(node_id: int) -> void:
	_road_selected_node = node_id
	if _road_overlay != null and is_instance_valid(_road_overlay):
		_road_overlay.queue_redraw()

func _road_node_world(nid: int) -> Vector2:
	for n: Variant in GameManager.road_nodes:
		var d := n as Dictionary
		if int(d.get("id", -1)) == nid:
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return Vector2.INF

func _draw_road_overlay() -> void:
	var edge_col := Color(0.95, 0.78, 0.25, 0.80)   # gold road line
	var node_col := Color(1.0, 0.55, 0.10, 0.95)    # amber dot
	var sel_col  := Color(0.30, 0.95, 0.40, 1.0)    # green ring on the selection
	# Thick edge lines first so the dots draw on top.
	for e: Variant in GameManager.road_edges:
		if not (e is Array) or (e as Array).size() != 2:
			continue
		var a := _road_node_world(int((e as Array)[0]))
		var b := _road_node_world(int((e as Array)[1]))
		if a == Vector2.INF or b == Vector2.INF:
			continue
		_road_overlay.draw_line(a, b, edge_col, 10.0, true)
	for n: Variant in GameManager.road_nodes:
		var d := n as Dictionary
		var nid := int(d.get("id", -1))
		var p := Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		_road_overlay.draw_circle(p, 13.0, node_col)
		_road_overlay.draw_arc(p, 13.0, 0.0, TAU, 20, Color(0.15, 0.10, 0.03, 0.9), 2.0)
		if nid == _road_selected_node:
			_road_overlay.draw_arc(p, 20.0, 0.0, TAU, 24, sel_col, 3.0)

# ── Admin-placed entities ──────────────────────────────────────────────────────
# ── Trade caravans (Phase 5c) ────────────────────────────────────────────────
## caravan id → Caravan node. The server owns the roster (exactly two), so this
## spawns on first sight and just re-applies state thereafter.
var _caravan_registry: Dictionary = {}

func _on_caravans_updated(list: Array) -> void:
	for entry: Variant in list:
		if not (entry is Dictionary):
			continue
		var d := entry as Dictionary
		var cid := str(d.get("id", ""))
		if cid.is_empty():
			continue
		var node: Node2D = _caravan_registry.get(cid) as Node2D
		if node == null or not is_instance_valid(node):
			node = Area2D.new()
			node.set_script(_Caravan)
			node.set("caravan_id", cid)
			node.set("entity_id", cid)
			node.position = Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
			$Interactables.add_child(node)
			_caravan_registry[cid] = node
		node.call("apply_state", d)

func _on_caravan_hit(id: String, hp: int, mhp: int) -> void:
	var node: Node2D = _caravan_registry.get(id) as Node2D
	if node == null or not is_instance_valid(node):
		return
	node.set("current_hp", hp)
	node.set("max_hp", maxi(1, mhp))
	node.call("flash_hit")

func _on_caravan_removed(id: String) -> void:
	var node: Node2D = _caravan_registry.get(id) as Node2D
	if node != null and is_instance_valid(node):
		node.queue_free()
	_caravan_registry.erase(id)

# ── Visible thralls (V1.5.5) ─────────────────────────────────────────────────
## thrall id → WorldThrall node. Owner-only: driven off THIS player's roster
## (the "thralls" push), reconciled whenever it changes. Only thralls with a
## server-provided `work_spot` (assigned to a town task) are shown.
var _thrall_registry: Dictionary = {}

func _on_thralls_updated() -> void:
	var seen: Dictionary = {}
	for entry: Variant in ThrallManager.roster:
		if not (entry is Dictionary):
			continue
		var d := entry as Dictionary
		if not (d.get("work_spot", null) is Array):
			continue   # unassigned / no town chosen → not on the map
		var id := str(d.get("id", ""))
		if id.is_empty():
			continue
		seen[id] = true
		var node: Node2D = _thrall_registry.get(id) as Node2D
		if node == null or not is_instance_valid(node):
			node = _WorldThrall.new()
			$Interactables.add_child(node)
			_thrall_registry[id] = node
		node.call("apply_state", d)
	# Despawn thralls that are no longer assigned / present.
	for id: Variant in _thrall_registry.keys():
		if not seen.has(id):
			var n: Node2D = _thrall_registry[id] as Node2D
			if is_instance_valid(n):
				n.queue_free()
			_thrall_registry.erase(id)

func _on_world_entities_received(entities: Array) -> void:
	# Clear any existing admin entities + the whole stream index, then re-ingest
	# the authoritative set.
	for id: Variant in _admin_registry.keys():
		_remove_admin_node(str(id))
	_admin_index.clear()
	_admin_id_chunk.clear()
	_admin_loaded.clear()
	if _world_ready:
		for e: Variant in entities:
			if e is Dictionary:
				_ingest_admin_entity(e as Dictionary)
		_refresh_admin_stream_now()

func _spawn_admin_entities_from_cache() -> void:
	for e: Variant in NetworkManager.world_entities_cache:
		if e is Dictionary:
			_ingest_admin_entity(e as Dictionary)
	_refresh_admin_stream_now()

## Immediately load the admin entities around the player's CURRENT position,
## without waiting for a chunk change. Fixes "things missing on login until you
## move" — the authoritative set can arrive and re-index after the first chunk
## load, leaving everything unloaded until the next _update_chunks.
func _refresh_admin_stream_now() -> void:
	if _player == null:
		return
	var pcx := floori(_player.global_position.x / float(CHUNK_PX))
	var pcy := floori(_player.global_position.y / float(CHUNK_PX))
	for dx in range(-ACTIVE_RADIUS, ACTIVE_RADIUS + 1):
		for dy in range(-ACTIVE_RADIUS, ACTIVE_RADIUS + 1):
			var ch := Vector2i(pcx + dx, pcy + dy)
			if _admin_index.has(ch) and not _admin_loaded.has(ch):
				_load_admin_chunk(ch)

## True if this admin entity should STREAM by chunk (numerous, gameplay-light).
## Walls / stations / farm plots / seals / doors / warband structures stay loaded.
func _admin_streamable(entity: Dictionary) -> bool:
	var kind := str(entity.get("kind", ""))
	if kind == "monster" or kind == "npc":
		return true
	if kind == "resource":
		var data: Dictionary = entity.get("data", {}) as Dictionary if entity.get("data") is Dictionary else {}
		return str(data.get("type_str", "")) in _ADMIN_GATHER_TYPES
	return false

func _admin_chunk_of(entity: Dictionary) -> Vector2i:
	return Vector2i(floori(float(entity.get("x", 0.0)) / float(CHUNK_PX)),
		floori(float(entity.get("y", 0.0)) / float(CHUNK_PX)))

## Route one admin entity: keep-loaded types spawn immediately; streamable types
## go into the chunk index (and spawn now only if their chunk is already loaded).
func _ingest_admin_entity(entity: Dictionary) -> void:
	var id := str(entity.get("id", ""))
	if id.is_empty():
		return
	if not _admin_streamable(entity):
		_spawn_admin_entity(entity)
		return
	var ch := _admin_chunk_of(entity)
	if not _admin_index.has(ch):
		_admin_index[ch] = []
	(_admin_index[ch] as Array).append(entity)
	_admin_id_chunk[id] = ch
	if _admin_loaded.has(ch):
		_spawn_admin_entity(entity)
		(_admin_loaded[ch] as Array).append(id)

## Spawn all indexed admin entities for a chunk that just became active.
func _load_admin_chunk(ch: Vector2i) -> void:
	if _admin_loaded.has(ch):
		return
	var ids: Array = []
	for e: Variant in _admin_index.get(ch, []):
		var id := str((e as Dictionary).get("id", ""))
		if id.is_empty() or _admin_registry.has(id):
			continue
		_spawn_admin_entity(e as Dictionary)
		ids.append(id)
	_admin_loaded[ch] = ids

## Free the admin entities spawned for a chunk that left the active radius.
func _unload_admin_chunk(ch: Vector2i) -> void:
	for id: Variant in _admin_loaded.get(ch, []):
		_remove_admin_node(str(id))
	_admin_loaded.erase(ch)

## Load/unload admin chunks to match the desired procedural set (same radius).
func _update_admin_chunks(desired: Dictionary) -> void:
	var to_unload: Array = []
	for ch: Variant in _admin_loaded.keys():
		if not desired.has(ch):
			to_unload.append(ch)
	for ch: Variant in to_unload:
		_unload_admin_chunk(ch as Vector2i)
	for ch: Variant in desired.keys():
		if _admin_index.has(ch) and not _admin_loaded.has(ch):
			_load_admin_chunk(ch as Vector2i)

func _arr_to_color(raw: Variant) -> Color:
	if raw is Array and (raw as Array).size() >= 3:
		var a: Array = raw as Array
		return Color(float(a[0]), float(a[1]), float(a[2]),
					 float(a[3]) if a.size() > 3 else 1.0)
	return Color(0.7, 0.7, 0.7)

func _spawn_admin_entity(entity: Dictionary) -> void:
	var id := str(entity.get("id", ""))
	if id.is_empty() or _admin_registry.has(id):
		return
	var kind := str(entity.get("kind", ""))
	var data: Dictionary = (entity.get("data", {}) as Dictionary) if entity.get("data") is Dictionary else {}
	var pos := Vector2(float(entity.get("x", 0.0)), float(entity.get("y", 0.0)))
	var c := $Interactables
	match kind:
		"resource":
			var node: Node2D = _Interactable.instantiate()
			node.position              = pos
			node.interactable_type_str = str(data.get("type_str", "tree"))
			node.display_name          = str(data.get("display_name", "Resource"))
			node.required_skill        = str(data.get("skill", "woodcutting"))
			node.required_level        = int(data.get("level", 1))
			node.action_label          = str(data.get("action", "Interact"))
			node.color                 = _arr_to_color(data.get("color"))
			node.entity_id             = id
			# Seed structure HP mirror from the login-burst / add payload so
			# the HP bar draws correctly for damaged structures on first
			# frame (server overlays these fields from structures_state at
			# _load_world_entities time).
			if data.has("max_hp"):
				node.set("structure_max_hp", int(data.get("max_hp", 1)))
				node.set("structure_hp",     int(data.get("hp", data.get("max_hp", 1))))
				node.set("structure_alive",  bool(data.get("alive", true)))
				# If already destroyed at spawn, apply the death visual.
				if not bool(data.get("alive", true)) and node.has_method("destroy_structure_visual"):
					node.call("destroy_structure_visual")
			_node_registry[id]  = node
			_admin_registry[id] = node
			c.add_child(node)
		"monster":
			var m := Area2D.new()
			m.set_script(_Monster)
			m.position     = pos
			m.monster_type = str(data.get("monster_type", "rat"))
			m.entity_id    = id
			_monster_registry[id] = m
			_admin_registry[id]   = m
			c.add_child(m)
			var lv := int(data.get("level", 0))
			if lv > 0:
				m.call("scale_to_level", lv)
			# Dungeon boss rare drop (v1.5.3) — append it to the monster's loot
			# so the existing client-side drop path awards it on kill.
			var extra: Variant = data.get("extra_drop", null)
			if extra is Dictionary:
				var ed := extra as Dictionary
				var loot_arr: Array = m.get("loot") as Array
				var col: Variant = ed.get("color", [0.7, 0.7, 0.7, 1.0])
				loot_arr.append({
					"id": str(ed.get("id", "")),
					"name": str(ed.get("name", ed.get("id", "drop"))),
					"qty": 1,
					"color": _arr_to_color(col)})
				m.set("loot", loot_arr)
			# Stage 1 server AI seed. Live admin-place runs through the
			# server's `_handle_admin_place` and seeds AI synchronously,
			# but DB-loaded entries arrive via the login burst with no
			# server-side AI registered — this join is what restores it.
			# Server is idempotent (existing entry → AI fields preserved).
			NetworkManager.send_monster_join(id, pos.x, pos.y,
				int(m.get("max_hp")), int(m.get("xp_reward")),
				str(m.get("monster_type")), int(m.get("level")),
				int(m.get("attack")), true)   # seed_only: AI register, no aggro
		"npc":
			var n := Area2D.new()
			n.set_script(_NPC)
			n.position      = pos
			n.npc_type      = str(data.get("npc_type", "worker"))
			n.npc_name_str  = str(data.get("npc_name", "Villager"))
			n.quest_text    = str(data.get("quest_text", ""))
			n.wander_radius = float(data.get("wander_radius", 32.0))
			# Regional wardrobe from where the admin dropped them (Phase 5c).
			n.region        = _region_for_pos(pos)
			# Phase 4 — shopkeeper NPCs carry their shop_id in data so the
			# click dispatcher in NPC._on_player_interacted knows which
			# ShopCatalog template to open. Empty string for non-shopkeepers.
			n.shop_id       = str(data.get("shop_id", ""))
			_admin_registry[id] = n
			c.add_child(n)
		"farm_plot":
			# Server-authoritative farm plot — spawn the wired Interactable (the
			# same node the 3D client uses) so plant/grow/harvest all route
			# through the server `farm_plots` state (persisted + cheat-resistant).
			# The old client-local FarmPlot.gd node is retired: its grow timer
			# lived only in-session and used a divergent seed set.
			var farm_node: Node2D = _Interactable.instantiate()
			farm_node.position              = pos
			farm_node.interactable_type_str = "farm_plot"
			farm_node.display_name          = "Farm Plot"
			farm_node.required_skill        = "farming"
			farm_node.required_level        = 1
			farm_node.action_label          = "Tend"
			farm_node.color                 = Color(0.42, 0.30, 0.16)
			farm_node.entity_id             = id
			# Register in BOTH: _admin_registry for admin move/delete, and
			# _node_registry so _reg_node() (farm_plot_state routing) finds it —
			# without the latter the plot never receives its grow stage/bars.
			_admin_registry[id] = farm_node
			_node_registry[id]  = farm_node
			c.add_child(farm_node)
		"stronghold", "banner", "outpost":
			# Warband structures spawn as Interactable nodes with a custom
			# type_str so they reuse all the depth-pass, hover, and
			# collision plumbing. No gather logic — they're decorative for
			# v1 (clicking later opens a warband info popup).
			var ws_node: Node2D = _Interactable.instantiate()
			ws_node.position              = pos
			ws_node.interactable_type_str = kind
			ws_node.display_name          = "Warband %s" % kind.capitalize()
			ws_node.required_skill        = ""
			ws_node.required_level        = 1
			ws_node.action_label          = "Inspect"
			# Owner warband_id stored in entity meta so click-handlers can
			# look up which warband this belongs to.
			ws_node.color                 = Color(0.55, 0.30, 0.18)
			ws_node.entity_id             = id
			ws_node.set_meta("warband_id", str(data.get("warband_id", "")))
			_admin_registry[id] = ws_node
			c.add_child(ws_node)
		"seal_statue":
			# Seal of Kings — clickable. Phase 1 just renders a tall
			# golden marker via the existing Interactable. The action
			# menu shows "Awaken" when applicable; the click handler
			# routes to seal_awaken or seal_attack based on data.state.
			var seal_node: Node2D = _Interactable.instantiate()
			seal_node.position              = pos
			seal_node.interactable_type_str = "seal_statue"
			seal_node.display_name          = "Seal of Kings"
			seal_node.required_skill        = ""
			seal_node.required_level        = 1
			seal_node.action_label          = "Awaken"
			seal_node.color                 = Color(0.95, 0.78, 0.18)
			seal_node.entity_id             = id
			seal_node.set_meta("seal_state", str(data.get("state", "charged")))
			seal_node.set_meta("integrity", int(data.get("integrity", 100)))
			_admin_registry[id] = seal_node
			c.add_child(seal_node)
		"world_eater":
			# The Doom — slow, massive entity. Renders as a deep-purple
			# blob via Interactable for v1. Phase 2 (vulnerable boss
			# combat) will swap this for a Monster instance and reuse
			# the standard combat pipeline; for the foundation pass we
			# just need the visual on the map.
			var we_node: Node2D = _Interactable.instantiate()
			we_node.position              = pos
			we_node.interactable_type_str = "world_eater"
			we_node.display_name          = "The World-Eater"
			we_node.required_skill        = ""
			we_node.required_level        = 1
			we_node.action_label          = "Witness"
			we_node.color                 = Color(0.35, 0.05, 0.45)
			we_node.entity_id             = id
			we_node.set_meta("phase", int(data.get("phase", 1)))
			_admin_registry[id] = we_node
			c.add_child(we_node)
	# Tag so the editor's unified click-search finds admin entities too (their
	# a: id routes back to the admin placement handlers on delete/move).
	if _admin_registry.has(id):
		(_admin_registry[id] as Node).set_meta("edit_id", id)
		_admin_entity_data[id] = entity.duplicate(true)   # seed the Inspect editor
		# NOTE: admin ROTATION is intentionally 3D-only (it distorts the flat 2D
		# sprites). The server still persists + broadcasts it for the 3D client.

func _remove_admin_node(id: String) -> void:
	var node: Variant = _admin_registry.get(id)
	if node != null and is_instance_valid(node as Node):
		(node as Node).queue_free()
	_admin_registry.erase(id)
	_admin_entity_data.erase(id)
	_node_registry.erase(id)
	_monster_registry.erase(id)

## Nearest editable entity id within `radius` px of a world position, or "".
## Searches ALL tagged entities (admin-placed + procedural + town/NPC/boss), so
## the editor can delete/move anything. Returns the entity's stable edit id.
func admin_entity_at(world_pos: Vector2, radius: float = 44.0) -> String:
	var best := ""
	var best_d := radius * radius
	for grp: String in ["interactable", "monster"]:
		for n: Node in get_tree().get_nodes_in_group(grp):
			if not n.has_meta("edit_id"):
				continue
			var d := (n as Node2D).global_position.distance_squared_to(world_pos)
			if d < best_d:
				best_d = d
				best = str(n.get_meta("edit_id"))
	return best

## Raw stored wire dict for an admin-placed entity (id → {kind,subtype,x,y,data}),
## or {} if the id isn't an admin entity we cached. The Inspect editor uses this
## to seed its property form with the entity's live values.
func admin_entity_info(id: String) -> Dictionary:
	var v: Variant = _admin_entity_data.get(id, {})
	if v is Dictionary and not (v as Dictionary).is_empty():
		return v as Dictionary
	# Not currently loaded — fall back to the stream index so a far/streamed-out
	# admin entity can still be inspected/edited.
	if _admin_id_chunk.has(id):
		var ch: Vector2i = _admin_id_chunk[id]
		for e: Variant in _admin_index.get(ch, []):
			if str((e as Dictionary).get("id", "")) == id:
				return e as Dictionary
	# Pre-existing entity (n:/b:…) — synthesize editable info from the live node.
	if not id.begins_with("a:"):
		var n := _find_editable_node(id)
		if n != null:
			return _synth_info_for(n, id)
	return {}

## Build an editor-shaped info dict from a live procedural NPC/monster node.
func _synth_info_for(node: Node, id: String) -> Dictionary:
	var ntype: Variant = node.get("npc_type")
	if ntype is String and str(ntype) != "":
		var wr: Variant = node.get("wander_radius")
		return {"id": id, "kind": "npc", "subtype": str(ntype), "data": {
			"npc_name": str(node.get("npc_name_str")),
			"quest_text": str(node.get("quest_text")),
			"wander_radius": float(wr) if wr != null else 32.0,
			"shop_id": str(node.get("shop_id"))}}
	var mtype: Variant = node.get("monster_type")
	if mtype is String and str(mtype) != "":
		var lv: Variant = node.get("level")
		return {"id": id, "kind": "monster", "subtype": str(mtype),
			"data": {"level": int(lv) if lv != null else 1}}
	return {}

## All currently-loaded editable entities as [{id, name, pos}], name-sorted, for
## the admin browser. a: (admin-placed) entities + NPCs/bosses are always loaded;
## procedural resources are chunk-streamed so only nearby ones appear.
func admin_entity_list() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for grp: String in ["interactable", "monster"]:
		for n: Node in get_tree().get_nodes_in_group(grp):
			if not n.has_meta("edit_id"):
				continue
			var id := str(n.get_meta("edit_id"))
			if seen.has(id):
				continue
			seen[id] = true
			out.append({"id": id, "name": _editable_name(n),
				"pos": (n as Node2D).global_position})
	# Also list streamed-OUT admin entities (indexed but not currently spawned) so
	# the browser can still jump to them across the whole map.
	for ch: Variant in _admin_index.keys():
		for e_v: Variant in _admin_index[ch]:
			var e: Dictionary = e_v
			var id := str(e.get("id", ""))
			if id.is_empty() or seen.has(id):
				continue
			seen[id] = true
			var data: Dictionary = e.get("data", {}) as Dictionary if e.get("data") is Dictionary else {}
			var nm := str(data.get("npc_name", data.get("display_name", data.get("monster_type", id))))
			out.append({"id": id, "name": nm,
				"pos": Vector2(float(e.get("x", 0.0)), float(e.get("y", 0.0)))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out

## Best display name for an editable node (NPC name → display_name → monster type → id).
func _editable_name(n: Node) -> String:
	for prop: String in ["npc_name_str", "display_name"]:
		var v: Variant = n.get(prop)
		if v is String and not (v as String).is_empty():
			return v as String
	var mt: Variant = n.get("monster_type")
	if mt is String and not (mt as String).is_empty():
		return (mt as String).capitalize()
	return str(n.get_meta("edit_id"))

## Live world-px position of an admin entity's node (source of truth for Undo of
## a Move), or ZERO if the node is gone.
func admin_entity_pos(id: String) -> Vector2:
	var n: Variant = _admin_registry.get(id)
	if n != null and is_instance_valid(n as Node):
		return (n as Node2D).global_position
	return Vector2.ZERO

## Admin minimap teleport — jump the player to a world-px position. Overworld
## only; inside an interior we pop out first (the map shows the overworld).
func admin_teleport(world_pos: Vector2) -> void:
	if _player == null:
		return
	if GameManager.in_interior:
		NetworkManager.send_exit_interior()
		Events.chat_message.emit("[Admin] Left the interior — open the map again to teleport.")
		return
	_player.global_position = world_pos
	_update_chunks(world_pos)   # stream the destination in immediately
	Events.chat_message.emit("[Admin] Teleported to (%d, %d)." % [int(world_pos.x), int(world_pos.y)])

# ── Edit-persistence for pre-existing entities ────────────────────────────────
## Tag a freshly-built entity with its stable id and apply any saved edit.
## Returns false if the entity is deleted (caller must NOT add it to the tree).
func _register_editable(node: Node2D, id: String) -> bool:
	if _deleted_ids.has(id):
		return false
	# Already promoted to a persistent moved node — the live one stands; don't let
	# the home chunk spawn a second copy at the moved position.
	if _promoted_ids.has(id):
		return false
	node.set_meta("edit_id", id)
	if _moved.has(id):
		node.position = _moved[id] as Vector2
	return true

func _find_editable_node(id: String) -> Node2D:
	for grp: String in ["interactable", "monster"]:
		for n: Node in get_tree().get_nodes_in_group(grp):
			if n.has_meta("edit_id") and str(n.get_meta("edit_id")) == id:
				return n as Node2D
	return null

func _on_entity_edits_received(edits: Array) -> void:
	_deleted_ids.clear()
	_moved.clear()
	_edits_data.clear()
	for e: Variant in edits:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		var id := str(d.get("id", ""))
		if id.is_empty():
			continue
		if d.get("data") is Dictionary and not (d["data"] as Dictionary).is_empty():
			_edits_data[id] = d["data"]
		if bool(d.get("deleted", false)):
			_deleted_ids[id] = true
		elif d.get("x") != null and d.get("y") != null:
			_moved[id] = Vector2(float(d["x"]), float(d["y"]))
	# Apply to anything already spawned (towns/NPCs/bosses, loaded chunks). Rotation
	# is 3D-only, so it's deliberately not applied to the 2D sprites here.
	for id: Variant in _deleted_ids.keys():
		var dn := _find_editable_node(str(id))
		if dn != null:
			dn.queue_free()
	for id: Variant in _moved.keys():
		var mn := _find_editable_node(str(id))
		if mn != null:
			_relocate_node(mn, _moved[id] as Vector2)
			_promote_from_chunks(mn, str(id))
	for id: Variant in _edits_data.keys():
		var en := _find_editable_node(str(id))
		if en != null:
			_apply_entity_data(en, _edits_data[id] as Dictionary)

## Apply a data override to a pre-existing entity node — NPC name/dialogue/wander/
## shop, or monster/boss level. Missing/absent props are silently skipped.
func _apply_entity_data(node: Node, data: Dictionary) -> void:
	if data.is_empty() or not is_instance_valid(node):
		return
	if data.has("npc_name"):
		node.set("npc_name_str", str(data["npc_name"]))
	if data.has("quest_text"):
		node.set("quest_text", str(data["quest_text"]))
	if data.has("wander_radius"):
		node.set("wander_radius", float(data["wander_radius"]))
	if data.has("shop_id"):
		node.set("shop_id", str(data["shop_id"]))
	if data.has("level") and node.has_method("scale_to_level"):
		node.call("scale_to_level", int(data["level"]))
	if node.has_method("queue_redraw"):
		node.call("queue_redraw")

## Live data override (admin edited a procedural entity this session).
func _on_entity_data_edited(entity_id: String, data: Dictionary) -> void:
	_edits_data[entity_id] = data
	var n := _find_editable_node(entity_id)
	if n != null:
		_apply_entity_data(n, data)

## Pull a moved procedural node OUT of chunk streaming: remove it from whatever
## chunk owns it (so _unload_chunk can't free it) and mark it persistent. Called
## whenever an admin move lands on a chunk-streamed (non-a:) entity.
func _promote_from_chunks(node: Node2D, id: String) -> void:
	if id.begins_with("a:"):
		return   # admin entities aren't chunk-managed
	for key: Variant in _active_chunks.keys():
		var arr: Array = _active_chunks[key]
		var i := arr.find(node)
		if i >= 0:
			arr.remove_at(i)
			break
	_promoted_ids[id] = node

## After a chunk spawns, pull any freshly-spawned entity that has an active move
## override out of the chunk's cull-list (so returning near its OLD home doesn't
## re-cull it). Keeps moved entities visible at their new position.
func _pull_moved_from_chunk(key: Vector2i) -> void:
	if not _active_chunks.has(key):
		return
	var arr: Array = _active_chunks[key]
	for i in range(arr.size() - 1, -1, -1):
		var node: Variant = arr[i]
		if not is_instance_valid(node):
			continue
		var eid := str((node as Node).get("entity_id"))
		if eid != "" and _moved.has(eid):
			_promoted_ids[eid] = node
			arr.remove_at(i)

## Set a node's world position, re-anchoring an NPC's wander home so it doesn't
## drift back to its spawn (admin_set_position). Non-NPC nodes just move.
func _relocate_node(node: Node2D, gpos: Vector2) -> void:
	if node.has_method("admin_set_position"):
		node.call("admin_set_position", gpos)
	else:
		node.global_position = gpos

func _on_entity_edit_applied(entity_id: String, deleted: bool, x: float, y: float) -> void:
	if deleted:
		_deleted_ids[entity_id] = true
		_moved.erase(entity_id)
		var n := _find_editable_node(entity_id)
		if n != null:
			n.queue_free()
	else:
		_moved[entity_id] = Vector2(x, y)
		_deleted_ids.erase(entity_id)
		var mn2 := _find_editable_node(entity_id)
		if mn2 != null:
			_relocate_node(mn2, Vector2(x, y))
			_promote_from_chunks(mn2, entity_id)

func _on_world_entity_removed(entity_id: String) -> void:
	_remove_admin_node(entity_id)
	_deindex_admin(entity_id)

## Drop a streamed admin entity from the index + loaded lists (on remove).
func _deindex_admin(entity_id: String) -> void:
	if not _admin_id_chunk.has(entity_id):
		return
	var ch: Vector2i = _admin_id_chunk[entity_id]
	_admin_id_chunk.erase(entity_id)
	if _admin_index.has(ch):
		var arr: Array = _admin_index[ch]
		for i in range(arr.size() - 1, -1, -1):
			if str((arr[i] as Dictionary).get("id", "")) == entity_id:
				arr.remove_at(i)
	if _admin_loaded.has(ch):
		(_admin_loaded[ch] as Array).erase(entity_id)

func _on_world_entity_moved(entity_id: String, x: float, y: float) -> void:
	var node: Variant = _admin_registry.get(entity_id)
	if node != null and is_instance_valid(node as Node):
		_relocate_node(node as Node2D, Vector2(x, y))
	if _admin_entity_data.has(entity_id):
		var info: Dictionary = _admin_entity_data[entity_id]
		info["x"] = x
		info["y"] = y
	# Re-file the streamed entity AND update its stored x/y so a stream-out/in
	# respawns it at the MOVED position (not its original one). This must happen
	# for same-chunk moves too — that was the "TP back and it snapped home" bug.
	if _admin_id_chunk.has(entity_id):
		var old_ch: Vector2i = _admin_id_chunk[entity_id]
		var new_ch := Vector2i(floori(x / float(CHUNK_PX)), floori(y / float(CHUNK_PX)))
		# Pull the wire-dict from its current bucket, patch x/y, re-file (dest may
		# equal source for a same-chunk move).
		var moved_e: Dictionary = {}
		if _admin_index.has(old_ch):
			var arr: Array = _admin_index[old_ch]
			for i in range(arr.size() - 1, -1, -1):
				if str((arr[i] as Dictionary).get("id", "")) == entity_id:
					moved_e = arr[i]
					arr.remove_at(i)
					break
		if not moved_e.is_empty():
			moved_e["x"] = x
			moved_e["y"] = y
			if not _admin_index.has(new_ch):
				_admin_index[new_ch] = []
			(_admin_index[new_ch] as Array).append(moved_e)
			_admin_id_chunk[entity_id] = new_ch
			if new_ch != old_ch:
				if _admin_loaded.has(old_ch):
					(_admin_loaded[old_ch] as Array).erase(entity_id)
				if _admin_loaded.has(new_ch) \
						and not (_admin_loaded[new_ch] as Array).has(entity_id):
					(_admin_loaded[new_ch] as Array).append(entity_id)

## Admin rotation is 3D-ONLY (it distorts the flat 2D sprites). The 2D client
## intentionally ignores the rotation broadcast; the server still persists it and
## the 3D client applies it. No-op kept so the signal connection stays valid.
func _on_world_entity_rotated(_entity_id: String, _rot: float) -> void:
	pass

## The AdminPanel rotate tool reads this to compute the next step. The 2D client
## doesn't track rotation (3D-only), so it always reports 0 here.
func admin_entity_rot(_entity_id: String) -> float:
	return 0.0

# ── Server combat dispatch (route by entity_id to the live monster) ────────────
func _reg_mob(entity_id: String):
	var m: Variant = _monster_registry.get(entity_id)
	if m != null and is_instance_valid(m as Node):
		return m
	return null

func _on_mob_state(entity_id: String, hp: int, max_hp: int) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m != null: m.call("set_server_hp", hp, max_hp)

func _on_mob_hit(entity_id: String, _x: float, _y: float, _amount: int, _by: String, hp: int, max_hp: int, _crit: bool = false, _missed: bool = false) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m != null:
		m.call("set_server_hp", hp, max_hp)
		m.call("flash_hit")
	# A REMOTE player landed this hit → show THEIR swing (local player swings via
	# its own attack path). Keeps "see others fighting" true in 2D too.
	if _by != "" and _by != NetworkManager.my_username:
		var att := NetworkManager.other_player_node_by_name(_by)
		if att != null and att.has_method("play_swing"):
			att.call("play_swing", _x)

## A monster launched an attack (server broadcast) → play its 2D attack wind-up so
## melee attacks are visible in 2D as well as 3D.
func _on_monster_attacked(entity_id: String) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m != null and (m as Node).has_method("play_attack_wind_up"):
		(m as Node).call("play_attack_wind_up")

func _on_mob_died(entity_id: String, killer: String, xp_each: int,
		_participants: Array, xp_recipients: Array) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m == null:
		return
	var me := NetworkManager.my_username
	# Eligibility now lives in xp_recipients (damagers + warband-shared),
	# NOT in participants. Chunk-streamers who joined for visibility but
	# never dealt damage are intentionally excluded from this list.
	if me in xp_recipients and xp_each > 0:
		# Kill reward, split evenly by the server, mirrors the local _award_combat_xp split.
		GameManager.add_xp("melee", xp_each)
		GameManager.add_xp("defense", maxi(1, floori(xp_each * 0.3)))
		GameManager.add_xp("vitality", maxi(1, floori(xp_each * 0.3)))
		Events.monster_killed.emit(str(m.get("monster_type")))
		GameManager.on_monster_killed(str(m.get("monster_type")))
	# v1.7 B3 — the SERVER now rolls the killer's loot and pushes it (loot_reward);
	# the client no longer rolls it here. (Un-baked fallback comes back via
	# Events.loot_fallback → _on_loot_fallback, which spawns the local drops.)
	m.call("server_die")

## B3 un-baked fallback — the server told the KILLER (only they get loot_reward)
## to roll this monster's loot locally. Spawn its drops the old way.
func _on_loot_fallback(monster_id: String) -> void:
	var m: Variant = _reg_mob(monster_id)
	if m != null and is_instance_valid(m as Node) and (m as Object).has_method("spawn_loot_drops"):
		m.call("spawn_loot_drops")

func _on_mob_respawned(entity_id: String) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m != null: m.call("server_respawn")

func _on_mob_states_received(nodes: Array) -> void:
	for entry: Variant in nodes:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry as Dictionary
		var m: Variant = _reg_mob(str(d.get("id", "")))
		if m == null:
			continue
		if bool(d.get("alive", true)):
			m.call("set_server_hp", int(d.get("hp", 1)), int(d.get("max_hp", 1)))
		else:
			m.call("server_die")

## Stage 2 server-side AI — batched position broadcast. The server fires this
## every 0.5s with one entry per nearby alive monster; we tween each Monster
## node's global_position toward the new server-authoritative coords over
## 0.45s (50ms of curve margin to the next tick so motion never pauses). A
## per-monster tween is killed before a new one starts so updates don't stack.
## Also stamps `server_state` / `server_target` metadata on the node so the
## sprite layer can later read aggro / target without re-listening.
func _on_mob_positions_updated(updates: Array) -> void:
	for u: Variant in updates:
		if not (u is Dictionary):
			continue
		var d: Dictionary = u as Dictionary
		var mid := str(d.get("id", ""))
		if mid.is_empty():
			continue
		var node: Variant = _monster_registry.get(mid)
		if node == null or not is_instance_valid(node as Node):
			continue
		var n: Node2D = node as Node2D
		# Kill any in-flight tween for this monster before starting a new
		# one — otherwise the previous tween keeps writing global_position
		# in parallel and the motion jitters.
		var prev: Variant = _monster_pos_tweens.get(mid)
		if prev != null:
			var prev_tw := prev as Tween
			if prev_tw != null and prev_tw.is_valid():
				prev_tw.kill()
		var target := Vector2(float(d.get("x", n.global_position.x)),
							  float(d.get("y", n.global_position.y)))
		var tween := create_tween()
		tween.tween_property(n, "global_position", target, 0.45)
		_monster_pos_tweens[mid] = tween
		# Stamp server-side AI state on the node for later visual hooks
		# (Stage 3+ will tint the sprite or show aggro indicators using
		# these). Strings come straight from server: "idle" / "wander" /
		# "aggro" for state, username or "" for target.
		n.set_meta("server_state", str(d.get("state", "")))
		n.set_meta("server_target", str(d.get("target", "")))

# ── Gold piles (Phase 5 of the gold economy) ─────────────────────────────────
# Server broadcasts gold_pile_spawn on monster death; we instantiate a
# shared LootDrop visual via the existing LootDrop.gd script (mirrors the
# Monster._spawn_loot pattern). The pile_id is what links the visual to the
# server's authoritative state — clicking sends gold_pile_pickup, server
# validates proximity + claims, broadcasts gold_pile_remove to despawn.

func _on_gold_pile_spawn(pile_id: String, x: float, y: float, amount: int) -> void:
	if pile_id == "" or amount <= 0:
		return
	# Defensive: if a stale local node still exists under this id, free it
	# first so we don't leak duplicates after a race.
	if _gold_pile_nodes.has(pile_id):
		var old: Variant = _gold_pile_nodes[pile_id]
		if old != null and is_instance_valid(old as Node):
			(old as Node).queue_free()
		_gold_pile_nodes.erase(pile_id)
	var ld := Area2D.new()
	ld.set_script(load("res://scripts/LootDrop.gd"))
	ld.global_position = Vector2(x, y)
	$Interactables.add_child(ld)
	(ld as Area2D).call("setup_gold_pile", pile_id, amount)
	_gold_pile_nodes[pile_id] = ld

func _on_gold_pile_remove(pile_id: String) -> void:
	if not _gold_pile_nodes.has(pile_id):
		return
	var node: Variant = _gold_pile_nodes[pile_id]
	if node != null and is_instance_valid(node as Node):
		(node as Node).queue_free()
	_gold_pile_nodes.erase(pile_id)

# ── PvP death piles ──────────────────────────────────────────────────────────
# Same visual mechanism as gold piles: server broadcasts a spawn per stack;
# clicking sends pvp_pile_pickup; server broadcasts pvp_pile_remove which
# despawns the LootDrop node for every client that was tracking it. Grant
# arrives via pvp_pile_pickup_ok (client-authoritative inventory).
var _pvp_pile_nodes: Dictionary = {}   # pile_id (String) → LootDrop Area2D

func _on_pvp_pile_spawn(pile_id: String, x: float, y: float,
		item_id: String, item_name: String, qty: int, col: Color) -> void:
	if pile_id == "" or qty <= 0:
		return
	if _pvp_pile_nodes.has(pile_id):
		var old: Variant = _pvp_pile_nodes[pile_id]
		if old != null and is_instance_valid(old as Node):
			(old as Node).queue_free()
		_pvp_pile_nodes.erase(pile_id)
	var ld := Area2D.new()
	ld.set_script(load("res://scripts/LootDrop.gd"))
	ld.global_position = Vector2(x, y)
	$Interactables.add_child(ld)
	(ld as Area2D).call("setup_pvp_pile", pile_id, item_id, item_name, qty, col)
	_pvp_pile_nodes[pile_id] = ld

func _on_pvp_pile_remove(pile_id: String) -> void:
	if not _pvp_pile_nodes.has(pile_id):
		return
	var node: Variant = _pvp_pile_nodes[pile_id]
	if node != null and is_instance_valid(node as Node):
		(node as Node).queue_free()
	_pvp_pile_nodes.erase(pile_id)

## Server confirmed we claimed a PvP pile — apply the grant to the local
## inventory. The pvp_pile_remove message also fires (broadcast) so the
## visual despawns regardless of which client picked it up.
func _on_pvp_pile_pickup_ok(item_id: String, item_name: String,
		qty: int, col: Color) -> void:
	GameManager.add_item(item_id, item_name, qty, col)
	Events.chat_message.emit("Picked up %s ×%d." % [item_name, qty])

# ── Farm plot stage routing ──────────────────────────────────────────────────
# Server tells us the ripen stage of a specific plot (individual state changes)
# or bursts every active plot on login. Both paths funnel to the Interactable's
# `set_farm_stage` which swaps the visual.
func _on_farm_plot_state(entity_id: String, stage: int, seed_id: String,
		grow: float, eff: float, boost: float) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null and (n as Node).has_method("set_farm_stage"):
		n.call("set_farm_stage", stage, seed_id, grow, eff, boost)

func _on_farm_plot_burst(plots: Array) -> void:
	for entry: Variant in plots:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry as Dictionary
		var n: Variant = _reg_node(str(d.get("id", "")))
		if n != null and (n as Node).has_method("set_farm_stage"):
			n.call("set_farm_stage",
				int(d.get("stage", 0)),
				str(d.get("seed_id", "")),
				float(d.get("grow", 0.0)),
				float(d.get("eff", 0.0)),
				float(d.get("boost", 0.0)))

## Grant the harvested crop + Farming XP. Server sent the grant so the
## client can trust the item id — no gate needed here beyond adding to
## inventory + emitting XP. Always bumps the per-seed practice counter
## (success + fail both count as attempts).
func _on_farm_harvest_ok(_entity_id: String, item_id: String,
		item_name: String, qty: int, xp: int, seed_id: String) -> void:
	GameManager.grant_farm_harvest(item_id, item_name, qty, xp, seed_id)
	Events.chat_message.emit("Harvested %d× %s. +%d Farming XP." % [maxi(1, qty), item_name, xp])

## Monster projectile visual — spawn a small tweened sprite that flies
## from source to target over ~0.4 s. Damage is applied by the paired
## monster_attack broadcast so this is decoration only. `spread_orbs > 1`
## fans multiple orbs for chunky attacks (nidhogg fire breath).
## Also triggers the source monster's attack wind-up telegraph so the
## sprite plays its anticipation pose during the projectile's flight.
func _on_monster_projectile(entity_id: String, from_x: float, from_y: float,
		to_x: float, to_y: float, _style: String, color: Color,
		spread_orbs: int) -> void:
	# Fire the source monster's anticipation animation if we can find it.
	var src: Variant = _reg_node(entity_id)
	if src != null and (src as Node).has_method("play_attack_wind_up"):
		src.call("play_attack_wind_up")
	var orbs: int = maxi(1, spread_orbs)
	for i in range(orbs):
		# Spread the orbs across a small perpendicular offset so they read
		# as a fan rather than stacked on top of each other.
		var lateral: float = 0.0
		if orbs > 1:
			lateral = (float(i) - float(orbs - 1) * 0.5) * 14.0
		_spawn_monster_projectile_orb(from_x, from_y, to_x, to_y,
			color, lateral)

## Single projectile visual — colored circle + darker halo, tweened to
## the target then queue_freed. Extracted so nidhogg-style spread fans
## can call it in a loop with a lateral perpendicular offset.
func _spawn_monster_projectile_orb(from_x: float, from_y: float,
		to_x: float, to_y: float, color: Color, lateral: float) -> void:
	var orb := Node2D.new()
	var start := Vector2(from_x, from_y)
	var target := Vector2(to_x, to_y)
	# Perpendicular offset lets multi-orb spreads fan sideways.
	if abs(lateral) > 0.01:
		var dir := (target - start).normalized()
		var perp := Vector2(-dir.y, dir.x) * lateral
		start += perp
	orb.global_position = start
	# Draw the orb via a script-set draw callback so no extra scene file.
	var col := color
	orb.set_meta("orb_color", col)
	orb.draw.connect(func() -> void:
		orb.draw_circle(Vector2.ZERO, 5.0, col.darkened(0.35))
		orb.draw_circle(Vector2.ZERO, 3.5, col)
		orb.draw_circle(Vector2(-1.0, -1.0), 1.5, col.lightened(0.35)))
	add_child(orb)
	orb.z_index = 90
	# Kick a first draw — signal was connected after add_child so Godot's
	# initial paint pass might have skipped this node. Position updates
	# thereafter piggy-back the canvas transform, no more redraws needed.
	orb.queue_redraw()
	var tw := orb.create_tween()
	tw.tween_property(orb, "global_position", target, 0.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(orb.queue_free)

## Farming failure — crop lost, small consolation XP granted, counter
## still bumped. Reason chats as "rotted" (past the rot deadline) or
## "withered" (skill/practice roll failed).
func _on_farm_harvest_fail(_entity_id: String, seed_id: String,
		reason: String, xp: int) -> void:
	if xp > 0:
		GameManager.add_xp("farming", xp)
	if seed_id != "":
		GameManager.bump_recipe_count(seed_id)
	var pretty := seed_id.replace("_seed", "").capitalize()
	Events.chat_message.emit("The %s %s. +%d Farming XP." % [pretty, reason, xp])

# ── Server world-state dispatch (route by entity_id to the live node) ──────────
func _reg_node(entity_id: String):
	var n: Variant = _node_registry.get(entity_id)
	if n != null and is_instance_valid(n as Node):
		return n
	return null

func _on_gather_granted(entity_id: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("begin_gather")

func _on_gather_denied(entity_id: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("on_gather_busy")

func _on_node_remote_locked(entity_id: String, username: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("set_remote_gathering", true, username)

func _on_node_remote_unlocked(entity_id: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("set_remote_gathering", false, "")

func _on_node_remote_depleted(entity_id: String, respawn_in: float) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("apply_depleted", respawn_in)

func _on_node_remote_respawned(entity_id: String, x: float = -1.0, y: float = -1.0) -> void:
	var n: Variant = _reg_node(entity_id)
	if n == null:
		return
	# Admin gatherables wander on respawn (x/y ≥ 0) — relocate before un-depleting so
	# the move sticks against streaming (reuses the admin-move relocation path).
	if x >= 0.0:
		_relocate_node(n as Node2D, Vector2(x, y))
	n.call("apply_respawn")

func _on_node_states_received(nodes: Array) -> void:
	for entry: Variant in nodes:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry as Dictionary
		var n: Variant = _reg_node(str(d.get("id", "")))
		if n == null:
			continue
		var depleted_in := float(d.get("depleted_in", 0.0))
		var locked_by   := str(d.get("locked_by", ""))
		if depleted_in > 0.0:
			n.call("apply_depleted", depleted_in)
		elif not locked_by.is_empty():
			n.call("set_remote_gathering", true, locked_by)

func _process(delta: float) -> void:
	if not _world_ready or _player == null:
		return
	# Spectator: snap the camera puppet onto the followed target every frame
	# (the Camera2D's own smoothing turns the snaps into a smooth glide). Until
	# the target is visible we stay put, so the observer waits gracefully.
	if NetworkManager.spectating:
		var tpos: Variant = NetworkManager.get_spectate_target_pos()
		if tpos != null:
			_player.global_position = tpos as Vector2
	_chunk_timer -= delta
	if _chunk_timer > 0.0:
		return
	_chunk_timer = 0.5
	_update_chunks(_player.global_position)

# Called when player spawns or respawns
func _on_player_respawned(pos: Vector2) -> void:
	if not _world_ready:
		_world_ready = true
		# A live 2D↔3D SWITCH lands here already logged-in — cover the rebuild with a
		# loading page (fresh boot builds behind the login screen, so no page needed).
		if NetworkManager.state == NetworkManager.NetState.LOGGED_IN:
			_loading_scr = _LoadingScreen.new()
			add_child(_loading_scr)
		_spawn_interactables()
		_spawn_npcs()
		_spawn_bosses()
		_spawn_admin_entities_from_cache()
		# On a scene switch (2D↔3D toggle) the server's one-time tile-paint + edit
		# bursts already fired in the OLD scene, so replay the caches to rebuild the
		# REAL admin map instead of the bare procedural one.
		if not NetworkManager.tile_overrides_cache.is_empty():
			_on_tile_overrides_received(NetworkManager.tile_overrides_cache)
		if not NetworkManager.entity_edits_cache.is_empty():
			_on_entity_edits_received(NetworkManager.entity_edits_cache)
		if _loading_scr != null and is_instance_valid(_loading_scr):
			_loading_scr.call("set_ready")
		Events.world_build_ready.emit(false)   # the intro director times reveals on this
	# OUTSIDE the first-build block + gated on LOGGED_IN, so it fires on the POST-LOGIN
	# respawn (GameManager emits player_respawned with the login pos) — never on the
	# pre-login build that World._ready kicks off behind the login screen.
	_maybe_show_prologue(pos)
	_update_chunks(pos)

# First login (ONCE per account, `user://prologue.cfg` flag keyed by username). The
# opening's shore reveal is a 3D flythrough, so the prologue runs as a persistent DIRECTOR
# on the tree root (surviving the 2D→3D→2D scene switches, masking each load behind the
# book / white). Never fires on death-respawn / a 2D↔3D switch — it's inside the one-time
# first-spawn block and the flag is set by then. `intro_active` guards re-entry across the
# switches (the 3D scene + the 2D scene we come back to both skip here).
func _maybe_show_prologue(pos: Vector2) -> void:
	# Only once the player has actually LOGGED IN — the pre-login world build (built
	# behind the login screen) also emits player_respawned, and must not fire the intro.
	if NetworkManager.state != NetworkManager.NetState.LOGGED_IN:
		return
	if GameManager.intro_active:
		return
	if _player == null or not _prologue_seen().is_empty():
		return
	GameManager.intro_active = true
	var pro := _OpeningPrologue.new()
	get_tree().root.add_child(pro)   # ROOT, not self — survives the scene switches
	pro.call("start_intro", pos)

## "" if the prologue is unseen for this account, else the resolved username (truthy).
func _prologue_seen() -> String:
	var uname := NetworkManager.my_username
	if uname.is_empty():
		uname = "_offline"
	var cfg := ConfigFile.new()
	cfg.load("user://prologue.cfg")
	return uname if bool(cfg.get_value("seen", uname, false)) else ""

# Settings → "Replay Opening": play the storybook again on demand (bypasses the flag),
# IN PLACE (no 3D routing on a replay). The 2D shore pan runs if the player is at
# Bjorn's Landing; from anywhere else it's book + a plain white → game dissolve.
func _on_replay_prologue() -> void:
	if _world_ready:
		add_child(_OpeningPrologue.new())

# ── Shore cinematic (2D Camera2D pan) — world pixels. Bjorn's = Rect2(7200,3744,…);
#    top-down axes: north=-y, south=+y, east=+x, west=-x. TUNE after watching. ──
const _CINE_BJORN_RECT := Rect2(7200, 3744, 1376, 1376)
const _CINE_BEACH      := Vector2(8360, 5000)   # sand SE — the foam washes here
const _CINE_OCEAN      := Vector2(8900, 4300)   # out over the water NE/E
const _CINE_BEACH_ZOOM := Vector2(3.0, 3.0)
const _CINE_OCEAN_ZOOM := Vector2(1.7, 1.7)
const _CINE_CHAR_ZOOM  := Vector2(2.5, 2.5)     # = gameplay zoom (player.tscn)
const _CINE_SEG1       := 3.0
const _CINE_SEG2       := 3.4
var _cine_cam2d: Camera2D = null

## Called by OpeningPrologue during the shore reveal — the 2D camera pan:
## beach → ocean → sweep west + zoom onto the character, then hand back to the player
## camera and tell the prologue to finish. Away from Bjorn's (a replay) → no pan.
func play_shore_cinematic(prologue: Node) -> void:
	if _player == null or not _CINE_BJORN_RECT.has_point(_player.global_position):
		if prologue != null and prologue.has_method("cinematic_done"):
			prologue.call("cinematic_done")
		return
	var char_pos := _player.global_position
	_cine_cam2d = Camera2D.new()
	_cine_cam2d.zoom = _CINE_BEACH_ZOOM
	add_child(_cine_cam2d)
	_cine_cam2d.global_position = _CINE_BEACH
	_cine_cam2d.make_current()
	_spawn_cine_wave(_CINE_BEACH)
	var t := create_tween()
	t.tween_interval(0.9)   # hold on the beach as the white clears + the foam washes
	t.tween_property(_cine_cam2d, "global_position", _CINE_OCEAN, _CINE_SEG1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(_cine_cam2d, "zoom", _CINE_OCEAN_ZOOM, _CINE_SEG1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_interval(0.6)
	t.tween_property(_cine_cam2d, "global_position", char_pos, _CINE_SEG2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(_cine_cam2d, "zoom", _CINE_CHAR_ZOOM, _CINE_SEG2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.tween_callback(_end_shore_cinematic.bind(prologue))

func _end_shore_cinematic(prologue: Node) -> void:
	if _player != null:
		var pcam := _player.get_node_or_null("Camera2D") as Camera2D
		if pcam != null:
			pcam.make_current()
			pcam.reset_smoothing()
	if _cine_cam2d != null and is_instance_valid(_cine_cam2d):
		_cine_cam2d.queue_free()
		_cine_cam2d = null
	if prologue != null and is_instance_valid(prologue) and prologue.has_method("cinematic_done"):
		prologue.call("cinematic_done")

## Foam that washes up the sand once and recedes (placeholder VFX — swap for a real
## water sprite/shader later).
func _spawn_cine_wave(at: Vector2) -> void:
	var foam := Polygon2D.new()
	foam.polygon = PackedVector2Array([Vector2(-320, -28), Vector2(320, -28), Vector2(380, 52), Vector2(-380, 52)])
	foam.color = Color(0.92, 0.97, 1.0, 0.6)
	foam.z_index = 60
	foam.position = at + Vector2(150, 150)
	foam.modulate.a = 0.0
	add_child(foam)
	var wt := create_tween()
	wt.tween_property(foam, "modulate:a", 1.0, 0.5)
	wt.parallel().tween_property(foam, "position", at + Vector2(-60, -70), 1.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	wt.tween_property(foam, "modulate:a", 0.0, 0.8)
	wt.tween_callback(foam.queue_free)

# ── Chunk management ──────────────────────────────────────────────────────────
func _update_chunks(player_pos: Vector2) -> void:
	var pcx := floori(player_pos.x / float(CHUNK_PX))
	var pcy := floori(player_pos.y / float(CHUNK_PX))
	var center := Vector2i(pcx, pcy)
	if center == _last_chunk:
		return
	_last_chunk = center

	var max_cx := ceili(float(COLS * TILE) / float(CHUNK_PX))
	var max_cy := ceili(float(ROWS * TILE) / float(CHUNK_PX))

	# Build desired set
	var desired: Dictionary = {}
	for dx in range(-ACTIVE_RADIUS, ACTIVE_RADIUS + 1):
		for dy in range(-ACTIVE_RADIUS, ACTIVE_RADIUS + 1):
			var cx := pcx + dx
			var cy := pcy + dy
			if cx < 0 or cy < 0 or cx >= max_cx or cy >= max_cy:
				continue
			desired[Vector2i(cx, cy)] = true

	# Collect chunks to unload (don't modify dict during iteration)
	var to_unload: Array = []
	for key: Variant in _active_chunks.keys():
		if not desired.has(key):
			to_unload.append(key)
	for key: Variant in to_unload:
		_unload_chunk(key as Vector2i)

	# Load chunks not yet active
	for key: Variant in desired.keys():
		if not _active_chunks.has(key):
			_load_chunk((key as Vector2i).x, (key as Vector2i).y)

	# Stream admin (a:) entities at the SAME radius as procedural content.
	_update_admin_chunks(desired)

func _load_chunk(cx: int, cy: int) -> void:
	var key    := Vector2i(cx, cy)
	var nodes: Array = []
	# Interior band chunks: no procedural trees or monsters. Interior floors
	# are hand-painted tile canvases; procedural spawn would litter them
	# with wolves and oaks. Chunk-py boundary: EXTERIOR_ROWS * TILE.
	var is_interior_chunk := cy * CHUNK_PX >= EXTERIOR_ROWS * TILE
	if not is_interior_chunk:
		_spawn_chunk_resources(cx, cy, nodes)
		if PROCEDURAL_MONSTERS:
			_spawn_chunk_monsters(cx, cy, nodes)
		# Ambient life — cheap non-interactable creatures per chunk. Skipped
		# for interior chunks since interiors have no biome creatures. Freed
		# with the rest of the chunk nodes on unload (added to `nodes`).
		_spawn_chunk_ambient_life(cx, cy, nodes)
	_active_chunks[key] = nodes
	# Ask the server for the current shared state of this chunk's entities.
	var node_ids: Array = []
	var mob_ids:  Array = []
	for node: Variant in nodes:
		var obj := node as Object
		if obj.has_method("begin_gather"):
			node_ids.append(str((node as Node).get("entity_id")))
		elif obj.has_method("set_server_hp"):
			mob_ids.append(str((node as Node).get("entity_id")))
	if not node_ids.is_empty():
		NetworkManager.send_node_states(node_ids)
	if not mob_ids.is_empty():
		NetworkManager.send_monster_states(mob_ids)
	# Keep admin-moved entities out of this chunk's cull-list so they persist.
	_pull_moved_from_chunk(key)

func _unload_chunk(key: Vector2i) -> void:
	if not _active_chunks.has(key):
		return
	for node: Variant in _active_chunks[key]:
		# Defensive: entities can be removed from another path while their Node
		# ref still sits in this chunk's list — e.g. admin delete or a server
		# entity_remove broadcast that calls queue_free() before this chunk
		# unloads. Casting a freed-object Variant throws, so check validity
		# (which accepts freed refs and returns false) before any `as` cast.
		if not is_instance_valid(node):
			continue
		var n: Node = node as Node
		if n == null:
			continue
		if n.has_method("begin_gather"):
			_node_registry.erase(str(n.get("entity_id")))
		elif n.has_method("set_server_hp"):
			_monster_registry.erase(str(n.get("entity_id")))
		n.queue_free()
	_active_chunks.erase(key)

# ── Procedural chunk content ──────────────────────────────────────────────────
func _spawn_chunk_resources(cx: int, cy: int, out: Array) -> void:
	var ground := get_node_or_null("Ground")
	var c      := $Interactables
	var rng    := RandomNumberGenerator.new()
	rng.seed   = (cx * 7919 + cy * 6271) ^ 0xA3C5F1
	var ox     := float(cx * CHUNK_PX)
	var oy     := float(cy * CHUNK_PX)
	for _i in range(RES_ATTEMPTS):
		var pos := Vector2(
			clampf(ox + rng.randf() * CHUNK_PX, 64, COLS * TILE - 64),
			clampf(oy + rng.randf() * CHUNK_PX, 64, ROWS * TILE - 64))
		var biome: String = ""
		if ground != null:
			biome = ground.call("biome_at_world", pos)
		var d := _resource_data(biome, pos, rng, ground)
		if d.size() == 0:
			continue
		var node: Node2D = _Interactable.instantiate()
		node.position              = pos
		node.interactable_type_str = d[0]
		node.display_name          = d[1]
		# Gathering-skill overrides by node type (some biome tables still tag these
		# "foraging", which canonicalises to farming — wrong for debris). Herbs are
		# a FARMING activity; sticks train WOODCUTTING and stones train MINING so
		# picking up debris no longer feeds farming XP.
		match d[0]:
			"herb":  node.required_skill = "farming"
			"stick": node.required_skill = "woodcutting"
			"stone": node.required_skill = "mining"
			_:       node.required_skill = d[2]
		node.required_level        = d[3]
		node.action_label          = d[4]
		node.color                 = d[5]
		# Stable, deterministic id (chunk + spawn attempt). Both clients and the
		# server derive the same id without communication, so server-owned state
		# (locks / depletion / respawn) maps 1:1 to each client's node.
		node.entity_id = "r:%d:%d:%d" % [cx, cy, _i]
		if not _register_editable(node, node.entity_id):
			node.queue_free()
			continue
		_node_registry[node.entity_id] = node
		c.add_child(node)
		out.append(node)

## Instance one AmbientLife node per active chunk. The node picks its
## creature list from the chunk-center biome via Ground.biome_at_world.
## Added to `out` so _unload_chunk queue_frees it automatically when the
## player wanders out of range. Purely client-visual — no server sync.
func _spawn_chunk_ambient_life(cx: int, cy: int, out: Array) -> void:
	var ground := get_node_or_null("Ground")
	if ground == null:
		return
	var center := Vector2(float(cx) * CHUNK_PX + CHUNK_PX * 0.5,
			float(cy) * CHUNK_PX + CHUNK_PX * 0.5)
	var biome := ground.call("biome_at_world", center) as String
	var script := load("res://scripts/AmbientLife.gd")
	if script == null:
		return
	var node: Node2D = script.new() as Node2D
	node.name = "AmbientLife_%d_%d" % [cx, cy]
	# Position at chunk origin — creature coords are chunk-local (0..CHUNK_PX).
	node.global_position = Vector2(float(cx) * CHUNK_PX, float(cy) * CHUNK_PX)
	node.set("chunk_key", Vector2i(cx, cy))
	add_child(node)
	node.call("setup", biome)
	out.append(node)


func _spawn_chunk_monsters(cx: int, cy: int, out: Array) -> void:
	# Kill switch — defence in depth. The call site in _load_chunk is already
	# gated on PROCEDURAL_MONSTERS, but any future caller (bridge fill, quest
	# hooks, etc.) that misses the gate still short-circuits here.
	if not PROCEDURAL_MONSTERS:
		return
	var ground := get_node_or_null("Ground")
	var c      := $Interactables
	var rng    := RandomNumberGenerator.new()
	rng.seed   = (cx * 9901 + cy * 8317) ^ 0x7F3A9B
	var ox     := float(cx * CHUNK_PX)
	var oy     := float(cy * CHUNK_PX)
	for _i in range(MON_ATTEMPTS):
		var pos := Vector2(
			clampf(ox + rng.randf() * CHUNK_PX, 64, COLS * TILE - 64),
			clampf(oy + rng.randf() * CHUNK_PX, 64, ROWS * TILE - 64))
		if _in_safe_zone(pos):
			continue
		var biome: String = ""
		if ground != null:
			biome = ground.call("biome_at_world", pos)
		var mtype := _monster_type(biome, pos, rng)
		if mtype.is_empty():
			continue
		var m := Area2D.new()
		m.set_script(_Monster)
		m.position     = pos
		m.monster_type = mtype
		m.entity_id    = "m:%d:%d:%d" % [cx, cy, _i]
		if not _register_editable(m, m.entity_id):
			m.queue_free()
			continue
		_monster_registry[m.entity_id] = m
		c.add_child(m)
		# Stage 1 server AI seed — every chunk monster needs to register
		# with the server so _monster_ai_loop sees it. _ready ran during
		# add_child, so max_hp / attack / level / xp_reward are set.
		# Server's _handle_monster_join is idempotent (existing-entry path
		# leaves AI fields alone), so duplicate calls from multiple
		# clients in the same chunk are safe.
		NetworkManager.send_monster_join(m.entity_id, m.position.x, m.position.y,
			int(m.get("max_hp")), int(m.get("xp_reward")),
			str(m.get("monster_type")), int(m.get("level")),
			int(m.get("attack")), true)   # seed_only: chunk load, no aggro
		out.append(m)
	# Bridge monster — spawn one per border chunk (30% chance)
	if ground != null and rng.randi() % 10 < 3:
		var center := Vector2(ox + CHUNK_PX * 0.5, oy + CHUNK_PX * 0.5)
		if not _in_safe_zone(center):
			var cb := ground.call("biome_at_world", center) as String
			var biome_set: Dictionary = {}
			biome_set[cb] = true
			for corner: Vector2 in [Vector2(0.1, 0.1), Vector2(0.9, 0.1),
									Vector2(0.1, 0.9), Vector2(0.9, 0.9)]:
				var bm := ground.call("biome_at_world",
					Vector2(ox + CHUNK_PX * corner.x, oy + CHUNK_PX * corner.y)) as String
				biome_set[bm] = true
			if biome_set.size() > 1:
				var bridge := _bridge_monster_for_biomes(biome_set, rng)
				if not bridge.is_empty():
					var bm2 := Area2D.new()
					bm2.set_script(_Monster)
					bm2.position     = center
					bm2.monster_type = bridge
					var lv_range := _BRIDGE_LEVEL_RANGE.get(bridge, [1, 1]) as Array
					var lv := (lv_range[0] as int) + rng.randi() % maxi(1, (lv_range[1] as int) - (lv_range[0] as int) + 1)
					bm2.entity_id    = "m:%d:%d:b" % [cx, cy]
					if not _register_editable(bm2, bm2.entity_id):
						bm2.queue_free()
					else:
						_monster_registry[bm2.entity_id] = bm2
						c.add_child(bm2)
						bm2.call("scale_to_level", lv)
						# Bridge monster also needs to register for AI —
						# call AFTER scale_to_level so the server sees the
						# scaled max_hp / attack, not the base type stats.
						NetworkManager.send_monster_join(bm2.entity_id,
							bm2.position.x, bm2.position.y,
							int(bm2.get("max_hp")), int(bm2.get("xp_reward")),
							str(bm2.get("monster_type")), int(bm2.get("level")),
							int(bm2.get("attack")), true)   # seed_only: bridge fill, no aggro
						out.append(bm2)

# ── Static entity spawning (called once after first login) ───────────────────
func _spawn_interactables() -> void:
	var c := $Interactables
	for i in range(_TOWN_NODES.size()):
		_spawn_town_row(c, _TOWN_NODES[i] as Array, "t:%d" % i)
	# Kjelvik castle ring — generated, so it carries its own stable id prefix
	# ("kc:N") and never collides with the hand-listed "t:N" rows. Interior keys
	# are unaffected (walls/towers aren't enterable).
	var castle := _kjelvik_castle_nodes()
	for i in range(castle.size()):
		_spawn_town_row(c, castle[i] as Array, "kc:%d" % i)

## Instantiate one [pos, type, name, skill, level, action, color] row under
## `parent`, honouring admin delete/move edits via _register_editable.
## Wall/tower structure types that the server tracks as damageable town
## defences (Kjelvik's castle ring seeds matching structures_state["kc:N"]).
## Giving these rows their entity_id lets the attack path address the server
## structure so they can be smashed + repaired like admin-placed town walls.
const _ATTACKABLE_STRUCT_TYPES: Array = [
	"fortified_wall", "watchtower", "guard_tower", "wall", "gate"]

func _spawn_town_row(parent: Node, d: Array, edit_id: String) -> void:
	var node: Node2D = _Interactable.instantiate()
	node.position              = d[0]
	node.interactable_type_str = d[1]
	node.display_name          = d[2]
	node.required_skill        = d[3]
	node.required_level        = d[4]
	node.action_label          = d[5]
	node.color                 = d[6]
	# Only wall/tower town structures carry an entity_id (so left-click attacks
	# reach the server); the rest stay id-less so a bank/well click can't be
	# mistaken for a structure hit.
	if _ATTACKABLE_STRUCT_TYPES.has(str(d[1])):
		node.entity_id = edit_id
	if not _register_editable(node, edit_id):
		node.queue_free()
		return
	parent.add_child(node)

func _spawn_npcs() -> void:
	var c := $Interactables
	for i in range(_NPCS.size()):
		var d: Array = _NPCS[i]
		var n := Area2D.new()
		n.set_script(_NPC)
		n.position      = d[0]
		n.npc_type      = d[1]
		n.npc_name_str  = d[2]
		n.quest_text    = d[3]
		n.wander_radius = d[4]
		# Optional 6th column = shop_id, so a SEEDED shopkeeper can actually trade
		# (right-click → Trade / left-click) without needing an admin edit. Older
		# 5-column rows default to no shop.
		if d.size() > 5:
			n.shop_id   = str(d[5])
		# Regional wardrobe (Phase 5c) — derived from where the NPC stands.
		n.region        = _region_for_pos(d[0] as Vector2)
		if not _register_editable(n, "n:%d" % i):
			n.queue_free()
			continue
		c.add_child(n)
		_apply_entity_data(n, _edits_data.get("n:%d" % i, {}) as Dictionary)

## Which town an NPC stands in, for the regional wardrobe (Phase 5c). Mirrors
## the _SAFE_ZONES order; Kjelvik is checked first so the castle-quarter NPCs
## (whose rect just overlaps Ironwood's northern edge) resolve to the capital.
const _REGION_RECTS: Array = [
	["kjelvik",   Rect2(1984, 3008, 1376, 1376)],
	["frostheim", Rect2( 704,  256, 1376, 1376)],
	["ironwood",  Rect2(2880, 4288, 1376, 1376)],
	["eastmark",  Rect2(5248, 5184, 1376, 1376)],
	["bjorn",     Rect2(7200, 3744, 1376, 1376)],
]

func _region_for_pos(p: Vector2) -> String:
	for entry: Array in _REGION_RECTS:
		if (entry[1] as Rect2).has_point(p):
			return str(entry[0])
	return ""

func _spawn_bosses() -> void:
	var c := $Interactables
	for i in range(_BOSS_SPAWNS.size()):
		var d: Array = _BOSS_SPAWNS[i]
		var m := Area2D.new()
		m.set_script(_Monster)
		m.position     = d[0]
		m.monster_type = d[1]
		if not _register_editable(m, "b:%d" % i):
			m.queue_free()
			continue
		c.add_child(m)
		_apply_entity_data(m, _edits_data.get("b:%d" % i, {}) as Dictionary)

# ── Static spawn data accessors (v1.6 P3 — read by the 3D client) ─────────────
# The 3D world (World3D) reuses this static geometry instead of duplicating the
# ~150 rows of const town/NPC/boss data. Pure reads (no tree/_ready needed), so
# World3D can call them on a throwaway `WorldScript.new()` instance and free it.
func get_town_nodes() -> Array:   return _TOWN_NODES
func get_castle_nodes() -> Array: return _kjelvik_castle_nodes()
func get_npcs() -> Array:         return _NPCS
func get_boss_spawns() -> Array:  return _BOSS_SPAWNS

# ── Helpers ───────────────────────────────────────────────────────────────────
func _in_safe_zone(pos: Vector2) -> bool:
	for z: Variant in _SAFE_ZONES:
		if (z as Rect2).has_point(pos):
			return true
	return false

# Returns [type, name, skill, req_level, action, color] or []
func _is_shoreline(pos: Vector2, ground: Node) -> bool:
	if ground == null:
		return false
	for off: Vector2 in [Vector2(32, 0), Vector2(-32, 0), Vector2(0, 32), Vector2(0, -32)]:
		var nb: String = ground.call("biome_at_world", pos + off) as String
		if nb != "coast" and nb != "ocean":
			return true
	return false

## v1.7 B2a — BAKE the server-authoritative gather map. Reproduces every
## procedural node deterministically (SAME seed / RNG / _resource_data as
## _spawn_chunk_resources) + resolves its drop via a scratch node's _loot_data(),
## and adds all loaded admin (a:) gatherables. Result: id → {skill, level,
## drop_id, drop_name, xp, regen, color}. Uploaded so the server grants from it.
func bake_node_map() -> Dictionary:
	var out_map: Dictionary = {}
	var ground := get_node_or_null("Ground")
	if ground == null or not ground.has_method("biome_at_world"):
		return out_map
	var scratch: Node2D = _Interactable.instantiate()   # never added to tree
	var chunks_x := int(ceil(float(COLS) * TILE / float(CHUNK_PX)))
	var chunks_y := int(ceil(float(ROWS) * TILE / float(CHUNK_PX)))
	for cy in range(chunks_y):
		for cx in range(chunks_x):
			if cy * CHUNK_PX >= EXTERIOR_ROWS * TILE:
				continue   # interior band has no procedural resources
			var rng := RandomNumberGenerator.new()
			rng.seed = (cx * 7919 + cy * 6271) ^ 0xA3C5F1
			var ox := float(cx * CHUNK_PX)
			var oy := float(cy * CHUNK_PX)
			for i in range(RES_ATTEMPTS):
				var pos := Vector2(
					clampf(ox + rng.randf() * CHUNK_PX, 64, COLS * TILE - 64),
					clampf(oy + rng.randf() * CHUNK_PX, 64, ROWS * TILE - 64))
				var biome: String = str(ground.call("biome_at_world", pos))
				var d := _resource_data(biome, pos, rng, ground)
				if d.size() == 0:
					continue
				out_map["r:%d:%d:%d" % [cx, cy, i]] = _bake_entry(scratch, d)
	# Loaded admin gatherables.
	for id_v: Variant in _admin_registry.keys():
		var node: Variant = _admin_registry.get(id_v)
		if node == null or not is_instance_valid(node as Node):
			continue
		var n := node as Node2D
		if not n.has_method("_loot_data"):
			continue
		var loot: Dictionary = n.call("_loot_data")
		if loot.is_empty():
			continue
		out_map[str(id_v)] = {
			"skill": str(n.get("required_skill")), "level": int(n.get("required_level")),
			"type": str(n.get("interactable_type_str")),   # type → server secondaries (⑥)
			"drop_id": str(loot.get("id", "")), "drop_name": str(loot.get("name", "")),
			"xp": int(loot.get("xp", 0)),
			"regen": _bake_regen(str(n.get("interactable_type_str")), int(n.get("required_level"))),
			"color": _bake_color(loot.get("color", Color(0.7, 0.7, 0.7)))}
	scratch.free()
	# ⑥ — bake the forage-seed table so the SERVER rolls herb→seed with the same
	# odds (Farming.roll_forage_seed). Stored under a reserved key alongside the
	# node entries (ids are "r:.."/"a:.." so no collision).
	var seeds: Array = []
	for s: Dictionary in _Farming.SEEDS:
		seeds.append({"seed": str(s.get("seed", "")), "seed_name": str(s.get("seed_name", "")),
			"lv": int(s.get("lv", 1)), "color": s.get("color", [0.7, 0.7, 0.4, 1.0])})
	out_map["_forage_seeds"] = seeds
	return out_map

## Resolve one procedural node's grant entry. `d` = [type_str, display, skill,
## level, action, color] from _resource_data; applies the same skill overrides
## _spawn_chunk_resources does (herb→farming, stick→woodcutting, stone→mining).
func _bake_entry(scratch: Node2D, d: Array) -> Dictionary:
	var type_str := str(d[0])
	var skill := str(d[2])
	match type_str:
		"herb":  skill = "farming"
		"stick": skill = "woodcutting"
		"stone": skill = "mining"
	scratch.set("interactable_type_str", type_str)
	scratch.set("display_name", str(d[1]))
	scratch.set("required_skill", skill)
	scratch.set("required_level", int(d[3]))
	var loot: Dictionary = scratch.call("_loot_data")
	return {
		"skill": skill, "level": int(d[3]), "type": type_str,   # type → server secondaries (⑥)
		"drop_id": str(loot.get("id", "")), "drop_name": str(loot.get("name", "")),
		"xp": int(loot.get("xp", 0)),
		"regen": _bake_regen(type_str, int(d[3])),
		"color": _bake_color(loot.get("color", Color(0.7, 0.7, 0.7)))}

## Regen tiers mirror Interactable's config (tree/rock scale with level; ground
## pickups + forage regen fast). Server-timed regen replaces the client-supplied one.
func _bake_regen(type_str: String, level: int) -> float:
	if type_str in ["stick", "stone", "herb"]:
		return 20.0
	if level < 15:   return 30.0
	elif level < 30: return 45.0
	elif level < 50: return 60.0
	elif level < 70: return 75.0
	elif level < 85: return 90.0
	return 120.0

func _bake_color(c: Variant) -> Array:
	var col: Color = c if c is Color else Color(0.7, 0.7, 0.7)
	return [col.r, col.g, col.b, col.a]

## v1.7 B3 — bake the monster-loot table so the SERVER rolls kills' loot. For each
## monster type: its `loot` array + BOOT/GEM chance drops; plus the universal soul
## table. Uploaded like the node map; server rolls + pushes to the killer.
func bake_monster_loot() -> Dictionary:
	var out: Dictionary = {}
	var types: Array = load("res://scripts/AdminCatalog.gd").monster_types()
	for mtype_v: Variant in types:
		var mtype := str(mtype_v)
		var m: Object = _Monster.new()
		m.set("monster_type", mtype)
		m.set("level", 10)
		if m.has_method("_apply_type_stats"):
			m.call("_apply_type_stats")
		var entry: Dictionary = {"loot": []}
		var la: Variant = m.get("loot")
		if la is Array:
			for d_v: Variant in (la as Array):
				var d: Dictionary = d_v
				(entry["loot"] as Array).append({
					"id": str(d.get("id", "")), "name": str(d.get("name", "")),
					"color": _bake_color(d.get("color", Color(0.7, 0.7, 0.7)))})
		if _Monster.BOOT_DROPS.has(mtype):
			var b: Dictionary = _Monster.BOOT_DROPS[mtype]
			entry["boot"] = {"id": str(b["id"]), "name": str(b["name"]),
				"chance": float(b["chance"]), "color": _bake_color(b["color"])}
		if _Monster.GEM_DROPS.has(mtype):
			var g: Dictionary = _Monster.GEM_DROPS[mtype]
			entry["gem"] = {"id": str(g["id"]), "name": str(g["name"]),
				"chance": float(g["chance"]), "color": _bake_color(g["color"])}
		out[mtype] = entry
		(m as Node).free()
	var soul: Array = []
	for t_v: Variant in _Monster.SOUL_DROPS:
		var t: Array = t_v
		soul.append([int(t[0]), str(t[1]), str(t[2]), _bake_color(t[3])])
	out["_soul"] = {"chance": float(_Monster.SOUL_DROP_CHANCE), "tiers": soul}
	return out

func _resource_data(biome: String, pos: Vector2, rng: RandomNumberGenerator, ground: Node) -> Array:
	var r := rng.randi() % 10
	match biome:
		"plains":
			if r < 4: return ["herb",  "Herb Patch", "foraging", 1, "Pick", Color(0.62, 0.82, 0.20)]
			if r < 7: return ["stick", "Stick",       "foraging", 1, "Pick", Color(0.55, 0.36, 0.14)]
			if r < 9: return ["stone", "Stone",       "foraging", 1, "Pick", Color(0.58, 0.56, 0.52)]
		"oak_forest":
			if r < 4: return ["tree",  "Oak Tree",  "woodcutting",  1, "Chop", Color(0.18, 0.55, 0.15)]
			if r < 6: return ["herb",  "Wild Bush", "foraging",     1, "Pick", Color(0.72, 0.22, 0.52)]
			if r < 7: return ["stone", "Stone",     "foraging",     1, "Pick", Color(0.58, 0.56, 0.52)]
			if r < 9: return ["stick", "Stick",     "foraging",     1, "Pick", Color(0.55, 0.36, 0.14)]
		"pine_forest":
			if r < 5: return ["tree", "Pine Tree",      "woodcutting",  5, "Chop", Color(0.10, 0.42, 0.20)]
			if r < 7: return ["herb", "Mushroom Patch", "foraging",    10, "Pick", Color(0.72, 0.55, 0.38)]
			if r < 8: return ["stone","Stone",           "foraging",     1, "Pick", Color(0.58, 0.56, 0.52)]
			if r < 9: return ["stick","Stick",           "foraging",     1, "Pick", Color(0.55, 0.36, 0.14)]
		"dark_forest":
			if r < 3: return ["tree", "Cherry Tree",     "woodcutting", 20, "Chop", Color(0.98, 0.72, 0.80)]
			if r < 5: return ["herb", "Mushroom Patch",  "foraging",    10, "Pick", Color(0.72, 0.55, 0.38)]
			if r < 8: return ["herb", "Moonbloom Patch", "foraging",    40, "Pick", Color(0.78, 0.62, 0.95)]
		"swamp":
			if r < 3: return ["herb", "Mushroom Patch",  "foraging", 10, "Pick", Color(0.72, 0.55, 0.38)]
			if r < 6: return ["herb", "Moonbloom Patch", "foraging", 40, "Pick", Color(0.78, 0.62, 0.95)]
			if r < 8: return ["herb", "Ancient Root",    "foraging", 60, "Dig",  Color(0.42, 0.28, 0.12)]
		"mountain":
			if r >= 7: return []
			var ty := floori(pos.y / float(TILE))
			if ty < 30:
				if r < 2: return ["rock", "Runite Rock",  "mining", 85, "Mine", Color(0.65, 0.20, 0.82)]
				if r < 5: return ["rock", "Adamant Rock", "mining", 70, "Mine", Color(0.20, 0.65, 0.30)]
				return         ["rock", "Mithril Rock", "mining", 50, "Mine", Color(0.40, 0.65, 0.90)]
			elif ty < 70:
				if r < 2: return ["rock", "Adamant Rock", "mining", 70, "Mine", Color(0.20, 0.65, 0.30)]
				if r < 4: return ["rock", "Mithril Rock", "mining", 50, "Mine", Color(0.40, 0.65, 0.90)]
				if r < 6: return ["rock", "Gold Vein",    "mining", 40, "Mine", Color(0.88, 0.72, 0.12)]
				return         ["rock", "Iron Rock",    "mining", 15, "Mine", Color(0.55, 0.55, 0.60)]
			else:
				if r < 4: return ["rock", "Iron Rock",   "mining", 15, "Mine", Color(0.55, 0.55, 0.60)]
				return         ["rock", "Copper Rock", "mining",  1, "Mine", Color(0.72, 0.42, 0.22)]
		"rocky":
			if r < 3: return ["rock", "Copper Rock", "mining",  1, "Mine", Color(0.72, 0.42, 0.22)]
			if r < 6: return ["rock", "Iron Rock",   "mining", 15, "Mine", Color(0.55, 0.55, 0.60)]
			if r < 9: return ["rock", "Gold Vein",   "mining", 30, "Mine", Color(0.88, 0.72, 0.12)]
		"coast":
			# Only at the land-water edge so players can fish from shore
			if not _is_shoreline(pos, ground):
				return []
			var tx := floori(pos.x / float(TILE))
			if tx > 270:
				if r < 4: return ["fish", "Abyssal Depth", "fishing", 80, "Fish", Color(0.28, 0.45, 0.35)]
				if r < 7: return ["fish", "Shark Waters",  "fishing", 60, "Fish", Color(0.55, 0.58, 0.62)]
				return         ["fish", "Lobster Pot",   "fishing", 40, "Fish", Color(0.90, 0.30, 0.20)]
			elif tx > 255:
				if r < 3: return ["fish", "Shark Waters",  "fishing", 60, "Fish", Color(0.55, 0.58, 0.62)]
				if r < 6: return ["fish", "Lobster Pot",   "fishing", 40, "Fish", Color(0.90, 0.30, 0.20)]
				if r < 9: return ["fish", "Salmon Spot",   "fishing", 20, "Fish", Color(0.95, 0.55, 0.30)]
			else:
				if r < 5: return ["fish", "Fishing Spot", "fishing",  1, "Fish", Color(0.18, 0.52, 0.82)]
				if r < 8: return ["fish", "Salmon Spot",  "fishing", 20, "Fish", Color(0.95, 0.55, 0.30)]
		"ocean":
			pass  # no fishing in open ocean — players cannot reach it
		"snow":
			if r < 3: return ["tree", "Frost Tree",   "woodcutting", 50, "Chop", Color(0.72, 0.90, 0.98)]
			if r < 5: return ["rock", "Mithril Rock", "mining",      50, "Mine", Color(0.40, 0.65, 0.90)]
			if r < 7: return ["rock", "Adamant Rock", "mining",      70, "Mine", Color(0.20, 0.65, 0.30)]
			if r < 9: return ["rock", "Runite Rock",  "mining",      85, "Mine", Color(0.65, 0.20, 0.82)]
		"helheim":
			if r < 3: return ["tree", "Ancient Tree", "woodcutting", 70, "Chop", Color(0.35, 0.20, 0.08)]
			if r < 6: return ["herb", "Ancient Root", "foraging",    60, "Dig",  Color(0.42, 0.28, 0.12)]
			if r < 8: return ["rock", "Runite Rock",  "mining",      85, "Mine", Color(0.65, 0.20, 0.82)]
		"ashlands":
			if r < 3: return ["herb", "Ancient Root",    "foraging", 60, "Dig",  Color(0.42, 0.28, 0.12)]
			if r < 5: return ["rock", "Adamant Rock",    "mining",   70, "Mine", Color(0.20, 0.65, 0.30)]
			if r < 7: return ["rock", "Runite Rock",     "mining",   85, "Mine", Color(0.65, 0.20, 0.82)]
			if r < 9: return ["herb", "Moonbloom Patch", "foraging", 40, "Pick", Color(0.78, 0.62, 0.95)]
	return []

const _BRIDGE_LEVEL_RANGE: Dictionary = {
	"dire_wolf":       [12, 18],
	"elder_bear":      [26, 32],
	"ancient_troll":   [40, 48],
	"frost_wyrm":      [58, 67],
	"magma_elemental": [72, 80],
}

func _bridge_monster_for_biomes(biome_set: Dictionary, _rng: RandomNumberGenerator) -> String:
	var has_plains   := biome_set.has("plains")
	var has_forest   := biome_set.has("pine_forest") or biome_set.has("oak_forest")
	var has_dark     := biome_set.has("dark_forest") or biome_set.has("swamp")
	var has_mountain := biome_set.has("mountain") or biome_set.has("rocky")
	var has_snow     := biome_set.has("snow")
	var has_ash      := biome_set.has("ashlands")
	var has_helheim  := biome_set.has("helheim")
	if has_plains and has_forest:   return "dire_wolf"
	if has_forest and has_dark:     return "elder_bear"
	if has_mountain and has_forest: return "ancient_troll"
	if has_snow and has_mountain:   return "frost_wyrm"
	if has_ash and has_helheim:     return "magma_elemental"
	return ""

func _monster_type(biome: String, pos: Vector2, rng: RandomNumberGenerator) -> String:
	if rng.randi() % 10 >= 4:
		return ""
	var r := rng.randi() % 4
	match biome:
		"plains":
			# Distance to the starter town (Bjorn's Landing). Within 20 tiles
			# new players see the easy mobs; weak-to-strong gradient outward.
			var dist := floori(pos.distance_to(Vector2(7823, 4488)) / float(TILE))
			if dist < 20:
				if r == 0 or r == 2: return "rat"
				if r == 1:           return "chicken"
			elif dist < 40:
				if r == 0: return "rat"
				if r == 1: return "wolf"
				if r == 2: return "goblin"
			elif dist < 70:
				if r == 0: return "wolf"
				if r == 1: return "goblin"
				if r == 2: return "bandit"
				return "skeleton"
			else:
				if r == 0: return "wolf"
				if r == 1: return "bandit"
				if r == 2: return "bear"
				return "skeleton"
		"oak_forest":
			if r == 0: return "goblin"
			if r == 1: return "wolf"
			if r == 2: return "bandit"
		"pine_forest":
			if r == 0: return "wolf"
			if r == 1: return "bandit"
			if r == 2: return "bear"
		"dark_forest":
			if r == 0: return "skeleton"
			if r == 1: return "spider"
			if r == 2: return "forest_spirit"
		"swamp":
			if r == 0: return "skeleton"
			if r == 1: return "spider"
			if r == 2: return "forest_spirit"
		"mountain":
			var ty := floori(pos.y / float(TILE))
			if ty < 25:
				if r == 0: return "frost_giant"
				if r == 1: return "ice_draugr"
			elif ty < 60:
				if r == 0: return "ice_wolf"
				if r == 1: return "frost_giant"
				if r == 2: return "troll"
			else:
				if r == 0: return "bear"
				if r == 1: return "troll"
				if r == 2: return "ice_wolf"
		"rocky":
			if r == 0: return "bandit"
			if r == 1: return "bear"
			if r == 2: return "troll"
		"coast":
			pass  # no land monsters on water tiles
		"snow":
			if r == 0: return "ice_wolf"
			if r == 1: return "frost_giant"
			if r == 2: return "ice_draugr"
		"helheim":
			if r == 0: return "death_knight"
			if r == 1: return "spectral_warrior"
			if r == 2: return "shadow_draugr"
		"ashlands":
			if r == 0: return "fire_imp"
			if r == 1: return "lava_crawler"
			if r == 2: return "fire_giant"
			return "shadow_draugr"
	return ""

func _create_border_walls() -> void:
	var w := float(COLS * TILE)
	# Keep the physical world border at the EXTERIOR bounds — otherwise the
	# south wall would sit past the interior band and players could stroll
	# straight into it from the overworld. Interior rooms have their own
	# walls (built by InteriorScene) that constrain the player once inside.
	var h := float(EXTERIOR_ROWS * TILE)
	var t := 64.0
	var borders: Array[Array] = [
		[Vector2(w * 0.5, -t * 0.5),      Vector2(w + t * 2.0, t)],
		[Vector2(w * 0.5, h + t * 0.5),   Vector2(w + t * 2.0, t)],
		[Vector2(-t * 0.5, h * 0.5),      Vector2(t, h)],
		[Vector2(w + t * 0.5, h * 0.5),   Vector2(t, h)],
	]
	for bd: Array in borders:
		var body := StaticBody2D.new()
		body.collision_layer = 2
		body.collision_mask  = 0
		add_child(body)
		body.global_position = bd[0]
		var cs   := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = bd[1]
		cs.shape  = rect
		body.add_child(cs)

func _setup_camera_limits() -> void:
	var player := get_node_or_null("Player")
	if player == null:
		return
	var cam := player.get_node_or_null("Camera2D") as Camera2D
	if cam == null:
		return
	cam.limit_left   = 0
	cam.limit_top    = 0
	cam.limit_right  = COLS * TILE
	cam.limit_bottom = EXTERIOR_ROWS * TILE
