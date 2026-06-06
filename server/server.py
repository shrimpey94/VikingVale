"""
VikingVale Multiplayer Server
-------------------------------
WebSocket game server with SQLite persistence and offline thrall simulation.

Run:
    pip install websockets
    python server.py
"""

import asyncio
import hashlib
import json
import math
import os
import random
import secrets
import sqlite3
import time
from pathlib import Path

import profanity

try:
    from websockets.asyncio.server import serve
    import websockets
except ImportError:
    raise SystemExit("Missing dependency — run: pip install websockets")

PORT     = 8765
DB_PATH  = Path(__file__).parent / "game_server.db"
TILE_OVERRIDES_FILE = Path(__file__).parent / "tile_overrides.json"
WORLD_W  = 9600.0
WORLD_H  = 9600.0
MAX_DIST_FOR_ACTION  = 160.0
ACTION_RATE_LIMIT_MS = 500
IDLE_EFFICIENCY      = 0.55
MAX_IDLE_SECONDS     = 24 * 3600
# Per-resource overhead representing depleting a node + its respawn before the
# next can be gathered. Keeps idle gathering near live rates (~2 logs/min at
# tier 1) instead of one item per swing.
IDLE_GATHER_RESPAWN  = 22.0
WANDER_RADIUS        = 512.0   # px — 16 tiles; how far from logout the ghost wanders
IDLE_SPEED           = 160.0   # px/s — matches Player.SPEED
IDLE_MOVE_TICK       = 0.5     # seconds between position broadcasts while walking

# Hardcoded admin account. Only this username may place/delete/move world
# entities and use the /gold and /spawn commands.
ADMIN_USERNAME = "Busterrdust"

DEFAULT_SKILL_XP = {
    "woodcutting": 0, "mining": 0, "fishing": 0, "foraging": 0,
    "smithing": 0, "cooking": 0, "crafting": 0, "construction": 0,
    "farming": 0,
    "melee": 0, "ranged": 0, "magic": 0, "defense": 0,
    "vitality": 1154, "soul": 0,
}

# ── Thrall reward table ────────────────────────────────────────────────────────
# cycle = seconds for one full gather (swing_time * node_hp at that level)
# From Interactable._set_stats: tree swing = 2.0+lv*0.10, hp = 4+floor(lv/3)
#                               rock swing = 2.5+lv*0.12, hp = 4+floor(lv/3)
#                               fish swing = 4.0,          hp = 3
#                               herb swing = 2.0,          hp = 2

TASK_REWARDS = {
    # ── Woodcutting ───────────────────────────────────────────────────────────────
    # swing_time / success_at_req / success_at_99 match Interactable.gd _set_stats tiers
    ("woodcut", "oak"):      {"skill":"woodcutting","level":1,  "xp":25,  "swing_time":2.5,"success_at_req":0.80,"success_at_99":0.95,"item_id":"oak_log",      "item_name":"Oak Log"},
    ("woodcut", "pine"):     {"skill":"woodcutting","level":1,  "xp":35,  "swing_time":2.5,"success_at_req":0.80,"success_at_99":0.95,"item_id":"pine_log",     "item_name":"Pine Log"},
    ("woodcut", "cherry"):   {"skill":"woodcutting","level":15, "xp":50,  "swing_time":2.5,"success_at_req":0.55,"success_at_99":0.90,"item_id":"cherry_log",   "item_name":"Cherry Log"},
    ("woodcut", "ironwood"): {"skill":"woodcutting","level":30, "xp":75,  "swing_time":2.5,"success_at_req":0.40,"success_at_99":0.80,"item_id":"ironwood_log", "item_name":"Ironwood Log"},
    ("woodcut", "frost"):    {"skill":"woodcutting","level":50, "xp":100, "swing_time":3.0,"success_at_req":0.30,"success_at_99":0.70,"item_id":"frost_log",    "item_name":"Frost Log"},
    ("woodcut", "ancient"):  {"skill":"woodcutting","level":70, "xp":130, "swing_time":3.0,"success_at_req":0.25,"success_at_99":0.60,"item_id":"ancient_log",  "item_name":"Ancient Log"},
    # ── Mining ────────────────────────────────────────────────────────────────────
    ("mine", "copper"):  {"skill":"mining","level":1,  "xp":30,  "swing_time":2.5,"success_at_req":0.80,"success_at_99":0.95,"item_id":"copper_ore",  "item_name":"Copper Ore"},
    ("mine", "iron"):    {"skill":"mining","level":15, "xp":55,  "swing_time":2.5,"success_at_req":0.55,"success_at_99":0.90,"item_id":"iron_ore",    "item_name":"Iron Ore"},
    ("mine", "gold"):    {"skill":"mining","level":30, "xp":65,  "swing_time":2.5,"success_at_req":0.40,"success_at_99":0.80,"item_id":"gold_ore",    "item_name":"Gold Ore"},
    ("mine", "mithril"): {"skill":"mining","level":50, "xp":90,  "swing_time":3.0,"success_at_req":0.30,"success_at_99":0.70,"item_id":"mithril_ore", "item_name":"Mithril Ore"},
    ("mine", "adamant"): {"skill":"mining","level":70, "xp":110, "swing_time":3.0,"success_at_req":0.25,"success_at_99":0.60,"item_id":"adamant_ore", "item_name":"Adamant Ore"},
    ("mine", "runite"):  {"skill":"mining","level":85, "xp":125, "swing_time":3.5,"success_at_req":0.20,"success_at_99":0.50,"item_id":"runite_ore",  "item_name":"Runite Ore"},
    # ── Fishing ───────────────────────────────────────────────────────────────────
    ("fish", "small"):   {"skill":"fishing","level":1,  "xp":20, "swing_time":3.0,"success_at_req":0.75,"success_at_99":0.95,"item_id":"raw_fish",   "item_name":"Raw Fish"},
    ("fish", "salmon"):  {"skill":"fishing","level":20, "xp":35, "swing_time":3.5,"success_at_req":0.55,"success_at_99":0.90,"item_id":"raw_salmon", "item_name":"Raw Salmon"},
    ("fish", "lobster"): {"skill":"fishing","level":40, "xp":60, "swing_time":4.0,"success_at_req":0.40,"success_at_99":0.80,"item_id":"lobster",    "item_name":"Lobster"},
    ("fish", "shark"):   {"skill":"fishing","level":60, "xp":90, "swing_time":5.0,"success_at_req":0.25,"success_at_99":0.70,"item_id":"raw_shark",  "item_name":"Raw Shark"},
    # ── Foraging ──────────────────────────────────────────────────────────────────
    ("forage", "herb"):      {"skill":"foraging","level":1,  "xp":15, "swing_time":2.5,"success_at_req":0.90,"success_at_99":0.99,"item_id":"herbs",        "item_name":"Herbs"},
    ("forage", "mushroom"):  {"skill":"foraging","level":1,  "xp":20, "swing_time":2.5,"success_at_req":0.90,"success_at_99":0.99,"item_id":"mushrooms",    "item_name":"Mushrooms"},
    ("forage", "berries"):   {"skill":"foraging","level":5,  "xp":30, "swing_time":2.5,"success_at_req":0.90,"success_at_99":0.99,"item_id":"berries",      "item_name":"Berries"},
    ("forage", "moonbloom"): {"skill":"foraging","level":15, "xp":50, "swing_time":2.5,"success_at_req":0.90,"success_at_99":0.99,"item_id":"moonbloom",    "item_name":"Moonbloom"},
    ("forage", "root"):      {"skill":"foraging","level":30, "xp":70, "swing_time":2.5,"success_at_req":0.90,"success_at_99":0.99,"item_id":"ancient_root", "item_name":"Ancient Root"},
    # ── Combat ────────────────────────────────────────────────────────────────────
    ("combat", "rat"):      {"skill":"melee","level":1,  "xp_kill":30,  "monster_hp":10,  "monster_atk":1,  "swing_time":2.5,"item_id":"rat_bone",     "item_name":"Rat Bone"},
    ("combat", "goblin"):   {"skill":"melee","level":5,  "xp_kill":50,  "monster_hp":20,  "monster_atk":2,  "swing_time":2.5,"item_id":"goblin_ear",   "item_name":"Goblin Ear"},
    ("combat", "skeleton"): {"skill":"melee","level":15, "xp_kill":80,  "monster_hp":30,  "monster_atk":3,  "swing_time":2.5,"item_id":"bone",         "item_name":"Bone"},
    ("combat", "draugr"):   {"skill":"melee","level":25, "xp_kill":120, "monster_hp":50,  "monster_atk":5,  "swing_time":2.5,"item_id":"draugr_shard", "item_name":"Draugr Shard"},
    ("combat", "dragon"):   {"skill":"melee","level":60, "xp_kill":300, "monster_hp":100, "monster_atk":10, "swing_time":2.5,"item_id":"dragon_scale", "item_name":"Dragon Scale"},
}

# ── Quest catalog (mirror of scripts/QuestData.gd) ────────────────────────────
# Kept in sync MANUALLY — change one, change both. Same duplication pattern as
# _SHOPS_PY / _BASE_PRICES_EXPLICIT. Per-quest schema:
#   title          : str
#   description    : str
#   giver_npc      : str  — same NPC accepts and turns in
#   required       : dict — flat {skill: min_level}, each checked INDEPENDENTLY
#                            (no max-of-skills / no combat pseudo-skill)
#   repeatable     : bool — re-accept immediately after completion
#   daily          : bool — re-accept at next UTC midnight
#   boss           : bool — boss-repeat rule (see _quest_grant_rewards)
#   chain_next     : str  — quest_id to unlock at its NPC on completion ("" = standalone)
#   objectives     : list — [{type, target_id, quantity, display}], type in {kill, gather, talk}
#   rewards.xp     : dict {skill: amount}  — always granted on completion
#   rewards.gold   : int                   — first-completion-only for boss+repeatable
#   rewards.items  : list [{id, name, qty, color}]  — same first-only rule for boss+repeatable

_QUESTS_PY = {
    "q_rats": {
        "title": "Rat Infestation",
        "description": "Kill 5 Giant Rats near the walls of Kjelvik.",
        "giver_npc": "Elder Bjarne",
        "required": {},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "rat", "quantity": 5,
             "display": "Slay Giant Rats"},
        ],
        "rewards": {"xp": {"melee": 100, "vitality": 25}, "gold": 50, "items": []},
    },
    "q_wolves": {
        "title": "Goblin Hunt",
        "description": "Drive off 4 Goblins terrorising the Frostheim hunting grounds.",
        "giver_npc": "Hunter Ragnhild",
        "required": {},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "goblin", "quantity": 4,
             "display": "Slay Goblins"},
        ],
        "rewards": {"xp": {"melee": 120}, "gold": 80, "items": []},
    },
    "q_ironwood": {
        "title": "Into the Ironwood",
        "description": "Venture east and slay 3 Skeletons haunting the Ironwood.",
        "giver_npc": "Torsten the Wanderer",
        "required": {"melee": 5},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "skeleton", "quantity": 3,
             "display": "Slay Skeletons"},
        ],
        "rewards": {"xp": {"melee": 150, "vitality": 25}, "gold": 100, "items": []},
    },
    "q_ashlands": {
        "title": "Ashlands Menace",
        "description": "Investigate the ashlands by slaying 5 Draugr.",
        "giver_npc": "Scout Halfdan",
        "required": {"melee": 25},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "draugr", "quantity": 5,
             "display": "Slay Draugr"},
        ],
        "rewards": {"xp": {"melee": 350, "vitality": 50}, "gold": 250, "items": []},
    },
    "q_oak_logs": {
        "title": "Fresh Lumber",
        "description": "Bring Ulfr 10 Oak Logs for the workshop. He always needs more.",
        "giver_npc": "Blacksmith Ulfr",
        "required": {},
        "repeatable": True, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "oak_log", "quantity": 10,
             "display": "Gather Oak Logs"},
        ],
        "rewards": {"xp": {"woodcutting": 80}, "gold": 30, "items": []},
    },
    "q_logs": {
        "title": "Ironwood Timber",
        "description": "Gather 3 Ironwood Logs for Ulfr's legendary blade.",
        "giver_npc": "Blacksmith Ulfr",
        "required": {"woodcutting": 35},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "ironwood_log", "quantity": 3,
             "display": "Gather Ironwood Logs"},
        ],
        "rewards": {"xp": {"woodcutting": 200}, "gold": 150,
                    "items": [{"id": "iron_axe", "name": "Iron Axe",
                               "qty": 1, "color": [0.55, 0.55, 0.60, 1.0]}]},
    },
    "q_copper": {
        "title": "Copper Strike",
        "description": "Old Brynjar's forge is cold — bring him 5 Copper Ore.",
        "giver_npc": "Old Brynjar",
        "required": {},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "copper_ore", "quantity": 5,
             "display": "Mine Copper Ore"},
        ],
        "rewards": {"xp": {"mining": 90}, "gold": 40, "items": []},
    },
    "q_herbs": {
        "title": "Apothecary's Need",
        "description": "Brynhildr the Apothecary's stocks run low. Bring 8 Herbs daily.",
        "giver_npc": "Brynhildr the Apothecary",
        "required": {},
        "repeatable": False, "daily": True, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "herbs", "quantity": 8,
             "display": "Forage Herbs"},
        ],
        "rewards": {"xp": {"foraging": 70}, "gold": 35, "items": []},
    },
    "q_first_fish": {
        "title": "First Catch",
        "description": "Sigrid wants to see a fresh fish — bring her a Raw Fish, then speak with her again.",
        "giver_npc": "Sigrid the Fishmonger",
        "required": {},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_fish",
        "objectives": [
            {"type": "gather", "target_id": "raw_fish", "quantity": 1,
             "display": "Catch a Raw Fish"},
            {"type": "talk",   "target_id": "Sigrid the Fishmonger", "quantity": 1,
             "display": "Show Sigrid your catch"},
        ],
        "rewards": {"xp": {"fishing": 40}, "gold": 20,
                    "items": [{"id": "fishing_pole", "name": "Fishing Pole",
                               "qty": 1, "color": [0.48, 0.30, 0.08, 1.0]}]},
    },
    "q_fish": {
        "title": "Eastern Waters",
        "description": "Bring back 3 Lobsters from the coastal waters east of Bjorn's Landing.",
        "giver_npc": "Merchant Eydis",
        "required": {"fishing": 40},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "lobster", "quantity": 3,
             "display": "Catch Lobsters"},
        ],
        "rewards": {"xp": {"fishing": 180}, "gold": 75, "items": []},
    },
    "q_kill_nidhogg": {
        "title": "Slayer of Níðhöggr",
        "description": "The serpent stirs again. Find Níðhöggr and bring him down.",
        "giver_npc": "Captain Sten",
        "required": {"melee": 50, "vitality": 30},
        "repeatable": True, "daily": False, "boss": True, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "nidhogg", "quantity": 1,
             "display": "Slay Níðhöggr"},
        ],
        "rewards": {"xp": {"melee": 5000, "vitality": 500}, "gold": 10000,
                    "items": [{"id": "dragon_scale", "name": "Dragon Scale",
                               "qty": 3, "color": [0.20, 0.75, 0.35, 1.0]}]},
    },
}


# Predecessor lookup table — derived once at module load by scanning chain_next.
# {successor_quest_id: predecessor_quest_id}
_QUEST_PREREQS: dict = {}
for _qid, _q in _QUESTS_PY.items():
    _nxt = str(_q.get("chain_next", ""))
    if _nxt:
        _QUEST_PREREQS[_nxt] = _qid


# ── Shop economy (Phase 2 of the gold rework) ─────────────────────────────────
# Server-side mirror of scripts/ItemPrices.gd and scripts/ShopCatalog.gd. Kept
# in sync MANUALLY — change one, change both. The duplication is the price of
# Python⇆GDScript not sharing a const namespace, and matches the existing
# pattern (TASK_REWARDS above mirrors client data the same way).

# Skill list used by the sell-back multiplier — must match the 15 entries in
# GameManager.player_skill_xp and ItemPrices._SKILLS.
_SHOP_SKILLS = (
    "woodcutting", "mining", "fishing", "foraging",
    "smithing", "cooking", "crafting", "construction", "farming",
    "melee", "ranged", "magic", "defense", "vitality", "soul",
)

# Explicit base prices (mirror of ItemPrices.PRICES; tier-derived items get
# precomputed below). All values in gold.
_BASE_PRICES_EXPLICIT = {
    # Pickups / consumables
    "stick": 2, "stone": 3, "feather": 1, "arrows": 2, "rune_essence": 80,
    "magic_dust": 15, "craft_kit": 10, "arrow_bundle": 8, "timber": 12,
    # Logs
    "oak_log": 10, "pine_log": 15, "cherry_log": 35,
    "ironwood_log": 80, "frost_log": 150, "ancient_log": 300,
    # Ores
    "copper_ore": 12, "iron_ore": 25, "gold_ore": 60,
    "mithril_ore": 140, "adamant_ore": 280, "runite_ore": 550,
    # Bars
    "copper_bar": 35, "iron_bar": 75, "gold_bar": 180,
    "mithril_bar": 400, "adamant_bar": 800, "runite_bar": 1600,
    # Foraging
    "herbs": 5, "mushrooms": 8, "berries": 15, "moonbloom": 30, "ancient_root": 60,
    # Raw fish + meat
    "raw_fish": 8, "raw_salmon": 20, "lobster": 45, "raw_shark": 120,
    "abyssal_eel": 220, "raw_meat": 4, "raw_chicken": 5,
    # Deep-sea ladder
    "silverfin": 60, "frost_cod": 90, "void_squid": 130, "anglerfish": 180,
    "deep_runefish": 240, "lava_eel": 310, "abyssal_pearl": 390,
    "leviathan_eel": 480, "sea_serpent_scale": 580, "kraken_meat": 700,
    "leviathan_eye": 1000,
    # Standard monster drops
    "rat_bone": 5, "bone": 15, "goblin_ear": 12, "wolf_pelt": 30,
    "bandit_hood": 40, "bear_claw": 60, "draugr_shard": 60, "spider_silk": 80,
    "troll_hide": 100, "spirit_essence": 120, "ice_fang": 180, "ice_shard": 200,
    "frost_crystal": 250, "imp_horn": 280, "lava_carapace": 380,
    "dragon_scale": 400, "giant_ember": 450, "shadow_essence": 520,
    "death_rune": 600, "spectral_essence": 700,
    # Sea-monster drops
    "crab_claw": 10, "seagull_feather": 3, "eel_skin": 15, "serpent_scrap": 25,
    "razor_tooth": 60, "barnacle_shard": 100, "squid_ink": 140,
    "serpent_fang": 200, "siren_scale": 260, "witch_pearl": 340,
    "frost_heart": 450, "ember_lantern": 520, "void_tentacle": 650,
    "world_serpent_scale": 1200, "drowned_crown": 3000,
    # Cooked food
    "cooked_fish": 12, "herb_tea": 8, "cooked_rat_meat": 8, "roasted_chicken": 10,
    "grilled_trout": 18, "baked_potato": 14, "cooked_salmon": 28,
    "vegetable_stew": 24, "meat_pie": 30, "fish_soup": 28, "cooked_lobster": 60,
    "hearty_stew": 40, "shark_steak": 180, "honey_glazed_ham": 60,
    "stuffed_boar": 80, "spiced_fish": 50, "dragon_fin_soup": 200,
    "mead_braised_ribs": 90, "frost_trout_fillet": 150, "venison_roast": 95,
    "magma_prawn": 220, "smoked_bear": 180, "elder_fish_platter": 350,
    "giants_feast": 320, "eel_stew": 260, "leviathan_stew": 550,
    "kraken_platter": 900, "feast_of_valhalla": 2000,
    # Bait / lures
    "earthworm": 3, "fatty_lard": 50, "runic_lure": 2500, "kraken_bait": 5000,
    # Farming
    "barley_seed": 10, "cabbage_seed": 25, "onion_seed": 45,
    "wheat_seed": 80, "tomato_seed": 150,
    "barley": 5, "cabbage": 15, "onion": 30, "wheat": 50, "tomato": 90,
    # Wood tools
    "wooden_axe": 5, "wooden_pickaxe": 5, "wooden_fishing_pole": 5, "fishing_pole": 15,
    # Boats
    "oak_rowboat": 200, "pine_canoe": 500, "cherry_sailboat": 1200,
    "ironwood_longship": 3000, "frost_warship": 6000, "ancient_dragonship": 15000,
    # DEFS entries whose tier prefix isn't in TIER_INDEX
    "ironwood_bow": 600,
}

# Equipment derivation — mirrors Equipment.TIER_INDEX and the WEAPON/ARMOR/
# TOOL base tables in ItemPrices.gd. Used to precompute prices for every
# {tier}_{piece} combination at module load (so runtime is a flat dict.get).
_TIER_INDEX_PY = {
    "leather": 0, "copper": 1, "bronze": 1, "iron": 2, "gold": 1,
    "mithril": 4, "adamant": 5, "runite": 6, "dragon": 7,
}
_WEAPON_BASE_PY = {"sword": 40, "axe": 50, "battleaxe": 60, "mace": 35, "bow": 35, "staff": 30}
_ARMOR_BASE_PY = {
    "helm": 30, "helmet": 30, "body": 80, "platebody": 80, "chestplate": 80,
    "legs": 60, "platelegs": 60, "leg": 60, "boots": 25, "boot": 25,
    "gloves": 20, "gauntlets": 20, "glove": 20, "bracers": 25, "vambraces": 25,
    "arms": 25, "shield": 40, "quiver": 40, "amulet": 80, "necklace": 80,
    "ring": 30,
}
_TOOL_BASE_PY = {"pickaxe": 50}


def _build_base_prices() -> dict:
    out = dict(_BASE_PRICES_EXPLICIT)
    for tier, idx in _TIER_INDEX_PY.items():
        mult = 2 ** idx
        for piece, base in {**_WEAPON_BASE_PY, **_ARMOR_BASE_PY, **_TOOL_BASE_PY}.items():
            key = f"{tier}_{piece}"
            if key not in out:
                out[key] = int(base * mult)
    return out


_BASE_PRICES = _build_base_prices()

# Soulbound items — refuse to sell. Empty in v1; populate when quest rewards
# or unique drops land.
_SOULBOUND_ITEMS = set()

# Shop templates (mirror of ShopCatalog.SHOPS). The structure must match: any
# stock_template entry needs id / name / color / max / restock_per_tick.
# Phase 5 of the gold economy — monster gold drops. Mirror of Monster.gd's
# gold_min/gold_max fields. Roll in _monster_die. Anything not listed drops
# 0 gold (the dict lookup default).
_MONSTER_GOLD_PY = {
    "goblin":           (    5,    200),
    "skeleton":         (   30,    500),
    "bandit":           (  100,   2000),
    "troll":            (  400,    600),
    "frost_giant":      (  500,   2000),
    "fire_imp":         (   20,    100),
    "fire_giant":       (  700,   2000),
    "death_knight":     ( 1000,   4000),
    "spectral_warrior": ( 3000,  10000),
}


_SHOPS_PY = {
    "general_store": {
        "name": "Kjelvik General Store", "buy_multiplier": 1.0,
        "stock_template": [
            {"id": "stick",               "name": "Stick",               "color": [0.55, 0.36, 0.14, 1.0], "max": 100, "restock_per_tick": 10.0},
            {"id": "stone",               "name": "Stone",               "color": [0.58, 0.56, 0.52, 1.0], "max": 100, "restock_per_tick": 10.0},
            {"id": "arrows",              "name": "Arrows",              "color": [0.72, 0.65, 0.50, 1.0], "max": 200, "restock_per_tick": 20.0},
            {"id": "oak_log",             "name": "Oak Log",             "color": [0.60, 0.40, 0.15, 1.0], "max":  30, "restock_per_tick":  3.0},
            {"id": "copper_ore",          "name": "Copper Ore",          "color": [0.75, 0.45, 0.20, 1.0], "max":  30, "restock_per_tick":  3.0},
            {"id": "wooden_axe",          "name": "Wooden Axe",          "color": [0.55, 0.38, 0.16, 1.0], "max":   5, "restock_per_tick":  0.5},
            {"id": "wooden_pickaxe",      "name": "Wooden Pickaxe",      "color": [0.50, 0.34, 0.14, 1.0], "max":   5, "restock_per_tick":  0.5},
            {"id": "wooden_fishing_pole", "name": "Wooden Fishing Pole", "color": [0.45, 0.28, 0.08, 1.0], "max":   5, "restock_per_tick":  0.5},
            {"id": "fishing_pole",        "name": "Fishing Pole",        "color": [0.48, 0.30, 0.08, 1.0], "max":   3, "restock_per_tick":  0.3},
        ],
    },
    "weapons_smith": {
        "name": "Frostheim Smith", "buy_multiplier": 1.0,
        "stock_template": [
            {"id": "copper_bar",     "name": "Copper Bar",     "color": [0.80, 0.50, 0.20, 1.0], "max": 20, "restock_per_tick": 2.0},
            {"id": "iron_bar",       "name": "Iron Bar",       "color": [0.60, 0.60, 0.65, 1.0], "max": 15, "restock_per_tick": 1.5},
            {"id": "copper_axe",     "name": "Copper Axe",     "color": [0.78, 0.48, 0.22, 1.0], "max":  5, "restock_per_tick": 0.5},
            {"id": "copper_pickaxe", "name": "Copper Pickaxe", "color": [0.72, 0.44, 0.18, 1.0], "max":  5, "restock_per_tick": 0.5},
            {"id": "iron_axe",       "name": "Iron Axe",       "color": [0.55, 0.55, 0.60, 1.0], "max":  4, "restock_per_tick": 0.4},
            {"id": "iron_pickaxe",   "name": "Iron Pickaxe",   "color": [0.50, 0.50, 0.55, 1.0], "max":  4, "restock_per_tick": 0.4},
            {"id": "iron_sword",     "name": "Iron Sword",     "color": [0.55, 0.55, 0.60, 1.0], "max":  3, "restock_per_tick": 0.3},
            {"id": "iron_helm",      "name": "Iron Helm",      "color": [0.55, 0.55, 0.60, 1.0], "max":  3, "restock_per_tick": 0.3},
            {"id": "iron_body",      "name": "Iron Body",      "color": [0.55, 0.55, 0.60, 1.0], "max":  2, "restock_per_tick": 0.2},
            {"id": "iron_legs",      "name": "Iron Legs",      "color": [0.55, 0.55, 0.60, 1.0], "max":  2, "restock_per_tick": 0.2},
            {"id": "iron_boots",     "name": "Iron Boots",     "color": [0.60, 0.62, 0.65, 1.0], "max":  3, "restock_per_tick": 0.3},
        ],
    },
    "fishmonger": {
        "name": "Bjorn's Fishmonger", "buy_multiplier": 1.0,
        "stock_template": [
            {"id": "earthworm",     "name": "Earthworm",     "color": [0.55, 0.30, 0.20, 1.0], "max": 50, "restock_per_tick": 10.0},
            {"id": "fatty_lard",    "name": "Fatty Lard",    "color": [0.92, 0.86, 0.62, 1.0], "max": 20, "restock_per_tick":  2.0},
            {"id": "raw_fish",      "name": "Raw Fish",      "color": [0.70, 0.90, 0.95, 1.0], "max": 30, "restock_per_tick":  3.0},
            {"id": "raw_salmon",    "name": "Raw Salmon",    "color": [0.95, 0.55, 0.30, 1.0], "max": 15, "restock_per_tick":  1.0},
            {"id": "cooked_fish",   "name": "Cooked Fish",   "color": [0.85, 0.65, 0.35, 1.0], "max": 12, "restock_per_tick":  1.0},
            {"id": "cooked_salmon", "name": "Cooked Salmon", "color": [0.95, 0.52, 0.28, 1.0], "max":  8, "restock_per_tick":  0.5},
        ],
    },
    "apothecary": {
        "name": "Eastmark Apothecary", "buy_multiplier": 1.0,
        "stock_template": [
            {"id": "herbs",           "name": "Herbs",           "color": [0.45, 0.80, 0.20, 1.0], "max": 50, "restock_per_tick": 5.0},
            {"id": "mushrooms",       "name": "Mushrooms",       "color": [0.72, 0.55, 0.38, 1.0], "max": 30, "restock_per_tick": 3.0},
            {"id": "berries",         "name": "Berries",         "color": [0.72, 0.18, 0.50, 1.0], "max": 20, "restock_per_tick": 2.0},
            {"id": "moonbloom",       "name": "Moonbloom",       "color": [0.78, 0.62, 0.95, 1.0], "max": 10, "restock_per_tick": 1.0},
            {"id": "herb_tea",        "name": "Herb Tea",        "color": [0.55, 0.85, 0.45, 1.0], "max": 15, "restock_per_tick": 1.5},
            {"id": "baked_potato",    "name": "Baked Potato",    "color": [0.74, 0.58, 0.34, 1.0], "max":  8, "restock_per_tick": 0.5},
            {"id": "cooked_rat_meat", "name": "Cooked Rat Meat", "color": [0.62, 0.40, 0.28, 1.0], "max": 10, "restock_per_tick": 1.0},
        ],
    },
    "magic_vendor": {
        "name": "Ironwood Magic Vendor", "buy_multiplier": 1.0,
        "stock_template": [
            {"id": "rune_essence", "name": "Rune Essence", "color": [0.65, 0.35, 0.80, 1.0], "max": 50, "restock_per_tick": 5.0},
            {"id": "magic_dust",   "name": "Magic Dust",   "color": [0.65, 0.35, 0.80, 1.0], "max": 30, "restock_per_tick": 3.0},
            {"id": "feather",      "name": "Feather",      "color": [0.95, 0.94, 0.88, 1.0], "max": 50, "restock_per_tick": 5.0},
            {"id": "copper_bar",   "name": "Copper Bar",   "color": [0.80, 0.50, 0.20, 1.0], "max": 10, "restock_per_tick": 1.0},
            {"id": "gold_amulet",  "name": "Gold Amulet",  "color": [0.95, 0.80, 0.15, 1.0], "max":  2, "restock_per_tick": 0.1},
            {"id": "ironwood_bow", "name": "Ironwood Bow", "color": [0.28, 0.14, 0.06, 1.0], "max":  2, "restock_per_tick": 0.1},
        ],
    },
}


# ── Database ───────────────────────────────────────────────────────────────────

def _db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db() -> None:
    with _db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS players (
                id            TEXT PRIMARY KEY,
                username      TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                salt          TEXT NOT NULL,
                x             REAL DEFAULT 7823,
                y             REAL DEFAULT 4488,
                skill_xp      TEXT DEFAULT '{}',
                inventory     TEXT DEFAULT '[]',
                bank          TEXT DEFAULT '[]',
                task_queue    TEXT DEFAULT '[]',
                created_at    REAL DEFAULT 0,
                last_seen     REAL DEFAULT 0
            )
        """)
        try:
            conn.execute("ALTER TABLE players ADD COLUMN task_queue TEXT DEFAULT '[]'")
        except Exception:
            pass
        try:
            conn.execute("ALTER TABLE players ADD COLUMN gold INTEGER DEFAULT 0")
        except Exception:
            pass
        try:
            conn.execute("ALTER TABLE players ADD COLUMN appearance TEXT DEFAULT '{}'")
        except Exception:
            pass
        try:
            conn.execute("ALTER TABLE players ADD COLUMN equipment TEXT DEFAULT '{}'")
        except Exception:
            pass
        # Phase 6 of interiors — three new columns for the current interior
        # state (empty = on the exterior overworld). interior_x/y are the
        # player's position INSIDE the active interior; the exterior x/y in
        # the existing columns are preserved as the "return point".
        try:
            conn.execute("ALTER TABLE players ADD COLUMN interior_id TEXT DEFAULT ''")
        except Exception:
            pass
        try:
            conn.execute("ALTER TABLE players ADD COLUMN interior_x REAL DEFAULT 0")
        except Exception:
            pass
        try:
            conn.execute("ALTER TABLE players ADD COLUMN interior_y REAL DEFAULT 0")
        except Exception:
            pass
        conn.execute("""
            CREATE TABLE IF NOT EXISTS ah_listings (
                id          TEXT PRIMARY KEY,
                seller_id   TEXT NOT NULL,
                seller_name TEXT NOT NULL,
                item_id     TEXT NOT NULL,
                item_name   TEXT NOT NULL,
                qty         INTEGER NOT NULL,
                price_each  INTEGER NOT NULL,
                listed_at   REAL NOT NULL
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS friendships (
                player_id TEXT NOT NULL,
                friend_id TEXT NOT NULL,
                PRIMARY KEY (player_id, friend_id)
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS clans (
                id         TEXT PRIMARY KEY,
                name       TEXT UNIQUE NOT NULL,
                leader_id  TEXT NOT NULL,
                bank       TEXT DEFAULT '[]',
                gold       INTEGER DEFAULT 0,
                created_at REAL NOT NULL
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS clan_members (
                clan_id   TEXT NOT NULL,
                player_id TEXT NOT NULL,
                role      TEXT DEFAULT 'member',
                joined_at REAL NOT NULL,
                PRIMARY KEY (clan_id, player_id)
            )
        """)
        # Multi-admin roster. Two ranks: 'owner' (cannot be demoted, only one
        # exists — Busterrdust, hardcoded and re-asserted on every boot) and
        # 'admin' (full panel + admin command access EXCEPT for /promote and
        # /demote, which are owner-only). Lookups are case-insensitive against
        # the player's actual username, so we normalize on write/read.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS admins (
                username TEXT PRIMARY KEY,
                rank     TEXT NOT NULL DEFAULT 'admin'
            )
        """)
        # Admin-placed world entities — persist independently of the procedurally
        # generated world, so they survive restarts and load for every client.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS world_entities (
                id      TEXT PRIMARY KEY,
                kind    TEXT NOT NULL,
                subtype TEXT NOT NULL,
                x       REAL NOT NULL,
                y       REAL NOT NULL,
                data    TEXT DEFAULT '{}'
            )
        """)
        # Admin-painted terrain overrides — biome name keyed by tile coordinate.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS tile_overrides (
                tx    INTEGER NOT NULL,
                ty    INTEGER NOT NULL,
                biome TEXT NOT NULL,
                PRIMARY KEY (tx, ty)
            )
        """)
        # Admin edits to PRE-EXISTING (procedural / hardcoded) entities, keyed by
        # their stable client id (r:/m:/t:/n:/b:). deleted=1 hides them; x/y (when
        # set) override their spawn position. Survives chunk streaming + restarts.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS entity_edits (
                id      TEXT PRIMARY KEY,
                deleted INTEGER DEFAULT 0,
                x       REAL,
                y       REAL
            )
        """)
        # ── Migration framework ───────────────────────────────────────────────
        # Single-row counter tracking the schema version. CHECK forces id=1 so
        # no second row can ever exist. Each _migrate_vN function runs inside
        # its own transaction and bumps this counter atomically.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS db_version (
                id      INTEGER PRIMARY KEY CHECK (id = 1),
                version INTEGER NOT NULL
            )
        """)
        conn.execute("INSERT OR IGNORE INTO db_version (id, version) VALUES (1, 0)")
        conn.commit()
    print(f"[db] {DB_PATH}")
    _run_migrations()


# ══════════════════════════════════════════════════════════════════════════════
# SCHEMA MIGRATIONS
# ══════════════════════════════════════════════════════════════════════════════
# Each migration is gated on the current schema version. New migrations append
# to the _MIGRATIONS list with the next sequential version number. Failures
# rollback and halt server startup — we never run with half-migrated state.

# Backup files retained for one boot, then swept by the cleanup migration.
_BAK_TILE_OVERRIDES = Path(__file__).parent / "tile_overrides.json.bak"
_BAK_SHOP_STOCK     = Path(__file__).parent / "shop_stock.json.bak"

# Boss-type allowlist for HP persistence. Add to this set as new world bosses
# come online. Non-boss monsters always boot at full HP.
_BOSS_MONSTER_TYPES: set = {"nidhogg"}


def _get_db_version() -> int:
    with _db() as conn:
        row = conn.execute("SELECT version FROM db_version WHERE id=1").fetchone()
    return int(row["version"]) if row else 0


def _set_db_version(conn, v: int) -> None:
    conn.execute("UPDATE db_version SET version=? WHERE id=1", (v,))


def _run_migrations() -> None:
    cur = _get_db_version()
    target = len(_MIGRATIONS)
    if cur >= target:
        return
    print(f"[db] migrating schema {cur} → {target}")
    for i, fn in enumerate(_MIGRATIONS, start=1):
        if i <= cur:
            continue
        name = fn.__name__
        try:
            with _db() as conn:
                fn(conn)
                _set_db_version(conn, i)
                conn.commit()
            print(f"[db] ✓ migration v{i} ({name})")
        except Exception as e:
            print(f"[db] ✗ migration v{i} ({name}) FAILED: {e}")
            print(f"[db] startup halted to preserve data integrity")
            raise


def _migrate_v1(conn) -> None:
    """Create server_state. Seed the keys we'll write to from boot:
    server_start_time (first-ever boot, never overwritten) and
    total_uptime_seconds (incremented every 60s while the loop runs)."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS server_state (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)
    now = str(int(time.time()))
    conn.execute(
        "INSERT OR IGNORE INTO server_state (key, value) VALUES ('server_start_time', ?)",
        (now,))
    conn.execute(
        "INSERT OR IGNORE INTO server_state (key, value) VALUES ('total_uptime_seconds', '0')")


def _migrate_v2(conn) -> None:
    """tile_overrides.json → tile_overrides table.
    The table already exists (CREATE IF NOT EXISTS in init_db). Add the
    updated_at column, bulk-load the JSON, then rename the file to .bak."""
    try:
        conn.execute("ALTER TABLE tile_overrides ADD COLUMN updated_at REAL DEFAULT 0")
    except Exception:
        pass   # column already exists from a previous attempted migration
    f = TILE_OVERRIDES_FILE
    if not f.exists():
        return   # nothing to migrate — fresh server
    try:
        data = json.loads(f.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"[migration v2] couldn't parse {f.name}: {e}")
        return
    if not isinstance(data, dict):
        return
    now = time.time()
    inserted = 0
    for key, biome in data.items():
        # key format is "tx,ty" per _tile_key
        try:
            tx_s, ty_s = key.split(",")
            tx = int(tx_s); ty = int(ty_s)
        except (ValueError, AttributeError):
            continue
        conn.execute(
            "INSERT OR REPLACE INTO tile_overrides (tx, ty, biome, updated_at) "
            "VALUES (?, ?, ?, ?)",
            (tx, ty, str(biome), now))
        inserted += 1
    f.replace(_BAK_TILE_OVERRIDES)
    print(f"[migration v2] migrated {inserted} tiles → SQLite, JSON → .bak")


def _migrate_v3(conn) -> None:
    """shop_stock.json → shop_stock table. Same migrate-then-bak pattern."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS shop_stock (
            npc_id       TEXT NOT NULL,
            item_id      TEXT NOT NULL,
            quantity     REAL NOT NULL DEFAULT 0,
            last_restock REAL NOT NULL,
            PRIMARY KEY (npc_id, item_id)
        )
    """)
    f = SHOP_STOCK_FILE
    if not f.exists():
        return
    try:
        data = json.loads(f.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"[migration v3] couldn't parse {f.name}: {e}")
        return
    if not isinstance(data, dict):
        return
    now = time.time()
    inserted = 0
    # shop_stock.json structure: {npc_id: {"current_stock": {item_id: qty, ...}, ...}}
    for npc_id, state in data.items():
        if not isinstance(state, dict):
            continue
        stock = state.get("current_stock", {})
        if not isinstance(stock, dict):
            continue
        for item_id, qty in stock.items():
            try:
                q = float(qty)
            except (TypeError, ValueError):
                continue
            conn.execute(
                "INSERT OR REPLACE INTO shop_stock "
                "(npc_id, item_id, quantity, last_restock) VALUES (?, ?, ?, ?)",
                (str(npc_id), str(item_id), q, now))
            inserted += 1
    f.replace(_BAK_SHOP_STOCK)
    print(f"[migration v3] migrated {inserted} stock rows → SQLite, JSON → .bak")


def _migrate_v4(conn) -> None:
    """players: defeated_bosses + current_boat + boat_sailing.
    All three default to safe empty values; existing rows pick up the
    defaults automatically. Idempotent via try/except per column."""
    for ddl in (
        "ALTER TABLE players ADD COLUMN defeated_bosses TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE players ADD COLUMN current_boat    TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE players ADD COLUMN boat_sailing    INTEGER NOT NULL DEFAULT 0",
    ):
        try:
            conn.execute(ddl)
        except Exception:
            pass


def _migrate_v5(conn) -> None:
    """admins audit trail: promoted_by + promoted_at."""
    for ddl in (
        "ALTER TABLE admins ADD COLUMN promoted_by TEXT",
        "ALTER TABLE admins ADD COLUMN promoted_at REAL",
    ):
        try:
            conn.execute(ddl)
        except Exception:
            pass


def _migrate_v6(conn) -> None:
    """inventory_loss_log — replaces the in-memory ring buffer.
    Capped at 50 rows per player; overflow trim runs on each insert."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS inventory_loss_log (
            id        INTEGER PRIMARY KEY,
            player_id TEXT    NOT NULL,
            item_id   TEXT    NOT NULL,
            item_name TEXT    NOT NULL,
            quantity  INTEGER NOT NULL,
            color     TEXT    NOT NULL DEFAULT '[0.7,0.7,0.7,1.0]',
            reason    TEXT    NOT NULL DEFAULT '',
            restored  INTEGER NOT NULL DEFAULT 0,
            lost_at   REAL    NOT NULL
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_loss_log_player
            ON inventory_loss_log (player_id, lost_at DESC)
    """)


def _migrate_v7(conn) -> None:
    """monster_state — AI position + state persistence. Empty at creation;
    populated lazily as monsters tick or get joined. is_boss decides whether
    hp survives a restart (true for nidhogg etc.; false drops back to max_hp
    every boot, per the partial-persist rule)."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS monster_state (
            monster_id   TEXT PRIMARY KEY,
            monster_type TEXT NOT NULL,
            level        INTEGER NOT NULL,
            hostile      INTEGER NOT NULL,
            is_boss      INTEGER NOT NULL DEFAULT 0,
            state        TEXT    NOT NULL,
            home_x       REAL    NOT NULL,
            home_y       REAL    NOT NULL,
            pos_x        REAL    NOT NULL,
            pos_y        REAL    NOT NULL,
            hp           INTEGER NOT NULL,
            max_hp       INTEGER NOT NULL,
            alive        INTEGER NOT NULL DEFAULT 1,
            last_updated REAL    NOT NULL
        )
    """)


def _migrate_v8(conn) -> None:
    """One-shot .bak cleanup. Runs once and is then a no-op forever (the
    files no longer exist). If the operator wants to restore a backup,
    they need to do it before the boot that triggers this migration —
    that's the one-boot safety net."""
    deleted = 0
    for bak in (_BAK_TILE_OVERRIDES, _BAK_SHOP_STOCK):
        try:
            if bak.exists():
                bak.unlink()
                deleted += 1
        except Exception as e:
            print(f"[migration v8] couldn't delete {bak.name}: {e}")
    if deleted:
        print(f"[migration v8] cleaned up {deleted} backup file(s)")


def _migrate_v9(conn) -> None:
    """quests — per-player quest progress + history. Composite PK includes
    accepted_at so daily/repeatable quests can accumulate completed rows
    across time without UPSERT collisions on (player_id, quest_id). The
    active-status partial index keeps the hot lookup (current active quests
    for a player) cheap regardless of historical row count."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS quests (
            player_id    TEXT NOT NULL,
            quest_id     TEXT NOT NULL,
            status       TEXT NOT NULL,
            progress     TEXT NOT NULL DEFAULT '{}',
            accepted_at  REAL NOT NULL,
            completed_at REAL,
            PRIMARY KEY (player_id, quest_id, accepted_at)
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_quests_active
            ON quests (player_id, status)
            WHERE status = 'active'
    """)


_MIGRATIONS = [
    _migrate_v1, _migrate_v2, _migrate_v3, _migrate_v4,
    _migrate_v5, _migrate_v6, _migrate_v7, _migrate_v8,
    _migrate_v9,
]


def _hash(password: str, salt: str) -> str:
    return hashlib.sha256((password + salt).encode()).hexdigest()


# ── Session / idle stores ──────────────────────────────────────────────────────
sessions:         dict = {}   # ws → {id, username, x, y, last_action_ms}
idle_simulations: dict = {}   # player_id → asyncio.Task
idle_summaries:   dict = {}   # player_id → summary (pending pickup on reconnect)
idle_info:        dict = {}   # player_id → {id, username, x, y}
trades:           dict = {}   # player_id → {partner, offer:list, locked:bool, confirmed:bool}


# ── server_state k/v store (post-consolidation) ──────────────────────────────
# Generic global config + counters. Cached in memory at boot and write-through
# on update so reads are O(1). Initialized by migration v1.

_server_state_cache: dict = {}


def _server_state_get(key: str, default: str = "") -> str:
    if key in _server_state_cache:
        return _server_state_cache[key]
    try:
        with _db() as conn:
            row = conn.execute(
                "SELECT value FROM server_state WHERE key=?", (key,)).fetchone()
        if row is not None:
            v = str(row["value"])
            _server_state_cache[key] = v
            return v
    except Exception:
        pass
    return default


def _server_state_set(key: str, value: str) -> None:
    _server_state_cache[key] = value
    try:
        with _db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO server_state (key, value) VALUES (?, ?)",
                (key, value))
            conn.commit()
    except Exception as e:
        print(f"[server_state] failed to write {key}: {e}")


async def _uptime_counter_loop() -> None:
    """Cumulative real uptime counter. Adds 60 every 60s — drift-tolerant by
    design: if the asyncio scheduler hiccups, we may lose a few seconds, but
    we never DOUBLE-count and we always advance in whole minutes. Survives
    crashes (max ~60s of lost tracking)."""
    while True:
        await asyncio.sleep(60.0)
        try:
            cur = int(_server_state_get("total_uptime_seconds", "0"))
            _server_state_set("total_uptime_seconds", str(cur + 60))
        except Exception as e:
            print(f"[uptime] tick failed: {e}")


def _world_age_days() -> float:
    """Cumulative uptime expressed in days. Used by anything that surfaces a
    world-age display. Off-time is NOT counted — only seconds the loop ran."""
    try:
        return int(_server_state_get("total_uptime_seconds", "0")) / 86400.0
    except Exception:
        return 0.0


# ── Boot recovery routines ──────────────────────────────────────────────────
def _recover_sailing_boats() -> None:
    """Players whose session crashed mid-sail kept boat_sailing=1 in the DB
    with their boat id in current_boat. On reboot, re-grant the boat to
    their inventory and clear the flag. Mirrors _force_dock_to_shore but
    runs server-side without a player session. Color falls back to gray
    via _color_for_item — the boat re-appears in inventory, which is what
    matters; visual polish on the icon recovers as soon as the player
    next picks it up via the normal pickup path."""
    try:
        with _db() as conn:
            rows = conn.execute(
                "SELECT id, username, current_boat, inventory FROM players "
                "WHERE boat_sailing = 1 AND current_boat <> ''"
            ).fetchall()
            recovered = 0
            for r in rows:
                bid = str(r["current_boat"])
                if not bid:
                    continue
                try:
                    inv = json.loads(r["inventory"] or "[]")
                except Exception:
                    inv = []
                bname = bid.replace("_", " ").title()
                _inv_add_qty(inv, bid, bname, 1, _color_for_item(bid))
                conn.execute(
                    "UPDATE players SET inventory=?, current_boat='', "
                    "boat_sailing=0 WHERE id=?",
                    (json.dumps(inv), r["id"]))
                recovered += 1
                print(f"[boot] recovered boat {bid} → {r['username']}")
            if recovered:
                conn.commit()
            if recovered:
                print(f"[boot] {recovered} sailing boat(s) recovered")
    except Exception as e:
        print(f"[boot] boat recovery failed: {e}")


def _purge_orphan_monster_state() -> None:
    """Sweep monster_state rows that have no valid backing entity:
      • IDs starting with 'a:' must have a matching world_entities row.
      • IDs matching the chunk pattern 'm:cx:cy:i' are accepted as valid —
        chunk generation is deterministic, so re-spawn will line up.
      • Anything else (legacy ids, manual SQL injections, etc.) is purged.
    Admin can re-place monsters via the F10 panel afterward."""
    try:
        with _db() as conn:
            rows = conn.execute(
                "SELECT monster_id FROM monster_state").fetchall()
            if not rows:
                return
            admin_ids = {
                str(r["id"]) for r in conn.execute(
                    "SELECT id FROM world_entities WHERE kind='monster'"
                ).fetchall()
            }
            purged = 0
            for r in rows:
                mid = str(r["monster_id"])
                if mid.startswith("a:"):
                    if mid in admin_ids:
                        continue
                    conn.execute(
                        "DELETE FROM monster_state WHERE monster_id=?", (mid,))
                    purged += 1
                    continue
                # Chunk pattern: m:<int>:<int>:<int>
                parts = mid.split(":")
                if len(parts) == 4 and parts[0] == "m" \
                        and parts[1].lstrip("-").isdigit() \
                        and parts[2].lstrip("-").isdigit() \
                        and parts[3].isdigit():
                    continue
                conn.execute(
                    "DELETE FROM monster_state WHERE monster_id=?", (mid,))
                purged += 1
            if purged:
                conn.commit()
                print(f"[boot] purged {purged} orphan monster_state row(s)")
    except Exception as e:
        print(f"[boot] orphan-purge failed: {e}")

# ── Tile overrides (in-memory, periodic flush) ────────────────────────────────
# Live source of truth: a string-keyed dict "tx,ty" → biome name. Loaded from
# tile_overrides.json at startup; mutations set _tile_overrides_dirty and the
# autosave loop writes the file every 30s (or sooner if the admin clicks Save
# Map). Per-tile SQLite writes have been removed — they were the biggest cost
# in the paint hot path.
tile_overrides:        dict = {}
tile_overrides_dirty:  bool = False

# Inventory loss audit log — fully SQLite-backed post-consolidation. See
# inventory_loss_log table + _log_inventory_loss(). Capped at
# _LOSS_LOG_CAP_DB rows per player; admin restore reads the most recent
# unrestored row. Losses now survive restarts (the in-memory ring buffer
# the old comment described is gone).


def _broadcast(msg: dict, exclude_ws=None) -> None:
    data = json.dumps(msg)
    for ws in list(sessions):
        if ws is not exclude_ws:
            asyncio.ensure_future(_safe_send(ws, data))


async def _safe_send(ws, data: str) -> None:
    try:
        await ws.send(data)
    except Exception:
        pass


async def _send(ws, msg: dict) -> None:
    await _safe_send(ws, json.dumps(msg))


# ── Idle simulation helpers ────────────────────────────────────────────────────

def _build_xp_table() -> list:
    # Cumulative XP to reach each level (RuneScape-style). Mirrors GameManager.
    table = [0, 0]
    points = 0.0
    for lv in range(1, 99):
        points += math.floor(lv + 300.0 * (2.0 ** (lv / 7.0)))
        table.append(int(points // 4))
    return table


_XP_TABLE = _build_xp_table()


def _calc_level(xp: int) -> int:
    lv = 1
    while lv < 99 and xp >= _XP_TABLE[lv + 1]:
        lv += 1
    return lv


def _atk_power(melee_xp: int) -> int:
    return max(1, _calc_level(melee_xp) // 3 + 5)


def _def_power(defense_xp: int) -> int:
    return max(0, _calc_level(defense_xp) // 4)


def _has_tool(inventory: list, task_type: str) -> bool:
    keywords = {"woodcut": "axe", "mine": "pickaxe", "fish": "fishing_pole"}
    kw = keywords.get(task_type)
    if kw is None:
        return True
    return any(kw in str(item.get("id", "")) for item in inventory if isinstance(item, dict))


INV_CAP = 28
# Mirrors GameManager.STACKABLE — only ammo / consumables stack into one slot.
_STACKABLE = {"arrows", "feather", "herbs", "stick", "stone", "magic_dust", "rune_essence"}
_CROPS = {"barley", "cabbage", "onion", "wheat", "tomato"}


def _is_stackable(item_id: str) -> bool:
    return (item_id in _STACKABLE or item_id.endswith("_rune")
            or item_id.endswith("_seed") or item_id in _CROPS)


def _inv_add(inventory: list, item_id: str, item_name: str) -> None:
    if _is_stackable(item_id):
        for item in inventory:
            if isinstance(item, dict) and item.get("id") == item_id:
                item["qty"] = int(item.get("qty", 0)) + 1
                return
    if len(inventory) < INV_CAP:
        inventory.append({"id": item_id, "name": item_name, "qty": 1, "color": [0.7, 0.7, 0.7, 1.0]})


def _inv_full(inventory: list) -> bool:
    return len(inventory) >= INV_CAP


def _calc_success_chance(reward: dict, skill_xp: dict) -> float:
    """Scale success chance linearly from success_at_req → success_at_99."""
    at_req    = float(reward.get("success_at_req", 1.0))
    at_99     = float(reward.get("success_at_99",  1.0))
    req_level = int(reward.get("level", 1))
    skill     = str(reward.get("skill", "woodcutting"))
    cur_level = _calc_level(skill_xp.get(skill, 0))
    if req_level >= 99:
        return at_req
    t = max(0.0, min(1.0, (cur_level - req_level) / (99.0 - req_level)))
    return at_req + (at_99 - at_req) * t


def _tool_bonus_for_inv(inventory: list, task_type: str) -> float:
    """Flat success-chance bonus from equipped tool tier."""
    keywords = {"woodcut": "axe", "mine": "pickaxe", "fish": "fishing_pole"}
    kw = keywords.get(task_type, "")
    if not kw:
        return 0.0
    for item in inventory:
        if not isinstance(item, dict):
            continue
        iid = str(item.get("id", ""))
        if kw in iid:
            if "runite"  in iid: return 0.30
            if "adamant" in iid: return 0.25
            if "mithril" in iid: return 0.20
            if "gold"    in iid: return 0.15
            if "iron"    in iid: return 0.10
            return 0.05
    return 0.0


def _idle_save(player_id: str, skill_xp: dict, inventory: list, x: float, y: float) -> None:
    try:
        with _db() as conn:
            conn.execute(
                "UPDATE players SET x=?,y=?,skill_xp=?,inventory=?,last_seen=? WHERE id=?",
                (x, y, json.dumps(skill_xp), json.dumps(inventory), time.time(), player_id)
            )
            conn.commit()
    except Exception as e:
        print(f"[idle_save] {player_id}: {e}")


# ── Idle movement helpers ─────────────────────────────────────────────────────

def _pick_spot(home_x: float, home_y: float, rng: random.Random) -> tuple:
    """Return a random pixel position within WANDER_RADIUS of home."""
    angle = rng.uniform(0.0, 2.0 * math.pi)
    dist  = rng.uniform(64.0, WANDER_RADIUS)
    x = max(32.0, min(WORLD_W - 32.0, home_x + math.cos(angle) * dist))
    y = max(32.0, min(WORLD_H - 32.0, home_y + math.sin(angle) * dist))
    return x, y


async def _idle_walk(player_id: str, px: float, py: float,
                     dest_x: float, dest_y: float) -> tuple:
    """Walk the idle character from (px,py) to (dest,dest).
    Broadcasts idle_move and updates idle_info every IDLE_MOVE_TICK seconds.
    Returns the final (x, y).  Fully cancellable."""
    dx   = dest_x - px
    dy   = dest_y - py
    dist = math.sqrt(dx * dx + dy * dy)
    if dist < 2.0:
        return px, py

    travel   = dist / IDLE_SPEED
    steps    = max(1, int(travel / IDLE_MOVE_TICK))
    dt       = travel / steps

    for i in range(steps):
        t  = (i + 1) / steps
        cx = px + dx * t
        cy = py + dy * t
        _broadcast({"type": "idle_move", "id": player_id, "x": cx, "y": cy})
        if player_id in idle_info:
            idle_info[player_id]["x"] = cx
            idle_info[player_id]["y"] = cy
        await asyncio.sleep(dt)

    return dest_x, dest_y


# ── Idle simulation coroutine ──────────────────────────────────────────────────

async def _idle_simulation(player_id: str, username: str,
                            start_x: float, start_y: float) -> None:
    start_time = time.time()
    summary = {
        "elapsed_seconds": 0,
        "xp_gained":       {},
        "items_gained":    {},
        "deaths":          0,
        "stopped_reason":  "completed",
    }
    skill_xp  = {}
    inventory = []
    px, py    = start_x, start_y
    rng       = random.Random()   # fresh RNG per session

    try:
        with _db() as conn:
            row = conn.execute("SELECT * FROM players WHERE id=?", (player_id,)).fetchone()
        if not row:
            return

        skill_xp   = json.loads(row["skill_xp"]  or "{}")
        inventory  = json.loads(row["inventory"]  or "[]")
        task_queue = json.loads(row["task_queue"] or "[]")
        current_hp = _calc_level(skill_xp.get("vitality", 1154)) * 10

        if not task_queue:
            return

        task_idx   = 0
        save_ticks = 0

        while task_idx < len(task_queue):
            if time.time() - start_time >= MAX_IDLE_SECONDS:
                summary["stopped_reason"] = "24h_limit"
                break

            task      = task_queue[task_idx]
            ttype     = str(task.get("type",      ""))
            target    = str(task.get("target",    ""))
            condition = str(task.get("condition", "forever"))
            cond_val  = float(task.get("condition_value", 0))

            reward = TASK_REWARDS.get((ttype, target))
            if not reward:
                task_idx += 1
                continue
            if _calc_level(skill_xp.get(reward["skill"], 0)) < reward.get("level", 1):
                task_idx += 1
                continue
            # No tool check — idle bot always attempts the task

            task_start    = time.time()
            condition_met = False
            died          = False

            while not condition_met:
                if time.time() - start_time >= MAX_IDLE_SECONDS:
                    summary["stopped_reason"] = "24h_limit"
                    condition_met = True
                    break

                # Pre-action condition check
                if condition == "hours" and (time.time() - task_start) >= cond_val * 3600:
                    condition_met = True; break
                if condition == "level" and _calc_level(skill_xp.get(reward["skill"], 0)) >= int(cond_val):
                    condition_met = True; break
                if condition == "inventory_full" and _inv_full(inventory):
                    summary["stopped_reason"] = "inventory_full"
                    condition_met = True; break

                # ── Walk to a resource spot ──────────────────────────────────
                dest_x, dest_y = _pick_spot(start_x, start_y, rng)
                px, py = await _idle_walk(player_id, px, py, dest_x, dest_y)

                # ── Combat ──────────────────────────────────────────────────
                if ttype == "combat":
                    atk    = _atk_power(skill_xp.get("melee",   0))
                    defp   = _def_power(skill_xp.get("defense", 0))
                    mob_hp = reward["monster_hp"]
                    swing  = reward["swing_time"] * 1.25  # idle is 25% slower

                    while mob_hp > 0 and current_hp > 0:
                        await asyncio.sleep(swing)
                        if time.time() - start_time >= MAX_IDLE_SECONDS:
                            break
                        mob_hp -= atk
                        if mob_hp > 0:
                            current_hp -= max(0, reward["monster_atk"] - defp)

                    if current_hp <= 0:
                        summary["deaths"] += 1
                        current_hp = _calc_level(skill_xp.get("vitality", 1154)) * 10
                        # Walk back to Bjorn's Landing spawn
                        px, py = await _idle_walk(player_id, px, py, 7823.0, 4488.0)
                        # Reset home to spawn so wander doesn't go off-map
                        start_x, start_y = 7823.0, 4488.0
                        summary["stopped_reason"] = "death"
                        condition_met = True
                        died          = True
                    else:
                        xp = int(reward["xp_kill"] * IDLE_EFFICIENCY)
                        for s in ("melee", "defense", "vitality"):
                            share = xp // 3
                            skill_xp[s] = skill_xp.get(s, 0) + share
                            summary["xp_gained"][s] = summary["xp_gained"].get(s, 0) + share
                        _inv_add(inventory, reward["item_id"], reward["item_name"])
                        summary["items_gained"][reward["item_id"]] = (
                            summary["items_gained"].get(reward["item_id"], 0) + 1)

                # ── Gathering ───────────────────────────────────────────────
                else:
                    # One resource = depleting a node (avg swings to a success, each
                    # 25% slower than live) + the node respawning before the next.
                    swing   = reward["swing_time"] * 1.25
                    chance  = min(1.0, _calc_success_chance(reward, skill_xp)
                                       + _tool_bonus_for_inv(inventory, ttype))
                    period  = swing / max(0.05, chance) + IDLE_GATHER_RESPAWN
                    slept = 0.0
                    while slept < period:
                        step = min(1.0, period - slept)
                        await asyncio.sleep(step)
                        slept += step
                        if time.time() - start_time >= MAX_IDLE_SECONDS:
                            summary["stopped_reason"] = "24h_limit"
                            condition_met = True
                            break
                    if not condition_met:
                        xp_gain = int(reward["xp"] * IDLE_EFFICIENCY)
                        skill   = reward["skill"]
                        skill_xp[skill] = skill_xp.get(skill, 0) + xp_gain
                        summary["xp_gained"][skill] = summary["xp_gained"].get(skill, 0) + xp_gain
                        _inv_add(inventory, reward["item_id"], reward["item_name"])
                        summary["items_gained"][reward["item_id"]] = (
                            summary["items_gained"].get(reward["item_id"], 0) + 1)

                save_ticks += 1
                if save_ticks % 20 == 0:
                    _idle_save(player_id, skill_xp, inventory, px, py)

                # Post-action condition check
                if condition == "hours" and (time.time() - task_start) >= cond_val * 3600:
                    condition_met = True
                elif condition == "level" and _calc_level(skill_xp.get(reward["skill"], 0)) >= int(cond_val):
                    condition_met = True
                elif condition == "inventory_full" and _inv_full(inventory):
                    summary["stopped_reason"] = "inventory_full"
                    condition_met = True

            if died:
                break
            task_idx += 1

    except asyncio.CancelledError:
        pass
    except Exception as e:
        print(f"[idle] error for {username}: {e}")
    finally:
        summary["elapsed_seconds"] = time.time() - start_time
        _idle_save(player_id, skill_xp, inventory, px, py)
        idle_simulations.pop(player_id, None)
        idle_info.pop(player_id, None)
        idle_summaries[player_id] = summary
        print(f"[idle] {username}  {summary['elapsed_seconds']/3600:.1f}h  "
              f"xp={summary['xp_gained']}  deaths={summary['deaths']}")


# ── Handlers ───────────────────────────────────────────────────────────────────

async def _handle_register(ws, msg: dict) -> None:
    username = str(msg.get("username", "")).strip()
    password = str(msg.get("password", ""))
    if len(username) < 3 or len(username) > 20:
        await _send(ws, {"type": "register_fail", "reason": "Username must be 3–20 characters."})
        return
    if not username.replace("_", "").isalnum():
        await _send(ws, {"type": "register_fail", "reason": "Letters, numbers and underscores only."})
        return
    if profanity.contains_profanity(username):
        await _send(ws, {"type": "register_fail", "reason": "Name not allowed."})
        return
    if len(password) < 4:
        await _send(ws, {"type": "register_fail", "reason": "Password must be at least 4 characters."})
        return
    with _db() as conn:
        if conn.execute("SELECT 1 FROM players WHERE username=?", (username,)).fetchone():
            await _send(ws, {"type": "register_fail", "reason": "Username already taken."})
            return
        salt = secrets.token_hex(16)
        pid  = secrets.token_hex(16)
        # Explicit x/y on insert — the table's column DEFAULT only applies to
        # fresh databases, and `CREATE TABLE IF NOT EXISTS` never updates an
        # existing table's defaults. Passing the spawn position here means
        # every NEW account lands at Bjorn's Landing regardless of whether
        # the operator started from a fresh DB or migrated an old one.
        conn.execute(
            "INSERT INTO players (id,username,password_hash,salt,x,y,skill_xp,created_at,last_seen) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (pid, username, _hash(password, salt), salt,
             7823.0, 4488.0,
             json.dumps(DEFAULT_SKILL_XP), time.time(), time.time())
        )
        conn.commit()
    await _send(ws, {"type": "register_ok", "username": username})
    print(f"[register] {username}")


async def _handle_login(ws, msg: dict) -> None:
    username = str(msg.get("username", "")).strip()
    password = str(msg.get("password", ""))
    with _db() as conn:
        row = conn.execute("SELECT * FROM players WHERE username=?", (username,)).fetchone()
    if not row or _hash(password, row["salt"]) != row["password_hash"]:
        await _send(ws, {"type": "login_fail", "reason": "Invalid username or password."})
        return

    player_id = row["id"]

    # Stop idle simulation if running
    if player_id in idle_simulations:
        idle_simulations[player_id].cancel()
        await asyncio.sleep(0.1)

    # Kick a duplicate session on a DIFFERENT connection. Crucially skip the
    # current ws: clicking Login again on the same connection (common while
    # waiting for the green "connected" dot) must NOT close our own socket.
    for ews, s in list(sessions.items()):
        if s["id"] == player_id and ews is not ws:
            await _send(ews, {"type": "kicked", "reason": "Logged in from another location."})
            await ews.close()
            sessions.pop(ews, None)
            break

    appearance = json.loads((row["appearance"] if "appearance" in row.keys() else None) or "{}")
    equipment  = json.loads((row["equipment"]  if "equipment"  in row.keys() else None) or "{}")

    # Phase 6 — interior state from DB. Empty interior_id = exterior. When
    # non-empty, the active position is interior_x/y; exterior x/y stays the
    # return point.
    cur_interior_id = ""
    cur_interior_x  = 0.0
    cur_interior_y  = 0.0
    try:
        cur_interior_id = str(row["interior_id"] or "")
        cur_interior_x  = float(row["interior_x"] or 0.0)
        cur_interior_y  = float(row["interior_y"] or 0.0)
    except (IndexError, KeyError, TypeError):
        pass
    sessions[ws] = {
        "id":             player_id,
        "username":       row["username"],
        "x":              float(row["x"]),
        "y":              float(row["y"]),
        "appearance":     appearance,
        "equipment":      equipment,
        "last_action_ms": 0,
        "interior_id":    cur_interior_id,
        "interior_x":     cur_interior_x,
        "interior_y":     cur_interior_y,
    }
    with _db() as conn:
        conn.execute("UPDATE players SET last_seen=? WHERE id=?", (time.time(), player_id))
        conn.commit()

    pending_summary = idle_summaries.pop(player_id, None)
    task_queue      = json.loads(row["task_queue"] or "[]")

    player_data = {
        "id":           player_id,
        "username":     row["username"],
        "x":            float(row["x"]),
        "y":            float(row["y"]),
        "skill_xp":     json.loads(row["skill_xp"]  or "{}"),
        "inventory":    json.loads(row["inventory"]  or "[]"),
        "bank":         json.loads(row["bank"]       or "[]"),
        "gold":         int(row["gold"] or 0),
        "appearance":   appearance,
        "equipment":    equipment,
        "task_queue":   task_queue,
        "idle_summary": pending_summary,
        # Multi-admin: '', 'admin', or 'owner'. Client uses this to gate F10
        # panel access and the /promote /demote chat commands.
        "admin_rank":   _admin_rank(row["username"]),
        # Full quest snapshot — active rows + completed_ids + completion counts.
        # Client never assumes quest state; this is the only source on login.
        "quest_state":  _quest_state_snapshot_safe(player_id),
    }

    await _send(ws, {"type": "login_ok", "player_data": player_data})

    # Send currently online players
    for ows, s in sessions.items():
        if ows is not ws:
            await _send(ws, {"type": "player_join",
                             "id": s["id"], "username": s["username"],
                             "x": s["x"],   "y": s["y"],
                             "appearance": s.get("appearance", {}),
                             "equipment":  s.get("equipment", {})})

    # Send currently idle players (translucent ghosts)
    for pid, info in idle_info.items():
        await _send(ws, {"type": "player_join",
                         "id": info["id"], "username": info["username"],
                         "x": info["x"],   "y": info["y"], "idle": True})

    # Remove any idle ghost of this player from everyone else
    _broadcast({"type": "player_leave", "id": player_id}, exclude_ws=ws)

    # Announce this player to everyone else
    _broadcast({"type": "player_join",
                "id": player_id, "username": row["username"],
                "x": float(row["x"]), "y": float(row["y"]),
                "appearance": appearance, "equipment": equipment}, exclude_ws=ws)

    # Friends: send this player's list and refresh online friends' lists
    await _send_friends_list(ws, player_id)
    await _notify_friends_presence(player_id)

    # Clan: send this player's clan and refresh clanmates' rosters (online dots)
    await _send_clan_info(ws, player_id)
    with _db() as conn:
        _login_cid = _clan_id_for_player(conn, player_id)
    if _login_cid is not None:
        await _broadcast_clan_info(_login_cid)

    # Admin-placed persistent world entities (resources/monsters/NPCs).
    await _send(ws, {"type": "world_entities", "entities": _load_world_entities()})
    # Admin-painted terrain overrides.
    await _send(ws, {"type": "tile_overrides", "overrides": _load_tile_overrides()})
    # Admin edits (deletions / moves) to pre-existing entities.
    await _send(ws, {"type": "entity_edits", "edits": _load_entity_edits()})

    print(f"[login] {username}  ({len(sessions)} online)")


async def _handle_move(ws, session: dict, msg: dict) -> None:
    x = msg.get("x", session["x"])
    y = msg.get("y", session["y"])
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        return
    session["x"] = max(0.0, min(WORLD_W, float(x)))
    session["y"] = max(0.0, min(WORLD_H, float(y)))
    session["boat"] = str(msg.get("boat", ""))
    _broadcast({"type": "player_move",
                "id": session["id"], "x": session["x"], "y": session["y"],
                "boat": session["boat"]}, exclude_ws=ws)


async def _handle_skill_action(ws, session: dict, msg: dict) -> None:
    now_ms = int(time.time() * 1000)
    if now_ms - session["last_action_ms"] < ACTION_RATE_LIMIT_MS:
        return
    session["last_action_ms"] = now_ms
    node_x      = float(msg.get("node_x", 0))
    node_y      = float(msg.get("node_y", 0))
    skill       = str(msg.get("skill", ""))
    required_lv = int(msg.get("required_level", 1))
    dx = session["x"] - node_x
    dy = session["y"] - node_y
    if dx * dx + dy * dy > MAX_DIST_FOR_ACTION ** 2:
        await _send(ws, {"type": "skill_result", "ok": False, "reason": "You are too far away."})
        return
    with _db() as conn:
        row = conn.execute("SELECT skill_xp FROM players WHERE id=?", (session["id"],)).fetchone()
    xp_data    = json.loads(row["skill_xp"] or "{}") if row else {}
    current_lv = _calc_level(xp_data.get(skill, 0))
    if current_lv < required_lv:
        await _send(ws, {"type": "skill_result", "ok": False,
                         "reason": f"You need level {required_lv} {skill}."})
        return
    await _send(ws, {"type": "skill_result", "ok": True,
                     "action":    msg.get("action",    ""),
                     "node_type": msg.get("node_type", "")})


async def _handle_save(session: dict, msg: dict) -> None:
    try:
        new_inv = msg.get("inventory", [])
        if isinstance(new_inv, list):
            prev_inv = session.get("inventory", []) or []
            # New equipment (if the client sent it) AND the previous
            # equipment snapshot. The loss detector compares the union of
            # inventory + equipment so that moving an item into a slot
            # doesn't look like a loss. _handle_set_appearance may have
            # already mutated session["equipment"] before this save runs;
            # that's fine because we want to compare against the player's
            # current snapshot, not the wire-time one.
            prev_eq = session.get("equipment", {}) or {}
            raw_eq = msg.get("equipment", None)
            new_eq = raw_eq if isinstance(raw_eq, dict) else prev_eq
            # Audit log: any item whose total qty decreased since the last
            # save we observed is recorded so /restore can re-grant it. The
            # admin sees a list of recent losses and decides which to revert.
            _detect_inventory_losses(session, prev_inv, new_inv,
                                     prev_eq, new_eq)
            session["inventory"] = new_inv
        if "equipment" in msg and isinstance(msg["equipment"], dict):
            session["equipment"] = msg["equipment"]
        with _db() as conn:
            conn.execute(
                "UPDATE players SET x=?,y=?,skill_xp=?,inventory=?,bank=?,equipment=?,last_seen=? WHERE id=?",
                (session["x"], session["y"],
                 json.dumps(msg.get("skill_xp",  {})),
                 json.dumps(new_inv),
                 json.dumps(msg.get("bank",      [])),
                 json.dumps(session.get("equipment", {})),
                 time.time(), session["id"])
            )
            conn.commit()
    except Exception as e:
        print(f"[save] error for {session['username']}: {e}")


async def _handle_set_appearance(ws, session: dict, msg: dict) -> None:
    appr = msg.get("appearance", {})
    equip = msg.get("equipment", None)
    if not isinstance(appr, dict):
        return
    session["appearance"] = appr
    if isinstance(equip, dict):
        session["equipment"] = equip
    try:
        with _db() as conn:
            conn.execute("UPDATE players SET appearance=?, equipment=? WHERE id=?",
                         (json.dumps(appr), json.dumps(session.get("equipment", {})),
                          session["id"]))
            conn.commit()
    except Exception as e:
        print(f"[appearance] error for {session['username']}: {e}")
    # Tell everyone else to re-render this player
    _broadcast({"type": "player_appearance", "id": session["id"],
                "appearance": appr, "equipment": session.get("equipment", {})},
               exclude_ws=ws)


async def _handle_lookup_player(ws, msg: dict) -> None:
    target = str(msg.get("username", "")).strip()
    if not target:
        return
    with _db() as conn:
        row = conn.execute(
            "SELECT username, skill_xp FROM players WHERE username=?", (target,)
        ).fetchone()
    if not row:
        await _send(ws, {"type": "player_lookup", "username": target,
                         "found": False, "skill_xp": {}})
        return
    skill_xp = json.loads(row["skill_xp"] or "{}")
    await _send(ws, {"type": "player_lookup", "username": row["username"],
                     "found": True, "skill_xp": skill_xp})


async def _handle_set_task_queue(session: dict, msg: dict) -> None:
    queue = msg.get("queue", [])
    if not isinstance(queue, list):
        return
    try:
        with _db() as conn:
            conn.execute("UPDATE players SET task_queue=? WHERE id=?",
                         (json.dumps(queue), session["id"]))
            conn.commit()
    except Exception as e:
        print(f"[task_queue] {session['username']}: {e}")


# ── Auction House handlers ────────────────────────────────────────────────────

def _all_listings() -> list:
    with _db() as conn:
        rows = conn.execute(
            "SELECT id, seller_name, item_id, item_name, qty, price_each "
            "FROM ah_listings ORDER BY listed_at DESC LIMIT 200"
        ).fetchall()
    return [
        {"id": r["id"], "seller_name": r["seller_name"], "item_id": r["item_id"],
         "item_name": r["item_name"], "qty": r["qty"], "price_each": r["price_each"]}
        for r in rows
    ]


def _broadcast_ah_listings() -> None:
    _broadcast({"type": "ah_listings", "listings": _all_listings()})


async def _handle_ah_list(ws, session: dict, msg: dict) -> None:
    item_id    = str(msg.get("item_id",    "")).strip()
    item_name  = str(msg.get("item_name",  "")).strip()
    qty        = int(msg.get("qty",        0))
    price_each = int(msg.get("price_each", 0))

    if not item_id or qty <= 0 or price_each <= 0:
        await _send(ws, {"type": "ah_list_result", "ok": False,
                         "reason": "Invalid listing parameters."})
        return

    with _db() as conn:
        row = conn.execute("SELECT inventory FROM players WHERE id=?",
                           (session["id"],)).fetchone()
        if not row:
            await _send(ws, {"type": "ah_list_result", "ok": False,
                             "reason": "Player not found."})
            return

        inventory = json.loads(row["inventory"] or "[]")

        removed = False
        for item in inventory:
            if isinstance(item, dict) and item.get("id") == item_id:
                have = int(item.get("qty", 0))
                if have < qty:
                    await _send(ws, {"type": "ah_list_result", "ok": False,
                                     "reason": f"You only have {have}x {item_name}."})
                    return
                item["qty"] = have - qty
                if item["qty"] <= 0:
                    inventory.remove(item)
                removed = True
                break

        if not removed:
            await _send(ws, {"type": "ah_list_result", "ok": False,
                             "reason": "Item not found in your inventory."})
            return

        listing_id = secrets.token_hex(8)
        conn.execute(
            "INSERT INTO ah_listings "
            "(id, seller_id, seller_name, item_id, item_name, qty, price_each, listed_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (listing_id, session["id"], session["username"],
             item_id, item_name, qty, price_each, time.time())
        )
        conn.execute("UPDATE players SET inventory=? WHERE id=?",
                     (json.dumps(inventory), session["id"]))
        conn.commit()

    await _send(ws, {"type": "ah_list_result", "ok": True,
                     "inventory": inventory})
    _broadcast_ah_listings()
    print(f"[ah_list] {session['username']} listed {qty}x {item_id} @ {price_each}g")


async def _handle_ah_browse(ws, msg: dict) -> None:
    search = str(msg.get("search", "")).strip().lower()
    with _db() as conn:
        rows = conn.execute(
            "SELECT id, seller_name, item_id, item_name, qty, price_each "
            "FROM ah_listings ORDER BY listed_at DESC LIMIT 200"
        ).fetchall()

    listings = []
    for row in rows:
        if search and search not in str(row["item_name"]).lower():
            continue
        listings.append({
            "id":          row["id"],
            "seller_name": row["seller_name"],
            "item_id":     row["item_id"],
            "item_name":   row["item_name"],
            "qty":         row["qty"],
            "price_each":  row["price_each"],
        })

    await _send(ws, {"type": "ah_listings", "listings": listings})


async def _handle_ah_my_listings(ws, session: dict) -> None:
    with _db() as conn:
        rows = conn.execute(
            "SELECT id, item_id, item_name, qty, price_each "
            "FROM ah_listings WHERE seller_id=? ORDER BY listed_at DESC",
            (session["id"],)
        ).fetchall()

    listings = [
        {"id": row["id"], "item_id": row["item_id"], "item_name": row["item_name"],
         "qty": row["qty"], "price_each": row["price_each"]}
        for row in rows
    ]
    await _send(ws, {"type": "ah_my_listings", "listings": listings})


async def _handle_ah_buy(ws, session: dict, msg: dict) -> None:
    listing_id = str(msg.get("listing_id", ""))
    qty        = max(1, int(msg.get("qty", 1)))

    with _db() as conn:
        listing = conn.execute(
            "SELECT * FROM ah_listings WHERE id=?", (listing_id,)
        ).fetchone()

        if not listing:
            await _send(ws, {"type": "ah_purchase_result", "ok": False,
                             "reason": "Listing no longer exists."})
            return

        if listing["seller_id"] == session["id"]:
            await _send(ws, {"type": "ah_purchase_result", "ok": False,
                             "reason": "You cannot buy your own listing."})
            return

        qty        = min(qty, listing["qty"])
        total_cost = qty * listing["price_each"]

        buyer_row = conn.execute(
            "SELECT gold, inventory FROM players WHERE id=?", (session["id"],)
        ).fetchone()
        buyer_gold = int(buyer_row["gold"] or 0) if buyer_row else 0

        if buyer_gold < total_cost:
            await _send(ws, {"type": "ah_purchase_result", "ok": False,
                             "reason": f"Not enough gold. Need {total_cost}g, have {buyer_gold}g."})
            return

        buyer_inv = json.loads(buyer_row["inventory"] or "[]") if buyer_row else []
        _inv_add_qty(buyer_inv, listing["item_id"], listing["item_name"], qty,
                     _color_for_item(listing["item_id"]))

        new_buyer_gold = buyer_gold - total_cost
        conn.execute("UPDATE players SET gold=?, inventory=? WHERE id=?",
                     (new_buyer_gold, json.dumps(buyer_inv), session["id"]))

        seller_row = conn.execute(
            "SELECT gold FROM players WHERE id=?", (listing["seller_id"],)
        ).fetchone()
        seller_gold = int(seller_row["gold"] or 0) if seller_row else 0
        conn.execute("UPDATE players SET gold=? WHERE id=?",
                     (seller_gold + total_cost, listing["seller_id"]))

        new_qty = listing["qty"] - qty
        if new_qty <= 0:
            conn.execute("DELETE FROM ah_listings WHERE id=?", (listing_id,))
        else:
            conn.execute("UPDATE ah_listings SET qty=? WHERE id=?",
                         (new_qty, listing_id))
        conn.commit()

    await _send(ws, {"type": "ah_purchase_result", "ok": True,
                     "gold": new_buyer_gold, "inventory": buyer_inv, "reason": ""})
    _broadcast_ah_listings()

    # Notify seller if online
    for ows, s in sessions.items():
        if s["id"] == listing["seller_id"]:
            await _safe_send(ows, json.dumps({
                "type": "chat", "username": "Auction House",
                "text": f"Your {listing['item_name']} sold for {total_cost}g!"
            }))
            break

    print(f"[ah_buy] {session['username']} bought {qty}x {listing['item_id']} "
          f"from {listing['seller_name']} for {total_cost}g")


async def _handle_ah_cancel(ws, session: dict, msg: dict) -> None:
    listing_id = str(msg.get("listing_id", ""))

    with _db() as conn:
        listing = conn.execute(
            "SELECT * FROM ah_listings WHERE id=? AND seller_id=?",
            (listing_id, session["id"])
        ).fetchone()

        if not listing:
            await _send(ws, {"type": "ah_cancel_result", "ok": False,
                             "reason": "Listing not found or not yours."})
            return

        seller_row = conn.execute(
            "SELECT inventory FROM players WHERE id=?", (session["id"],)
        ).fetchone()
        seller_inv = json.loads(seller_row["inventory"] or "[]") if seller_row else []
        _inv_add_qty(seller_inv, listing["item_id"], listing["item_name"], listing["qty"],
                     _color_for_item(listing["item_id"]))

        conn.execute("DELETE FROM ah_listings WHERE id=?", (listing_id,))
        conn.execute("UPDATE players SET inventory=? WHERE id=?",
                     (json.dumps(seller_inv), session["id"]))
        conn.commit()

    await _send(ws, {"type": "ah_cancel_result", "ok": True,
                     "inventory": seller_inv})
    _broadcast_ah_listings()
    print(f"[ah_cancel] {session['username']} cancelled {listing['item_id']} listing")


# ── Trading handlers ──────────────────────────────────────────────────────────

def _ws_for_player(player_id: str):
    for ws, s in sessions.items():
        if s["id"] == player_id:
            return ws
    return None


def _session_by_username(username: str):
    uname = username.lower()
    for ws, s in sessions.items():
        if s["username"].lower() == uname:
            return ws, s
    return None, None


async def _end_trade(player_id: str, reason: str) -> None:
    """Tear down a trade for both participants and notify them."""
    t = trades.pop(player_id, None)
    if not t:
        return
    partner_id = t["partner"]
    trades.pop(partner_id, None)
    for pid in (player_id, partner_id):
        pws = _ws_for_player(pid)
        if pws is not None:
            await _send(pws, {"type": "trade_cancel", "reason": reason})


async def _sync_trade_offers(a_id: str, b_id: str) -> None:
    """Push each side's current offers + lock state to both clients."""
    ta = trades.get(a_id)
    tb = trades.get(b_id)
    if not ta or not tb:
        return
    aws = _ws_for_player(a_id)
    bws = _ws_for_player(b_id)
    if aws is not None:
        await _send(aws, {"type": "trade_offer",
                          "their_items": tb["offer"], "your_items": ta["offer"],
                          "their_gold": tb["gold"],   "your_gold": ta["gold"]})
        await _send(aws, {"type": "trade_status",
                          "their_lock": tb["locked"], "your_lock": ta["locked"]})
    if bws is not None:
        await _send(bws, {"type": "trade_offer",
                          "their_items": ta["offer"], "your_items": tb["offer"],
                          "their_gold": ta["gold"],   "your_gold": tb["gold"]})
        await _send(bws, {"type": "trade_status",
                          "their_lock": ta["locked"], "your_lock": tb["locked"]})


async def _handle_trade_request(ws, session: dict, msg: dict) -> None:
    target = str(msg.get("to", "")).strip()
    tws, tsess = _session_by_username(target)
    if tws is None:
        await _send(ws, {"type": "trade_cancel", "reason": f"{target} is not online."})
        return
    if tsess["id"] == session["id"]:
        return
    if session["id"] in trades or tsess["id"] in trades:
        await _send(ws, {"type": "trade_cancel",
                         "reason": "One of you is already in a trade."})
        return
    await _send(tws, {"type": "trade_request", "from": session["username"]})


async def _handle_trade_accept(ws, session: dict, msg: dict) -> None:
    requester = str(msg.get("from", "")).strip()
    aws, asess = _session_by_username(requester)
    if aws is None:
        await _send(ws, {"type": "trade_cancel",
                         "reason": f"{requester} is no longer online."})
        return
    if asess["id"] in trades or session["id"] in trades:
        await _send(ws, {"type": "trade_cancel", "reason": "Trade could not start."})
        return
    trades[asess["id"]]   = {"partner": session["id"], "offer": [], "gold": 0, "locked": False, "confirmed": False}
    trades[session["id"]] = {"partner": asess["id"],   "offer": [], "gold": 0, "locked": False, "confirmed": False}
    # Empty offer opens the trade window on both clients.
    await _sync_trade_offers(asess["id"], session["id"])
    print(f"[trade] {asess['username']} <-> {session['username']} started")


async def _handle_trade_offer(ws, session: dict, msg: dict) -> None:
    t = trades.get(session["id"])
    if not t:
        return
    items = msg.get("items", [])
    if not isinstance(items, list):
        items = []
    # Changing an offer clears both locks (OSRS behaviour).
    t["offer"]    = items
    t["gold"]     = max(0, int(msg.get("gold", 0)))
    t["locked"]   = False
    t["confirmed"] = False
    partner = trades.get(t["partner"])
    if partner:
        partner["locked"]    = False
        partner["confirmed"] = False
    await _sync_trade_offers(session["id"], t["partner"])


async def _handle_trade_lock(ws, session: dict) -> None:
    t = trades.get(session["id"])
    if not t:
        return
    t["locked"] = True
    await _sync_trade_offers(session["id"], t["partner"])


async def _handle_trade_confirm(ws, session: dict) -> None:
    t = trades.get(session["id"])
    if not t:
        return
    partner_id = t["partner"]
    partner = trades.get(partner_id)
    if not partner:
        await _end_trade(session["id"], "Partner left the trade.")
        return
    if not (t["locked"] and partner["locked"]):
        return
    t["confirmed"] = True
    if not partner["confirmed"]:
        return  # wait for the other side to confirm

    # ── Both confirmed — validate and execute the swap atomically ───────────────
    a_id, b_id = session["id"], partner_id
    a_offer = t["offer"]
    b_offer = partner["offer"]
    a_gold_offer = max(0, int(t.get("gold", 0)))
    b_gold_offer = max(0, int(partner.get("gold", 0)))
    try:
        with _db() as conn:
            a_row = conn.execute("SELECT inventory, gold FROM players WHERE id=?", (a_id,)).fetchone()
            b_row = conn.execute("SELECT inventory, gold FROM players WHERE id=?", (b_id,)).fetchone()
            a_inv = json.loads(a_row["inventory"] or "[]") if a_row else []
            b_inv = json.loads(b_row["inventory"] or "[]") if b_row else []
            a_gold = int(a_row["gold"] or 0) if a_row else 0
            b_gold = int(b_row["gold"] or 0) if b_row else 0

            if not _inv_has_all(a_inv, a_offer) or not _inv_has_all(b_inv, b_offer):
                await _end_trade(a_id, "Trade failed — items no longer available.")
                return
            if a_gold < a_gold_offer or b_gold < b_gold_offer:
                await _end_trade(a_id, "Trade failed — not enough gold.")
                return

            # Remove offered items from each, add to the other. Color comes
            # from the offer payload when the client included one; falls back
            # to the shop-catalog lookup so the receiving inventory row is
            # never colorless (the 5-arg _inv_add_qty requires a color).
            for it in a_offer:
                _iid = str(it.get("id", ""))
                _inv_remove_qty(a_inv, _iid, int(it.get("qty", 0)))
                _inv_add_qty(b_inv, _iid, str(it.get("name", "")),
                             int(it.get("qty", 0)),
                             it.get("color") or _color_for_item(_iid))
            for it in b_offer:
                _iid = str(it.get("id", ""))
                _inv_remove_qty(b_inv, _iid, int(it.get("qty", 0)))
                _inv_add_qty(a_inv, _iid, str(it.get("name", "")),
                             int(it.get("qty", 0)),
                             it.get("color") or _color_for_item(_iid))

            # Transfer gold.
            a_gold = a_gold - a_gold_offer + b_gold_offer
            b_gold = b_gold - b_gold_offer + a_gold_offer

            conn.execute("UPDATE players SET inventory=?, gold=? WHERE id=?", (json.dumps(a_inv), a_gold, a_id))
            conn.execute("UPDATE players SET inventory=?, gold=? WHERE id=?", (json.dumps(b_inv), b_gold, b_id))
            conn.commit()
    except Exception as e:
        print(f"[trade] error: {e}")
        await _end_trade(a_id, "Trade failed — server error.")
        return

    trades.pop(a_id, None)
    trades.pop(b_id, None)

    aws = _ws_for_player(a_id)
    bws = _ws_for_player(b_id)
    if aws is not None:
        await _send(aws, {"type": "trade_complete", "items": b_offer,
                          "inventory": a_inv, "gold": a_gold})
    if bws is not None:
        await _send(bws, {"type": "trade_complete", "items": a_offer,
                          "inventory": b_inv, "gold": b_gold})
    print(f"[trade] completed {session['username']} <-> {partner.get('partner','?')}")


def _inv_has_all(inventory: list, offer: list) -> bool:
    for it in offer:
        iid = str(it.get("id", ""))
        need = int(it.get("qty", 0))
        have = 0
        for inv_it in inventory:
            if isinstance(inv_it, dict) and inv_it.get("id") == iid:
                have = int(inv_it.get("qty", 0))
                break
        if have < need or need <= 0:
            return False
    return True


def _inv_remove_qty(inventory: list, item_id: str, qty: int) -> None:
    for item in list(inventory):
        if isinstance(item, dict) and item.get("id") == item_id:
            item["qty"] = int(item.get("qty", 0)) - qty
            if item["qty"] <= 0:
                inventory.remove(item)
            return


# ── Friends handlers ──────────────────────────────────────────────────────────

def _is_online(player_id: str) -> bool:
    return any(s["id"] == player_id for s in sessions.values())


def _get_friends(player_id: str) -> list:
    with _db() as conn:
        rows = conn.execute(
            "SELECT p.id AS fid, p.username AS uname FROM friendships f "
            "JOIN players p ON p.id = f.friend_id WHERE f.player_id=? "
            "ORDER BY p.username COLLATE NOCASE", (player_id,)
        ).fetchall()
    return [{"username": r["uname"], "online": _is_online(r["fid"])} for r in rows]


async def _send_friends_list(ws, player_id: str) -> None:
    await _send(ws, {"type": "friends_list", "friends": _get_friends(player_id)})


async def _notify_friends_presence(player_id: str) -> None:
    """Refresh the friends list of every online player who has this player as a friend."""
    with _db() as conn:
        rows = conn.execute(
            "SELECT player_id FROM friendships WHERE friend_id=?", (player_id,)
        ).fetchall()
    for r in rows:
        fid = r["player_id"]
        fws = _ws_for_player(fid)
        if fws is not None:
            await _send(fws, {"type": "friends_list", "friends": _get_friends(fid)})


async def _handle_friend_request(ws, session: dict, msg: dict) -> None:
    target = str(msg.get("target", "")).strip()
    tws, tsess = _session_by_username(target)
    if tws is None:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": f"{target} is not online."})
        return
    if tsess["id"] == session["id"]:
        return
    with _db() as conn:
        existing = conn.execute(
            "SELECT 1 FROM friendships WHERE player_id=? AND friend_id=?",
            (session["id"], tsess["id"])).fetchone()
    if existing:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": f"You are already friends with {target}."})
        return
    await _send(tws, {"type": "friend_request", "from": session["username"]})


async def _handle_friend_accept(ws, session: dict, msg: dict) -> None:
    requester = str(msg.get("from", "")).strip()
    rws, rsess = _session_by_username(requester)
    if rsess is not None:
        req_id = rsess["id"]
    else:
        with _db() as conn:
            row = conn.execute("SELECT id FROM players WHERE username=?", (requester,)).fetchone()
        req_id = row["id"] if row else None
    if req_id is None:
        return
    with _db() as conn:
        conn.execute("INSERT OR IGNORE INTO friendships (player_id, friend_id) VALUES (?,?)",
                     (session["id"], req_id))
        conn.execute("INSERT OR IGNORE INTO friendships (player_id, friend_id) VALUES (?,?)",
                     (req_id, session["id"]))
        conn.commit()
    await _send_friends_list(ws, session["id"])
    if rws is not None:
        await _send_friends_list(rws, req_id)
        await _send(rws, {"type": "chat", "username": "System",
                          "text": f"{session['username']} accepted your friend request."})
    print(f"[friend] {session['username']} <-> {requester} added")


async def _handle_friend_decline(ws, session: dict, msg: dict) -> None:
    requester = str(msg.get("from", "")).strip()
    rws, _ = _session_by_username(requester)
    if rws is not None:
        await _send(rws, {"type": "chat", "username": "System",
                          "text": f"{session['username']} declined your friend request."})


async def _handle_friend_remove(ws, session: dict, msg: dict) -> None:
    target = str(msg.get("target", "")).strip()
    with _db() as conn:
        row = conn.execute("SELECT id FROM players WHERE username=?", (target,)).fetchone()
        tid = row["id"] if row else None
        if tid:
            conn.execute("DELETE FROM friendships WHERE player_id=? AND friend_id=?",
                         (session["id"], tid))
            conn.execute("DELETE FROM friendships WHERE player_id=? AND friend_id=?",
                         (tid, session["id"]))
            conn.commit()
    await _send_friends_list(ws, session["id"])
    if tid:
        tws = _ws_for_player(tid)
        if tws is not None:
            await _send_friends_list(tws, tid)


async def _handle_whisper(ws, session: dict, msg: dict) -> None:
    target = str(msg.get("to", "")).strip()
    text   = str(msg.get("text", "")).strip()[:200]
    if not text:
        return
    text = profanity.censor(text)
    tws, _ = _session_by_username(target)
    if tws is None:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": f"{target} is not online."})
        return
    await _send(tws, {"type": "chat", "username": f"From {session['username']}", "text": text})
    await _send(ws,  {"type": "chat", "username": f"To {target}", "text": text})


# ── Admin handlers (multi-admin: Busterrdust owner + DB-registered admins) ────

def _normalized_admin_name(name: str) -> str:
    """Admin lookup is case-insensitive so /promote BUSTY and /promote busty
    target the same person. Store and compare in lowercase."""
    return str(name or "").strip().lower()


def _bootstrap_owner_admin() -> None:
    """Ensure the hardcoded ADMIN_USERNAME exists in the admins table at rank
    'owner' on every boot. Idempotent — an INSERT OR REPLACE re-asserts the
    rank in case it was ever overwritten by a stray manual edit."""
    with _db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO admins (username, rank) VALUES (?, 'owner')",
            (_normalized_admin_name(ADMIN_USERNAME),))
        conn.commit()


def _admin_rank(username: str) -> str:
    """Return 'owner', 'admin', or '' (no rank) for the given username."""
    if not username:
        return ""
    # Owner is always recognized even before bootstrap finishes (e.g. during
    # the very first connection before the table exists in the running cache).
    if _normalized_admin_name(username) == _normalized_admin_name(ADMIN_USERNAME):
        return "owner"
    with _db() as conn:
        row = conn.execute(
            "SELECT rank FROM admins WHERE username=?",
            (_normalized_admin_name(username),)).fetchone()
    if row is None:
        return ""
    return str(row["rank"])


def _is_admin(session: dict) -> bool:
    """Any rank ('owner' or 'admin') gates into admin-only handlers."""
    return _admin_rank(session.get("username", "")) != ""


def _is_owner(session: dict) -> bool:
    """Owner-only checks (promote/demote)."""
    return _admin_rank(session.get("username", "")) == "owner"


async def _handle_admin_rank_command(ws, session: dict, text: str) -> None:
    """Parses /promote <name> and /demote <name>. Owner-only. The owner row
    is immutable — any /demote targeting Busterrdust is rejected, and a
    /demote targeting a non-admin is a no-op confirmation rather than an
    error so the owner doesn't have to remember exact case."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Only the owner can promote or demote.")
        return
    parts = text.strip().split(maxsplit=1)
    if len(parts) < 2 or not parts[1].strip():
        await _admin_confirm(ws, f"Usage: {parts[0]} <username>")
        return
    cmd = parts[0]
    target_raw = parts[1].strip()
    target = _normalized_admin_name(target_raw)
    if target == _normalized_admin_name(ADMIN_USERNAME):
        await _admin_confirm(ws, "The owner cannot be demoted or re-promoted.")
        return
    if cmd == "/promote":
        with _db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO admins (username, rank) VALUES (?, 'admin')",
                (target,))
            conn.commit()
        await _admin_confirm(ws, f"Promoted {target_raw} to admin.")
        # Notify the target if they're online so the F10 panel unlocks live.
        for tws, tsess in sessions.items():
            if _normalized_admin_name(tsess.get("username", "")) == target:
                await _send(tws, {"type": "admin_rank_changed", "rank": "admin"})
                await _send(tws, {"type": "chat", "username": "Server",
                                  "text": "You have been promoted to admin."})
                break
        print(f"[admin] {session['username']} promoted {target_raw}")
    elif cmd == "/demote":
        with _db() as conn:
            cur = conn.execute(
                "DELETE FROM admins WHERE username=?", (target,))
            conn.commit()
            removed = cur.rowcount > 0
        if removed:
            await _admin_confirm(ws, f"Demoted {target_raw}.")
            for tws, tsess in sessions.items():
                if _normalized_admin_name(tsess.get("username", "")) == target:
                    await _send(tws, {"type": "admin_rank_changed", "rank": ""})
                    await _send(tws, {"type": "chat", "username": "Server",
                                      "text": "Your admin rank has been revoked."})
                    break
            print(f"[admin] {session['username']} demoted {target_raw}")
        else:
            await _admin_confirm(ws, f"{target_raw} was not an admin.")


def _load_world_entities() -> list:
    with _db() as conn:
        rows = conn.execute(
            "SELECT id, kind, subtype, x, y, data FROM world_entities"
        ).fetchall()
    out = []
    for r in rows:
        try:
            data = json.loads(r["data"] or "{}")
        except Exception:
            data = {}
        out.append({"id": r["id"], "kind": r["kind"], "subtype": r["subtype"],
                    "x": float(r["x"]), "y": float(r["y"]), "data": data})
    return out


async def _admin_confirm(ws, text: str) -> None:
    await _send(ws, {"type": "chat", "username": "Admin", "text": text})


async def _handle_admin_place(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    kind    = str(msg.get("kind", "")).strip()
    subtype = str(msg.get("subtype", "")).strip()
    if kind not in ("resource", "monster", "npc") or not subtype:
        await _admin_confirm(ws, "Invalid entity.")
        return
    x = float(msg.get("x", session["x"]))
    y = float(msg.get("y", session["y"]))
    data = msg.get("data", {})
    if not isinstance(data, dict):
        data = {}
    eid = "a:" + secrets.token_hex(8)
    with _db() as conn:
        conn.execute(
            "INSERT INTO world_entities (id, kind, subtype, x, y, data) VALUES (?,?,?,?,?,?)",
            (eid, kind, subtype, x, y, json.dumps(data)))
        conn.commit()
    entity = {"id": eid, "kind": kind, "subtype": subtype, "x": x, "y": y, "data": data}
    _broadcast({"type": "world_entity_add", "entity": entity})
    await _admin_confirm(ws, f"Placed {kind} '{subtype}'.")
    print(f"[admin] {session['username']} placed {kind}:{subtype} at ({x:.0f},{y:.0f})")
    # Stage 1 AI seed for admin-placed monsters. Without this, the monster
    # sits inert in the world until a client triggers monster_join — at
    # which point monster_join's existing-entry branch preserves the AI we
    # seed here (it only refreshes max_hp / xp_reward from the wire). The
    # admin's chosen subtype (monster_type) + data.level drive the AI;
    # attack and max_hp use heuristics until the client engages and sends
    # the real values from Monster.gd._apply_type_stats.
    if kind == "monster":
        monster_type = str(data.get("monster_type", subtype) or subtype)
        level = max(1, int(data.get("level", 1)))
        attack = _heuristic_attack(level)
        max_hp = _heuristic_max_hp(level)
        st = {
            "x": x, "y": y,
            "max_hp": max_hp, "hp": max_hp,
            "alive": True,
            "participants": [], "damage": {},
            "xp_reward": max(1, level * 10),
            "respawn_until": 0.0,
        }
        _seed_monster_ai(st, x, y, monster_type, level, attack)
        monsters_state[eid] = st
        _mark_monster_dirty(eid)
        print(f"[admin_ai] seeded monster {eid} type={monster_type} "
              f"level={level} attack={attack} hostile={st['hostile']} "
              f"home=({x:.0f},{y:.0f})")


def _load_entity_edits() -> list:
    with _db() as conn:
        rows = conn.execute("SELECT id, deleted, x, y FROM entity_edits").fetchall()
    out = []
    for r in rows:
        out.append({"id": r["id"], "deleted": bool(r["deleted"]),
                    "x": (None if r["x"] is None else float(r["x"])),
                    "y": (None if r["y"] is None else float(r["y"]))})
    return out


async def _handle_admin_delete(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    eid = str(msg.get("id", "")).strip()
    if not eid:
        return
    if eid.startswith("a:"):
        # Admin-placed entity — remove from the persistent placement table.
        with _db() as conn:
            conn.execute("DELETE FROM world_entities WHERE id=?", (eid,))
            conn.commit()
        _broadcast({"type": "world_entity_remove", "id": eid})
    else:
        # Pre-existing (procedural/hardcoded) entity — record a deletion edit.
        with _db() as conn:
            conn.execute(
                "INSERT INTO entity_edits (id, deleted) VALUES (?,1) "
                "ON CONFLICT(id) DO UPDATE SET deleted=1", (eid,))
            conn.commit()
        _broadcast({"type": "entity_edit", "id": eid, "deleted": True})
    await _admin_confirm(ws, "Deleted entity.")


async def _handle_admin_move(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    eid = str(msg.get("id", "")).strip()
    if not eid:
        return
    x = float(msg.get("x", 0.0))
    y = float(msg.get("y", 0.0))
    if eid.startswith("a:"):
        with _db() as conn:
            conn.execute("UPDATE world_entities SET x=?, y=? WHERE id=?", (x, y, eid))
            conn.commit()
        _broadcast({"type": "world_entity_move", "id": eid, "x": x, "y": y})
    else:
        with _db() as conn:
            conn.execute(
                "INSERT INTO entity_edits (id, deleted, x, y) VALUES (?,0,?,?) "
                "ON CONFLICT(id) DO UPDATE SET x=excluded.x, y=excluded.y, deleted=0",
                (eid, x, y))
            conn.commit()
        _broadcast({"type": "entity_edit", "id": eid, "x": x, "y": y, "deleted": False})


async def _handle_admin_gold(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    target = str(msg.get("target", "")).strip()
    amount = int(msg.get("amount", 0))
    with _db() as conn:
        row = conn.execute("SELECT id, gold FROM players WHERE username=? COLLATE NOCASE",
                           (target,)).fetchone()
        if not row:
            await _admin_confirm(ws, f"No such player: {target}")
            return
        new_gold = max(0, int(row["gold"] or 0) + amount)
        conn.execute("UPDATE players SET gold=? WHERE id=?", (new_gold, row["id"]))
        conn.commit()
        tid = row["id"]
    # Silently update the target if they're online (no global chat message).
    tws = _ws_for_player(tid)
    if tws is not None:
        await _send(tws, {"type": "gold_set", "gold": new_gold})
    await _admin_confirm(ws, f"Gave {amount}g to {target} (now {new_gold}g).")
    print(f"[admin] {session['username']} /gold {target} {amount}")


# ── Admin item management ────────────────────────────────────────────────────
# Helpers + handlers backing the AdminPanel "Items" tab and the /give /take
# /restore /inv chat commands. All ops gated by _is_admin(). Every action logs
# to the server console as `[admin <iso ts>] <admin_name> ...` for audit.

def _admin_log(session: dict, action: str) -> None:
    """Single-line audit print with iso timestamp + admin name + action."""
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    print(f"[admin {ts}] {session['username']} {action}")


def _color_to_list(c) -> list:
    """Normalize a color value (string '(r,g,b,a)' or list/tuple) → [r,g,b,a]."""
    if isinstance(c, (list, tuple)) and len(c) >= 3:
        out = [float(c[0]), float(c[1]), float(c[2]),
               float(c[3]) if len(c) >= 4 else 1.0]
        return out
    if isinstance(c, str):
        s = c.strip().lstrip("(").rstrip(")")
        parts = [p.strip() for p in s.split(",")]
        try:
            vals = [float(p) for p in parts]
            while len(vals) < 4:
                vals.append(1.0)
            return vals[:4]
        except ValueError:
            pass
    return [0.7, 0.7, 0.7, 1.0]


# Item-id → color lookup, harvested from the shop catalog at module load.
# Sources are the only authoritative server-side color data we have; everything
# else (monster drops, deep-sea fish, runes) falls back to gray. Used by the
# call sites that receive items via inter-player flows (AH, trades, clan bank)
# where the receiving inventory needs a non-None color for the client to render.
_ITEM_COLORS_PY: dict = {}
for _shop in _SHOPS_PY.values():
    for _entry in _shop.get("stock_template", []):
        _iid = _entry.get("id")
        _col = _entry.get("color")
        if _iid and _col and _iid not in _ITEM_COLORS_PY:
            _ITEM_COLORS_PY[_iid] = list(_col)


def _color_for_item(item_id: str) -> list:
    """Look up a stored color for an item_id; gray if unknown.
    Used by AH purchases, trades, and clan-bank transfers — places where the
    server is the source of truth for the inventory line being inserted and
    has no per-item color in the originating payload."""
    return _ITEM_COLORS_PY.get(item_id, [0.7, 0.7, 0.7, 1.0])


def _inv_add_qty(inventory: list, item_id: str, item_name: str,
                 qty: int, color) -> int:
    """Add `qty` of an item to inventory. Stacks onto existing entry for
    stackable ids; otherwise appends a new entry per unit, capped at INV_CAP.
    Returns the number of units actually added (may be < qty if cap hit)."""
    if qty <= 0:
        return 0
    added = 0
    col = _color_to_list(color)
    if _is_stackable(item_id):
        for item in inventory:
            if isinstance(item, dict) and item.get("id") == item_id:
                item["qty"] = int(item.get("qty", 0)) + qty
                return qty
        if len(inventory) < INV_CAP:
            inventory.append({"id": item_id, "name": item_name,
                              "qty": qty, "color": col})
            return qty
        return 0
    while added < qty and len(inventory) < INV_CAP:
        inventory.append({"id": item_id, "name": item_name,
                          "qty": 1, "color": col})
        added += 1
    return added


def _inv_take_qty(inventory: list, item_id: str, qty: int) -> int:
    """Remove up to `qty` of an item from inventory. For stackable items,
    decrements the matching stack; for non-stackable, removes that many
    individual entries. Returns the number actually removed."""
    if qty <= 0:
        return 0
    removed = 0
    # Iterate in reverse so we can pop without index drift.
    i = len(inventory) - 1
    while i >= 0 and removed < qty:
        it = inventory[i]
        if isinstance(it, dict) and it.get("id") == item_id:
            cur = int(it.get("qty", 0))
            take = min(cur, qty - removed)
            cur -= take
            removed += take
            if cur <= 0:
                inventory.pop(i)
            else:
                it["qty"] = cur
        i -= 1
    return removed


_LOSS_LOG_CAP_DB = 50   # SQLite-backed cap (was 20 in-memory)


def _log_inventory_loss(player_id: str, item_id: str, name: str,
                        qty: int, color, reason: str = "save_delta") -> None:
    """Record a loss in the inventory_loss_log SQLite table. Capped at
    _LOSS_LOG_CAP_DB rows per player; overflow trim runs in the same
    transaction so the table can't grow unbounded even under high churn."""
    if qty <= 0:
        return
    col_json = json.dumps(_color_to_list(color))
    now = time.time()
    try:
        with _db() as conn:
            conn.execute(
                "INSERT INTO inventory_loss_log "
                "(player_id, item_id, item_name, quantity, color, reason, "
                "restored, lost_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?)",
                (player_id, item_id, name, int(qty), col_json, reason, now))
            # Trim oldest if over cap.
            conn.execute(
                "DELETE FROM inventory_loss_log "
                "WHERE player_id = ? AND id NOT IN ("
                "  SELECT id FROM inventory_loss_log "
                "  WHERE player_id = ? ORDER BY lost_at DESC LIMIT ?)",
                (player_id, player_id, _LOSS_LOG_CAP_DB))
            conn.commit()
    except Exception as e:
        print(f"[loss_log] insert failed for {player_id}: {e}")


def _detect_inventory_losses(session: dict, prev_inv: list, new_inv: list,
                              prev_eq: dict, new_eq: dict) -> None:
    """Compare two inventory+equipment snapshots and log items whose total
    qty dropped across the union. Equipping an item to a slot would otherwise
    look like a loss (inventory qty -1), so we count occupied equipment
    slots as +1 of that item id on both sides of the comparison. Items that
    truly vanished (boat lost mid-sail, save-format bug, etc.) still show up
    because they're missing from both inventory AND equipment in the new
    snapshot."""
    def _sum_combined(inv, eq):
        totals = {}
        names  = {}
        cols   = {}
        for it in inv:
            if not isinstance(it, dict):
                continue
            iid = str(it.get("id", ""))
            if not iid:
                continue
            totals[iid] = totals.get(iid, 0) + int(it.get("qty", 0))
            names.setdefault(iid, str(it.get("name", iid)))
            cols.setdefault(iid, it.get("color", [0.7, 0.7, 0.7, 1.0]))
        for _slot, iid in (eq or {}).items():
            iid_s = str(iid or "")
            if not iid_s:
                continue
            totals[iid_s] = totals.get(iid_s, 0) + 1
            names.setdefault(iid_s, iid_s.replace("_", " ").title())
        return totals, names, cols

    prev_totals, prev_names, prev_cols = _sum_combined(prev_inv, prev_eq)
    new_totals, _, _ = _sum_combined(new_inv, new_eq)
    for iid, prev_qty in prev_totals.items():
        new_qty = new_totals.get(iid, 0)
        if new_qty < prev_qty:
            _log_inventory_loss(session["id"], iid, prev_names[iid],
                                prev_qty - new_qty, prev_cols[iid])


async def _push_inventory_to(ws, inventory: list) -> None:
    """Send a player their current inventory so the client view matches what
    the server just mutated (admin give/take/restore). Same shape as the
    clan_bank_result push the client already handles."""
    await _send(ws, {"type": "admin_inventory_set", "inventory": inventory})


def _find_target_session(target: str):
    """Online lookup by username (case-insensitive). Returns (ws, session) or
    (None, None) if not online."""
    return _session_by_username(target)


async def _handle_admin_give_item(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    target = str(msg.get("target", "")).strip()
    item_id = str(msg.get("item_id", "")).strip()
    qty = int(msg.get("qty", 1))
    name = str(msg.get("name", item_id))
    color = msg.get("color", [0.7, 0.7, 0.7, 1.0])
    if not target or not item_id or qty <= 0:
        await _admin_confirm(ws, "Usage: target+item_id+qty required.")
        return
    tws, tsession = _find_target_session(target)
    if tsession is None:
        await _admin_confirm(ws, f"{target} is not online.")
        return
    inv = tsession.get("inventory", [])
    added = _inv_add_qty(inv, item_id, name, qty, color)
    tsession["inventory"] = inv
    if tws is not None:
        await _push_inventory_to(tws, inv)
    await _admin_confirm(ws, f"Gave {added}× {name} to {target}"
                              + (f" (inv full, {qty - added} dropped)"
                                 if added < qty else ""))
    _admin_log(session, f"give {target} {item_id} {added}/{qty}")


async def _handle_admin_take_item(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    target = str(msg.get("target", "")).strip()
    item_id = str(msg.get("item_id", "")).strip()
    qty = int(msg.get("qty", 1))
    if not target or not item_id or qty <= 0:
        await _admin_confirm(ws, "Usage: target+item_id+qty required.")
        return
    tws, tsession = _find_target_session(target)
    if tsession is None:
        await _admin_confirm(ws, f"{target} is not online.")
        return
    inv = tsession.get("inventory", [])
    removed = _inv_take_qty(inv, item_id, qty)
    tsession["inventory"] = inv
    if tws is not None:
        await _push_inventory_to(tws, inv)
    await _admin_confirm(ws, f"Took {removed}× {item_id} from {target}"
                              + (f" (only had {removed})" if removed < qty else ""))
    _admin_log(session, f"take {target} {item_id} {removed}/{qty}")


async def _handle_admin_view_inventory(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    target = str(msg.get("target", "")).strip()
    if not target:
        return
    tws, tsession = _find_target_session(target)
    if tsession is None:
        # Offline read from DB so admin can audit absent players too.
        with _db() as conn:
            row = conn.execute(
                "SELECT inventory FROM players WHERE username=? COLLATE NOCASE",
                (target,)).fetchone()
        if row is None:
            await _admin_confirm(ws, f"No such player: {target}")
            return
        try:
            inv = json.loads(row["inventory"] or "[]")
        except Exception:
            inv = []
        await _send(ws, {"type": "admin_inventory_view",
                         "target": target, "online": False, "inventory": inv})
    else:
        await _send(ws, {"type": "admin_inventory_view",
                         "target": tsession["username"], "online": True,
                         "inventory": tsession.get("inventory", [])})
    _admin_log(session, f"view_inv {target}")


async def _handle_admin_list_players(ws, session: dict, _msg: dict) -> None:
    if not _is_admin(session):
        return
    names = sorted(s["username"] for s in sessions.values())
    await _send(ws, {"type": "admin_player_list", "players": names})


async def _handle_admin_restore_last_loss(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    target = str(msg.get("target", "")).strip()
    if not target:
        await _admin_confirm(ws, "Usage: target required.")
        return
    tws, tsession = _find_target_session(target)
    if tsession is None:
        await _admin_confirm(ws, f"{target} is not online "
                                  "(restore only works for online players).")
        return
    # Most recent unrestored loss for this player, read from SQLite.
    try:
        with _db() as conn:
            row = conn.execute(
                "SELECT id, item_id, item_name, quantity, color "
                "FROM inventory_loss_log "
                "WHERE player_id = ? AND restored = 0 "
                "ORDER BY lost_at DESC LIMIT 1",
                (tsession["id"],)).fetchone()
    except Exception as e:
        await _admin_confirm(ws, f"Loss-log query failed: {e}")
        return
    if row is None:
        await _admin_confirm(ws, f"No unrestored losses logged for {target}.")
        return
    try:
        color = json.loads(row["color"])
    except Exception:
        color = [0.7, 0.7, 0.7, 1.0]
    inv = tsession.get("inventory", [])
    added = _inv_add_qty(inv, row["item_id"], row["item_name"],
                         int(row["quantity"]), color)
    tsession["inventory"] = inv
    try:
        with _db() as conn:
            conn.execute(
                "UPDATE inventory_loss_log SET restored = 1 WHERE id = ?",
                (int(row["id"]),))
            conn.commit()
    except Exception as e:
        print(f"[loss_log] mark-restored failed for id={row['id']}: {e}")
    if tws is not None:
        await _push_inventory_to(tws, inv)
    await _admin_confirm(ws, f"Restored {added}× {row['item_name']} to {target}.")
    _admin_log(session, f"restore_last_loss {target} {row['item_id']} {added}")


def _tile_key(tx: int, ty: int) -> str:
    return f"{tx},{ty}"


def _tile_overrides_to_list() -> list:
    """Wire / login bulk format — list of {tx, ty, biome} dicts."""
    out = []
    for key, biome in tile_overrides.items():
        try:
            tx_str, ty_str = key.split(",", 1)
            out.append({"tx": int(tx_str), "ty": int(ty_str), "biome": biome})
        except (ValueError, AttributeError):
            continue
    return out


def _load_tile_overrides_from_disk() -> None:
    """Populate the in-memory `tile_overrides` dict from the SQLite table.
    Post-consolidation the table is the single source of truth — the legacy
    JSON file is migrated and renamed to .bak by migration v2 on first boot."""
    global tile_overrides, tile_overrides_dirty
    try:
        with _db() as conn:
            rows = conn.execute(
                "SELECT tx, ty, biome FROM tile_overrides").fetchall()
        for r in rows:
            tile_overrides[_tile_key(int(r["tx"]), int(r["ty"]))] = r["biome"]
        tile_overrides_dirty = False
        print(f"[tile_overrides] loaded {len(tile_overrides)} tiles from SQLite")
    except Exception as e:
        print(f"[tile_overrides] SQLite load failed: {e}")


def _save_tile_overrides_to_disk() -> None:
    """Flush the in-memory dict to the tile_overrides table. UPSERT per row
    so any concurrent admin edit racing this flush doesn't get clobbered."""
    global tile_overrides_dirty
    try:
        now = time.time()
        with _db() as conn:
            # Wipe rows that no longer have an in-memory mapping (admin cleared them).
            existing = {(int(r["tx"]), int(r["ty"]))
                        for r in conn.execute("SELECT tx, ty FROM tile_overrides")}
            present: set = set()
            for key, biome in tile_overrides.items():
                try:
                    tx_s, ty_s = key.split(",")
                    tx = int(tx_s); ty = int(ty_s)
                except (ValueError, AttributeError):
                    continue
                present.add((tx, ty))
                conn.execute(
                    "INSERT OR REPLACE INTO tile_overrides "
                    "(tx, ty, biome, updated_at) VALUES (?, ?, ?, ?)",
                    (tx, ty, str(biome), now))
            for tx, ty in existing - present:
                conn.execute(
                    "DELETE FROM tile_overrides WHERE tx=? AND ty=?", (tx, ty))
            conn.commit()
        tile_overrides_dirty = False
        print(f"[tile_overrides] saved {len(tile_overrides)} tiles to SQLite")
    except Exception as e:
        print(f"[tile_overrides] save failed: {e}")


# ══════════════════════════════════════════════════════════════════════════════
# ── Shop economy plumbing (Phase 2) ──────────────────────────────────────────
# Persistence mirrors the tile_overrides pattern: in-memory dict, dirty flag,
# atomic save via tmp+replace, 30s autosave loop. Restock is a separate 60s
# loop. State is per-NPC (keyed by shop NPC's entity_id) so two general
# stores in different towns track stock independently. Server is fully
# authoritative on all transactions.

SHOP_STOCK_FILE      = Path(__file__).parent / "shop_stock.json"
SHOP_TICK_SECONDS    = 60.0     # restock cadence (matches stock_template
                                # restock_per_tick semantics)
SHOP_AUTOSAVE_PERIOD = 30.0
SHOP_ACCESS_RANGE    = 200.0    # px from shopkeeper to buy/sell

shopkeeper_state: dict = {}     # npc_id → state dict (see _seed_shop_state)
shop_stock_dirty:  bool = False


def _player_sell_back_multiplier(skill_xp: dict) -> float:
    """Mirror of ItemPrices.sell_back_multiplier(player). Formula:
    floor(sum_of_15_skill_levels / 150) * 0.05 + 0.20, clamped [0.20, 0.50].
    Cap hits at sum=900 (avg skill level 60)."""
    total = 0
    for skill in _SHOP_SKILLS:
        total += _calc_level(int(skill_xp.get(skill, 0)))
    return max(0.20, min(0.50, 0.20 + math.floor(total / 150.0) * 0.05))


def _base_price_for(item_id: str) -> int:
    """Returns the base gold value of an item, or 0 if unpriced. Both the
    explicit table and the tier-derived combinations were merged into
    _BASE_PRICES at module load."""
    return int(_BASE_PRICES.get(item_id, 0))


def _seed_shop_state(npc_id: str, shop_id: str) -> dict:
    """Build a fresh state entry seeded to template max. Called on first
    shop_open for an NPC if it isn't in shopkeeper_state yet, AND used by the
    disk-load path to rehydrate. current_stock values are FLOATS so the
    60s restock can apply fractional rates (e.g. 0.3/tick for wooden axes)
    without rounding artifacts. Display rounds DOWN to int."""
    template = _SHOPS_PY.get(shop_id, {})
    stock = {}
    for entry in template.get("stock_template", []):
        stock[str(entry["id"])] = float(entry["max"])
    return {
        "shop_id": shop_id,
        "current_stock": stock,
        "last_restock_at": time.time(),
    }


def _get_or_seed_shop_state(npc_id: str, shop_id: str) -> dict:
    """Returns the live state, seeding from template if first reference. Used
    by both shop_open and the disk-loader rehydration."""
    global shop_stock_dirty
    st = shopkeeper_state.get(npc_id)
    if st is None or st.get("shop_id") != shop_id:
        st = _seed_shop_state(npc_id, shop_id)
        shopkeeper_state[npc_id] = st
        shop_stock_dirty = True
    return st


def _stock_to_int(stock_floats: dict) -> dict:
    """Display floor for the wire — clients see whole-number stock counts."""
    return {iid: int(qty) for iid, qty in stock_floats.items()}


def _load_shop_stock_from_disk() -> None:
    """Populate `shopkeeper_state` from the shop_stock table. Post-
    consolidation SQLite is the only store; the legacy JSON was migrated to
    .bak by migration v3. Stock rows group by npc_id; each shop's shop_id is
    looked up from world_entities (where admin-placed shopkeepers live)."""
    global shopkeeper_state
    try:
        with _db() as conn:
            stock_rows = conn.execute(
                "SELECT npc_id, item_id, quantity, last_restock "
                "FROM shop_stock").fetchall()
            # Best-known shop_id per NPC lives in world_entities.data JSON.
            we_rows = conn.execute(
                "SELECT id, data FROM world_entities WHERE kind='npc'"
            ).fetchall()
        npc_to_shop: dict = {}
        for r in we_rows:
            try:
                d = json.loads(r["data"] or "{}")
                sid = str(d.get("shop_id", ""))
                if sid:
                    npc_to_shop[str(r["id"])] = sid
            except Exception:
                continue
        grouped: dict = {}
        latest_restock: dict = {}
        for r in stock_rows:
            npc_id = str(r["npc_id"])
            grouped.setdefault(npc_id, {})[str(r["item_id"])] = float(r["quantity"])
            latest_restock[npc_id] = max(
                latest_restock.get(npc_id, 0.0), float(r["last_restock"]))
        loaded = 0
        for npc_id, stock in grouped.items():
            shop_id = npc_to_shop.get(npc_id, "")
            if shop_id not in _SHOPS_PY:
                continue
            shopkeeper_state[npc_id] = {
                "shop_id":         shop_id,
                "current_stock":   stock,
                "last_restock_at": latest_restock.get(npc_id, time.time()),
            }
            loaded += 1
        print(f"[shop_stock] loaded {loaded} shopkeepers from SQLite")
    except Exception as e:
        print(f"[shop_stock] SQLite load failed: {e}")


def _save_shop_stock_to_disk() -> None:
    """Flush shopkeeper_state to the shop_stock table. Wipes the per-NPC
    rows before inserting the current snapshot so items removed from a
    shop template don't linger as orphans."""
    global shop_stock_dirty
    try:
        with _db() as conn:
            for npc_id, st in shopkeeper_state.items():
                last = float(st.get("last_restock_at", time.time()))
                stock = st.get("current_stock", {})
                conn.execute(
                    "DELETE FROM shop_stock WHERE npc_id=?", (str(npc_id),))
                for item_id, qty in stock.items():
                    try:
                        q = float(qty)
                    except (TypeError, ValueError):
                        continue
                    conn.execute(
                        "INSERT OR REPLACE INTO shop_stock "
                        "(npc_id, item_id, quantity, last_restock) "
                        "VALUES (?, ?, ?, ?)",
                        (str(npc_id), str(item_id), q, last))
            conn.commit()
        shop_stock_dirty = False
        print(f"[shop_stock] saved {len(shopkeeper_state)} shopkeepers to SQLite")
    except Exception as e:
        print(f"[shop_stock] save failed: {e}")


async def _shop_stock_autosave_loop() -> None:
    """Flushes shopkeeper_state to disk every 30s if dirty. Buys/sells set
    the dirty flag; the loop itself does no shop logic."""
    while True:
        await asyncio.sleep(SHOP_AUTOSAVE_PERIOD)
        if shop_stock_dirty:
            _save_shop_stock_to_disk()


async def _shop_restock_loop() -> None:
    """Every SHOP_TICK_SECONDS, regen each item up to template.max by its
    restock_per_tick (float; accumulates fractional)."""
    global shop_stock_dirty
    while True:
        await asyncio.sleep(SHOP_TICK_SECONDS)
        now = time.time()
        any_changed = False
        for npc_id, st in shopkeeper_state.items():
            template = _SHOPS_PY.get(st.get("shop_id", ""))
            if not template:
                continue
            stock = st["current_stock"]
            for entry in template["stock_template"]:
                iid = str(entry["id"])
                cap = float(entry["max"])
                rate = float(entry.get("restock_per_tick", 0.0))
                if rate <= 0.0:
                    continue
                current = stock.get(iid, 0.0)
                if current < cap:
                    stock[iid] = min(cap, current + rate)
                    any_changed = True
            st["last_restock_at"] = now
        if any_changed:
            shop_stock_dirty = True


def _player_near_npc(session: dict, npc_id: str) -> bool:
    """Validate the player is close enough to the NPC to transact. Pulls the
    NPC's stored position from world_entities (admin-placed) — if not found,
    skip the check (chunk-spawned NPCs aren't expected for shops in v1, but
    we don't want to silently refuse if they show up)."""
    with _db() as conn:
        row = conn.execute(
            "SELECT x, y FROM world_entities WHERE id=?", (npc_id,)
        ).fetchone()
    if not row:
        return True   # unknown NPC origin — let the transaction through
    dx = float(session.get("x", 0.0)) - float(row["x"])
    dy = float(session.get("y", 0.0)) - float(row["y"])
    return (dx * dx + dy * dy) <= (SHOP_ACCESS_RANGE * SHOP_ACCESS_RANGE)


async def _push_gold_and_inventory(ws, session: dict, new_gold: int,
                                    inventory: list) -> None:
    """Common post-transaction push: updated gold + inventory. Reuses the
    existing gold_set and admin_inventory_set message types the client
    already handles."""
    await _send(ws, {"type": "gold_set", "gold": new_gold})
    await _send(ws, {"type": "admin_inventory_set", "inventory": inventory})


async def _handle_shop_open(ws, session: dict, msg: dict) -> None:
    npc_id  = str(msg.get("npc_id", "")).strip()
    shop_id = str(msg.get("shop_id", "")).strip()
    if not npc_id or shop_id not in _SHOPS_PY:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "Unknown shop."})
        return
    if not _player_near_npc(session, npc_id):
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "You're too far from the shopkeeper."})
        return
    st = _get_or_seed_shop_state(npc_id, shop_id)
    # Read skill_xp for the sell-back multiplier snapshot.
    with _db() as conn:
        row = conn.execute("SELECT skill_xp FROM players WHERE id=?",
                           (session["id"],)).fetchone()
    skill_xp = json.loads(row["skill_xp"] or "{}") if row else {}
    await _send(ws, {
        "type":            "shop_state",
        "npc_id":          npc_id,
        "shop_id":         shop_id,
        "shop_name":       str(_SHOPS_PY[shop_id].get("name", "")),
        "buy_multiplier":  float(_SHOPS_PY[shop_id].get("buy_multiplier", 1.0)),
        "sell_back_mult":  _player_sell_back_multiplier(skill_xp),
        "current_stock":   _stock_to_int(st["current_stock"]),
    })


async def _handle_shop_buy(ws, session: dict, msg: dict) -> None:
    global shop_stock_dirty
    npc_id  = str(msg.get("npc_id", "")).strip()
    item_id = str(msg.get("item_id", "")).strip()
    qty     = max(1, int(msg.get("qty", 1)))
    if not npc_id or not item_id:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "Invalid request."})
        return
    st = shopkeeper_state.get(npc_id)
    if st is None:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "Shop not open. Click the shopkeeper first."})
        return
    template = _SHOPS_PY.get(st["shop_id"], {})
    entry = next((e for e in template.get("stock_template", [])
                  if str(e["id"]) == item_id), None)
    if entry is None:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "This shop does not carry that item."})
        return
    if not _player_near_npc(session, npc_id):
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "You're too far from the shopkeeper."})
        return
    available_int = int(st["current_stock"].get(item_id, 0.0))
    if available_int < qty:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": f"Only {available_int} in stock."})
        return
    unit_price = int(round(_base_price_for(item_id)
                           * float(template.get("buy_multiplier", 1.0))))
    if unit_price <= 0:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "That item has no price."})
        return
    total_cost = unit_price * qty
    # Gold + inventory checks via DB (matches _handle_admin_gold pattern).
    with _db() as conn:
        row = conn.execute(
            "SELECT gold, inventory FROM players WHERE id=?",
            (session["id"],)).fetchone()
        if not row:
            await _send(ws, {"type": "shop_result", "ok": False,
                             "reason": "Player record missing."})
            return
        current_gold = int(row["gold"] or 0)
        if current_gold < total_cost:
            await _send(ws, {"type": "shop_result", "ok": False,
                             "reason": f"Not enough gold ({total_cost}g needed)."})
            return
        inventory = json.loads(row["inventory"] or "[]")
        added = _inv_add_qty(inventory, item_id, str(entry["name"]),
                             qty, entry.get("color", [0.7, 0.7, 0.7, 1.0]))
        if added <= 0:
            await _send(ws, {"type": "shop_result", "ok": False,
                             "reason": "Your inventory is full."})
            return
        # Charge for what we actually added (in case INV_CAP shaved units).
        actual_cost = unit_price * added
        new_gold = current_gold - actual_cost
        conn.execute(
            "UPDATE players SET gold=?, inventory=? WHERE id=?",
            (new_gold, json.dumps(inventory), session["id"]))
        conn.commit()
    # Decrement server stock (float-precision; floor on display).
    st["current_stock"][item_id] = max(0.0,
        float(st["current_stock"][item_id]) - added)
    shop_stock_dirty = True
    session["inventory"] = inventory
    await _push_gold_and_inventory(ws, session, new_gold, inventory)
    await _send(ws, {"type": "shop_result", "ok": True,
                     "current_stock": _stock_to_int(st["current_stock"]),
                     "bought_qty": added})


async def _handle_shop_sell(ws, session: dict, msg: dict) -> None:
    """Universal sell-back per design: any shop, any priced non-soulbound
    item, at sell_back_multiplier(player). Shop's stock is NOT incremented
    on player sell — sold items are absorbed by the shopkeeper, not stocked."""
    npc_id  = str(msg.get("npc_id", "")).strip()
    item_id = str(msg.get("item_id", "")).strip()
    qty     = max(1, int(msg.get("qty", 1)))
    if not npc_id or not item_id:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "Invalid request."})
        return
    st = shopkeeper_state.get(npc_id)
    if st is None:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "Shop not open."})
        return
    if not _player_near_npc(session, npc_id):
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "You're too far from the shopkeeper."})
        return
    if item_id in _SOULBOUND_ITEMS:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "This item cannot be sold."})
        return
    base = _base_price_for(item_id)
    if base <= 0:
        await _send(ws, {"type": "shop_result", "ok": False,
                         "reason": "The shopkeeper has no use for that."})
        return
    with _db() as conn:
        row = conn.execute(
            "SELECT gold, inventory, skill_xp FROM players WHERE id=?",
            (session["id"],)).fetchone()
        if not row:
            return
        inventory = json.loads(row["inventory"] or "[]")
        skill_xp  = json.loads(row["skill_xp"]  or "{}")
        removed = _inv_take_qty(inventory, item_id, qty)
        if removed <= 0:
            await _send(ws, {"type": "shop_result", "ok": False,
                             "reason": "You don't have that item."})
            return
        mult = _player_sell_back_multiplier(skill_xp)
        unit_price = int(round(base * mult))
        gain = unit_price * removed
        current_gold = int(row["gold"] or 0)
        new_gold = current_gold + gain
        conn.execute(
            "UPDATE players SET gold=?, inventory=? WHERE id=?",
            (new_gold, json.dumps(inventory), session["id"]))
        conn.commit()
    session["inventory"] = inventory
    await _push_gold_and_inventory(ws, session, new_gold, inventory)
    await _send(ws, {"type": "shop_result", "ok": True,
                     "sold_qty": removed,
                     "gold_gained": gain})


async def _handle_shop_close(ws, session: dict, msg: dict) -> None:
    """No-op stub — reserved for future per-player viewing locks or
    transaction-batch flushing. Server doesn't track open-shop windows in v1."""
    return


# ══════════════════════════════════════════════════════════════════════════════
# ── Interior entry / exit (Phase 6) ──────────────────────────────────────────
# Doors are admin-placed world entities with `data.interior_id` carrying the
# interior key. When the client clicks a door, it sends `enter_interior` with
# the door's `entity_id`; the server validates proximity, resolves the
# interior_id from the entity's data dict, snapshots the player's exterior
# position as the return point, and updates session.interior_*. Phase 7
# wires the visual scene-swap on the client; Phase 6 is protocol + state
# only. Existing exterior x/y is preserved as the return point.

DOOR_INTERACT_RANGE = 64.0   # px — generous so misclicks still register


async def _handle_enter_interior(ws, session: dict, msg: dict) -> None:
    door_id = str(msg.get("door_id", "")).strip()
    if not door_id:
        await _send(ws, {"type": "interior_error",
                         "reason": "Missing door id."})
        return
    # If already inside an interior, refuse the entry — design choice: doors
    # are exterior-only for v1, no chained interiors.
    if session.get("interior_id", "") != "":
        await _send(ws, {"type": "interior_error",
                         "reason": "You're already inside."})
        return
    with _db() as conn:
        row = conn.execute(
            "SELECT kind, subtype, x, y, data FROM world_entities WHERE id=?",
            (door_id,)).fetchone()
    if not row:
        await _send(ws, {"type": "interior_error",
                         "reason": "Door not found."})
        return
    if str(row["subtype"]) != "door":
        await _send(ws, {"type": "interior_error",
                         "reason": "Not a door."})
        return
    # Proximity check — anti-cheat plus prevents misclicks on far-away doors.
    dx = float(session.get("x", 0.0)) - float(row["x"])
    dy = float(session.get("y", 0.0)) - float(row["y"])
    if dx * dx + dy * dy > DOOR_INTERACT_RANGE * DOOR_INTERACT_RANGE:
        await _send(ws, {"type": "interior_error",
                         "reason": "You're too far from the door."})
        return
    try:
        data = json.loads(row["data"] or "{}")
    except Exception:
        data = {}
    interior_id = str(data.get("interior_id", ""))
    if not interior_id:
        await _send(ws, {"type": "interior_error",
                         "reason": "This door leads nowhere."})
        return
    # Snapshot exterior pos as the return point (already in session.x/y).
    # Interior spawn coords come from InteriorCatalog in Phase 8; for now use
    # (0, 0) as a placeholder — Phase 7's scene swap doesn't care.
    session["interior_id"] = interior_id
    session["interior_x"]  = 0.0
    session["interior_y"]  = 0.0
    # Persist immediately so a crash/relog lands the player back inside.
    with _db() as conn:
        conn.execute(
            "UPDATE players SET interior_id=?, interior_x=?, interior_y=? "
            "WHERE id=?",
            (interior_id, 0.0, 0.0, session["id"]))
        conn.commit()
    await _send(ws, {
        "type":        "interior_entered",
        "interior_id": interior_id,
        "x":           0.0,
        "y":           0.0,
        "return_x":    float(session.get("x", 0.0)),
        "return_y":    float(session.get("y", 0.0)),
    })
    print(f"[interior] {session['username']} entered {interior_id} "
          f"via door {door_id}")


async def _handle_exit_interior(ws, session: dict, msg: dict) -> None:
    if session.get("interior_id", "") == "":
        await _send(ws, {"type": "interior_error",
                         "reason": "You're not inside an interior."})
        return
    interior_id = session["interior_id"]
    return_x = float(session.get("x", 0.0))
    return_y = float(session.get("y", 0.0))
    session["interior_id"] = ""
    session["interior_x"]  = 0.0
    session["interior_y"]  = 0.0
    with _db() as conn:
        conn.execute(
            "UPDATE players SET interior_id='', interior_x=0, interior_y=0 "
            "WHERE id=?",
            (session["id"],))
        conn.commit()
    await _send(ws, {
        "type": "interior_exited",
        "x":    return_x,
        "y":    return_y,
    })
    print(f"[interior] {session['username']} exited {interior_id}")


# ══════════════════════════════════════════════════════════════════════════════
# ── Gold piles (Phase 5 of the gold economy) ─────────────────────────────────
# Server-tracked world piles, ephemeral (no disk persistence). On monster
# death the server rolls gold, creates a pile, and broadcasts gold_pile_spawn
# to nearby clients. First client to send gold_pile_pickup (within range)
# claims the whole pile. Stale piles expire on the existing world tick loop.

gold_piles: dict = {}     # pile_id → {x, y, amount, expires_at, claimed: bool}
GOLD_PILE_LIFETIME    = 120.0   # seconds before unclaimed piles vanish
GOLD_PILE_PICKUP_RANGE = 48.0   # px from session pos to claim — generous so
                                 # walking over still triggers a click pickup


def _spawn_gold_pile(x: float, y: float, amount: int) -> str:
    """Create a server-tracked pile and broadcast its existence to nearby
    clients. Returns the pile_id so callers can correlate with their own
    state (none currently)."""
    if amount <= 0:
        return ""
    pile_id = "g:" + secrets.token_hex(6)
    gold_piles[pile_id] = {
        "x": float(x), "y": float(y),
        "amount": int(amount),
        "expires_at": time.time() + GOLD_PILE_LIFETIME,
        "claimed": False,
    }
    _broadcast_near(x, y, {
        "type":   "gold_pile_spawn",
        "id":     pile_id,
        "x":      float(x),
        "y":      float(y),
        "amount": int(amount),
    })
    return pile_id


async def _handle_gold_pile_pickup(ws, session: dict, msg: dict) -> None:
    pile_id = str(msg.get("id", ""))
    p = gold_piles.get(pile_id)
    if p is None or p.get("claimed"):
        return
    dx = float(session.get("x", 0.0)) - p["x"]
    dy = float(session.get("y", 0.0)) - p["y"]
    if dx * dx + dy * dy > GOLD_PILE_PICKUP_RANGE * GOLD_PILE_PICKUP_RANGE:
        return
    p["claimed"] = True
    amount = int(p["amount"])
    # Credit gold (matches _handle_admin_gold pattern: DB read+write +
    # gold_set push).
    with _db() as conn:
        row = conn.execute(
            "SELECT gold FROM players WHERE id=?", (session["id"],)
        ).fetchone()
        if not row:
            return
        new_gold = int(row["gold"] or 0) + amount
        conn.execute(
            "UPDATE players SET gold=? WHERE id=?",
            (new_gold, session["id"]))
        conn.commit()
    await _send(ws, {"type": "gold_set", "gold": new_gold})
    # Tell every nearby client to despawn the visual. The pile entry stays
    # in `gold_piles` with claimed=True only briefly — _world_tick_loop's
    # expire pass GCs it next tick.
    _broadcast_near(p["x"], p["y"],
        {"type": "gold_pile_remove", "id": pile_id})


def _load_tile_overrides() -> list:
    """Login bulk format. Reads from the in-memory dict (the file/SQLite was
    already loaded into it at startup)."""
    return _tile_overrides_to_list()


async def _handle_admin_tile_set(ws, session: dict, msg: dict) -> None:
    global tile_overrides_dirty
    if not _is_admin(session):
        return
    tx = int(msg.get("tx", -1))
    ty = int(msg.get("ty", -1))
    biome = str(msg.get("biome", "")).strip()
    if tx < 0 or ty < 0 or not biome:
        return
    tile_overrides[_tile_key(tx, ty)] = biome
    tile_overrides_dirty = True
    _broadcast({"type": "tile_set", "tx": tx, "ty": ty, "biome": biome})


async def _handle_admin_tile_clear(ws, session: dict, msg: dict) -> None:
    global tile_overrides_dirty
    if not _is_admin(session):
        return
    tx = int(msg.get("tx", -1))
    ty = int(msg.get("ty", -1))
    if tx < 0 or ty < 0:
        return
    if tile_overrides.pop(_tile_key(tx, ty), None) is not None:
        tile_overrides_dirty = True
    _broadcast({"type": "tile_clear", "tx": tx, "ty": ty})


async def _handle_admin_save_map(ws, session: dict, msg: dict) -> None:
    """Save Map button on the admin panel — immediate flush + confirmation."""
    if not _is_admin(session):
        return
    if tile_overrides_dirty:
        _save_tile_overrides_to_disk()
        await _send(ws, {"type": "chat", "username": "Admin",
                         "text": f"Map saved ({len(tile_overrides)} tile edits)."})
    else:
        await _send(ws, {"type": "chat", "username": "Admin",
                         "text": "Nothing to save — no unsaved changes."})


async def _handle_admin_spawn(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    subtype = str(msg.get("subtype", "")).strip()
    level   = max(1, int(msg.get("level", 1)))
    if not subtype:
        return
    x = float(msg.get("x", session["x"]))
    y = float(msg.get("y", session["y"]))
    data = {"monster_type": subtype, "level": level}
    eid = "a:" + secrets.token_hex(8)
    with _db() as conn:
        conn.execute(
            "INSERT INTO world_entities (id, kind, subtype, x, y, data) VALUES (?,?,?,?,?,?)",
            (eid, "monster", subtype, x, y, json.dumps(data)))
        conn.commit()
    entity = {"id": eid, "kind": "monster", "subtype": subtype, "x": x, "y": y, "data": data}
    _broadcast({"type": "world_entity_add", "entity": entity})
    await _admin_confirm(ws, f"Spawned {subtype} (lv {level}).")


FARM_PLOT_CONSTRUCTION_LEVEL = 10


async def _handle_build_farm_plot(ws, session: dict, msg: dict) -> None:
    """Player-built farm plot. Late-game gated: must be in a warband AND have
    Construction >= 10. Placed at the player's position, persisted like an
    admin-placed entity so it loads for everyone and survives restarts."""
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        row = conn.execute("SELECT skill_xp FROM players WHERE id=?",
                           (session["id"],)).fetchone()
    if cid is None:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": "Only warband members can build farm plots."})
        return
    skill_xp = json.loads(row["skill_xp"] or "{}") if row else {}
    if _calc_level(skill_xp.get("construction", 0)) < FARM_PLOT_CONSTRUCTION_LEVEL:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": f"Requires Construction level {FARM_PLOT_CONSTRUCTION_LEVEL}."})
        return
    x = float(msg.get("x", session["x"]))
    y = float(msg.get("y", session["y"]))
    eid = "a:" + secrets.token_hex(8)
    with _db() as conn:
        conn.execute(
            "INSERT INTO world_entities (id, kind, subtype, x, y, data) VALUES (?,?,?,?,?,?)",
            (eid, "farm_plot", "farm_plot", x, y, json.dumps({"owner": session["username"]})))
        conn.commit()
    entity = {"id": eid, "kind": "farm_plot", "subtype": "farm_plot",
              "x": x, "y": y, "data": {"owner": session["username"]}}
    _broadcast({"type": "world_entity_add", "entity": entity})
    await _send(ws, {"type": "chat", "username": "System", "text": "You build a farm plot."})
    print(f"[farm] {session['username']} built a plot at ({x:.0f},{y:.0f})")


# ── Clan / Warband handlers ───────────────────────────────────────────────────

CLAN_COST = 10000


def _clan_id_for_player(conn, player_id: str):
    row = conn.execute("SELECT clan_id FROM clan_members WHERE player_id=?",
                       (player_id,)).fetchone()
    return row["clan_id"] if row else None


def _build_clan_info(conn, clan_id: str) -> dict:
    clan = conn.execute("SELECT * FROM clans WHERE id=?", (clan_id,)).fetchone()
    if not clan:
        return {}
    rows = conn.execute(
        "SELECT cm.player_id AS pid, cm.role AS role, p.username AS uname "
        "FROM clan_members cm JOIN players p ON p.id = cm.player_id "
        "WHERE cm.clan_id=? ORDER BY (cm.role='leader') DESC, p.username COLLATE NOCASE",
        (clan_id,)
    ).fetchall()
    members = [{"username": r["uname"], "role": r["role"], "online": _is_online(r["pid"])}
               for r in rows]
    leader_row = conn.execute("SELECT username FROM players WHERE id=?",
                              (clan["leader_id"],)).fetchone()
    return {
        "id":      clan["id"],
        "name":    clan["name"],
        "leader":  leader_row["username"] if leader_row else "?",
        "gold":    int(clan["gold"] or 0),
        "bank":    json.loads(clan["bank"] or "[]"),
        "members": members,
    }


async def _send_clan_info(ws, player_id: str) -> None:
    with _db() as conn:
        cid = _clan_id_for_player(conn, player_id)
        if cid is None:
            await _send(ws, {"type": "clan_info", "clan": None})
            return
        info = _build_clan_info(conn, cid)
    await _send(ws, {"type": "clan_info", "clan": info})


async def _broadcast_clan_info(clan_id: str) -> None:
    """Push fresh clan info to every online member."""
    with _db() as conn:
        info = _build_clan_info(conn, clan_id)
        rows = conn.execute("SELECT player_id FROM clan_members WHERE clan_id=?",
                            (clan_id,)).fetchall()
        member_ids = [r["player_id"] for r in rows]
    for pid in member_ids:
        pws = _ws_for_player(pid)
        if pws is not None:
            await _send(pws, {"type": "clan_info", "clan": info})


async def _handle_clan_create(ws, session: dict, msg: dict) -> None:
    name = str(msg.get("name", "")).strip()
    if len(name) < 3 or len(name) > 24:
        await _send(ws, {"type": "clan_result", "ok": False,
                         "reason": "Clan name must be 3–24 characters."})
        return
    with _db() as conn:
        if _clan_id_for_player(conn, session["id"]) is not None:
            await _send(ws, {"type": "clan_result", "ok": False,
                             "reason": "You are already in a clan."})
            return
        if conn.execute("SELECT 1 FROM clans WHERE name=? COLLATE NOCASE", (name,)).fetchone():
            await _send(ws, {"type": "clan_result", "ok": False,
                             "reason": "That clan name is taken."})
            return
        prow = conn.execute("SELECT gold FROM players WHERE id=?", (session["id"],)).fetchone()
        gold = int(prow["gold"] or 0) if prow else 0
        if gold < CLAN_COST:
            await _send(ws, {"type": "clan_result", "ok": False,
                             "reason": f"You need {CLAN_COST:,} gold to found a clan."})
            return
        new_gold = gold - CLAN_COST
        clan_id  = secrets.token_hex(8)
        conn.execute("INSERT INTO clans (id, name, leader_id, bank, gold, created_at) "
                     "VALUES (?,?,?,?,?,?)",
                     (clan_id, name, session["id"], "[]", 0, time.time()))
        conn.execute("INSERT INTO clan_members (clan_id, player_id, role, joined_at) "
                     "VALUES (?,?,?,?)",
                     (clan_id, session["id"], "leader", time.time()))
        conn.execute("UPDATE players SET gold=? WHERE id=?", (new_gold, session["id"]))
        conn.commit()
    await _send(ws, {"type": "clan_result", "ok": True, "gold": new_gold,
                     "reason": f"Founded clan '{name}'!"})
    await _send_clan_info(ws, session["id"])
    print(f"[clan] {session['username']} founded '{name}'")


async def _handle_clan_invite(ws, session: dict, msg: dict) -> None:
    target = str(msg.get("target", "")).strip()
    tws, tsess = _session_by_username(target)
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "You are not in a clan."})
            return
        clan = conn.execute("SELECT name FROM clans WHERE id=?", (cid,)).fetchone()
        if tsess is None:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": f"{target} is not online."})
            return
        if _clan_id_for_player(conn, tsess["id"]) is not None:
            await _send(ws, {"type": "clan_result", "ok": False,
                             "reason": f"{target} is already in a clan."})
            return
        clan_name = clan["name"]
    await _send(tws, {"type": "clan_invite", "from": session["username"],
                      "clan_id": cid, "clan_name": clan_name})
    await _send(ws, {"type": "clan_result", "ok": True, "reason": f"Invited {target}."})


async def _handle_clan_accept(ws, session: dict, msg: dict) -> None:
    clan_id = str(msg.get("clan_id", "")).strip()
    with _db() as conn:
        if _clan_id_for_player(conn, session["id"]) is not None:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "You are already in a clan."})
            return
        clan = conn.execute("SELECT id FROM clans WHERE id=?", (clan_id,)).fetchone()
        if not clan:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "That clan no longer exists."})
            return
        conn.execute("INSERT OR IGNORE INTO clan_members (clan_id, player_id, role, joined_at) "
                     "VALUES (?,?,?,?)", (clan_id, session["id"], "member", time.time()))
        conn.commit()
    await _broadcast_clan_info(clan_id)
    print(f"[clan] {session['username']} joined a clan")


async def _handle_clan_decline(ws, session: dict, msg: dict) -> None:
    requester = str(msg.get("from", "")).strip()
    rws, _ = _session_by_username(requester)
    if rws is not None:
        await _send(rws, {"type": "chat", "username": "System",
                          "text": f"{session['username']} declined your clan invite."})


async def _handle_clan_leave(ws, session: dict, msg: dict) -> None:
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        clan = conn.execute("SELECT leader_id FROM clans WHERE id=?", (cid,)).fetchone()
        is_leader = clan and clan["leader_id"] == session["id"]
        conn.execute("DELETE FROM clan_members WHERE clan_id=? AND player_id=?",
                     (cid, session["id"]))
        remaining = conn.execute(
            "SELECT player_id FROM clan_members WHERE clan_id=? ORDER BY joined_at",
            (cid,)).fetchall()
        disbanded = False
        if not remaining:
            # Last member left — disband the clan.
            conn.execute("DELETE FROM clans WHERE id=?", (cid,))
            disbanded = True
        elif is_leader:
            # Promote the longest-standing remaining member to leader.
            new_leader = remaining[0]["player_id"]
            conn.execute("UPDATE clans SET leader_id=? WHERE id=?", (new_leader, cid))
            conn.execute("UPDATE clan_members SET role='leader' WHERE clan_id=? AND player_id=?",
                         (cid, new_leader))
        conn.commit()
    await _send(ws, {"type": "clan_info", "clan": None})
    if not disbanded:
        await _broadcast_clan_info(cid)
    print(f"[clan] {session['username']} left a clan")


async def _handle_clan_kick(ws, session: dict, msg: dict) -> None:
    target = str(msg.get("target", "")).strip()
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        clan = conn.execute("SELECT leader_id FROM clans WHERE id=?", (cid,)).fetchone()
        if not clan or clan["leader_id"] != session["id"]:
            await _send(ws, {"type": "clan_result", "ok": False,
                             "reason": "Only the leader can kick members."})
            return
        trow = conn.execute("SELECT id FROM players WHERE username=?", (target,)).fetchone()
        if not trow or trow["id"] == session["id"]:
            return
        conn.execute("DELETE FROM clan_members WHERE clan_id=? AND player_id=?",
                     (cid, trow["id"]))
        conn.commit()
        kicked_id = trow["id"]
    await _broadcast_clan_info(cid)
    kws = _ws_for_player(kicked_id)
    if kws is not None:
        await _send(kws, {"type": "clan_info", "clan": None})
        await _send(kws, {"type": "chat", "username": "System",
                          "text": "You were removed from the clan."})


async def _handle_clan_bank_deposit(ws, session: dict, msg: dict) -> None:
    item_id = str(msg.get("item_id", "")).strip()
    qty     = int(msg.get("qty", 0))
    if not item_id or qty <= 0:
        return
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        prow = conn.execute("SELECT inventory FROM players WHERE id=?", (session["id"],)).fetchone()
        inv  = json.loads(prow["inventory"] or "[]") if prow else []
        item_name = ""
        have = 0
        for it in inv:
            if isinstance(it, dict) and it.get("id") == item_id:
                have = int(it.get("qty", 0))
                item_name = str(it.get("name", item_id))
                break
        if have < qty:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "Not enough to deposit."})
            return
        _inv_remove_qty(inv, item_id, qty)
        clan = conn.execute("SELECT bank FROM clans WHERE id=?", (cid,)).fetchone()
        bank = json.loads(clan["bank"] or "[]")
        _inv_add_qty(bank, item_id, item_name, qty, _color_for_item(item_id))
        conn.execute("UPDATE players SET inventory=? WHERE id=?", (json.dumps(inv), session["id"]))
        conn.execute("UPDATE clans SET bank=? WHERE id=?", (json.dumps(bank), cid))
        conn.commit()
    await _send(ws, {"type": "clan_bank_result", "ok": True, "inventory": inv})
    await _broadcast_clan_info(cid)


async def _handle_clan_bank_withdraw(ws, session: dict, msg: dict) -> None:
    item_id = str(msg.get("item_id", "")).strip()
    qty     = int(msg.get("qty", 0))
    if not item_id or qty <= 0:
        return
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        clan = conn.execute("SELECT bank FROM clans WHERE id=?", (cid,)).fetchone()
        bank = json.loads(clan["bank"] or "[]")
        item_name = ""
        have = 0
        for it in bank:
            if isinstance(it, dict) and it.get("id") == item_id:
                have = int(it.get("qty", 0))
                item_name = str(it.get("name", item_id))
                break
        if have < qty:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "Not enough in the clan bank."})
            return
        _inv_remove_qty(bank, item_id, qty)
        prow = conn.execute("SELECT inventory FROM players WHERE id=?", (session["id"],)).fetchone()
        inv  = json.loads(prow["inventory"] or "[]") if prow else []
        _inv_add_qty(inv, item_id, item_name, qty, _color_for_item(item_id))
        conn.execute("UPDATE players SET inventory=? WHERE id=?", (json.dumps(inv), session["id"]))
        conn.execute("UPDATE clans SET bank=? WHERE id=?", (json.dumps(bank), cid))
        conn.commit()
    await _send(ws, {"type": "clan_bank_result", "ok": True, "inventory": inv})
    await _broadcast_clan_info(cid)


# ── Shared world state (resource nodes) ───────────────────────────────────────
# Geometry is deterministic on the client (shared chunk seeds), so the server only
# owns *mutable* state, keyed by the client's stable entity_id. Default = available;
# we only store entries for nodes that are currently locked or depleted (lazy).
# entity_id -> {"x": float, "y": float, "depleted_until": float, "lock": player_id|None}
nodes_state: dict = {}

INTEREST_RADIUS = 1700.0  # px (~53 tiles) — only stream world events to nearby clients


# ══════════════════════════════════════════════════════════════════════════════
# QUEST SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

def _quest_def(quest_id: str) -> dict:
    """Returns the quest definition dict or {} if unknown."""
    return _QUESTS_PY.get(quest_id, {})


def _player_skill_levels(player_id: str) -> dict:
    """Compute current skill levels for a player. Reads skill_xp JSON from
    SQLite and runs each through _calc_level. Used by the accept-time
    prerequisite gate."""
    try:
        with _db() as conn:
            row = conn.execute(
                "SELECT skill_xp FROM players WHERE id=?", (player_id,)
            ).fetchone()
    except Exception:
        return {}
    if row is None:
        return {}
    try:
        xp_data = json.loads(row["skill_xp"] or "{}")
    except Exception:
        return {}
    out = {}
    for skill, xp in xp_data.items():
        try:
            out[str(skill)] = _calc_level(int(xp))
        except Exception:
            continue
    return out


def _is_same_utc_day(a: float, b: float) -> bool:
    """True if two Unix timestamps fall on the same UTC date."""
    import datetime as _dt
    da = _dt.datetime.utcfromtimestamp(a).date()
    db = _dt.datetime.utcfromtimestamp(b).date()
    return da == db


def _quest_active_row(conn, player_id: str, quest_id: str):
    """Single active row for (player, quest). Active is unique per player_id
    by design — accept_handler refuses to insert a second active row."""
    return conn.execute(
        "SELECT accepted_at, progress FROM quests "
        "WHERE player_id=? AND quest_id=? AND status='active'",
        (player_id, quest_id)).fetchone()


def _quest_completed_count(conn, player_id: str, quest_id: str) -> int:
    row = conn.execute(
        "SELECT COUNT(*) AS c FROM quests "
        "WHERE player_id=? AND quest_id=? AND status='completed'",
        (player_id, quest_id)).fetchone()
    return int(row["c"]) if row else 0


def _quest_last_completion(conn, player_id: str, quest_id: str) -> float:
    row = conn.execute(
        "SELECT MAX(completed_at) AS t FROM quests "
        "WHERE player_id=? AND quest_id=? AND status='completed'",
        (player_id, quest_id)).fetchone()
    return float(row["t"]) if row and row["t"] is not None else 0.0


def _quest_player_completed_ids(conn, player_id: str) -> list:
    """All quest_ids the player has completed at least once. Used by the chain
    prerequisite check — a chained quest is only available if its predecessor
    appears in this list."""
    rows = conn.execute(
        "SELECT DISTINCT quest_id FROM quests "
        "WHERE player_id=? AND status='completed'",
        (player_id,)).fetchall()
    return [str(r["quest_id"]) for r in rows]


def _quest_can_accept(conn, session: dict, quest_id: str) -> tuple:
    """Returns (ok: bool, reason: str). Centralizes all accept-time gates:
       1. Quest must exist.
       2. No existing active row.
       3. Repeat rules (one-shot, repeatable, daily) per status history.
       4. Chain prerequisite — predecessor must be completed.
       5. Per-skill level prereqs — each checked independently.
    Admins bypass #4 and #5 only (rules 2-3 still apply: an admin can't
    hold two active rows of the same quest)."""
    q = _quest_def(quest_id)
    if not q:
        return (False, f"Unknown quest: {quest_id}")
    pid = session["id"]
    # 2: no existing active row
    if _quest_active_row(conn, pid, quest_id) is not None:
        return (False, "Quest already in your log.")
    # 3: re-acceptance rules
    completed_count = _quest_completed_count(conn, pid, quest_id)
    if completed_count > 0:
        if bool(q.get("repeatable", False)):
            pass   # repeatable — fine to re-accept
        elif bool(q.get("daily", False)):
            last = _quest_last_completion(conn, pid, quest_id)
            if _is_same_utc_day(last, time.time()):
                return (False, "Daily quest already done today.")
        else:
            return (False, "Quest already completed.")
    admin = _is_admin(session)
    if not admin:
        # 4: chain prereq
        prereq = _QUEST_PREREQS.get(quest_id, "")
        if prereq:
            completed_ids = _quest_player_completed_ids(conn, pid)
            if prereq not in completed_ids:
                return (False, "You haven't finished the prerequisite quest.")
        # 5: per-skill levels (independent checks)
        skill_levels = _player_skill_levels(pid)
        for skill, need in q.get("required", {}).items():
            have = int(skill_levels.get(str(skill), 0))
            if have < int(need):
                return (False, f"Requires {skill.capitalize()} level {int(need)}.")
    return (True, "")


def _initial_progress_for(quest_id: str) -> str:
    """All objectives start at 0 — stored as a JSON dict keyed by objective
    index. Index keys (not target_id keys) so a quest with two of the same
    target stays unambiguous."""
    q = _quest_def(quest_id)
    if not q:
        return "{}"
    objs = q.get("objectives", [])
    return json.dumps({str(i): 0 for i in range(len(objs))})


def _is_quest_complete(quest_id: str, progress: dict) -> bool:
    """True if every objective's progress >= its quantity."""
    q = _quest_def(quest_id)
    if not q:
        return False
    objs = q.get("objectives", [])
    for i, obj in enumerate(objs):
        need = int(obj.get("quantity", 1))
        have = int(progress.get(str(i), 0))
        if have < need:
            return False
    return True


def _quest_state_snapshot(conn, player_id: str) -> dict:
    """Build the {active: [...], completed_ids: [...], offered: [...]}
    payload sent to the client on login and after every quest mutation.
    `offered` is the union of currently-acceptable quest_ids — what the
    client uses to draw `!` markers on NPCs."""
    active_rows = conn.execute(
        "SELECT quest_id, progress, accepted_at FROM quests "
        "WHERE player_id=? AND status='active'",
        (player_id,)).fetchall()
    active = []
    for r in active_rows:
        try:
            prog = json.loads(r["progress"] or "{}")
        except Exception:
            prog = {}
        active.append({
            "quest_id":    str(r["quest_id"]),
            "progress":    prog,
            "accepted_at": float(r["accepted_at"]),
        })
    completed_ids = _quest_player_completed_ids(conn, player_id)
    completion_counts = {}
    for cid in completed_ids:
        completion_counts[cid] = completion_counts.get(cid, 0) + 1
    # Recompute the per-id "completion count" by actually re-grouping.
    # (The list contains distincts, but we want true counts for daily/repeat
    # display in the QuestLog "completed N times" line.)
    rows = conn.execute(
        "SELECT quest_id, COUNT(*) AS c FROM quests "
        "WHERE player_id=? AND status='completed' GROUP BY quest_id",
        (player_id,)).fetchall()
    completion_counts = {str(r["quest_id"]): int(r["c"]) for r in rows}
    return {
        "active":            active,
        "completed_ids":     completed_ids,
        "completion_counts": completion_counts,
    }


async def _push_quest_state(ws, session: dict) -> None:
    """Push a fresh snapshot to one client. Called after accept / complete /
    abandon / progress changes."""
    with _db() as conn:
        snap = _quest_state_snapshot(conn, session["id"])
    await _send(ws, {"type": "quest_state", **snap})


def _quest_state_snapshot_safe(player_id: str) -> dict:
    """Connection-less wrapper for callers (e.g. login_ok payload assembly)
    that don't already hold a connection. Returns the same shape as
    _quest_state_snapshot. Best-effort: returns an empty snapshot on any
    DB failure rather than aborting login."""
    try:
        with _db() as conn:
            return _quest_state_snapshot(conn, player_id)
    except Exception as e:
        print(f"[quest] snapshot for {player_id} failed: {e}")
        return {"active": [], "completed_ids": [], "completion_counts": {}}


async def _handle_quest_accept(ws, session: dict, msg: dict) -> None:
    quest_id = str(msg.get("quest_id", "")).strip()
    if not quest_id:
        return
    with _db() as conn:
        ok, reason = _quest_can_accept(conn, session, quest_id)
        if not ok:
            await _send(ws, {"type": "chat", "username": "Quests", "text": reason})
            return
        now = time.time()
        conn.execute(
            "INSERT INTO quests (player_id, quest_id, status, progress, "
            "accepted_at, completed_at) VALUES (?, ?, 'active', ?, ?, NULL)",
            (session["id"], quest_id, _initial_progress_for(quest_id), now))
        conn.commit()
    print(f"[quest] {session['username']} accepted {quest_id}")
    await _push_quest_state(ws, session)


async def _handle_quest_abandon(ws, session: dict, msg: dict) -> None:
    """Drop an active quest. Progress is fully erased — the row is DELETED
    (not marked failed) so the player can re-accept and start from 0 with
    no partial credit carried over."""
    quest_id = str(msg.get("quest_id", "")).strip()
    if not quest_id:
        return
    with _db() as conn:
        cur = conn.execute(
            "DELETE FROM quests WHERE player_id=? AND quest_id=? AND status='active'",
            (session["id"], quest_id))
        conn.commit()
        if cur.rowcount == 0:
            return
    print(f"[quest] {session['username']} abandoned {quest_id}")
    await _push_quest_state(ws, session)


def _quest_grant_rewards(conn, session: dict, quest_id: str,
                         prior_completion_count: int) -> dict:
    """Apply rewards to the player's inventory + gold + skill XP. Returns a
    summary dict the caller pushes to the client for UI feedback.
    Boss-repeat rule: when (boss AND repeatable AND prior_count >= 1),
    gold and items are stripped — only XP is granted."""
    q = _quest_def(quest_id)
    if not q:
        return {}
    rewards = q.get("rewards", {})
    pid = session["id"]
    row = conn.execute(
        "SELECT gold, inventory, skill_xp FROM players WHERE id=?",
        (pid,)).fetchone()
    if row is None:
        return {}
    gold = int(row["gold"] or 0)
    try:
        inv = json.loads(row["inventory"] or "[]")
    except Exception:
        inv = []
    try:
        skill_xp = json.loads(row["skill_xp"] or "{}")
    except Exception:
        skill_xp = {}

    diminished = (bool(q.get("boss", False))
                  and bool(q.get("repeatable", False))
                  and prior_completion_count >= 1)
    granted_gold = 0
    granted_items = []
    if not diminished:
        granted_gold = int(rewards.get("gold", 0))
        gold += granted_gold
        for it in rewards.get("items", []):
            if not isinstance(it, dict):
                continue
            iid = str(it.get("id", ""))
            if not iid:
                continue
            qty = int(it.get("qty", 1))
            color = it.get("color", _color_for_item(iid))
            added = _inv_add_qty(inv, iid, str(it.get("name", iid)), qty, color)
            if added > 0:
                granted_items.append({"id": iid, "qty": added})
    # XP is always granted.
    granted_xp = {}
    for skill, amount in rewards.get("xp", {}).items():
        try:
            n = int(amount)
        except (TypeError, ValueError):
            continue
        skill_xp[str(skill)] = int(skill_xp.get(str(skill), 0)) + n
        granted_xp[str(skill)] = n

    conn.execute(
        "UPDATE players SET gold=?, inventory=?, skill_xp=? WHERE id=?",
        (gold, json.dumps(inv), json.dumps(skill_xp), pid))
    session["inventory"] = inv
    return {
        "gold":        granted_gold,
        "new_gold":    gold,
        "items":       granted_items,
        "xp":          granted_xp,
        "diminished":  diminished,
        "new_inv":     inv,
    }


async def _handle_quest_complete(ws, session: dict, msg: dict) -> None:
    """Player turned in a completed quest at the giver NPC. Validates the
    active row exists, all objectives are filled, then atomically marks the
    row completed, applies rewards, and pushes updated state."""
    quest_id = str(msg.get("quest_id", "")).strip()
    if not quest_id:
        return
    q = _quest_def(quest_id)
    if not q:
        return
    with _db() as conn:
        row = _quest_active_row(conn, session["id"], quest_id)
        if row is None:
            await _send(ws, {"type": "chat", "username": "Quests",
                             "text": "You don't have that quest."})
            return
        try:
            progress = json.loads(row["progress"] or "{}")
        except Exception:
            progress = {}
        if not _is_quest_complete(quest_id, progress):
            await _send(ws, {"type": "chat", "username": "Quests",
                             "text": "Objectives not yet complete."})
            return
        prior = _quest_completed_count(conn, session["id"], quest_id)
        now = time.time()
        # Mark this row completed; PK includes accepted_at so this row is
        # the unique active one we matched on.
        conn.execute(
            "UPDATE quests SET status='completed', completed_at=? "
            "WHERE player_id=? AND quest_id=? AND accepted_at=?",
            (now, session["id"], quest_id, float(row["accepted_at"])))
        result = _quest_grant_rewards(conn, session, quest_id, prior)
        conn.commit()
    # Push reward feedback to the client.
    if result:
        if result.get("new_inv") is not None:
            await _send(ws, {"type": "admin_inventory_set",
                             "inventory": result["new_inv"]})
        await _send(ws, {"type": "gold_set", "gold": int(result.get("new_gold", 0))})
        for skill, amount in result.get("xp", {}).items():
            await _send(ws, {"type": "xp_gained", "skill": skill, "amount": amount})
        # Chat summary.
        bits = []
        if result.get("gold", 0) > 0:
            bits.append(f"{result['gold']}g")
        for it in result.get("items", []):
            bits.append(f"{it['qty']}× {it['id']}")
        xp_bits = [f"{n} {s} XP" for s, n in result.get("xp", {}).items()]
        bits.extend(xp_bits)
        suffix = ""
        if result.get("diminished"):
            suffix = "  (boss repeat: XP only)"
        await _send(ws, {"type": "chat", "username": "Quests",
                         "text": f"« {q['title']} — Rewards: "
                                 + ", ".join(bits) + suffix})
    print(f"[quest] {session['username']} completed {quest_id} "
          f"(prior={prior}, diminished={result.get('diminished', False)})")
    await _push_quest_state(ws, session)


def _quest_progress(player_id: str, obj_type: str, target_id: str,
                    count: int = 1) -> bool:
    """Bumps progress on every active quest objective matching (obj_type,
    target_id). Returns True if any row was modified — caller pushes a
    fresh quest_state to the client on True. Safe to call from any
    progress hook (kill / gather / talk)."""
    if count <= 0 or not target_id:
        return False
    changed = False
    with _db() as conn:
        active = conn.execute(
            "SELECT quest_id, accepted_at, progress FROM quests "
            "WHERE player_id=? AND status='active'",
            (player_id,)).fetchall()
        for r in active:
            qid = str(r["quest_id"])
            q = _quest_def(qid)
            if not q:
                continue
            try:
                progress = json.loads(r["progress"] or "{}")
            except Exception:
                progress = {}
            row_changed = False
            for i, obj in enumerate(q.get("objectives", [])):
                if str(obj.get("type")) != obj_type:
                    continue
                if str(obj.get("target_id")) != target_id:
                    continue
                need = int(obj.get("quantity", 1))
                have = int(progress.get(str(i), 0))
                if have >= need:
                    continue
                progress[str(i)] = min(need, have + count)
                row_changed = True
            if row_changed:
                conn.execute(
                    "UPDATE quests SET progress=? "
                    "WHERE player_id=? AND quest_id=? AND accepted_at=?",
                    (json.dumps(progress), player_id, qid, float(r["accepted_at"])))
                changed = True
        if changed:
            conn.commit()
    return changed


async def _push_quest_state_if_changed(ws, session: dict, changed: bool) -> None:
    if changed:
        await _push_quest_state(ws, session)


async def _handle_quest_talk(ws, session: dict, msg: dict) -> None:
    """Client fires this when the player talks to an NPC — used to advance
    `talk` objectives. Server validates only that the NPC name is non-empty;
    we don't check distance here because the dialogue path already gates on
    proximity client-side."""
    npc_name = str(msg.get("npc_name", "")).strip()
    if not npc_name:
        return
    changed = _quest_progress(session["id"], "talk", npc_name, 1)
    await _push_quest_state_if_changed(ws, session, changed)





async def _handle_player_died(ws, session: dict, msg: dict) -> None:
    """Death drop pipeline. Server is authoritative for what's lost:
      • Sort inventory by ItemPrices.price_for descending.
      • Keep the 4 highest-value entries; drop everything else as world
        LootDrops scattered around the death position so other players can
        see and pick them up.
      • Subtract 25% of current gold (rounded down) and spawn a server-
        tracked gold pile at death position so anyone nearby can claim it.
    Pushes the dying client a fresh inventory + gold so its UI reconciles."""
    x = float(msg.get("x", session.get("x", 0.0)))
    y = float(msg.get("y", session.get("y", 0.0)))
    with _db() as conn:
        row = conn.execute(
            "SELECT inventory, gold FROM players WHERE id=?",
            (session["id"],)).fetchone()
        if row is None:
            return
        inv: list = json.loads(row["inventory"] or "[]")
        gold = int(row["gold"] or 0)
        # Rank inventory entries by price_for; keep top 4, drop the rest.
        # Tie-break with stack qty so a 50-arrow stack with the same unit
        # price as a single item still floats above the single.
        indexed = []
        for i, it in enumerate(inv):
            if not isinstance(it, dict):
                continue
            iid = str(it.get("id", ""))
            qty = int(it.get("qty", 1))
            price = _base_price_for(iid)
            indexed.append((price * qty, price, i, it))
        indexed.sort(key=lambda t: (t[0], t[1]), reverse=True)
        keep_ids = {t[2] for t in indexed[:4]}
        kept: list = []
        dropped: list = []
        for i, it in enumerate(inv):
            if i in keep_ids:
                kept.append(it)
            else:
                dropped.append(it)
        new_gold = int(gold * 0.75)
        gold_lost = gold - new_gold
        conn.execute(
            "UPDATE players SET inventory=?, gold=? WHERE id=?",
            (json.dumps(kept), new_gold, session["id"]))
        conn.commit()
    session["inventory"] = kept
    # Broadcast each dropped item as a world LootDrop. Small angular jitter
    # around the death position so a 28-slot dump doesn't stack on a single
    # pixel. exclude_ws=None so the dying client also sees its own drops
    # (the client did NOT pre-spawn anything in this flow — the server is
    # the single source of truth for death drops).
    import math as _math, random as _random
    for it in dropped:
        if not isinstance(it, dict):
            continue
        iid = str(it.get("id", ""))
        if not iid:
            continue
        a = _random.uniform(0.0, 2.0 * _math.pi)
        r = _random.uniform(8.0, 32.0)
        dx = x + _math.cos(a) * r
        dy = y + _math.sin(a) * r
        _broadcast_near(x, y, {
            "type": "player_drop_spawned",
            "item_id": iid,
            "item_name": str(it.get("name", iid)),
            "qty": int(it.get("qty", 1)),
            "color": it.get("color", [0.7, 0.7, 0.7, 1.0]),
            "x": dx, "y": dy,
        })
    if gold_lost > 0:
        _spawn_gold_pile(x, y, gold_lost)
    # Reconcile the dying client's UI.
    await _send(ws, {"type": "admin_inventory_set", "inventory": kept})
    await _send(ws, {"type": "gold_set", "gold": new_gold})
    print(f"[death] {session['username']} died at ({x:.0f},{y:.0f}) — "
          f"dropped {len(dropped)} items + {gold_lost}g pile")


async def _handle_player_drop(ws, session: dict, msg: dict) -> None:
    """Player right-clicked an inventory item and chose Drop. Validate the
    item is actually held server-side (so a tampered client can't conjure
    drops out of thin air), remove it from the persisted inventory, and
    broadcast a player_drop_spawned to OTHER nearby clients so the world
    pickup is visible to everyone. The dropping client already spawned its
    own LootDrop locally for instant feedback."""
    item_id   = str(msg.get("item_id", "")).strip()
    item_name = str(msg.get("item_name", ""))
    qty       = max(1, int(msg.get("qty", 1)))
    if not item_id:
        return
    x = float(msg.get("x", session.get("x", 0.0)))
    y = float(msg.get("y", session.get("y", 0.0)))
    color = msg.get("color", [0.7, 0.7, 0.7, 1.0])
    with _db() as conn:
        row = conn.execute(
            "SELECT inventory FROM players WHERE id=?",
            (session["id"],)).fetchone()
        inv = json.loads(row["inventory"] or "[]") if row else []
        removed = _inv_take_qty(inv, item_id, qty)
        if removed <= 0:
            return
        conn.execute("UPDATE players SET inventory=? WHERE id=?",
                     (json.dumps(inv), session["id"]))
        conn.commit()
    _broadcast_near(x, y, {
        "type": "player_drop_spawned",
        "item_id": item_id, "item_name": item_name,
        "qty": removed, "color": color, "x": x, "y": y,
    }, exclude_ws=ws)
    print(f"[drop] {session['username']} dropped {removed}x {item_id} at ({x:.0f},{y:.0f})")


def _broadcast_near(x: float, y: float, msg: dict, exclude_ws=None,
                    radius: float = INTEREST_RADIUS) -> None:
    data = json.dumps(msg)
    r2 = radius * radius
    for ws, s in list(sessions.items()):
        if ws is exclude_ws:
            continue
        dx = s["x"] - x
        dy = s["y"] - y
        if dx * dx + dy * dy <= r2:
            asyncio.ensure_future(_safe_send(ws, data))


async def _handle_gather_request(ws, session: dict, msg: dict) -> None:
    eid = str(msg.get("id", ""))
    if not eid:
        return
    x = float(msg.get("x", session["x"]))
    y = float(msg.get("y", session["y"]))
    now = time.time()
    st = nodes_state.get(eid)
    if st is not None:
        if st["depleted_until"] > now:
            await _send(ws, {"type": "gather_busy", "id": eid})
            return
        if st["lock"] is not None and st["lock"] != session["id"] and _is_online(st["lock"]):
            await _send(ws, {"type": "gather_busy", "id": eid})
            return
    # Lock it to this player.
    nodes_state[eid] = {"x": x, "y": y, "depleted_until": 0.0, "lock": session["id"]}
    await _send(ws, {"type": "gather_grant", "id": eid})
    _broadcast_near(x, y, {"type": "node_locked", "id": eid, "x": x, "y": y,
                           "username": session["username"]}, exclude_ws=ws)


async def _handle_gather_complete(ws, session: dict, msg: dict) -> None:
    eid = str(msg.get("id", ""))
    st = nodes_state.get(eid)
    if st is None or st["lock"] != session["id"]:
        return  # not the locking player — ignore
    regen = max(1.0, float(msg.get("regen", 30.0)))
    now = time.time()
    st["lock"] = None
    st["depleted_until"] = now + regen
    _broadcast_near(st["x"], st["y"],
                    {"type": "node_depleted", "id": eid, "respawn_in": regen},
                    exclude_ws=ws)
    # Quest progress — the client tells us which item dropped from this
    # node so we can credit gather-type objectives.
    drop_item = str(msg.get("drop_item", "")).strip()
    if drop_item:
        if _quest_progress(session["id"], "gather", drop_item, 1):
            await _push_quest_state(ws, session)


async def _handle_gather_release(ws, session: dict, msg: dict) -> None:
    eid = str(msg.get("id", ""))
    st = nodes_state.get(eid)
    if st is None or st["lock"] != session["id"]:
        return
    st["lock"] = None
    _broadcast_near(st["x"], st["y"], {"type": "node_unlocked", "id": eid})
    if st["depleted_until"] <= time.time():
        nodes_state.pop(eid, None)  # back to default — free the entry


async def _handle_node_states(ws, session: dict, msg: dict) -> None:
    ids = msg.get("ids", [])
    if not isinstance(ids, list):
        return
    now = time.time()
    out = []
    for raw_id in ids:
        eid = str(raw_id)
        st = nodes_state.get(eid)
        if st is None:
            continue
        depleted_in = max(0.0, st["depleted_until"] - now)
        locked = st["lock"] is not None and st["lock"] != session["id"] and _is_online(st["lock"])
        if depleted_in <= 0.0 and not locked:
            continue  # available — client default is fine
        locker = ""
        if locked:
            lws = _ws_for_player(st["lock"])
            if lws is not None:
                locker = sessions[lws]["username"]
        out.append({"id": eid, "depleted_in": depleted_in, "locked_by": locker})
    await _send(ws, {"type": "node_states", "nodes": out})


def _clear_player_locks(player_id: str) -> None:
    """On disconnect, drop any gather locks the player held so nodes don't stick."""
    for eid, st in list(nodes_state.items()):
        if st["lock"] == player_id:
            st["lock"] = None
            _broadcast_near(st["x"], st["y"], {"type": "node_unlocked", "id": eid})
            if st["depleted_until"] <= time.time():
                nodes_state.pop(eid, None)


# ── Shared combat (monsters) ──────────────────────────────────────────────────
# Server owns each monster's HP, the set of participants (max 5), and per-player
# damage so it can split XP and award loot to the top-damage dealer on death.
# id -> {x,y,max_hp,hp,alive,participants:[pid],damage:{pid:int},xp_reward,respawn_until}
monsters_state: dict = {}

# Dirty set for the monster_state SQLite mirror. Mutations to the dict above
# add the monster_id here; a 5s loop drains the set and UPSERTs the rows.
_monster_state_dirty: set = set()

MONSTER_RESPAWN = 45.0
MAX_FIGHTERS    = 5


def _mark_monster_dirty(mid: str) -> None:
    """Tag a monster for persistence flush. O(1) — set membership."""
    if mid:
        _monster_state_dirty.add(mid)


def _load_monster_state_from_db() -> None:
    """Rehydrate `monsters_state` from the SQLite mirror at boot. Runs AFTER
    _purge_orphan_monster_state so anything we read is guaranteed valid.
    Combat/aggro fields stay transient — re-seeded on the next monster_join."""
    try:
        with _db() as conn:
            rows = conn.execute(
                "SELECT monster_id, monster_type, level, hostile, is_boss, state, "
                "home_x, home_y, pos_x, pos_y, hp, max_hp, alive "
                "FROM monster_state").fetchall()
        now = time.time()
        for r in rows:
            mid = str(r["monster_id"])
            mtype = str(r["monster_type"])
            lvl = int(r["level"])
            is_boss = bool(int(r["is_boss"] or 0))
            # Non-boss monsters always boot at full HP (partial-persist rule).
            db_max_hp = int(r["max_hp"])
            hp = int(r["hp"]) if is_boss else db_max_hp
            # Combat fields that aren't persisted in monster_state — attack,
            # xp_reward, respawn_until. Seeded from heuristics here so the AI
            # tick can read them safely. They get OVERWRITTEN with the real
            # client-supplied values on the next monster_join from any player.
            monsters_state[mid] = {
                "x": float(r["pos_x"]), "y": float(r["pos_y"]),
                "home_x": float(r["home_x"]), "home_y": float(r["home_y"]),
                "monster_type": mtype,
                "level": lvl,
                "hostile": bool(int(r["hostile"] or 0)),
                "is_boss": is_boss,
                "state": str(r["state"] or "idle"),
                "target_player": None,
                "max_hp": db_max_hp,
                "hp": hp,
                "alive": bool(int(r["alive"] or 1)),
                "participants": [], "damage": {},
                "last_attack_at": 0.0,
                "next_wander_at": now,   # rolled forward on next AI tick
                "wander_x": float(r["pos_x"]),
                "wander_y": float(r["pos_y"]),
                "aggro_radius": _aggro_radius_for(lvl),
                "passive_flee": _default_passive_flee(mtype),
                "size": _default_size(mtype),
                # ── Combat field defaults (NOT in monster_state schema) ──
                "attack":        _heuristic_attack(lvl),
                "xp_reward":     max(1, lvl * 4),
                "respawn_until": 0.0,
            }
        if rows:
            print(f"[boot] loaded {len(rows)} monster_state row(s) from SQLite")
    except Exception as e:
        print(f"[boot] monster_state load failed: {e}")


def _flush_monster_state() -> int:
    """Drain _monster_state_dirty and UPSERT each entry. Returns row count."""
    if not _monster_state_dirty:
        return 0
    ids = list(_monster_state_dirty)
    _monster_state_dirty.clear()
    now = time.time()
    wrote = 0
    try:
        with _db() as conn:
            for mid in ids:
                st = monsters_state.get(mid)
                if st is None or "home_x" not in st:
                    # Was removed or never AI-seeded — drop from table too.
                    conn.execute(
                        "DELETE FROM monster_state WHERE monster_id=?", (mid,))
                    continue
                mtype = str(st.get("monster_type", ""))
                is_boss = 1 if mtype in _BOSS_MONSTER_TYPES else 0
                conn.execute(
                    "INSERT OR REPLACE INTO monster_state "
                    "(monster_id, monster_type, level, hostile, is_boss, "
                    " state, home_x, home_y, pos_x, pos_y, hp, max_hp, alive, "
                    " last_updated) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (mid, mtype, int(st.get("level", 1)),
                     1 if st.get("hostile") else 0,
                     is_boss,
                     str(st.get("state", "idle")),
                     float(st["home_x"]), float(st["home_y"]),
                     float(st.get("x", st["home_x"])),
                     float(st.get("y", st["home_y"])),
                     int(st.get("hp", st.get("max_hp", 1))),
                     int(st.get("max_hp", 1)),
                     1 if st.get("alive", True) else 0,
                     now))
                wrote += 1
            conn.commit()
    except Exception as e:
        print(f"[monster_state] flush failed: {e}")
    return wrote


async def _monster_state_flush_loop() -> None:
    """5s batched flush. Caps write rate to 2 transactions per monster per
    10s — far below the AI tick rate (0.5s). Drift between flushes is
    acceptable; a server crash loses at most 5s of position state per
    monster, and chunk-deterministic IDs mean nothing is permanently lost."""
    while True:
        await asyncio.sleep(5.0)
        _flush_monster_state()

# ── Monster AI tuning (server-side wander / aggro / chase / attack) ───────────
# Tick rate sets the server-side cadence AND the client-side tween duration in
# Stage 2. Keep them equal so movement looks smooth (no perceived jitter).
MONSTER_AI_TICK         = 0.5
# Movement speeds reduced 40% from the original 30/45 — monsters now amble
# rather than glide. Combined with the much longer wander intervals below,
# the world feels less like a treadmill of constantly-moving enemies.
MONSTER_WALK_SPEED      = 18.0    # px/s, idle/wander (was 30.0)
MONSTER_CHASE_SPEED     = 27.0    # px/s, aggro chase (was 45.0)
MONSTER_AGGRO_BASE      = 120.0   # px, level-1 monsters' aggro radius
MONSTER_AGGRO_PER_LV    = 2.0     # px per level on top of the base
MONSTER_AGGRO_MIN       = 80.0    # floor, even for level 1
MONSTER_AGGRO_MAX       = 220.0   # cap, even for level 99
MONSTER_DE_AGGRO        = 250.0   # break aggro if target > this from monster home
MONSTER_HOME_LEASH      = 300.0   # snap monster back home if it strays this far
MONSTER_WANDER_RADIUS   = 80.0    # px around home for wander targets
# Idle-between-movements timer. Each monster picks a random value from this
# range after arriving at a wander target; with random.uniform(15,45) per
# monster the cadences naturally stagger so a cluster never moves in lockstep.
MONSTER_WANDER_INTERVAL = (15.0, 45.0)   # min/max seconds between wander picks
# Passive types (chickens, rats) sit still even more than the rest — they
# spend most of their life pecking/sniffing in place rather than ambling.
MONSTER_WANDER_INTERVAL_PASSIVE = (30.0, 90.0)
MONSTER_ATTACK_RANGE    = 20.0    # tightened from 40 — monsters need to be
                                  # actually next to you to hit, with `size`
                                  # added on top per body radius (see below).
MONSTER_ATTACK_COOLDOWN = 2.5

# Per-monster body radius added to ATTACK_RANGE so a giant doesn't need to
# overlap a player's centre to land a hit. Default = medium for anything not
# listed (matches goblin/wolf-class monsters).
_MONSTER_SIZE_DEFAULT = 18
_MONSTER_SIZES = {
    # small (12) — passive critters
    "chicken": 12, "rat": 12,
    # medium (18) — covered by the default; listed only when we want explicit
    # override that differs from default.
    # large (24)
    "bear": 24, "elder_bear": 24, "troll": 24, "ancient_troll": 24,
    "draugr": 24, "ice_draugr": 24, "shadow_draugr": 24,
    "death_knight": 24, "spectral_warrior": 24, "lava_crawler": 24,
    # giant (30)
    "frost_giant": 30, "fire_giant": 30, "nidhogg": 30,
    "frost_wyrm": 30, "magma_elemental": 30,
}


def _default_size(monster_type: str) -> int:
    return _MONSTER_SIZES.get(monster_type, _MONSTER_SIZE_DEFAULT)

# Type-default hostility. Passive types never aggro on proximity; flee types
# also run from attackers (Stage 3 wires the flee response). Anything not in
# these sets defaults hostile=True / passive_flee=False.
_PASSIVE_MONSTER_TYPES = {"chicken", "rat"}
_FLEEING_MONSTER_TYPES = {"chicken", "rat"}


def _default_hostile(monster_type: str) -> bool:
    return monster_type not in _PASSIVE_MONSTER_TYPES


def _default_passive_flee(monster_type: str) -> bool:
    return monster_type in _FLEEING_MONSTER_TYPES


def _wander_interval_for(monster_type: str) -> tuple:
    """Idle-between-wanders range for this monster type. Passive critters
    (chicken/rat) sit still much longer than hostile mobs — they peck/sniff
    in place far more than they move. Other types use the standard 15-45s."""
    if monster_type in _PASSIVE_MONSTER_TYPES:
        return MONSTER_WANDER_INTERVAL_PASSIVE
    return MONSTER_WANDER_INTERVAL


def _aggro_radius_for(level: int) -> float:
    raw = MONSTER_AGGRO_BASE + max(0, level) * MONSTER_AGGRO_PER_LV
    return max(MONSTER_AGGRO_MIN, min(MONSTER_AGGRO_MAX, raw))


def _step_toward(cx: float, cy: float, tx: float, ty: float,
                 max_step: float) -> tuple:
    """Move (cx, cy) up to `max_step` pixels toward (tx, ty). Snaps to the
    target if within step distance. Returns (new_x, new_y)."""
    dx = tx - cx
    dy = ty - cy
    d2 = dx * dx + dy * dy
    if d2 == 0.0 or d2 <= max_step * max_step:
        return tx, ty
    d = d2 ** 0.5
    return cx + dx / d * max_step, cy + dy / d * max_step


def _find_session_by_username(uname: str):
    """Case-insensitive lookup. Returns the session dict or None."""
    if not uname:
        return None
    target = uname.lower()
    for s in sessions.values():
        if s["username"].lower() == target:
            return s
    return None


def _seed_monster_ai(st: dict, home_x: float, home_y: float,
                     monster_type: str, level: int, attack: int,
                     fresh: bool = True) -> None:
    """Initialize the AI fields on a monsters_state entry. Called from
    _handle_monster_join when a fresh combat session attaches to a monster
    that hasn't run yet, AND from _handle_admin_place so admin-spawned
    monsters start wandering immediately without waiting for a client to
    engage them. The function only sets AI fields — combat fields (hp,
    max_hp, participants, etc.) must already be on the entry.

    `fresh=True` (default) is the first-registration path and zeroes
    `last_attack_at` so the monster can fire its first attack as soon as
    cooldown allows. `fresh=False` is the legacy-bootstrap path called when
    an existing entry was missing AI fields — in that case we deliberately
    DO NOT touch `last_attack_at` so a player engaging an already-aggroed
    monster doesn't grant it a free immediate hit by resetting cooldown."""
    now = time.time()
    st["home_x"] = home_x
    st["home_y"] = home_y
    st["monster_type"] = monster_type
    st["level"] = level
    st["attack"] = attack
    st["state"] = "idle"
    st["target_player"] = None
    if fresh or "last_attack_at" not in st:
        st["last_attack_at"] = 0.0
    # Initial timer offset is sampled from this monster's type-specific range
    # AND additionally jittered on first seed so a chunk of fresh-spawned
    # monsters doesn't all fire its first wander on the same tick.
    _wint = _wander_interval_for(monster_type)
    st["next_wander_at"] = now + random.uniform(*_wint)
    st["wander_x"] = home_x
    st["wander_y"] = home_y
    st["aggro_radius"] = _aggro_radius_for(level)
    st["hostile"] = _default_hostile(monster_type)
    st["passive_flee"] = _default_passive_flee(monster_type)
    st["size"] = _default_size(monster_type)
    st["is_boss"] = monster_type in _BOSS_MONSTER_TYPES
    # Persist the fresh AI state — the next batched flush writes the row.
    # Caller passes the monster_id via the parent scope, so we look it up by
    # identity instead of name: any caller that already has the id should
    # invoke _mark_monster_dirty(mid) themselves; this helper can't tell.


def _is_ai_seeded(st: dict) -> bool:
    """True once _seed_monster_ai has run on this entry. Used to short-
    circuit re-init in monster_join so a client chunk-load doesn't reset
    an already-running AI (admin-placed, or seeded earlier this session)
    back to idle-at-home."""
    return "state" in st


def _heuristic_attack(level: int) -> int:
    """Damage value for admin-placed monsters that haven't been engaged
    yet — their real attack stat lives in Monster.gd._apply_type_stats
    and only arrives on the client's monster_join. Used as a stand-in so
    the AI's monster_attack broadcast carries a sensible number; gets
    overwritten only if the user wires real stats through the catalog."""
    return max(2, level // 3 + 1)


def _heuristic_max_hp(level: int) -> int:
    """Placeholder hp for admin-placed monsters before a client's
    monster_join supplies the real value. monster_join's existing-entry
    branch (below) overwrites this when it arrives."""
    return max(5, level * 4 + 2)


async def _handle_monster_join(ws, session: dict, msg: dict) -> None:
    mid = str(msg.get("id", ""))
    if not mid:
        return
    x = float(msg.get("x", session["x"]))
    y = float(msg.get("y", session["y"]))
    max_hp = max(1, int(msg.get("max_hp", 10)))
    xp_reward = max(1, int(msg.get("xp_reward", 1)))
    # Stage 1 AI seed inputs — backward compatible: clients that don't send
    # these fall back to a default-passive "rat"-ish entry. With the client
    # extension below, monster_type/level/attack come from the actual
    # Monster.gd stats so hostile defaults and aggro radius scale correctly.
    monster_type = str(msg.get("monster_type", "rat"))
    level        = max(1, int(msg.get("level", 1)))
    attack       = max(0, int(msg.get("attack", 2)))
    now = time.time()
    st = monsters_state.get(mid)
    if st is None:
        # Fresh registration — seed combat fields + AI fields together.
        st = {
            # Existing combat fields — untouched contract for monster_damage /
            # monster_died / monster_states / monster_leave.
            "x": x, "y": y,
            "max_hp": max_hp, "hp": max_hp,
            "alive": True,
            "participants": [], "damage": {},
            "xp_reward": xp_reward,
            "respawn_until": 0.0,
        }
        _seed_monster_ai(st, x, y, monster_type, level, attack)
        monsters_state[mid] = st
        _mark_monster_dirty(mid)
    else:
        # Existing entry — could be an admin-placed monster whose AI is
        # already running, or a same-session re-join from another player.
        # By spec: update combat fields only (hp/max_hp/xp_reward) and never
        # touch home_pos / state / target / hostile / passive_flee. This
        # keeps a running AI monster stable across client chunk reloads.
        if not _is_ai_seeded(st):
            # Pre-Stage-1 legacy entry without AI fields — bootstrap them
            # now using the join's stats (rare; safety net for sessions
            # that span the deploy of this code). fresh=False so we don't
            # zero last_attack_at on what is technically a subsequent join.
            _seed_monster_ai(st, st.get("x", x), st.get("y", y),
                             monster_type, level, attack, fresh=False)
            _mark_monster_dirty(mid)
        # If the client is supplying real stats (max_hp > 1 / xp_reward > 1)
        # and our current values look like the admin-place placeholder,
        # upgrade to the wire-time values. hp scales proportionally so a
        # damaged-then-rejoined monster keeps the same fractional HP.
        # All st[] reads here go through .get() with sane defaults so a
        # legacy entry loaded from SQLite (which doesn't persist combat
        # fields) doesn't KeyError before _handle_monster_join can fill it.
        cur_max_hp = int(st.get("max_hp", 0))
        cur_hp     = int(st.get("hp", 0))
        cur_xp     = int(st.get("xp_reward", 0))
        if max_hp > 0 and cur_max_hp != max_hp:
            ratio = float(cur_hp) / float(max(1, cur_max_hp)) if cur_max_hp > 0 else 1.0
            st["max_hp"] = max_hp
            st["hp"] = max(1, int(round(max_hp * ratio)))
        if xp_reward > 0 and cur_xp != xp_reward:
            st["xp_reward"] = xp_reward
        # Defensive backfill — if any combat field is still missing after
        # the upgrade pass, use the join's value or a heuristic so the AI
        # tick can read it. Belt-and-suspenders against malformed loads.
        st.setdefault("max_hp", max(1, max_hp))
        st.setdefault("hp",     st.get("max_hp", max(1, max_hp)))
        st.setdefault("xp_reward",     max(1, xp_reward))
        st.setdefault("attack",        max(0, attack))
        st.setdefault("respawn_until", 0.0)
        st.setdefault("alive",         True)
    if not st.get("alive", True):
        await _send(ws, {"type": "monster_dead", "id": mid,
                         "respawn_in": max(0.0, st["respawn_until"] - now)})
        return
    pid = session["id"]
    if pid not in st["participants"]:
        if len(st["participants"]) >= MAX_FIGHTERS:
            await _send(ws, {"type": "monster_full", "id": mid})
            return
        st["participants"].append(pid)
        st["damage"].setdefault(pid, 0)
    await _send(ws, {"type": "monster_state", "id": mid,
                     "hp": st["hp"], "max_hp": st["max_hp"], "alive": True})


async def _handle_monster_damage(ws, session: dict, msg: dict) -> None:
    mid = str(msg.get("id", ""))
    amt = max(0, int(msg.get("amount", 0)))
    st = monsters_state.get(mid)
    if st is None or not st["alive"] or amt <= 0:
        return
    pid = session["id"]
    if pid not in st["participants"]:
        if len(st["participants"]) >= MAX_FIGHTERS:
            return
        st["participants"].append(pid)
        st["damage"].setdefault(pid, 0)
    st["hp"] = max(0, st["hp"] - amt)
    st["damage"][pid] = st["damage"].get(pid, 0) + amt
    _broadcast_near(st["x"], st["y"],
                    {"type": "monster_hit", "id": mid, "x": st["x"], "y": st["y"],
                     "amount": amt, "by": session["username"],
                     "hp": st["hp"], "max_hp": st["max_hp"]})
    if st["hp"] <= 0:
        await _monster_die(mid, st)


async def _monster_die(mid: str, st: dict) -> None:
    st["alive"] = False
    st["respawn_until"] = time.time() + MONSTER_RESPAWN
    damage_dict = st.get("damage", {})
    # Killer = top-damage dealer. Drives loot drop authority on the client.
    killer_pid = max(damage_dict, key=damage_dict.get) if damage_dict else None
    # XP eligibility — ONLY players who dealt damage, plus the warband rule.
    # World.gd sends monster_join for every chunk-streamed monster (so the
    # server knows they exist), which adds chunk-loaders to `participants`
    # without them ever engaging. We can't trust participants here; damage
    # is the only honest signal of "this player actually fought".
    damagers = [pid for pid, dmg in damage_dict.items() if int(dmg) > 0]
    # Warband rule — if 2+ players from the SAME warband dealt damage, every
    # member of that warband who joined the fight (participants list) also
    # gets full XP, including those who didn't personally swing. Solo
    # warband members fall back to the per-player default.
    warband_of: dict = {}
    with _db() as conn:
        for pid in damagers:
            wb = _clan_id_for_player(conn, pid)
            if wb:
                warband_of[pid] = wb
        warband_counts: dict = {}
        for wb in warband_of.values():
            warband_counts[wb] = warband_counts.get(wb, 0) + 1
        bonus_warbands = {wb for wb, n in warband_counts.items() if n >= 2}
        xp_recipient_pids = set(damagers)
        if bonus_warbands:
            for pid in st.get("participants", []):
                if pid in xp_recipient_pids:
                    continue
                wb = _clan_id_for_player(conn, pid)
                if wb in bonus_warbands:
                    xp_recipient_pids.add(pid)
    n = max(1, len(xp_recipient_pids))
    xp_each = max(1, st["xp_reward"] // n)
    # Resolve all three lists to usernames in one pass.
    part_names = []
    for pid in st["participants"]:
        pws = _ws_for_player(pid)
        if pws is not None:
            part_names.append(sessions[pws]["username"])
    xp_recipients = []
    for pid in xp_recipient_pids:
        pws = _ws_for_player(pid)
        if pws is not None:
            xp_recipients.append(sessions[pws]["username"])
    killer_name = ""
    if killer_pid is not None:
        kws = _ws_for_player(killer_pid)
        if kws is not None:
            killer_name = sessions[kws]["username"]
    _broadcast_near(st["x"], st["y"],
                    {"type": "monster_died", "id": mid, "killer": killer_name,
                     "xp_each": xp_each, "participants": part_names,
                     # Authoritative XP-eligible username list. Clients
                     # check membership in THIS, not in `participants`.
                     "xp_recipients": xp_recipients})
    # Phase 5 gold drop — server rolls amount + broadcasts a world pile to
    # nearby clients. First player to walk over and pick it up wins the
    # whole pile (see _handle_gold_pile_pickup). Monsters not in
    # _MONSTER_GOLD_PY drop nothing.
    mtype = str(st.get("monster_type", ""))
    gmin, gmax = _MONSTER_GOLD_PY.get(mtype, (0, 0))
    if gmax > 0:
        amount = random.randint(gmin, gmax)
        _spawn_gold_pile(st["x"], st["y"], amount)
    # Quest progress — only XP-eligible players (damagers + warband-shared)
    # get kill credit. Mirrors the XP rule so chunk-streamers aren't given
    # progress on quests they didn't actually fight for.
    for pid in xp_recipient_pids:
        if _quest_progress(pid, "kill", mtype, 1):
            pws = _ws_for_player(pid)
            if pws is not None:
                await _push_quest_state(pws, sessions[pws])
    st["participants"] = []
    st["damage"] = {}


async def _handle_monster_leave(ws, session: dict, msg: dict) -> None:
    mid = str(msg.get("id", ""))
    st = monsters_state.get(mid)
    if st is not None and session["id"] in st["participants"]:
        st["participants"].remove(session["id"])


async def _handle_monster_states(ws, session: dict, msg: dict) -> None:
    ids = msg.get("ids", [])
    if not isinstance(ids, list):
        return
    now = time.time()
    out = []
    for raw_id in ids:
        mid = str(raw_id)
        st = monsters_state.get(mid)
        if st is None:
            continue
        if st["alive"]:
            if st["hp"] < st["max_hp"]:
                out.append({"id": mid, "alive": True, "hp": st["hp"], "max_hp": st["max_hp"]})
        else:
            out.append({"id": mid, "alive": False,
                        "respawn_in": max(0.0, st["respawn_until"] - now)})
    await _send(ws, {"type": "monster_states", "nodes": out})


def _clear_player_combat(player_id: str) -> None:
    for st in monsters_state.values():
        if player_id in st["participants"]:
            st["participants"].remove(player_id)


async def _world_tick_loop() -> None:
    """Respawn depleted nodes / dead monsters and tell nearby clients."""
    while True:
        await asyncio.sleep(1.0)
        now = time.time()
        for eid, st in list(nodes_state.items()):
            if st["depleted_until"] > 0.0 and st["depleted_until"] <= now:
                _broadcast_near(st["x"], st["y"], {"type": "node_respawned", "id": eid})
                st["depleted_until"] = 0.0
                if st["lock"] is None:
                    nodes_state.pop(eid, None)
        for mid, st in list(monsters_state.items()):
            if not st["alive"] and st["respawn_until"] <= now:
                st["alive"] = True
                st["hp"] = st["max_hp"]
                st["respawn_until"] = 0.0
                st["participants"] = []
                st["damage"] = {}
                # Snap back to home on respawn so a monster that died chasing
                # a player respawns at its spawn point, not the chase end.
                if "home_x" in st:
                    st["x"] = st["home_x"]
                    st["y"] = st["home_y"]
                    st["state"] = "idle"
                    st["target_player"] = None
                    st["wander_x"] = st["home_x"]
                    st["wander_y"] = st["home_y"]
                    st["next_wander_at"] = now + random.uniform(
                        *_wander_interval_for(st.get("monster_type", "")))
                _broadcast_near(st["x"], st["y"], {"type": "monster_respawned", "id": mid})
        # Phase 5 — sweep stale or claimed gold piles. Claimed entries get
        # one extra tick of grace before GC so any in-flight clients still
        # see the gold_pile_remove broadcast that fired during the pickup.
        for pile_id, p in list(gold_piles.items()):
            if p.get("claimed"):
                del gold_piles[pile_id]
                continue
            if p["expires_at"] <= now:
                _broadcast_near(p["x"], p["y"],
                    {"type": "gold_pile_remove", "id": pile_id})
                del gold_piles[pile_id]


# ── Monster AI loop (Stage 1 — server-side wander / aggro / chase / attack) ──
# Runs every MONSTER_AI_TICK seconds. For every monster registered in
# monsters_state (i.e. that a player has engaged via monster_join), the loop
# advances its state machine: idle → wander → aggro → chase → attack. The
# existing combat handlers (monster_damage / monster_died / monster_states /
# monster_leave) are unchanged — they continue to own HP, participants, loot,
# and respawn. The AI only owns position and behavior state.
#
# At the end of each tick the loop fires:
#   - One batched monster_pos_update per client (interest-filtered)
#   - One monster_attack broadcast per attack that landed this tick
async def _monster_ai_loop() -> None:
    # Diagnostic — if you never see this line in the console, the coroutine
    # is never being awaited (gather isn't running it / main() isn't running
    # / startup crashed earlier).
    print(f"[ai_loop] started — monsters_state id={id(monsters_state)} "
          f"entries={len(monsters_state)}")
    _tick_counter = 0
    while True:
        await asyncio.sleep(MONSTER_AI_TICK)
        _tick_counter += 1
        # Light heartbeat — prints once every 60 ticks (~30s) so the log
        # confirms the loop is alive without flooding.
        if _tick_counter % 60 == 1:
            print(f"[ai_loop] tick {_tick_counter} — "
                  f"{len(monsters_state)} monsters")
        now = time.time()
        attack_msgs = []   # list of (x, y, msg) to broadcast after the tick
        for mid, st in list(monsters_state.items()):
            if not st.get("alive", True):
                continue
            if "state" not in st:
                # Pre-AI monster_state entry — skip until something re-joins it
                # and seeds the AI fields.
                continue
            _tick_monster_ai(mid, st, now, attack_msgs)
        _broadcast_monster_positions()
        for ax, ay, amsg in attack_msgs:
            _broadcast_near(ax, ay, amsg)


def _tick_monster_ai(mid: str, st: dict, now: float, attack_msgs: list) -> None:
    """One AI tick for one monster. Mutates `st` in place. Appends any
    outgoing attack broadcasts to `attack_msgs` so the caller can fire them
    once after the whole tick has settled."""
    home_x, home_y = st["home_x"], st["home_y"]
    cur_x, cur_y = st["x"], st["y"]

    # Home leash — snap-back is the safety net for any state that drags the
    # monster too far (chase de-aggro race, server tick stall, etc.).
    leash2 = MONSTER_HOME_LEASH * MONSTER_HOME_LEASH
    dx, dy = cur_x - home_x, cur_y - home_y
    if dx * dx + dy * dy > leash2:
        st["x"], st["y"] = home_x, home_y
        st["state"] = "idle"
        st["target_player"] = None
        st["wander_x"], st["wander_y"] = home_x, home_y
        st["next_wander_at"] = now + random.uniform(
            *_wander_interval_for(st.get("monster_type", "")))
        return

    # ── Aggro / chase / attack ──
    if st["state"] == "aggro":
        tgt = _find_session_by_username(st["target_player"])
        if tgt is None:
            # Target logged out or username case-changed. Drop aggro, head home.
            st["state"] = "idle"
            st["target_player"] = None
            st["wander_x"], st["wander_y"] = home_x, home_y
            st["next_wander_at"] = now
            return
        tx, ty = float(tgt.get("x", home_x)), float(tgt.get("y", home_y))
        # De-aggro if target ran outside the leash from the monster's home.
        ddx, ddy = tx - home_x, ty - home_y
        if ddx * ddx + ddy * ddy > MONSTER_DE_AGGRO * MONSTER_DE_AGGRO:
            st["state"] = "idle"
            st["target_player"] = None
            st["wander_x"], st["wander_y"] = home_x, home_y
            st["next_wander_at"] = now
            return
        # Chase: step toward target at chase speed.
        step = MONSTER_CHASE_SPEED * MONSTER_AI_TICK
        new_x, new_y = _step_toward(cur_x, cur_y, tx, ty, step)
        st["x"], st["y"] = new_x, new_y
        # Attack if in range and cooldown elapsed. Range = ATTACK_RANGE
        # (20px tight) + the monster's `size` (its body radius), so a
        # rat (12) needs to be within 32px while a nidhogg (30) reaches
        # 50px. Prevents wide-hitbox monsters phantom-striking from
        # outside their visible silhouette.
        d2 = (new_x - tx) ** 2 + (new_y - ty) ** 2
        reach = MONSTER_ATTACK_RANGE + float(st.get("size", _MONSTER_SIZE_DEFAULT))
        if d2 <= reach * reach \
                and now - st["last_attack_at"] >= MONSTER_ATTACK_COOLDOWN:
            st["last_attack_at"] = now
            attack_msgs.append((new_x, new_y, {
                "type": "monster_attack",
                "id": mid,
                "target": tgt["username"],
                "damage": int(st["attack"]),
            }))
        return

    # ── Proximity aggro trigger (hostile only) ──
    if st["hostile"]:
        radius = float(st["aggro_radius"])
        best_d2 = radius * radius
        best_target = None
        for sess in sessions.values():
            sx, sy = float(sess.get("x", 0.0)), float(sess.get("y", 0.0))
            ddx, ddy = sx - cur_x, sy - cur_y
            d2 = ddx * ddx + ddy * ddy
            if d2 < best_d2:
                best_d2 = d2
                best_target = sess
        if best_target is not None:
            st["state"] = "aggro"
            st["target_player"] = best_target["username"]
            return

    # ── Wander ──
    # The timer is the ONLY trigger that pulls a monster out of idle. The old
    # code OR'd in an "arrived ⇒ pick new target" branch which fired every
    # tick once the monster reached its target — that nullified the interval
    # entirely. With the timer as gate, a monster arriving at its wander spot
    # actually sits there for the next 15-45s before moving again.
    if now >= st.get("next_wander_at", 0.0):
        angle = random.uniform(0.0, 2.0 * math.pi)
        dist  = random.uniform(0.0, MONSTER_WANDER_RADIUS)
        st["wander_x"] = home_x + math.cos(angle) * dist
        st["wander_y"] = home_y + math.sin(angle) * dist
        st["next_wander_at"] = now + random.uniform(
            *_wander_interval_for(st.get("monster_type", "")))
        st["state"] = "wander"
    # Step toward the wander target only while actually wandering.
    if st["state"] == "wander":
        step = MONSTER_WALK_SPEED * MONSTER_AI_TICK
        new_x, new_y = _step_toward(cur_x, cur_y, st["wander_x"], st["wander_y"], step)
        st["x"], st["y"] = new_x, new_y
        if (new_x - st["wander_x"]) ** 2 + (new_y - st["wander_y"]) ** 2 < 4.0:
            st["state"] = "idle"
        # Position/state changed — flag for the next batched persistence flush.
        _mark_monster_dirty(mid)


def _broadcast_monster_positions() -> None:
    """Per-client batched monster_pos_update. One message per client per
    tick, filtered to monsters within INTEREST_RADIUS of that client's
    session position. The filter saves bandwidth for far-away monsters and
    matches the existing _broadcast_near interest model used by hits/respawn.
    Snapshot list is built once and re-filtered per client so the work is
    O(monsters + clients · monsters) per tick — fine at the current scale.
    """
    snapshots = []
    for mid, st in monsters_state.items():
        if not st.get("alive", True):
            continue
        if "state" not in st:
            continue
        snapshots.append({
            "id":     mid,
            "x":      float(st["x"]),
            "y":      float(st["y"]),
            "state":  str(st["state"]),
            "target": str(st.get("target_player") or ""),
        })
    if not snapshots:
        return
    r2 = INTEREST_RADIUS * INTEREST_RADIUS
    for ws, sess in list(sessions.items()):
        px = float(sess.get("x", 0.0))
        py = float(sess.get("y", 0.0))
        filtered = []
        for snap in snapshots:
            ddx = snap["x"] - px
            ddy = snap["y"] - py
            if ddx * ddx + ddy * ddy <= r2:
                filtered.append(snap)
        if filtered:
            payload = json.dumps({"type": "monster_pos_update",
                                  "updates": filtered})
            asyncio.ensure_future(_safe_send(ws, payload))


# ── Auto-save heartbeat ────────────────────────────────────────────────────────

async def _tile_overrides_autosave_loop() -> None:
    """Every 30s, if the in-memory overrides have changed since the last flush,
    write tile_overrides.json. Saves are debounced this way so a long paint
    session doesn't grind on disk per stroke."""
    while True:
        await asyncio.sleep(30.0)
        if tile_overrides_dirty:
            _save_tile_overrides_to_disk()


async def _autosave_loop() -> None:
    while True:
        await asyncio.sleep(60)
        for ws in list(sessions):
            await _safe_send(ws, json.dumps({"type": "request_save"}))


# ── Main connection handler ────────────────────────────────────────────────────

async def _route_message(ws, session, mtype: str, msg: dict) -> None:
    if mtype == "register":
        await _handle_register(ws, msg)
    elif mtype == "login":
        await _handle_login(ws, msg)
    elif mtype == "ping":
        await _send(ws, {"type": "pong"})
    elif session is None:
        await _send(ws, {"type": "error", "reason": "Not authenticated."})
    elif mtype == "move":
        await _handle_move(ws, session, msg)
    elif mtype == "skill_action":
        await _handle_skill_action(ws, session, msg)
    elif mtype == "save":
        await _handle_save(session, msg)
    elif mtype == "set_task_queue":
        await _handle_set_task_queue(session, msg)
    elif mtype == "set_appearance":
        await _handle_set_appearance(ws, session, msg)
    elif mtype == "lookup_player":
        await _handle_lookup_player(ws, msg)
    elif mtype == "chat":
        text = str(msg.get("text", "")).strip()[:200]
        if text:
            # Owner-only /promote and /demote — parsed server-side so they
            # never leak into global chat even if the client forgets to gate.
            if text.startswith("/promote ") or text.startswith("/demote "):
                await _handle_admin_rank_command(ws, session, text)
                return
            text = profanity.censor(text)
            _broadcast({"type": "chat",
                        "username": session["username"], "text": text})
    elif mtype == "ah_browse":
        await _handle_ah_browse(ws, msg)
    elif mtype == "ah_my_listings":
        await _handle_ah_my_listings(ws, session)
    elif mtype == "ah_list":
        await _handle_ah_list(ws, session, msg)
    elif mtype == "ah_buy":
        await _handle_ah_buy(ws, session, msg)
    elif mtype == "ah_cancel":
        await _handle_ah_cancel(ws, session, msg)
    elif mtype == "trade_request":
        await _handle_trade_request(ws, session, msg)
    elif mtype == "trade_accept":
        await _handle_trade_accept(ws, session, msg)
    elif mtype == "trade_offer":
        await _handle_trade_offer(ws, session, msg)
    elif mtype == "trade_lock":
        await _handle_trade_lock(ws, session)
    elif mtype == "trade_confirm":
        await _handle_trade_confirm(ws, session)
    elif mtype == "trade_cancel":
        await _end_trade(session["id"], "Trade cancelled.")
    elif mtype == "friends_list":
        await _send_friends_list(ws, session["id"])
    elif mtype == "friend_request":
        await _handle_friend_request(ws, session, msg)
    elif mtype == "friend_accept":
        await _handle_friend_accept(ws, session, msg)
    elif mtype == "friend_decline":
        await _handle_friend_decline(ws, session, msg)
    elif mtype == "friend_remove":
        await _handle_friend_remove(ws, session, msg)
    elif mtype == "whisper":
        await _handle_whisper(ws, session, msg)
    elif mtype == "admin_place":
        await _handle_admin_place(ws, session, msg)
    elif mtype == "admin_delete":
        await _handle_admin_delete(ws, session, msg)
    elif mtype == "admin_move":
        await _handle_admin_move(ws, session, msg)
    elif mtype == "admin_gold":
        await _handle_admin_gold(ws, session, msg)
    elif mtype == "admin_spawn":
        await _handle_admin_spawn(ws, session, msg)
    elif mtype == "admin_give_item":
        await _handle_admin_give_item(ws, session, msg)
    elif mtype == "admin_take_item":
        await _handle_admin_take_item(ws, session, msg)
    elif mtype == "admin_view_inventory":
        await _handle_admin_view_inventory(ws, session, msg)
    elif mtype == "admin_list_players":
        await _handle_admin_list_players(ws, session, msg)
    elif mtype == "admin_restore_last_loss":
        await _handle_admin_restore_last_loss(ws, session, msg)
    elif mtype == "admin_tile_set":
        await _handle_admin_tile_set(ws, session, msg)
    elif mtype == "admin_tile_clear":
        await _handle_admin_tile_clear(ws, session, msg)
    elif mtype == "admin_save_map":
        await _handle_admin_save_map(ws, session, msg)
    elif mtype == "build_farm_plot":
        await _handle_build_farm_plot(ws, session, msg)
    elif mtype == "player_drop":
        await _handle_player_drop(ws, session, msg)
    elif mtype == "player_died":
        await _handle_player_died(ws, session, msg)
    elif mtype == "quest_accept":
        await _handle_quest_accept(ws, session, msg)
    elif mtype == "quest_complete":
        await _handle_quest_complete(ws, session, msg)
    elif mtype == "quest_abandon":
        await _handle_quest_abandon(ws, session, msg)
    elif mtype == "quest_talk":
        await _handle_quest_talk(ws, session, msg)
    elif mtype == "clan_info":
        await _send_clan_info(ws, session["id"])
    elif mtype == "clan_create":
        await _handle_clan_create(ws, session, msg)
    elif mtype == "clan_invite":
        await _handle_clan_invite(ws, session, msg)
    elif mtype == "clan_accept":
        await _handle_clan_accept(ws, session, msg)
    elif mtype == "clan_decline":
        await _handle_clan_decline(ws, session, msg)
    elif mtype == "clan_leave":
        await _handle_clan_leave(ws, session, msg)
    elif mtype == "clan_kick":
        await _handle_clan_kick(ws, session, msg)
    elif mtype == "clan_bank_deposit":
        await _handle_clan_bank_deposit(ws, session, msg)
    elif mtype == "clan_bank_withdraw":
        await _handle_clan_bank_withdraw(ws, session, msg)
    elif mtype == "gather_request":
        await _handle_gather_request(ws, session, msg)
    elif mtype == "gather_complete":
        await _handle_gather_complete(ws, session, msg)
    elif mtype == "gather_release":
        await _handle_gather_release(ws, session, msg)
    elif mtype == "node_states":
        await _handle_node_states(ws, session, msg)
    elif mtype == "monster_join":
        await _handle_monster_join(ws, session, msg)
    elif mtype == "monster_damage":
        await _handle_monster_damage(ws, session, msg)
    elif mtype == "monster_leave":
        await _handle_monster_leave(ws, session, msg)
    elif mtype == "monster_states":
        await _handle_monster_states(ws, session, msg)
    elif mtype == "shop_open":
        await _handle_shop_open(ws, session, msg)
    elif mtype == "shop_buy":
        await _handle_shop_buy(ws, session, msg)
    elif mtype == "shop_sell":
        await _handle_shop_sell(ws, session, msg)
    elif mtype == "shop_close":
        await _handle_shop_close(ws, session, msg)
    elif mtype == "gold_pile_pickup":
        await _handle_gold_pile_pickup(ws, session, msg)
    elif mtype == "enter_interior":
        await _handle_enter_interior(ws, session, msg)
    elif mtype == "exit_interior":
        await _handle_exit_interior(ws, session, msg)


async def handle_connection(ws) -> None:
    addr = getattr(ws, "remote_address", "?")
    print(f"[connect] {addr}")
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except (json.JSONDecodeError, ValueError):
                continue
            mtype   = msg.get("type", "")
            session = sessions.get(ws)
            # A handler raising must NOT drop the player's connection — log it and
            # keep the socket alive so one bad message can't kick them offline.
            try:
                await _route_message(ws, session, mtype, msg)
            except websockets.exceptions.ConnectionClosed:
                raise
            except Exception as e:
                print(f"[handler error] '{mtype}' from {addr}: {e!r}")
    except websockets.exceptions.ConnectionClosed:
        pass
    except Exception as e:
        print(f"[error] {addr}: {e}")
    finally:
        session = sessions.pop(ws, None)
        if session:
            player_id = session["id"]
            if player_id in trades:
                await _end_trade(player_id, "Trade partner disconnected.")
            _clear_player_locks(player_id)
            _clear_player_combat(player_id)
            await _notify_friends_presence(player_id)
            with _db() as conn:
                _logout_cid = _clan_id_for_player(conn, player_id)
            if _logout_cid is not None:
                await _broadcast_clan_info(_logout_cid)
            task_queue = []
            try:
                with _db() as conn:
                    row = conn.execute(
                        "SELECT task_queue FROM players WHERE id=?", (player_id,)).fetchone()
                    task_queue = json.loads(row["task_queue"] or "[]") if row else []
                    conn.execute(
                        "UPDATE players SET x=?,y=?,last_seen=? WHERE id=?",
                        (session["x"], session["y"], time.time(), player_id))
                    conn.commit()
            except Exception:
                pass

            if task_queue:
                info = {"id": player_id, "username": session["username"],
                        "x": session["x"], "y": session["y"]}
                idle_info[player_id] = info
                # Tell others to show this player as translucent ghost
                _broadcast({"type": "player_idle",
                            "id":       player_id,
                            "username": session["username"],
                            "x":        session["x"],
                            "y":        session["y"]})
                sim = asyncio.create_task(
                    _idle_simulation(player_id, session["username"],
                                     session["x"], session["y"]))
                idle_simulations[player_id] = sim
                print(f"[idle] started for {session['username']}")
            else:
                _broadcast({"type": "player_leave", "id": player_id})

            print(f"[disconnect] {session['username']}  ({len(sessions)} online)")
        else:
            print(f"[disconnect] {addr} (unauthenticated)")


# ── Entry point ────────────────────────────────────────────────────────────────

async def main() -> None:
    init_db()
    # Owner row is asserted on every boot so the hardcoded admin survives
    # any manual edits to the admins table.
    _bootstrap_owner_admin()
    # Tile overrides live in-memory; load from disk (or migrate from SQLite once)
    # BEFORE accepting clients, so the very first login already gets the full set.
    _load_tile_overrides_from_disk()
    # Shop stock rehydrates from JSON before clients connect — the very first
    # shop_open after a restart returns the persisted stock, not the template max.
    _load_shop_stock_from_disk()
    # Post-consolidation startup tasks: boat crash recovery + orphan
    # monster_state cleanup. Both run synchronously before accepting clients
    # so the first login already sees the cleaned-up world.
    _recover_sailing_boats()
    _purge_orphan_monster_state()
    # Rehydrate the AI dict from the persisted mirror (post-purge so only
    # valid rows reach memory). Non-boss monsters reset to full HP per the
    # partial-persist rule; bosses keep their last persisted HP.
    _load_monster_state_from_db()
    print(f"VikingVale server  ws://0.0.0.0:{PORT}")
    print("Press Ctrl+C to stop.\n")
    async with serve(handle_connection, "0.0.0.0", PORT) as server:
        await asyncio.gather(
            server.serve_forever(),
            _autosave_loop(),
            _tile_overrides_autosave_loop(),
            _world_tick_loop(),
            _monster_ai_loop(),
            _shop_restock_loop(),
            _shop_stock_autosave_loop(),
            _uptime_counter_loop(),
            _monster_state_flush_loop(),
        )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[shutdown] Server stopped.")
