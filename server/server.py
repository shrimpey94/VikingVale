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
import mail
import terrain

try:
    from websockets.asyncio.server import serve
    import websockets
except ImportError:
    raise SystemExit("Missing dependency — run: pip install websockets")

# Load server/.env if python-dotenv is installed. Used for SMTP creds +
# PUBLIC_BASE_URL (see mail.py + .env.example). dotenv is optional; the
# server still boots without it — mail.send_email just no-ops.
try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).parent / ".env")
except ImportError:
    pass

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
    # ──────────────────────────────────────────────────────────────────────
    # Act 1 → Act 2 hand-off + Act 2 Five Tokens + Act 3 Town Pledges.
    # Mirror of scripts/QuestData.gd entries — keep in sync manually.
    # ──────────────────────────────────────────────────────────────────────
    "q_old_bjarnes_letter": {
        "title": "Old Bjarne's Letter",
        "description": "Bjarne has pressed a sealed letter into your hand. He told you to find the Ironwood Hermit Skade — somewhere west of Ironwood Keep, in the central plains nobody walks anymore. \"Read nothing,\" he said. \"Just put it in her hand.\"",
        "giver_npc": "Elder Bjarne",
        "required": {"melee": 10, "woodcutting": 10},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_frost",
        "objectives": [
            {"type": "talk", "target_id": "Ironwood Hermit Skade",
             "quantity": 1, "display": "Deliver Bjarne's letter to Skade"},
        ],
        "rewards": {"xp": {"melee": 200, "vitality": 50}, "gold": 150,
                    "items": []},
    },
    "q_token_frost": {
        "title": "The Frost Token",
        "description": "Skade has told you what Bjarne could not write: the High Seat is real, and it cannot be sat without the Five Tokens. The first lies on the chest of the Ice Draugr Captain at Frostheim's glacier shrine.",
        "giver_npc": "Hunter Ragnhild",
        "required": {"melee": 25},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_iron",
        "objectives": [
            {"type": "kill", "target_id": "ice_draugr", "quantity": 3,
             "display": "Slay Ice Draugr at the glacier"},
        ],
        "rewards": {"xp": {"melee": 600, "vitality": 100, "defense": 100},
                    "gold": 400,
                    "items": [{"id": "frost_token", "name": "Frost Token",
                               "qty": 1, "color": [0.72, 0.90, 0.98, 1.0]}]},
    },
    "q_token_iron": {
        "title": "The Iron Token",
        "description": "Bjarne tells you the second Token has rested in Kjelvik for two hundred years. He will only give it up when you have proven you understand what it costs.",
        "giver_npc": "Elder Bjarne",
        "required": {"melee": 30},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_sea",
        "objectives": [
            {"type": "kill", "target_id": "draugr", "quantity": 5,
             "display": "Slay Draugr near Kjelvik"},
            {"type": "talk", "target_id": "Elder Bjarne", "quantity": 1,
             "display": "Return to Bjarne"},
        ],
        "rewards": {"xp": {"melee": 800, "vitality": 150, "defense": 150},
                    "gold": 600,
                    "items": [{"id": "iron_token", "name": "Iron Token",
                               "qty": 1, "color": [0.62, 0.62, 0.68, 1.0]}]},
    },
    "q_token_sea": {
        "title": "The Sea Token",
        "description": "Sea Captain Valdis at Bjorn's Landing keeps the third Token at a shrine somewhere along the eastern cliffs — but she will only sail you there once you have proven your worth as a deep-water hand.",
        "giver_npc": "Sea Captain Valdis",
        "required": {"fishing": 30},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_heart",
        "objectives": [
            {"type": "gather", "target_id": "lobster", "quantity": 5,
             "display": "Catch Lobsters for Valdis"},
            {"type": "talk", "target_id": "Sea Captain Valdis", "quantity": 1,
             "display": "Return to Valdis"},
        ],
        "rewards": {"xp": {"fishing": 500, "melee": 300}, "gold": 500,
                    "items": [{"id": "sea_token", "name": "Sea Token",
                               "qty": 1, "color": [0.20, 0.55, 0.92, 1.0]}]},
    },
    "q_token_heart": {
        "title": "The Heart Token",
        "description": "The Heart Token lies at Skade's hermitage itself, in the center plains where the maps say nothing exists.",
        "giver_npc": "Ironwood Hermit Skade",
        "required": {"melee": 40, "magic": 25},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_fifth",
        "objectives": [
            {"type": "talk", "target_id": "Ironwood Hermit Skade",
             "quantity": 1, "display": "Return to Skade's hermitage"},
        ],
        "rewards": {"xp": {"magic": 800, "vitality": 200}, "gold": 700,
                    "items": [{"id": "heart_token", "name": "Heart Token",
                               "qty": 1, "color": [0.85, 0.30, 0.30, 1.0]}]},
    },
    "q_token_fifth": {
        "title": "The Fifth Token",
        "description": "Four Tokens. Captain Sten waits at the Helheim shore. The road is the Ashlands. The price is three Spectral Warriors slain on the way.",
        "giver_npc": "Captain Sten",
        "required": {"melee": 50, "vitality": 30},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "spectral_warrior", "quantity": 3,
             "display": "Slay Spectral Warriors on the Ashlands road"},
            {"type": "talk", "target_id": "Captain Sten", "quantity": 1,
             "display": "Bring the essences to Sten"},
        ],
        "rewards": {"xp": {"melee": 2000, "vitality": 400, "magic": 400},
                    "gold": 2000,
                    "items": [
                        {"id": "fifth_token", "name": "Fifth Token",
                         "qty": 1, "color": [0.92, 0.78, 0.20, 1.0]},
                        # Marker item — server checks for this id to unlock
                        # warband creation. Don't drop on death.
                        {"id": "high_seat_warrant",
                         "name": "Warrant of the High Seat", "qty": 1,
                         "color": [0.95, 0.85, 0.30, 1.0]},
                    ]},
    },
    "q_pledge_kjelvik": {
        "title": "Pledge of Kjelvik",
        "description": "Bjarne accepts that the High Seat is yours to seek. Bring him 20 Iron Bars to rebuild the wall and clear 10 Skeletons from the Great Hall cellars.",
        "giver_npc": "Elder Bjarne",
        "required": {"melee": 50, "smithing": 40},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "iron_bar", "quantity": 20,
             "display": "Forge Iron Bars for Kjelvik's wall"},
            {"type": "kill", "target_id": "skeleton", "quantity": 10,
             "display": "Clear the Great Hall cellars"},
            {"type": "talk", "target_id": "Elder Bjarne", "quantity": 1,
             "display": "Swear the oath at the stone seat"},
        ],
        "rewards": {"xp": {"melee": 1500, "smithing": 800, "defense": 400},
                    "gold": 3000,
                    "items": [{"id": "pledge_kjelvik",
                               "name": "Pledge of Kjelvik", "qty": 1,
                               "color": [0.62, 0.62, 0.68, 1.0]}]},
    },
    "q_pledge_bjorn": {
        "title": "Pledge of Bjorn's Landing",
        "description": "Bring Valdis 5 Raw Sharks and slay 8 Bandits raiding the coast road.",
        "giver_npc": "Sea Captain Valdis",
        "required": {"fishing": 50, "melee": 45},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "raw_shark", "quantity": 5,
             "display": "Bring Valdis Raw Sharks"},
            {"type": "kill", "target_id": "bandit", "quantity": 8,
             "display": "Clear the coast-road bandits"},
            {"type": "talk", "target_id": "Sea Captain Valdis", "quantity": 1,
             "display": "Swear the oath at the dock-end shrine"},
        ],
        "rewards": {"xp": {"fishing": 1200, "melee": 1000, "defense": 400},
                    "gold": 3000,
                    "items": [{"id": "pledge_bjorn",
                               "name": "Pledge of Bjorn's Landing", "qty": 1,
                               "color": [0.20, 0.55, 0.92, 1.0]}]},
    },
    "q_pledge_frostheim": {
        "title": "Pledge of Frostheim",
        "description": "Slay 15 Goblins and 5 Ice Wolves at the high passes and bring Ragnhild 10 Frost Logs for the palisade.",
        "giver_npc": "Hunter Ragnhild",
        "required": {"melee": 50, "woodcutting": 50},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "goblin", "quantity": 15,
             "display": "Slay Goblins at the high passes"},
            {"type": "kill", "target_id": "ice_wolf", "quantity": 5,
             "display": "Slay Ice Wolves"},
            {"type": "gather", "target_id": "frost_log", "quantity": 10,
             "display": "Gather Frost Logs for the palisade"},
            {"type": "talk", "target_id": "Hunter Ragnhild", "quantity": 1,
             "display": "Swear the oath at the mountain shrine"},
        ],
        "rewards": {"xp": {"melee": 1500, "woodcutting": 800, "defense": 400},
                    "gold": 3000,
                    "items": [{"id": "pledge_frostheim",
                               "name": "Pledge of Frostheim", "qty": 1,
                               "color": [0.72, 0.90, 0.98, 1.0]}]},
    },
    "q_pledge_ironwood": {
        "title": "Pledge of Ironwood Keep",
        "description": "Bring Ulfr 15 Ironwood Logs and clear 12 Wolves from the dark grove.",
        "giver_npc": "Blacksmith Ulfr",
        "required": {"melee": 50, "smithing": 50, "woodcutting": 45},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "ironwood_log", "quantity": 15,
             "display": "Gather Ironwood Logs"},
            {"type": "kill", "target_id": "wolf", "quantity": 12,
             "display": "Clear wolves from the dark grove"},
            {"type": "talk", "target_id": "Blacksmith Ulfr", "quantity": 1,
             "display": "Swear the oath at the Ironwood Tree"},
        ],
        "rewards": {"xp": {"smithing": 1500, "woodcutting": 800, "melee": 600},
                    "gold": 3000,
                    "items": [{"id": "pledge_ironwood",
                               "name": "Pledge of Ironwood Keep", "qty": 1,
                               "color": [0.28, 0.14, 0.08, 1.0]}]},
    },
    "q_pledge_eastmark": {
        "title": "Pledge of Eastmark Post",
        "description": "Slay 10 Draugr on the Ashlands patrol and 5 Fire Imps beyond the rim.",
        "giver_npc": "Scout Halfdan",
        "required": {"melee": 55, "vitality": 35},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "draugr", "quantity": 10,
             "display": "Clear Draugr on the Ashlands patrol"},
            {"type": "kill", "target_id": "fire_imp", "quantity": 5,
             "display": "Slay Fire Imps beyond the rim"},
            {"type": "talk", "target_id": "Scout Halfdan", "quantity": 1,
             "display": "Swear the oath at the perimeter watchstone"},
        ],
        "rewards": {"xp": {"melee": 1800, "vitality": 500, "defense": 500},
                    "gold": 3000,
                    "items": [{"id": "pledge_eastmark",
                               "name": "Pledge of Eastmark Post", "qty": 1,
                               "color": [0.85, 0.30, 0.18, 1.0]}]},
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


def _migrate_v10(conn) -> None:
    """Town pledges — which warband holds each of the five towns. One row
    per town (max 5 rows ever). When a warband completes a pledge quest
    for a town, the existing row is UPSERTed to point to that warband.
    `path` is 'diplomatic' or 'conquest' for future cosmetic/audit use."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS town_pledges (
            town_id     TEXT PRIMARY KEY,
            warband_id  TEXT NOT NULL,
            pledged_at  REAL NOT NULL,
            path        TEXT NOT NULL DEFAULT 'diplomatic'
        )
    """)


def _migrate_v11(conn) -> None:
    """Warband alliances — one-pact-per-warband. Composite PK with the
    smaller id first (lexicographic) so a pair (A, B) is stored as
    (min, max) — prevents duplicate (A,B)/(B,A) rows. Server enforces
    the single-pact rule at insert time by checking that neither warband
    already appears in any row."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS warband_alliances (
            warband_a   TEXT NOT NULL,
            warband_b   TEXT NOT NULL,
            pacted_at   REAL NOT NULL,
            PRIMARY KEY (warband_a, warband_b)
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_alliances_a ON warband_alliances (warband_a)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_alliances_b ON warband_alliances (warband_b)
    """)


def _migrate_v13(conn) -> None:
    """Backstory perk id + saved pet type on `players`. Both are short
    strings; backstory is one-shot (set at creation), pet_type is freely
    changeable. The mods themselves and the live pet entity live entirely
    client-side via Backstory.apply()/PetManager.summon()."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(players)")}
    if "backstory" not in cols:
        conn.execute(
            "ALTER TABLE players ADD COLUMN backstory TEXT NOT NULL DEFAULT ''")
    if "pet_type" not in cols:
        conn.execute(
            "ALTER TABLE players ADD COLUMN pet_type TEXT NOT NULL DEFAULT ''")


def _migrate_v14(conn) -> None:
    """Seal of Kings + World-Eater state.

    Single-row config table holds the global event status. The statue
    itself lives in `world_entities` (kind='seal_statue'), the
    World-Eater in `world_entities` (kind='world_eater'). This config
    row tracks the lifecycle metadata that doesn't fit on either.

    States:
      'dormant'  — no ruling warband; statue invisible/inert
      'charged'  — a warband holds all 5 pledges; statue exists, attackable
      'breaking' — challenger awakened the seal; raid in progress
      'walking'  — World-Eater is in Phase 1 (invulnerable sundering walk)
      'boss'     — World-Eater is in Phase 2 (vulnerable, anyone can attack)
    """
    conn.execute("""
        CREATE TABLE IF NOT EXISTS seal_state (
            id              INTEGER PRIMARY KEY CHECK (id = 1),
            state           TEXT    NOT NULL DEFAULT 'dormant',
            ruling_warband  TEXT    NOT NULL DEFAULT '',
            doomed_warband  TEXT    NOT NULL DEFAULT '',
            awakened_by     TEXT    NOT NULL DEFAULT '',
            awakened_at     REAL    NOT NULL DEFAULT 0,
            world_eater_id  TEXT    NOT NULL DEFAULT ''
        )
    """)
    conn.execute(
        "INSERT OR IGNORE INTO seal_state (id, state) VALUES (1, 'dormant')")


def _migrate_v12(conn) -> None:
    """Account recovery + brute-force protection columns on `players`.

    Adds an optional `email` (recovery routing — username stays the login
    identity), the email verification flag, password-reset token + expiry,
    failed-login counter, lockout timestamp, and last-login audit fields.
    All defaults are chosen so existing rows remain valid without any
    data backfill: empty email, unverified, no token, zero failures, no
    lockout, zero timestamps.

    SQLite limitation: ADD COLUMN ... DEFAULT can only be a literal, so
    each is added one at a time. Partial-unique index on non-empty emails
    so the optional column can still be looked up cheaply.
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(players)")}
    add = [
        ("email",                  "TEXT NOT NULL DEFAULT ''"),
        ("email_verified",         "INTEGER NOT NULL DEFAULT 0"),
        ("password_reset_token",   "TEXT NOT NULL DEFAULT ''"),
        ("password_reset_expires", "REAL NOT NULL DEFAULT 0"),
        ("failed_login_count",     "INTEGER NOT NULL DEFAULT 0"),
        ("locked_until",           "REAL NOT NULL DEFAULT 0"),
        ("last_login_at",          "REAL NOT NULL DEFAULT 0"),
        ("last_login_ip",          "TEXT NOT NULL DEFAULT ''"),
    ]
    for name, ddl in add:
        if name not in cols:
            conn.execute(f"ALTER TABLE players ADD COLUMN {name} {ddl}")
    # Partial index on non-empty emails — cheap lookup for password-reset
    # routing without forcing uniqueness across the empty-string default.
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_players_email
            ON players(email) WHERE email != ''
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_players_reset_token
            ON players(password_reset_token) WHERE password_reset_token != ''
    """)


def _migrate_v15(conn) -> None:
    """Tile editor extras: per-tile color tint (hue + brightness) and
    per-tile passability flag. All default to neutral (no tint, passable)
    so existing rows remain valid without backfill.

    tint_h / tint_v are int8-ish — stored as INTEGER in [-100, 100] which
    the shader maps to ±20% shifts. passable is 1 = walkable, 0 = blocked.
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(tile_overrides)")}
    if "tint_h" not in cols:
        conn.execute(
            "ALTER TABLE tile_overrides ADD COLUMN tint_h INTEGER NOT NULL DEFAULT 0")
    if "tint_v" not in cols:
        conn.execute(
            "ALTER TABLE tile_overrides ADD COLUMN tint_v INTEGER NOT NULL DEFAULT 0")
    if "passable" not in cols:
        conn.execute(
            "ALTER TABLE tile_overrides ADD COLUMN passable INTEGER NOT NULL DEFAULT 1")


def _migrate_v16(conn) -> None:
    """Interior return-coord persistence. Exit was reading session["x"] as
    the return target, but that's the LIVE player coord which gets
    overwritten by interior movement — players teleported to the world
    corner on exit. Added dedicated columns so relog + exit both use
    the saved entry position."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(players)")}
    if "interior_return_x" not in cols:
        conn.execute("ALTER TABLE players ADD COLUMN interior_return_x REAL DEFAULT 0")
    if "interior_return_y" not in cols:
        conn.execute("ALTER TABLE players ADD COLUMN interior_return_y REAL DEFAULT 0")


def _migrate_v17(conn) -> None:
    """Structure HP persistence. Previously RAM-only — restarting the
    server reset every damaged structure back to full HP. New
    structure_state table mirrors monsters_state's partial-persist
    pattern: hp/max_hp/alive/subtype/owner/wood survive restart. The
    entity's world_entities row remains the source of truth for
    position + type; this table just carries combat state."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS structure_state (
            entity_id TEXT PRIMARY KEY,
            hp        INTEGER NOT NULL,
            max_hp    INTEGER NOT NULL,
            alive     INTEGER NOT NULL DEFAULT 1,
            subtype   TEXT NOT NULL,
            x         REAL NOT NULL,
            y         REAL NOT NULL,
            owner     TEXT NOT NULL DEFAULT '',
            wood      TEXT NOT NULL DEFAULT 'oak'
        )
    """)


_MIGRATIONS = [
    _migrate_v1, _migrate_v2, _migrate_v3, _migrate_v4,
    _migrate_v5, _migrate_v6, _migrate_v7, _migrate_v8,
    _migrate_v9, _migrate_v10, _migrate_v11, _migrate_v12, _migrate_v13,
    _migrate_v14, _migrate_v15, _migrate_v16, _migrate_v17,
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

def _looks_like_email(s: str) -> bool:
    """Cheap email validator — checks shape only, not deliverability.
    `local@domain.tld` with no spaces, single @, dot in domain, both parts
    non-empty. SMTP will catch the rest. Good enough for signup gating."""
    if not s or " " in s or "@" not in s:
        return False
    if s.count("@") != 1:
        return False
    local, _, domain = s.partition("@")
    if not local or not domain or "." not in domain:
        return False
    if domain.startswith(".") or domain.endswith("."):
        return False
    return True


async def _handle_register(ws, msg: dict) -> None:
    username = str(msg.get("username", "")).strip()
    password = str(msg.get("password", ""))
    # Email is optional at signup but if provided it must be well-formed
    # and unique. Empty is fine — the player can add an email later via
    # the Account section in SettingsPanel.
    email = str(msg.get("email", "")).strip().lower()
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
    if email and not _looks_like_email(email):
        await _send(ws, {"type": "register_fail", "reason": "Email doesn't look right."})
        return
    with _db() as conn:
        if conn.execute("SELECT 1 FROM players WHERE username=?", (username,)).fetchone():
            await _send(ws, {"type": "register_fail", "reason": "Username already taken."})
            return
        if email and conn.execute(
                "SELECT 1 FROM players WHERE LOWER(email)=? AND email != ''",
                (email,)).fetchone():
            await _send(ws, {"type": "register_fail",
                "reason": "An account with that email already exists."})
            return
        salt = secrets.token_hex(16)
        pid  = secrets.token_hex(16)
        # Explicit x/y on insert — the table's column DEFAULT only applies to
        # fresh databases, and `CREATE TABLE IF NOT EXISTS` never updates an
        # existing table's defaults. Passing the spawn position here means
        # every NEW account lands at Bjorn's Landing regardless of whether
        # the operator started from a fresh DB or migrated an old one.
        conn.execute(
            "INSERT INTO players (id,username,password_hash,salt,x,y,skill_xp,email,created_at,last_seen) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (pid, username, _hash(password, salt), salt,
             7823.0, 4488.0,
             json.dumps(DEFAULT_SKILL_XP), email, time.time(), time.time())
        )
        conn.commit()
    await _send(ws, {"type": "register_ok", "username": username})
    print(f"[register] {username} email={email!r}")


# ── Password recovery (Phase C) ───────────────────────────────────────────
#
# Three handlers form the reset flow:
#   request_password_reset       → issue token + email (anti-enumeration)
#   verify_password_reset_token  → client pre-flight before showing the
#                                  new-password screen
#   complete_password_reset      → consume token, hash new password
#
# Tokens are 32-byte hex (64 chars). Single-use: cleared on completion.
# Expiry: 60 minutes. Anti-enumeration: request always returns success even
# if the user doesn't exist OR has no email on file — never reveals which.

PASSWORD_RESET_TTL_SECONDS = 60 * 60  # 1 hour
PASSWORD_RESET_TTL_MINUTES = PASSWORD_RESET_TTL_SECONDS // 60


async def _handle_request_password_reset(ws, msg: dict) -> None:
    # Accept EITHER username or email so the user can type whichever they
    # remember. We look up by both fields when both are provided to keep
    # the flow forgiving.
    username = str(msg.get("username", "")).strip()
    email = str(msg.get("email", "")).strip().lower()
    now = time.time()
    row = None
    with _db() as conn:
        if username:
            row = conn.execute(
                "SELECT id, username, email FROM players WHERE username=?",
                (username,)).fetchone()
        if row is None and email:
            row = conn.execute(
                "SELECT id, username, email FROM players "
                "WHERE LOWER(email)=? AND email != ''",
                (email,)).fetchone()
        # Issue a token + send email ONLY when we have a row with a
        # non-empty email. In every other case (no row found / row has
        # no email), we silently drop and return success anyway. This
        # is the anti-enumeration property: an attacker can't tell from
        # the response whether the account exists.
        if row and row["email"]:
            token = secrets.token_hex(32)
            expires = now + PASSWORD_RESET_TTL_SECONDS
            conn.execute(
                "UPDATE players SET password_reset_token=?, "
                "password_reset_expires=? WHERE id=?",
                (token, expires, row["id"]))
            conn.commit()
            # Build + send the email outside the DB transaction.
            text_body, html_body = mail.build_reset_email(
                str(row["username"]), token, PASSWORD_RESET_TTL_MINUTES)
            mail.send_email(
                str(row["email"]),
                mail.SUBJECT_PASSWORD_RESET,
                text_body, html_body)
            print(f"[reset] token issued for {row['username']!r} "
                  f"(email={row['email']!r}, expires in "
                  f"{PASSWORD_RESET_TTL_MINUTES} min)")
    # Anti-enumeration generic reply.
    await _send(ws, {
        "type": "request_password_reset_ok",
        "message": "If an account exists for that name or email, a reset "
                   "link has been sent.",
    })


async def _handle_verify_password_reset_token(ws, msg: dict) -> None:
    token = str(msg.get("token", "")).strip()
    if not token or len(token) != 64:
        await _send(ws, {"type": "verify_password_reset_token_result",
                         "ok": False})
        return
    now = time.time()
    with _db() as conn:
        row = conn.execute(
            "SELECT id, password_reset_expires FROM players "
            "WHERE password_reset_token=? AND password_reset_token != ''",
            (token,)).fetchone()
    ok = bool(row and float(row["password_reset_expires"] or 0) > now)
    await _send(ws, {"type": "verify_password_reset_token_result", "ok": ok})


async def _handle_complete_password_reset(ws, msg: dict) -> None:
    token = str(msg.get("token", "")).strip()
    new_password = str(msg.get("new_password", ""))
    if not token or len(token) != 64:
        await _send(ws, {"type": "complete_password_reset_fail",
                         "reason": "Invalid token."})
        return
    if len(new_password) < 4:
        await _send(ws, {"type": "complete_password_reset_fail",
                         "reason": "Password must be at least 4 characters."})
        return
    now = time.time()
    with _db() as conn:
        row = conn.execute(
            "SELECT id, username, email, password_reset_expires "
            "FROM players WHERE password_reset_token=? "
            "AND password_reset_token != ''", (token,)).fetchone()
        if not row or float(row["password_reset_expires"] or 0) <= now:
            await _send(ws, {"type": "complete_password_reset_fail",
                             "reason": "Token is invalid or has expired."})
            return
        # Re-roll the salt on every password change. Hashing key never
        # gets reused even if the same string is chosen.
        salt = secrets.token_hex(16)
        conn.execute(
            "UPDATE players SET password_hash=?, salt=?, "
            "password_reset_token='', password_reset_expires=0, "
            "failed_login_count=0, locked_until=0 WHERE id=?",
            (_hash(new_password, salt), salt, row["id"]))
        conn.commit()
    print(f"[reset] password changed for {row['username']!r}")
    # Confirmation email is best-effort — even if it fails the password
    # change has already committed.
    if row["email"]:
        text_body, html_body = mail.build_password_changed_email(
            str(row["username"]))
        mail.send_email(str(row["email"]),
            mail.SUBJECT_PASSWORD_CHANGED, text_body, html_body)
    await _send(ws, {"type": "complete_password_reset_ok",
                     "username": row["username"]})


async def _handle_change_email(ws, session, msg: dict) -> None:
    """Player self-service: set or change own email. Treats empty string as
    'remove email'. Requires current password as a soft verification step
    so a stolen session can't silently hijack the recovery channel."""
    if session is None:
        return
    current_password = str(msg.get("current_password", ""))
    new_email = str(msg.get("email", "")).strip().lower()
    if new_email and not _looks_like_email(new_email):
        await _send(ws, {"type": "change_email_fail",
            "reason": "Email doesn't look right."})
        return
    with _db() as conn:
        row = conn.execute("SELECT * FROM players WHERE id=?",
            (session["id"],)).fetchone()
        if not row or _hash(current_password, row["salt"]) != row["password_hash"]:
            await _send(ws, {"type": "change_email_fail",
                "reason": "Current password is wrong."})
            return
        if new_email and conn.execute(
                "SELECT 1 FROM players WHERE LOWER(email)=? AND id != ? "
                "AND email != ''",
                (new_email, session["id"])).fetchone():
            await _send(ws, {"type": "change_email_fail",
                "reason": "Another account already uses that email."})
            return
        # Changing the email re-arms the verified flag — the new address
        # has to prove itself again. Empty string clears verified too.
        conn.execute(
            "UPDATE players SET email=?, email_verified=0 WHERE id=?",
            (new_email, session["id"]))
        conn.commit()
    print(f"[account] {session['username']} email -> {new_email!r}")
    await _send(ws, {"type": "change_email_ok", "email": new_email})


async def _handle_change_password(ws, session, msg: dict) -> None:
    """Player self-service: rotate password. Requires current password."""
    if session is None:
        return
    current_password = str(msg.get("current_password", ""))
    new_password = str(msg.get("new_password", ""))
    if len(new_password) < 4:
        await _send(ws, {"type": "change_password_fail",
            "reason": "New password must be at least 4 characters."})
        return
    with _db() as conn:
        row = conn.execute("SELECT * FROM players WHERE id=?",
            (session["id"],)).fetchone()
        if not row or _hash(current_password, row["salt"]) != row["password_hash"]:
            await _send(ws, {"type": "change_password_fail",
                "reason": "Current password is wrong."})
            return
        new_salt = secrets.token_hex(16)
        conn.execute(
            "UPDATE players SET password_hash=?, salt=?, "
            "failed_login_count=0, locked_until=0 WHERE id=?",
            (_hash(new_password, new_salt), new_salt, session["id"]))
        conn.commit()
    print(f"[account] {session['username']} rotated password")
    # Best-effort confirmation email if the user has one on file.
    if row["email"]:
        text_body, html_body = mail.build_password_changed_email(
            str(row["username"]))
        mail.send_email(str(row["email"]),
            mail.SUBJECT_PASSWORD_CHANGED, text_body, html_body)
    await _send(ws, {"type": "change_password_ok"})


async def _handle_set_backstory(ws, session, msg: dict) -> None:
    """One-shot character-creation pick. Server enforces a single set:
    a backstory can only be chosen while the column is empty (newly-made
    character). After that, the choice is permanent — admins can clear
    it manually via SQLite if anyone needs a do-over."""
    if session is None:
        return
    bs = str(msg.get("backstory", "")).strip().lower()
    valid = {"viking", "fisher", "craftsman", "mage", "archer"}
    if bs not in valid:
        await _send(ws, {"type": "set_backstory_fail",
            "reason": "Unknown backstory."})
        return
    with _db() as conn:
        row = conn.execute("SELECT backstory FROM players WHERE id=?",
            (session["id"],)).fetchone()
        if not row:
            return
        if str(row["backstory"] or "") != "":
            await _send(ws, {"type": "set_backstory_fail",
                "reason": "Backstory already chosen."})
            return
        conn.execute("UPDATE players SET backstory=? WHERE id=?",
            (bs, session["id"]))
        conn.commit()
    print(f"[backstory] {session['username']} -> {bs!r}")
    await _send(ws, {"type": "set_backstory_ok", "backstory": bs})


async def _handle_set_pet_type(ws, session, msg: dict) -> None:
    """Player picks (or changes) their pet. RAM-only entity lives on the
    client — server only persists the chosen type so re-login restores it.
    Empty string = no pet."""
    if session is None:
        return
    pt = str(msg.get("pet_type", "")).strip().lower()
    valid = {"", "wolf_pup", "raven", "fox", "drake", "boarlet"}
    if pt not in valid:
        return
    with _db() as conn:
        conn.execute("UPDATE players SET pet_type=? WHERE id=?",
            (pt, session["id"]))
        conn.commit()
    await _send(ws, {"type": "set_pet_type_ok", "pet_type": pt})


async def _handle_get_account_info(ws, session, _msg: dict) -> None:
    """Returns current account snapshot for the Account section UI."""
    if session is None:
        return
    with _db() as conn:
        row = conn.execute(
            "SELECT email, email_verified, last_login_at FROM players WHERE id=?",
            (session["id"],)).fetchone()
    if not row:
        return
    await _send(ws, {
        "type": "account_info",
        "username": session["username"],
        "email": str(row["email"] or ""),
        "email_verified": bool(int(row["email_verified"] or 0)),
        "last_login_at": float(row["last_login_at"] or 0),
    })


async def _handle_login(ws, msg: dict) -> None:
    username = str(msg.get("username", "")).strip()
    password = str(msg.get("password", ""))
    # Best-effort client IP — websockets exposes it via the underlying
    # connection if available. Used for audit logging only.
    client_ip = ""
    try:
        peer = getattr(ws, "remote_address", None)
        if peer and isinstance(peer, tuple) and len(peer) > 0:
            client_ip = str(peer[0])
    except Exception:
        client_ip = ""
    now = time.time()
    with _db() as conn:
        row = conn.execute("SELECT * FROM players WHERE username=?", (username,)).fetchone()
        # Lockout gate — runs BEFORE the password check so a locked
        # account can't be probed during the lockout window. Generic
        # reason text preserves the existing "don't leak which field is
        # wrong" stance even when locked.
        if row and float(row["locked_until"] or 0) > now:
            await _send(ws, {"type": "login_fail",
                "reason": "Too many failed attempts. Try again later."})
            return
        if not row or _hash(password, row["salt"]) != row["password_hash"]:
            # Increment failed counter on the specific row when one was
            # found. We don't punish typos before lockout; 10 strikes in
            # a row = 15 minute cool-down, then counter resets on next
            # success. No counter is created for non-existent usernames
            # (anti-enumeration: lookup behavior matches existing-user
            # bad-password from the outside).
            if row:
                new_count = int(row["failed_login_count"] or 0) + 1
                if new_count >= 10:
                    conn.execute(
                        "UPDATE players SET failed_login_count=0, "
                        "locked_until=? WHERE id=?",
                        (now + 900.0, row["id"]))
                    print(f"[login] LOCKED {username} for 15 min "
                          f"(10 failed attempts)")
                else:
                    conn.execute(
                        "UPDATE players SET failed_login_count=? WHERE id=?",
                        (new_count, row["id"]))
                conn.commit()
            await _send(ws, {"type": "login_fail",
                "reason": "Invalid username or password."})
            return
        # Success — reset counters + stamp audit fields.
        conn.execute(
            "UPDATE players SET failed_login_count=0, locked_until=0, "
            "last_login_at=?, last_login_ip=? WHERE id=?",
            (now, client_ip, row["id"]))
        conn.commit()

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
    # Persisted return coords (v16 columns). If the row predates the migration
    # or the columns are 0 (never entered interior), fall back to the current
    # exterior x/y so an exit never lands the player at (0,0).
    cur_interior_return_x = float(row["x"])
    cur_interior_return_y = float(row["y"])
    try:
        cur_interior_id = str(row["interior_id"] or "")
        cur_interior_x  = float(row["interior_x"] or 0.0)
        cur_interior_y  = float(row["interior_y"] or 0.0)
        if "interior_return_x" in row.keys():
            rx_col = float(row["interior_return_x"] or 0.0)
            ry_col = float(row["interior_return_y"] or 0.0)
            # Only trust the persisted return coord if it's non-zero AND
            # sits inside the exterior playable area (walls block the
            # interior band at ty >= 300, so ry must be < ~9600 to be a
            # real exterior return).
            if rx_col > 0.0 and ry_col > 0.0 and ry_col < 9600.0:
                cur_interior_return_x = rx_col
                cur_interior_return_y = ry_col
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
        # Restore the return coord from the DB so an exit after relog
        # teleports the player back to their pre-entry exterior position,
        # not to (0, 0) / world corner.
        "interior_return_x": cur_interior_return_x,
        "interior_return_y": cur_interior_return_y,
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
        # Backstory perk id (Backstory.gd). Empty string = not chosen yet
        # (e.g. legacy accounts), client opens the picker on first login
        # after the column exists.
        "backstory":    str(row["backstory"] or "") if "backstory" in row.keys() else "",
        # Interior state (Phase 6). If the player was inside a building
        # when their last session ended, we ship the interior_id + return
        # coords on login so the client can auto-re-enter — the world
        # already stored this session state, so the player wakes up
        # exactly where they were before the crash / relog.
        "interior_id":  cur_interior_id,
        # Prefer the dedicated interior_return_* columns (v16). Fall back
        # to row["x"]/["y"] for legacy rows where those columns are 0 —
        # in that case row.x/y is still the last exterior position because
        # the player wasn't inside at their previous session end.
        "interior_return_x": float(row["interior_return_x"] or row["x"])
            if "interior_return_x" in row.keys() else float(row["x"]),
        "interior_return_y": float(row["interior_return_y"] or row["y"])
            if "interior_return_y" in row.keys() else float(row["y"]),
        # Per-building interior coord (v-post-16). Client uses this to
        # respawn the InteriorScene at the SAME plot the player left —
        # important now that each building instance has its own room.
        "interior_x":  cur_interior_x,
        "interior_y":  cur_interior_y,
        # Saved pet type (Pet.gd via PetManager). Empty string = no pet
        # picked yet; client opens the picker or just shows "no pet".
        "pet_type":     str(row["pet_type"] or "") if "pet_type" in row.keys() else "",
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


async def _handle_admin_wipemonsters(ws, session: dict) -> None:
    """Wipe every monster from the world in one shot. Removes all admin-placed
    monsters from world_entities, purges every entry from the live AI dict +
    monster_state DB via _purge_monster_state (which also broadcasts a
    monster_died so all clients free their local visuals), and reports the
    count back to the invoker.

    Any-admin (not owner-only): the world can be repopulated from the admin
    panel afterward, so a stray misuse is recoverable. Procedural chunk
    monsters are already disabled in World.gd via PROCEDURAL_MONSTERS=false,
    so nothing repopulates the world after the wipe."""
    if not _is_admin(session):
        await _admin_confirm(ws, "Only an admin can run /wipemonsters.")
        return
    # Snapshot every monster the server is currently tracking. Two sources:
    #   1. world_entities rows with kind='monster' (admin-placed, persisted).
    #   2. monsters_state RAM entries (procedural + admin, live AI).
    admin_ids: list = []
    with _db() as conn:
        rows = conn.execute(
            "SELECT id FROM world_entities WHERE kind='monster'").fetchall()
        admin_ids = [str(r["id"]) for r in rows]
        conn.execute("DELETE FROM world_entities WHERE kind='monster'")
        conn.commit()
    # Union — some monsters have RAM state but no world_entities row (e.g.
    # procedural chunk monsters that were seeded before the wipe flag was
    # flipped). Purge them too so no phantoms tick.
    all_ids = set(admin_ids) | set(monsters_state.keys())
    for mid in all_ids:
        _purge_monster_state(mid)
    # world_entity_remove broadcast for the admin-placed rows so client
    # world state matches (monster_died already dispatched by _purge, which
    # covers the visual despawn; world_entity_remove keeps the admin
    # entity registry consistent too).
    for eid in admin_ids:
        _broadcast({"type": "world_entity_remove", "id": eid})
    total = len(all_ids)
    await _admin_confirm(ws, f"Wiped {total} monster(s) from the world.")
    print(f"[wipemonsters] {session['username']} wiped {total} monster(s) "
          f"({len(admin_ids)} admin-placed, {total - len(admin_ids)} live AI)")


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
        # For structures, overlay the live (or rehydrated) HP so the
        # client's initial world_entity_add carries current combat state.
        # Without this, a client logging in mid-battle would see a
        # damaged wall spawn at full HP visually until the next combat
        # broadcast — the HP bar would flash on the first hit.
        eid = str(r["id"])
        if eid in structures_state:
            sst = structures_state[eid]
            data["hp"]     = int(sst.get("hp", 0))
            data["max_hp"] = int(sst.get("max_hp", 1))
            data["alive"]  = bool(sst.get("alive", True))
        out.append({"id": eid, "kind": r["kind"], "subtype": r["subtype"],
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
    # Structure placement overlap check — two structures can't share space.
    # Only enforced for structure subtypes; monsters/NPCs/trees stay free.
    if subtype in _STRUCTURE_SIZES:
        if _placement_would_overlap(subtype, x, y):
            await _admin_confirm(ws,
                f"Cannot place {subtype} — overlaps existing structure.")
            return
    data = msg.get("data", {})
    if not isinstance(data, dict):
        data = {}
    eid = "a:" + secrets.token_hex(8)
    with _db() as conn:
        conn.execute(
            "INSERT INTO world_entities (id, kind, subtype, x, y, data) VALUES (?,?,?,?,?,?)",
            (eid, kind, subtype, x, y, json.dumps(data)))
        conn.commit()
    _known_admin_entity_ids.add(eid)
    # Structure HP seed — track live HP for combat damage. Non-structure
    # resources (trees, rocks) don't get this — they use the existing
    # per-node depletion / respawn flow.
    if subtype in _STRUCTURE_SIZES:
        wood = str(data.get("wood", "oak"))
        max_hp_s = _structure_max_hp(subtype, wood)
        structures_state[eid] = {
            "hp": max_hp_s, "max_hp": max_hp_s, "alive": True,
            "subtype": subtype, "x": x, "y": y,
            "owner": str(data.get("owner", session["username"])),
            "wood": wood,
        }
        _mark_structure_dirty(eid)
        # Reflect the seed HP into the entity's data dict so the client
        # gets it in the world_entity_add broadcast below.
        data["hp"] = max_hp_s
        data["max_hp"] = max_hp_s
        data["alive"] = True
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
    # ALWAYS purge the AI/combat/SQLite state first. If `eid` is a static
    # entity (rock / npc / banner) the purge is a no-op (returns False) and
    # we fall through. If it's a monster (admin-placed `a:...` or procedural
    # deterministic id), this kills the ghost-AI bug at the source.
    was_monster = _purge_monster_state(eid)
    if was_monster:
        print(f"[admin] {session['username']} purged monster {eid}")
    if eid.startswith("a:"):
        # Admin-placed entity — remove from the persistent placement table.
        with _db() as conn:
            conn.execute("DELETE FROM world_entities WHERE id=?", (eid,))
            conn.commit()
        _known_admin_entity_ids.discard(eid)
        _broadcast({"type": "world_entity_remove", "id": eid})
    else:
        # Pre-existing (procedural/hardcoded) entity — record a deletion edit.
        with _db() as conn:
            conn.execute(
                "INSERT INTO entity_edits (id, deleted) VALUES (?,1) "
                "ON CONFLICT(id) DO UPDATE SET deleted=1", (eid,))
            conn.commit()
        _broadcast({"type": "entity_edit", "id": eid, "deleted": True})
    # Mark dead in the existence cache so the AI tick loop's safety net
    # rejects any leftover monsters_state entry on the very next tick.
    _purged_entity_ids.add(eid)
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


def _player_has_item(player_id: str, item_id: str, min_qty: int = 1) -> bool:
    """True if the player's persisted inventory contains at least min_qty of
    item_id. Used by gates that need to check item-based prerequisites
    (e.g. warband creation requires the High Seat Warrant). Reads from
    SQLite, not session cache, so it works even when the player is
    offline-checked by an admin or background task."""
    try:
        with _db() as conn:
            row = conn.execute(
                "SELECT inventory FROM players WHERE id=?",
                (player_id,)).fetchone()
        if row is None:
            return False
        inv = json.loads(row["inventory"] or "[]")
    except Exception:
        return False
    total = 0
    for it in inv:
        if isinstance(it, dict) and str(it.get("id", "")) == item_id:
            total += int(it.get("qty", 0))
            if total >= min_qty:
                return True
    return False


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


# ── Admin Accounts tab (Phase E) ──────────────────────────────────────────
#
# Four read+write handlers for the admin UI's account-management surface.
# All require _is_admin (owner OR admin role). Audit logging via the
# existing _admin_confirm pattern + server-side print.

async def _handle_admin_list_accounts(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    query = str(msg.get("query", "")).strip().lower()
    rows = []
    with _db() as conn:
        if query:
            cursor = conn.execute(
                "SELECT id, username, email, email_verified, "
                "last_login_at, last_login_ip, locked_until, "
                "failed_login_count, created_at "
                "FROM players "
                "WHERE LOWER(username) LIKE ? OR LOWER(email) LIKE ? "
                "ORDER BY username LIMIT 100",
                (f"%{query}%", f"%{query}%"))
        else:
            cursor = conn.execute(
                "SELECT id, username, email, email_verified, "
                "last_login_at, last_login_ip, locked_until, "
                "failed_login_count, created_at "
                "FROM players ORDER BY last_login_at DESC LIMIT 100")
        for r in cursor.fetchall():
            rows.append({
                "id": str(r["id"]),
                "username": str(r["username"]),
                "email": str(r["email"] or ""),
                "email_verified": bool(int(r["email_verified"] or 0)),
                "last_login_at": float(r["last_login_at"] or 0),
                "last_login_ip": str(r["last_login_ip"] or ""),
                "locked_until": float(r["locked_until"] or 0),
                "failed_login_count": int(r["failed_login_count"] or 0),
                "created_at": float(r["created_at"] or 0),
            })
    await _send(ws, {"type": "admin_account_list", "accounts": rows})


async def _handle_admin_reset_password(ws, session: dict, msg: dict) -> None:
    """Admin-initiated reset: issues a fresh token + sends the reset email.
    Same flow as the user-facing request, but always succeeds (no anti-
    enumeration since the admin is authenticated)."""
    if not _is_admin(session):
        return
    target = str(msg.get("username", "")).strip()
    if not target:
        await _admin_confirm(ws, "Usage: username required.")
        return
    now = time.time()
    with _db() as conn:
        row = conn.execute(
            "SELECT id, username, email FROM players WHERE username=?",
            (target,)).fetchone()
        if not row:
            await _admin_confirm(ws, f"No account named {target!r}.")
            return
        if not row["email"]:
            await _admin_confirm(ws,
                f"{target!r} has no email on file — cannot send reset.")
            return
        token = secrets.token_hex(32)
        conn.execute(
            "UPDATE players SET password_reset_token=?, "
            "password_reset_expires=? WHERE id=?",
            (token, now + PASSWORD_RESET_TTL_SECONDS, row["id"]))
        conn.commit()
    text_body, html_body = mail.build_reset_email(
        str(row["username"]), token, PASSWORD_RESET_TTL_MINUTES)
    sent = mail.send_email(str(row["email"]),
        mail.SUBJECT_PASSWORD_RESET, text_body, html_body)
    status = "sent" if sent else "issued (email send failed — check server logs)"
    print(f"[admin] {session['username']} reset password for {target!r} "
          f"({status})")
    await _admin_confirm(ws, f"Reset {status} for {target!r}.")


async def _handle_admin_unlock_account(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    target = str(msg.get("username", "")).strip()
    if not target:
        await _admin_confirm(ws, "Usage: username required.")
        return
    with _db() as conn:
        cursor = conn.execute(
            "UPDATE players SET locked_until=0, failed_login_count=0 "
            "WHERE username=?", (target,))
        conn.commit()
    if cursor.rowcount == 0:
        await _admin_confirm(ws, f"No account named {target!r}.")
        return
    print(f"[admin] {session['username']} unlocked {target!r}")
    await _admin_confirm(ws, f"{target!r} unlocked.")


async def _handle_admin_upload_terrain(ws, session: dict, msg: dict) -> None:
    """Owner-only — accept a base64-encoded passability bitmap from the
    admin client and persist it to server/terrain.bin. The client builds
    it by iterating Ground.biome_at_world over every tile in the 300×300
    world grid; the bake is a one-time job whenever biome generation
    changes. Format: 1 bit per tile, MSB-first row-major, bit=1 passable."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Terrain upload is owner-only.")
        return
    import base64
    try:
        raw = base64.b64decode(str(msg.get("bitmap_b64", "")))
    except Exception as ex:
        await _admin_confirm(ws, f"Bad bitmap encoding: {ex}")
        return
    if terrain.save_bitmap(raw):
        await _admin_confirm(ws,
            f"Terrain bitmap saved ({len(raw)} bytes) and active.")
    else:
        await _admin_confirm(ws,
            "Terrain save failed — size mismatch or I/O error. "
            "Check server log.")


async def _handle_admin_verify_email(ws, session: dict, msg: dict) -> None:
    if not _is_admin(session):
        return
    target = str(msg.get("username", "")).strip()
    if not target:
        await _admin_confirm(ws, "Usage: username required.")
        return
    with _db() as conn:
        cursor = conn.execute(
            "UPDATE players SET email_verified=1 WHERE username=?",
            (target,))
        conn.commit()
    if cursor.rowcount == 0:
        await _admin_confirm(ws, f"No account named {target!r}.")
        return
    print(f"[admin] {session['username']} manually verified email for "
          f"{target!r}")
    await _admin_confirm(ws, f"{target!r} email marked verified.")


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


## Tile editor v2 extras — per-tile color tint + passability flag, both
## defaulting to neutral. Stored as separate in-memory dicts so the
## existing tile_overrides:str string contract stays back-compat for
## anything that only cares about biome (gameplay code, biome_at_world).
tile_tints:       dict = {}   # (tx,ty) key → {"h": int, "v": int}   ±100 each
tile_passability: dict = {}   # (tx,ty) key → False                   True is default


def _tile_overrides_to_list() -> list:
    """Wire / login bulk format — list of {tx, ty, biome, tint_h, tint_v,
    passable} dicts. Defaults are baked in so older clients can still
    read just the biome field."""
    out = []
    keys = set(tile_overrides.keys()) | set(tile_tints.keys()) \
         | set(tile_passability.keys())
    for key in keys:
        try:
            tx_str, ty_str = key.split(",", 1)
            tx, ty = int(tx_str), int(ty_str)
        except (ValueError, AttributeError):
            continue
        tint = tile_tints.get(key, {})
        entry = {
            "tx": tx, "ty": ty,
            "biome": tile_overrides.get(key, ""),
            "tint_h": int(tint.get("h", 0)),
            "tint_v": int(tint.get("v", 0)),
            "passable": bool(tile_passability.get(key, True)),
        }
        out.append(entry)
    return out


def _load_tile_overrides_from_disk() -> None:
    """Populate in-memory tile dicts from the SQLite table. Post-consolidation
    the table is the single source of truth — the legacy JSON file is
    migrated and renamed to .bak by migration v2 on first boot."""
    global tile_overrides, tile_overrides_dirty, tile_tints, tile_passability
    try:
        with _db() as conn:
            rows = conn.execute(
                "SELECT tx, ty, biome, tint_h, tint_v, passable "
                "FROM tile_overrides").fetchall()
        tile_tints.clear()
        tile_passability.clear()
        for r in rows:
            key = _tile_key(int(r["tx"]), int(r["ty"]))
            biome_val = str(r["biome"] or "")
            if biome_val:
                tile_overrides[key] = biome_val
            h = int(r["tint_h"] or 0)
            v = int(r["tint_v"] or 0)
            if h != 0 or v != 0:
                tile_tints[key] = {"h": h, "v": v}
            p = bool(int(r["passable"] if r["passable"] is not None else 1))
            if not p:
                tile_passability[key] = False
        tile_overrides_dirty = False
        print(f"[tile_overrides] loaded {len(tile_overrides)} biomes, "
              f"{len(tile_tints)} tints, "
              f"{len(tile_passability)} blocked tiles from SQLite")
    except Exception as e:
        print(f"[tile_overrides] SQLite load failed: {e}")


def _save_tile_overrides_to_disk() -> None:
    """Flush the in-memory dict to the tile_overrides table. UPSERT per row
    so any concurrent admin edit racing this flush doesn't get clobbered."""
    global tile_overrides_dirty
    try:
        now = time.time()
        # A row is "live" if ANY of biome/tint/passability has a non-default
        # value for that tile. Union of the three in-memory dicts.
        live_keys = set(tile_overrides.keys()) | set(tile_tints.keys()) \
            | set(tile_passability.keys())
        with _db() as conn:
            existing = {(int(r["tx"]), int(r["ty"]))
                        for r in conn.execute("SELECT tx, ty FROM tile_overrides")}
            present: set = set()
            for key in live_keys:
                try:
                    tx_s, ty_s = key.split(",")
                    tx = int(tx_s); ty = int(ty_s)
                except (ValueError, AttributeError):
                    continue
                present.add((tx, ty))
                biome = str(tile_overrides.get(key, ""))
                tint = tile_tints.get(key, {})
                h = int(tint.get("h", 0))
                v = int(tint.get("v", 0))
                p_flag = 1 if tile_passability.get(key, True) else 0
                conn.execute(
                    "INSERT OR REPLACE INTO tile_overrides "
                    "(tx, ty, biome, tint_h, tint_v, passable, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (tx, ty, biome, h, v, p_flag, now))
            for tx, ty in existing - present:
                conn.execute(
                    "DELETE FROM tile_overrides WHERE tx=? AND ty=?", (tx, ty))
            conn.commit()
        tile_overrides_dirty = False
        print(f"[tile_overrides] saved {len(live_keys)} tile rows "
              f"({len(tile_overrides)} biomes, {len(tile_tints)} tints, "
              f"{len(tile_passability)} blocked)")
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
        # Town pledge tax skim — when this town is pledged to a warband,
        # 5% of the sale value is rerouted from the player to the warband's
        # shared bank gold. Player still sees `gain - tax` in their pocket;
        # tax appears in the warband's clan gold pool. Looked up by the
        # shopkeeper's NPC name (we have npc_id; map back to a known town).
        npc_name = ""
        try:
            sess_state = shopkeeper_state.get(npc_id, {})
            shop_id = str(sess_state.get("shop_id", ""))
            # Best-effort: try to find the NPC's name from world_entities
            # cache. Falls through to empty string → no tax if not found.
            we_row = conn.execute(
                "SELECT data FROM world_entities WHERE id=?",
                (npc_id,)).fetchone()
            if we_row:
                we_data = json.loads(we_row["data"] or "{}")
                npc_name = str(we_data.get("npc_name", ""))
        except Exception:
            pass
        town_id = _town_of_shopkeeper(npc_id, npc_name)
        tax = 0
        if town_id:
            warband_id = _warband_holding_town(conn, town_id)
            if warband_id:
                tax = int(gain * 0.05)
                if tax > 0:
                    conn.execute(
                        "UPDATE clans SET gold = COALESCE(gold, 0) + ? WHERE id = ?",
                        (tax, warband_id))
        net_gain = gain - tax
        current_gold = int(row["gold"] or 0)
        new_gold = current_gold + net_gain
        conn.execute(
            "UPDATE players SET gold=?, inventory=? WHERE id=?",
            (new_gold, json.dumps(inventory), session["id"]))
        conn.commit()
    session["inventory"] = inventory
    await _push_gold_and_inventory(ws, session, new_gold, inventory)
    await _send(ws, {"type": "shop_result", "ok": True,
                     "sold_qty": removed,
                     "gold_gained": net_gain})
    if tax > 0:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": f"({tax}g town tax to the ruling warband.)"})


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

# ── Structure sizing + placement helpers ─────────────────────────────────────
# Mirror of scripts/Interactable.gd _STRUCTURE_SIZES. Kept as a Python dict so
# the server can enforce non-overlap AABB placement + monster-blocked-attack
# range checks without a client roundtrip. If the client version changes both
# must be updated in lockstep — a single-source-of-truth would be a client
# push at boot; for MVP we hand-mirror.
_STRUCTURE_SIZES = {
    # Small
    "wall":            (32, 32),
    "fortified_wall":  (32, 32),
    "fence":           (32, 32),
    "gate":            (32, 32),
    # Medium
    "workbench":       (64, 64),
    "smith_station":   (64, 64),
    "bank_chest":      (64, 64),
    "armory_rack":     (64, 64),
    "well":            (64, 64),
    "altar":           (64, 64),
    "market_stall":    (64, 64),
    "site_marker":     (64, 64),
    "plant_bed":       (64, 64),
    "portal_shrine":   (64, 64),
    # Large
    "watchtower":      (128, 128),
    "guard_tower":     (128, 128),
    "house_frame":     (128, 128),
    "large_house":     (128, 128),
    "grand_hall":      (128, 128),
    "clan_hall":       (128, 128),
    "dock":            (128, 128),
}


# Per-tier HP multipliers matching Construction wood tiers.
_STRUCTURE_TIER_MULT = {
    "oak": 1.0, "pine": 1.1, "cherry": 1.3,
    "ironwood": 1.6, "frost": 2.0, "ancient": 2.6,
}


def _structure_max_hp(subtype: str, wood: str) -> int:
    """HP scales by size class × wood tier. Small=40, Medium=120, Large=320
    baseline; fortified_wall gets a bonus ×1.5."""
    size = _STRUCTURE_SIZES.get(subtype)
    if size is None:
        return 40
    w = size[0]
    if w >= 128:
        base = 320
    elif w >= 64:
        base = 120
    else:
        base = 40
    mult = _STRUCTURE_TIER_MULT.get(wood, 1.0)
    if subtype == "fortified_wall":
        mult *= 1.5
    return max(1, int(base * mult))


# Live structure state — populated at server boot from world_entities + a new
# structure_state SQLite table. Same partial-persist shape as monsters_state:
# HP + alive flag survive restart; combat participants are combat-only.
structures_state: dict = {}   # eid → {"hp": int, "max_hp": int, "alive": bool,
                              #         "subtype": str, "x": float, "y": float,
                              #         "owner": str, "wood": str}


# Banner territory radius — a warband's claim extends this many px from
# each of their banners. Chosen large enough that a single banner covers
# a small keep (~32-tile diameter) but small enough that a couple banners
# don't blanket the whole map. Tune once we ship warband raids at scale.
BANNER_TERRITORY_RADIUS = 512.0


def _territory_gate_for_player(session: dict, x: float, y: float):
    """Return None if `session`'s player can build at (x, y). Otherwise
    return a chat-back reason string.

    Rules (MVP — full no-man's-land shading is deferred):
      1. The point must be within BANNER_TERRITORY_RADIUS of at least one
         banner owned by the player's warband.
      2. The point must NOT be within any rival warband's banner radius.
         Rival territory OR "contested overlap" both reject.
      3. A player with no warband can't build anywhere via this path.
    """
    try:
        with _db() as conn:
            cid = _clan_id_for_player(conn, session["id"])
            if cid is None:
                return "You need a warband to build here."
            rows = conn.execute(
                "SELECT x, y, data FROM world_entities WHERE kind='resource' "
                "AND subtype='banner'"
            ).fetchall()
    except Exception:
        # Territory tables missing / DB error → fail-open for MVP so a
        # broken banner table doesn't hard-block all building.
        return None
    r2 = BANNER_TERRITORY_RADIUS * BANNER_TERRITORY_RADIUS
    inside_own = False
    inside_rival = False
    for row in rows:
        try:
            bdata = json.loads(row["data"] or "{}")
        except Exception:
            bdata = {}
        wb_id = str(bdata.get("warband_id", ""))
        if not wb_id:
            continue
        bx, by = float(row["x"]), float(row["y"])
        dx = x - bx
        dy = y - by
        if dx * dx + dy * dy > r2:
            continue
        if wb_id == cid:
            inside_own = True
        else:
            inside_rival = True
    if inside_rival:
        return ("Contested / rival territory."
                if inside_own else "Enemy territory.")
    if not inside_own:
        return "Outside your warband's territory."
    return None


def _structure_at_edge(mx: float, my: float, reach: float):
    """Return (eid, dist_to_edge) for the ALIVE structure whose hitbox edge
    is within `reach` of (mx, my). Nearest wins. Used by the monster AI:
    when a chase step is blocked, the monster attacks the closest structure
    it can reach instead of stalling."""
    best_eid = None
    best_d = reach + 0.1
    for eid, st in structures_state.items():
        if not st.get("alive", True):
            continue
        size = _STRUCTURE_SIZES.get(st["subtype"], (32, 32))
        half_w = size[0] / 2.0
        half_h = size[1] / 2.0
        dx = max(0.0, abs(mx - st["x"]) - half_w)
        dy = max(0.0, abs(my - st["y"]) - half_h)
        d = (dx * dx + dy * dy) ** 0.5
        if d <= reach and d < best_d:
            best_d = d
            best_eid = eid
    return (best_eid, best_d)


def _placement_would_overlap(subtype: str, x: float, y: float) -> bool:
    """Return True if placing a `subtype` structure at (x, y) would overlap
    ANY existing structure's AABB. Rejects hitbox overlap only; a structure
    can still sit next to (touching) another one, which is the expected
    "connectable" behavior the user asked for."""
    if subtype not in _STRUCTURE_SIZES:
        return False
    w, h = _STRUCTURE_SIZES[subtype]
    new_min_x, new_min_y = x - w / 2.0, y - h / 2.0
    new_max_x, new_max_y = x + w / 2.0, y + h / 2.0
    with _db() as conn:
        rows = conn.execute(
            "SELECT subtype, x, y FROM world_entities WHERE kind='resource'"
        ).fetchall()
    for r in rows:
        other_sub = str(r["subtype"])
        if other_sub not in _STRUCTURE_SIZES:
            continue
        ow, oh = _STRUCTURE_SIZES[other_sub]
        ox, oy = float(r["x"]), float(r["y"])
        omin_x, omin_y = ox - ow / 2.0, oy - oh / 2.0
        omax_x, omax_y = ox + ow / 2.0, oy + oh / 2.0
        # AABB overlap test.
        if (new_min_x < omax_x and new_max_x > omin_x
                and new_min_y < omax_y and new_max_y > omin_y):
            return True
    return False


# Interiors live FAR outside the exterior 300×300 tile grid (which ends
# at 9600 px). The exterior shader clips there, so anywhere past ~y=10000
# the player is drawn against nothing but the game's clear color — that's
# what makes it read as a "different scene" instead of a corner of the
# main map. Each interior gets its own island of coordinates 1000 px
# apart on the Y axis so their scenes never overlap even if the room
# sizes grow later.
_INTERIOR_ROOMS = {
    "great_hall": (500.0, 12000.0),
    "tavern":     (500.0, 13000.0),
    "chapel":     (500.0, 14000.0),
    "warehouse":  (500.0, 15000.0),
    "house":      (500.0, 16000.0),
}

# ── Per-building interior allocation ─────────────────────────────────────────
# Each unique building instance (different town, different door, different
# admin-placed structure) gets its OWN plot in the interior band so admin-
# painted floors + walls persist per-building. The base _INTERIOR_ROOMS above
# is only used as a fallback / theme reference.
#
# Grid layout of the interior band (y >= 12000 px, tx 15..225):
#   - Each plot: 25 tiles wide × 20 tiles tall (800 × 640 px)
#   - Origin at (tx=15, ty=375) → world (480, 12000)
#   - 8 columns × 8 rows = 64 plots (plenty for a small town-heavy world)
_INTERIOR_PLOT_W_TILES = 25
_INTERIOR_PLOT_H_TILES = 20
_INTERIOR_PLOT_COLS    = 8
_INTERIOR_PLOT_ROWS    = 8
_INTERIOR_ORIGIN_TX    = 15
_INTERIOR_ORIGIN_TY    = 375


def _interior_coord_for(key: str) -> tuple[float, float]:
    """Deterministic allocation — same key ALWAYS resolves to the same plot,
    so painted tiles persist per building without needing a separate
    assignment table. Slot count is bounded; if two buildings hash to the
    same slot they share the interior (rare for a village-scale world)."""
    import hashlib
    h = int(hashlib.sha1(key.encode()).hexdigest()[:8], 16)
    total = _INTERIOR_PLOT_COLS * _INTERIOR_PLOT_ROWS
    idx = h % total
    col = idx % _INTERIOR_PLOT_COLS
    row = idx // _INTERIOR_PLOT_COLS
    tx = _INTERIOR_ORIGIN_TX + col * _INTERIOR_PLOT_W_TILES
    ty = _INTERIOR_ORIGIN_TY + row * _INTERIOR_PLOT_H_TILES
    # Center the player inside the plot — 12 tiles right, 10 tiles down.
    return (float((tx + 12) * 32), float((ty + 10) * 32))


async def _handle_enter_interior(ws, session: dict, msg: dict) -> None:
    door_id = str(msg.get("door_id", "")).strip()
    # Client-side hint for hardcoded town buildings that live only as
    # Interactable nodes with `t:N` ids (never in world_entities). If the
    # SQL lookup below whiffs, we fall back to this hint. Admin-placed
    # buildings + doors leave the hint empty and use the DB path.
    interior_id_hint = str(msg.get("interior_id_hint", "")).strip().lower()
    if not door_id and not interior_id_hint:
        await _send(ws, {"type": "interior_error",
                         "reason": "Missing door id."})
        return
    # If already inside an interior, refuse the entry — design choice: doors
    # are exterior-only for v1, no chained interiors.
    if session.get("interior_id", "") != "":
        await _send(ws, {"type": "interior_error",
                         "reason": "You're already inside."})
        return
    row = None
    if door_id:
        with _db() as conn:
            row = conn.execute(
                "SELECT kind, subtype, x, y, data FROM world_entities WHERE id=?",
                (door_id,)).fetchone()
    if not row and not interior_id_hint:
        await _send(ws, {"type": "interior_error",
                         "reason": "Door not found."})
        return
    # ── Hardcoded-building fast path ──
    # No world_entities row but the client gave us a hint. Skip the
    # subtype + proximity checks (the client's own action-menu range
    # gate handled misclicks); accept the hint as the interior_id.
    if not row:
        valid_hints = {"great_hall", "tavern", "warehouse", "chapel", "house"}
        if interior_id_hint not in valid_hints:
            await _send(ws, {"type": "interior_error",
                             "reason": "Unknown interior."})
            return
        rx = float(session.get("x", 0.0))
        ry = float(session.get("y", 0.0))
        # Per-building interior — key by (theme, rounded exterior position)
        # so each building instance in each town gets its own plot. Two
        # different taverns (Kjelvik vs Frostheim) hash to different rooms
        # and admin paint stays local to each.
        key = f"{interior_id_hint}:{round(rx / 32.0)}:{round(ry / 32.0)}"
        tx, ty = _interior_coord_for(key)
        session["interior_id"] = interior_id_hint
        session["interior_x"]  = tx
        session["interior_y"]  = ty
        # Save the EXTERIOR return position — session["x"]/["y"] will be
        # overwritten by interior-side movement updates so we can't rely
        # on them at exit time. Server-truth for where to teleport back.
        session["interior_return_x"] = rx
        session["interior_return_y"] = ry
        with _db() as conn:
            conn.execute(
                "UPDATE players SET interior_id=?, interior_x=?, interior_y=?, "
                "interior_return_x=?, interior_return_y=? WHERE id=?",
                (interior_id_hint, tx, ty, rx, ry, session["id"]))
            conn.commit()
        await _send(ws, {
            "type":        "interior_entered",
            "interior_id": interior_id_hint,
            "x":           tx,
            "y":           ty,
            "return_x":    rx,
            "return_y":    ry,
        })
        print(f"[interior] {session['username']} entered {interior_id_hint} "
              f"at ({tx}, {ty}) via hardcoded building")
        return
    # Accept both explicit doors AND buildings — the user clicks the
    # building sprite directly, so requiring a separately-placed door
    # entity was too fussy for admin content creation.
    subtype = str(row["subtype"])
    if subtype != "door" and subtype != "building":
        await _send(ws, {"type": "interior_error",
                         "reason": "Not enterable."})
        return
    # Proximity check — anti-cheat plus prevents misclicks on far-away doors.
    # Buildings get a wider range since they're larger and the clickable
    # sprite is generous; DOOR_INTERACT_RANGE was tuned to a 28×38 door
    # sprite, but the new 100×90 buildings need more slack.
    dx = float(session.get("x", 0.0)) - float(row["x"])
    dy = float(session.get("y", 0.0)) - float(row["y"])
    reach = DOOR_INTERACT_RANGE * (2.0 if subtype == "building" else 1.0)
    if dx * dx + dy * dy > reach * reach:
        await _send(ws, {"type": "interior_error",
                         "reason": "You're too far from the entrance."})
        return
    try:
        data = json.loads(row["data"] or "{}")
    except Exception:
        data = {}
    interior_id = str(data.get("interior_id", ""))
    # For buildings without an explicit data.interior_id, derive one from
    # the entity's display_name so admin placements Just Work. Great Hall
    # → great_hall, Tavern → tavern, Warehouse → warehouse, Chapel →
    # chapel, House → house (fallback default in InteriorScene handles
    # unknowns cleanly).
    if not interior_id and subtype == "building":
        display_name = str(data.get("display_name", "")).strip().lower()
        _BUILDING_TO_INTERIOR = {
            "great hall": "great_hall",
            "tavern":     "tavern",
            "warehouse":  "warehouse",
            "chapel":     "chapel",
            "house":      "house",
        }
        interior_id = _BUILDING_TO_INTERIOR.get(display_name, "house")
    if not interior_id:
        await _send(ws, {"type": "interior_error",
                         "reason": "This door leads nowhere."})
        return
    rx = float(session.get("x", 0.0))
    ry = float(session.get("y", 0.0))
    # Per-building allocation — use the DB entity id if we have one so a
    # persisted door/building keeps the same interior across restarts.
    key = f"{interior_id}:{door_id}" if door_id else \
          f"{interior_id}:{round(rx / 32.0)}:{round(ry / 32.0)}"
    tx, ty = _interior_coord_for(key)
    session["interior_id"] = interior_id
    session["interior_x"]  = tx
    session["interior_y"]  = ty
    session["interior_return_x"] = rx
    session["interior_return_y"] = ry
    with _db() as conn:
        conn.execute(
            "UPDATE players SET interior_id=?, interior_x=?, interior_y=?, "
            "interior_return_x=?, interior_return_y=? WHERE id=?",
            (interior_id, tx, ty, rx, ry, session["id"]))
        conn.commit()
    await _send(ws, {
        "type":        "interior_entered",
        "interior_id": interior_id,
        "x":           tx,
        "y":           ty,
        "return_x":    rx,
        "return_y":    ry,
    })
    print(f"[interior] {session['username']} entered {interior_id} "
          f"at ({tx}, {ty}) via door {door_id}")


async def _handle_exit_interior(ws, session: dict, msg: dict) -> None:
    if session.get("interior_id", "") == "":
        await _send(ws, {"type": "interior_error",
                         "reason": "You're not inside an interior."})
        return
    interior_id = session["interior_id"]
    # Server-truth return coord saved on entry. session["x"]/["y"] are
    # the LIVE player position — during interior play those got updated
    # to y=12000+ interior coords, so using them here dumped players
    # near the world corner. Use the saved entry position instead.
    return_x = float(session.get("interior_return_x", 0.0))
    return_y = float(session.get("interior_return_y", 0.0))
    session["interior_id"] = ""
    session["interior_x"]  = 0.0
    session["interior_y"]  = 0.0
    session["interior_return_x"] = 0.0
    session["interior_return_y"] = 0.0
    # Snap the server's authoritative player position back to the return
    # coord immediately so any nearby-broadcast queries during the same
    # tick see the exterior position, not a stale interior one.
    session["x"] = return_x
    session["y"] = return_y
    with _db() as conn:
        conn.execute(
            "UPDATE players SET interior_id='', interior_x=0, interior_y=0, "
            "interior_return_x=0, interior_return_y=0, x=?, y=? WHERE id=?",
            (return_x, return_y, session["id"]))
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


async def _handle_admin_tile_set_bulk(ws, session: dict, msg: dict) -> None:
    """Bulk paint — N tiles in one message. Used by brush sizes >1×1
    and flood fill. Avoids spamming N separate `tile_set` messages.
    Format: {"tiles": [{"tx":int, "ty":int, "biome":str|null}, ...]}
    A null biome clears the override (same as admin_tile_clear)."""
    global tile_overrides_dirty
    if not _is_admin(session):
        return
    raw = msg.get("tiles", [])
    if not isinstance(raw, list):
        return
    changes = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        try:
            tx = int(entry.get("tx", -1))
            ty = int(entry.get("ty", -1))
        except Exception:
            continue
        if tx < 0 or ty < 0:
            continue
        b = entry.get("biome", None)
        key = _tile_key(tx, ty)
        if b is None or str(b).strip() == "":
            if tile_overrides.pop(key, None) is not None:
                changes.append({"tx": tx, "ty": ty, "biome": None})
        else:
            biome = str(b).strip()
            tile_overrides[key] = biome
            changes.append({"tx": tx, "ty": ty, "biome": biome})
    if changes:
        tile_overrides_dirty = True
        _broadcast({"type": "tile_set_bulk", "tiles": changes})


def _biome_at_for_server(tx: int, ty: int) -> str:
    """Server's view of the current biome at (tx, ty). Returns the override
    if one exists; otherwise empty string (server doesn't know the
    procedural base). Flood-fill uses this — when no override exists the
    fill is over the "default" pseudo-biome '' which still gives the
    expected behavior (paints any unpainted tile that's connected)."""
    return str(tile_overrides.get(_tile_key(tx, ty), ""))


async def _handle_admin_tile_flood_fill(ws, session: dict, msg: dict) -> None:
    """BFS flood fill from (tx, ty), replacing all 4-connected tiles
    of the SAME current biome with `biome`. Capped at 5000 tiles so a
    bad click on a huge ocean doesn't repaint the whole world."""
    global tile_overrides_dirty
    if not _is_admin(session):
        return
    tx = int(msg.get("tx", -1))
    ty = int(msg.get("ty", -1))
    biome = str(msg.get("biome", "")).strip()
    if tx < 0 or ty < 0 or not biome:
        return
    GRID_W, GRID_H = 300, 300
    if tx >= GRID_W or ty >= GRID_H:
        return
    src = _biome_at_for_server(tx, ty)
    if src == biome:
        return
    visited = set()
    queue = [(tx, ty)]
    changes = []
    CAP = 5000
    while queue and len(changes) < CAP:
        cx, cy = queue.pop()
        if (cx, cy) in visited:
            continue
        visited.add((cx, cy))
        if cx < 0 or cy < 0 or cx >= GRID_W or cy >= GRID_H:
            continue
        if _biome_at_for_server(cx, cy) != src:
            continue
        key = _tile_key(cx, cy)
        tile_overrides[key] = biome
        changes.append({"tx": cx, "ty": cy, "biome": biome})
        queue.extend([(cx + 1, cy), (cx - 1, cy),
                      (cx, cy + 1), (cx, cy - 1)])
    if changes:
        tile_overrides_dirty = True
        _broadcast({"type": "tile_set_bulk", "tiles": changes})
        await _admin_confirm(ws,
            f"Flood filled {len(changes)} tile(s) with '{biome}'.")
    else:
        await _admin_confirm(ws, "Nothing connected to flood — no change.")


async def _handle_admin_tile_tint(ws, session: dict, msg: dict) -> None:
    """Set per-tile color tint. h and v are integers in [-100, 100] which
    the shader maps to ±20% hue / brightness. tiles: list of {tx, ty}."""
    global tile_overrides_dirty
    if not _is_admin(session):
        return
    h = max(-100, min(100, int(msg.get("h", 0))))
    v = max(-100, min(100, int(msg.get("v", 0))))
    raw = msg.get("tiles", [])
    if not isinstance(raw, list):
        return
    changes = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        try:
            tx = int(entry.get("tx", -1))
            ty = int(entry.get("ty", -1))
        except Exception:
            continue
        if tx < 0 or ty < 0:
            continue
        key = _tile_key(tx, ty)
        if h == 0 and v == 0:
            tile_tints.pop(key, None)
        else:
            tile_tints[key] = {"h": h, "v": v}
        changes.append({"tx": tx, "ty": ty, "h": h, "v": v})
    if changes:
        tile_overrides_dirty = True
        _broadcast({"type": "tile_tint_bulk", "tiles": changes})


async def _handle_admin_tile_passability(ws, session: dict, msg: dict) -> None:
    """Toggle or set per-tile passability. tiles: list of {tx, ty}.
    passable: bool (True = walkable, False = blocked)."""
    global tile_overrides_dirty
    if not _is_admin(session):
        return
    p_flag = bool(msg.get("passable", True))
    raw = msg.get("tiles", [])
    if not isinstance(raw, list):
        return
    changes = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        try:
            tx = int(entry.get("tx", -1))
            ty = int(entry.get("ty", -1))
        except Exception:
            continue
        if tx < 0 or ty < 0:
            continue
        key = _tile_key(tx, ty)
        if p_flag:
            tile_passability.pop(key, None)
        else:
            tile_passability[key] = False
        changes.append({"tx": tx, "ty": ty, "passable": p_flag})
    if changes:
        tile_overrides_dirty = True
        _broadcast({"type": "tile_passability_bulk", "tiles": changes})


async def _handle_admin_tile_clear(ws, session: dict, msg: dict) -> None:
    global tile_overrides_dirty
    if not _is_admin(session):
        return
    tx = int(msg.get("tx", -1))
    ty = int(msg.get("ty", -1))
    if tx < 0 or ty < 0:
        return
    key = _tile_key(tx, ty)
    if tile_overrides.pop(key, None) is not None:
        tile_overrides_dirty = True
    # Erase also clears tint + passability for the tile — admin
    # "(erase)" is a full reset to the procedural baseline.
    tile_tints.pop(key, None)
    if tile_passability.pop(key, None) is not None:
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


async def _handle_build_wall(ws, session: dict, msg: dict) -> None:
    """Player-crafted wall placement (Phase 3 of Construction integration).
    Client has already deducted materials + granted XP; server does level
    gating + placement. Two subtypes: `wall` (level 1, any wood tier) and
    `fortified_wall` (level 70, iron/mithril/runite reinforcement). Persists
    as a resource-kind world entity so it loads via the standard admin
    entity path on relog and broadcasts to nearby clients."""
    subtype = str(msg.get("subtype", "")).strip()
    if subtype not in ("wall", "fortified_wall"):
        await _send(ws, {"type": "chat", "username": "System",
                         "text": "Unknown wall type."})
        return
    min_lv = 70 if subtype == "fortified_wall" else 1
    with _db() as conn:
        row = conn.execute("SELECT skill_xp FROM players WHERE id=?",
                           (session["id"],)).fetchone()
    skill_xp = json.loads(row["skill_xp"] or "{}") if row else {}
    if _calc_level(int(skill_xp.get("construction", 0))) < min_lv:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": f"Requires Construction level {min_lv}."})
        return
    x = float(msg.get("x", session.get("x", 0.0)))
    y = float(msg.get("y", session.get("y", 0.0)))
    # Placement guards — apply BEFORE the SQL insert so we don't have to
    # rollback on rejection.
    # 1. Non-overlap: two structures can't occupy the same footprint.
    if _placement_would_overlap(subtype, x, y):
        await _send(ws, {"type": "chat", "username": "System",
                         "text": "Can't build there — overlaps another structure."})
        return
    # 2. Territory gate: banner-radius check unless the player is an admin.
    #    Non-admin players must be within one of their own warband's banner
    #    radii AND outside every enemy warband's banner radius. Enforces
    #    "build in your own turf only" and blocks rival encroachment.
    if not _is_admin(session):
        gate_err = _territory_gate_for_player(session, x, y)
        if gate_err:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": gate_err})
            return
    wood = str(msg.get("wood", "oak"))
    display_name = str(msg.get("display_name", "Wall")).strip() or "Wall"
    color_arr = msg.get("color", [0.55, 0.36, 0.18, 1.0])
    if not isinstance(color_arr, list) or len(color_arr) < 4:
        color_arr = [0.55, 0.36, 0.18, 1.0]
    eid = "a:" + secrets.token_hex(8)
    data = {
        "type_str":     subtype,
        "display_name": display_name,
        "skill":        "construction",
        "level":        min_lv,
        "action":       "Inspect",
        "color":        color_arr,
        "wood":         wood,
        "owner":        session["username"],
    }
    with _db() as conn:
        conn.execute(
            "INSERT INTO world_entities (id, kind, subtype, x, y, data) "
            "VALUES (?,?,?,?,?,?)",
            (eid, "resource", subtype, x, y, json.dumps(data)))
        conn.commit()
    # Seed HP state so damage flow works from tick 1 (same as admin_place).
    max_hp_s = _structure_max_hp(subtype, wood)
    structures_state[eid] = {
        "hp": max_hp_s, "max_hp": max_hp_s, "alive": True,
        "subtype": subtype, "x": x, "y": y,
        "owner": session["username"], "wood": wood,
    }
    _mark_structure_dirty(eid)
    data["hp"] = max_hp_s
    data["max_hp"] = max_hp_s
    data["alive"] = True
    entity = {"id": eid, "kind": "resource", "subtype": subtype,
              "x": x, "y": y, "data": data}
    _broadcast({"type": "world_entity_add", "entity": entity})
    await _send(ws, {"type": "chat", "username": "System",
                     "text": f"You raise a {display_name}."})
    print(f"[wall] {session['username']} built {subtype} ({wood}) "
          f"at ({x:.0f},{y:.0f})")


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


# ── Warband structures (stronghold / banner / outpost) ───────────────────────
# Same persistence pattern as farm_plot but with three new kinds and
# explicit per-warband caps + spatial rules.

WARBAND_STRUCTURE_RULES = {
    "stronghold": {
        "min_construction": 50,
        "min_warband_size": 6,      # leader + 5 members
        "per_warband_cap":  1,
        "spacing_px":       2048.0, # 64 tiles between any two strongholds
    },
    "banner": {
        "min_construction": 25,
        "min_warband_size": 1,
        "per_warband_cap":  12,
        # Banner non-overlap: each banner claims a 16-tile radius (512 px),
        # so two banners must be at LEAST 1024 px (32 tiles) apart so their
        # claim circles don't intersect.
        "spacing_px":       1024.0,
    },
    "outpost": {
        "min_construction": 20,
        "min_warband_size": 1,
        # Outpost cap is per-warband total. Three outposts per banner is
        # enforced more loosely: server caps the total at 3 × banner_count
        # so a warband with 4 banners can have up to 12 outposts.
        "per_warband_cap":  36,
        "spacing_px":       128.0,  # token spacing so outposts don't stack
    },
}


def _warband_size(conn, clan_id: str) -> int:
    row = conn.execute(
        "SELECT COUNT(*) AS c FROM clan_members WHERE clan_id=?",
        (clan_id,)).fetchone()
    return int(row["c"]) if row else 0


def _warband_entity_count(conn, clan_id: str, kind: str) -> int:
    """Count world_entities for this warband+kind. Reads `warband_id` out
    of the data JSON — slow path uses LIKE; acceptable at our row count."""
    rows = conn.execute(
        "SELECT data FROM world_entities WHERE kind=?", (kind,)).fetchall()
    n = 0
    for r in rows:
        try:
            d = json.loads(r["data"] or "{}")
        except Exception:
            continue
        if str(d.get("warband_id", "")) == clan_id:
            n += 1
    return n


def _nearest_entity_distance(conn, kind: str, x: float, y: float) -> float:
    """Returns the distance in px from (x, y) to the nearest existing entity
    of `kind`. INF if none exist."""
    rows = conn.execute(
        "SELECT x, y FROM world_entities WHERE kind=?", (kind,)).fetchall()
    best = float("inf")
    for r in rows:
        dx = float(r["x"]) - x
        dy = float(r["y"]) - y
        d2 = dx * dx + dy * dy
        if d2 < best * best:
            best = d2 ** 0.5
    return best


async def _handle_banner_raid(ws, session: dict, msg: dict) -> None:
    """Player clicked an enemy banner with intent to raid. Drops banner
    integrity by 25; if it falls to 0, the banner is destroyed (removed
    from world_entities) and the tile reverts to neutral. Mission-based
    means there's no PvP — the raider takes a single deliberate action
    against the structure rather than an opposing player. Rules:
       - Banner must exist.
       - Raider's warband ≠ banner's warband.
       - Raider's warband not allied with banner's warband.
       - Raider must be within 256 px of the banner (close-quarters)."""
    eid = str(msg.get("entity_id", "")).strip()
    if not eid:
        return
    with _db() as conn:
        row = conn.execute(
            "SELECT id, x, y, data FROM world_entities "
            "WHERE id = ? AND kind = 'banner'",
            (eid,)).fetchone()
        if row is None:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "That banner no longer exists."})
            return
        try:
            data = json.loads(row["data"] or "{}")
        except Exception:
            data = {}
        banner_warband = str(data.get("warband_id", ""))
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Only warband members can raid."})
            return
        if cid == banner_warband:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "That's your own banner."})
            return
        if _are_allied(conn, cid, banner_warband):
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Allied warbands cannot raid each other."})
            return
        # Proximity gate — within 256 px (8 tiles) of the banner.
        bx, by = float(row["x"]), float(row["y"])
        sx, sy = float(session.get("x", 0.0)), float(session.get("y", 0.0))
        if (sx - bx) ** 2 + (sy - by) ** 2 > 256.0 * 256.0:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "You must be at the banner to raid it."})
            return
        # Apply 25 integrity damage.
        cur_int = int(data.get("integrity", 100))
        new_int = max(0, cur_int - 25)
        data["integrity"] = new_int
        if new_int <= 0:
            conn.execute("DELETE FROM world_entities WHERE id=?", (eid,))
            conn.commit()
            _broadcast({"type": "world_entity_remove", "id": eid})
            _broadcast({"type": "chat", "username": "System",
                        "text": f"A warband banner has fallen at "
                                f"({int(bx)},{int(by)})."})
            print(f"[raid] banner {eid} destroyed by {session['username']}")
            return
        conn.execute(
            "UPDATE world_entities SET data=? WHERE id=?",
            (json.dumps(data), eid))
        conn.commit()
    _broadcast({"type": "world_entity_update", "id": eid, "data": data})
    await _send(ws, {"type": "chat", "username": "System",
                     "text": f"You strike the banner. Integrity: {new_int}/100."})


async def _handle_banner_reinforce(ws, session: dict, msg: dict) -> None:
    """Owner-warband member spends 200 gold from the warband bank to
    restore 20 integrity to one of their banners. Capped at 100."""
    eid = str(msg.get("entity_id", "")).strip()
    if not eid:
        return
    with _db() as conn:
        row = conn.execute(
            "SELECT id, x, y, data FROM world_entities "
            "WHERE id = ? AND kind = 'banner'",
            (eid,)).fetchone()
        if row is None:
            return
        try:
            data = json.loads(row["data"] or "{}")
        except Exception:
            data = {}
        banner_warband = str(data.get("warband_id", ""))
        cid = _clan_id_for_player(conn, session["id"])
        if cid != banner_warband:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Only members of the owning warband can "
                                      "reinforce this banner."})
            return
        clan_row = conn.execute("SELECT gold FROM clans WHERE id=?",
                                (cid,)).fetchone()
        cur_gold = int(clan_row["gold"] or 0) if clan_row else 0
        if cur_gold < 200:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Your warband bank needs 200g to "
                                      "reinforce a banner."})
            return
        cur_int = int(data.get("integrity", 100))
        if cur_int >= 100:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Banner already at full integrity."})
            return
        new_int = min(100, cur_int + 20)
        data["integrity"] = new_int
        new_gold = cur_gold - 200
        conn.execute("UPDATE clans SET gold=? WHERE id=?", (new_gold, cid))
        conn.execute(
            "UPDATE world_entities SET data=? WHERE id=?",
            (json.dumps(data), eid))
        conn.commit()
    _broadcast({"type": "world_entity_update", "id": eid, "data": data})
    await _send(ws, {"type": "chat", "username": "System",
                     "text": f"Banner reinforced. Integrity: {new_int}/100. "
                              f"(-200g warband bank)"})


async def _handle_build_warband_structure(ws, session: dict, msg: dict) -> None:
    """Place a warband stronghold / banner / outpost at (x, y). Validates:
       1. Warband membership + Warrant of the High Seat (admins exempt).
       2. Per-kind construction level + warband size requirements.
       3. Per-warband cap (1 stronghold, 12 banners, 36 outposts).
       4. Spatial: stronghold-vs-stronghold 2048 px, banner non-overlap
          1024 px, outpost token-spacing 128 px.
    On success: INSERT into world_entities with data {warband_id, owner,
    integrity}, broadcast world_entity_add for live render."""
    kind = str(msg.get("kind", "")).strip()
    if kind not in WARBAND_STRUCTURE_RULES:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": f"Unknown structure kind: {kind}"})
        return
    rules = WARBAND_STRUCTURE_RULES[kind]
    x = float(msg.get("x", session["x"]))
    y = float(msg.get("y", session["y"]))
    admin = _is_admin(session)
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Only warband members can build that."})
            return
        # Warrant check (admins exempt).
        if not admin and not _player_has_item(session["id"], "high_seat_warrant"):
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Your warband needs the Warrant of the "
                                      "High Seat to build that."})
            return
        # Construction level.
        row = conn.execute("SELECT skill_xp FROM players WHERE id=?",
                           (session["id"],)).fetchone()
        skill_xp = json.loads(row["skill_xp"] or "{}") if row else {}
        clv = _calc_level(int(skill_xp.get("construction", 0)))
        if not admin and clv < rules["min_construction"]:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": f"Requires Construction level "
                                      f"{rules['min_construction']}."})
            return
        # Warband size (only stronghold has > 1 today, but the field
        # generalizes cleanly).
        if rules["min_warband_size"] > 1:
            wsz = _warband_size(conn, cid)
            if not admin and wsz < rules["min_warband_size"]:
                await _send(ws, {"type": "chat", "username": "System",
                                 "text": f"Your warband needs at least "
                                          f"{rules['min_warband_size']} members "
                                          f"to build a {kind}."})
                return
        # Per-warband cap.
        owned = _warband_entity_count(conn, cid, kind)
        if not admin and owned >= rules["per_warband_cap"]:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": f"Warband already has {owned} "
                                      f"{kind}(s) — cap reached."})
            return
        # Spacing rule — same-kind only (stronghold-vs-stronghold,
        # banner-vs-banner, outpost-vs-outpost).
        nearest = _nearest_entity_distance(conn, kind, x, y)
        if not admin and nearest < rules["spacing_px"]:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": f"Too close to another {kind} "
                                      f"({int(nearest)} px, need "
                                      f"{int(rules['spacing_px'])}+)."})
            return
        # All checks pass — insert.
        eid = "a:" + secrets.token_hex(8)
        data = {
            "warband_id": cid,
            "owner":      session["username"],
            "integrity":  100,
        }
        conn.execute(
            "INSERT INTO world_entities (id, kind, subtype, x, y, data) "
            "VALUES (?,?,?,?,?,?)",
            (eid, kind, kind, x, y, json.dumps(data)))
        conn.commit()
    entity = {"id": eid, "kind": kind, "subtype": kind,
              "x": x, "y": y, "data": data}
    _broadcast({"type": "world_entity_add", "entity": entity})
    await _send(ws, {"type": "chat", "username": "System",
                     "text": f"You raise a warband {kind}."})
    print(f"[warband] {session['username']} built {kind} at "
          f"({x:.0f},{y:.0f}) for clan {cid}")


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
    # Warband-creation prerequisite: the Five Tokens quest line awards the
    # "Warrant of the High Seat" on completion. No warrant = no warband.
    # Admins bypass — they can stress-test the system without farming Tokens.
    if not _is_admin(session) and not _player_has_item(session["id"],
            "high_seat_warrant"):
        await _send(ws, {"type": "clan_result", "ok": False,
                         "reason": "You must earn the Warrant of the High Seat. "
                                    "Complete the Five Tokens quest line first."})
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


# ── Warband alliances ────────────────────────────────────────────────────────
# /ally <name>     — leader proposes pact. Stored as a pending offer in
#                    memory until target leader also issues /ally <name>.
#                    Both within 60s → pact written to warband_alliances.
# /unally          — leader dissolves an existing pact.

_pending_ally_offers: dict = {}    # proposer_clan_id → (target_clan_id, expires_at)
ALLY_OFFER_TIMEOUT = 60.0


def _alliance_of(conn, clan_id: str) -> str:
    """Returns the ally warband_id for `clan_id`, or '' if not allied.
    Checks both columns of the warband_alliances row (pair stored
    canonically with min id first)."""
    row = conn.execute(
        "SELECT warband_a, warband_b FROM warband_alliances "
        "WHERE warband_a = ? OR warband_b = ? LIMIT 1",
        (clan_id, clan_id)).fetchone()
    if row is None:
        return ""
    if str(row["warband_a"]) == clan_id:
        return str(row["warband_b"])
    return str(row["warband_a"])


def _are_allied(conn, a: str, b: str) -> bool:
    if not a or not b or a == b:
        return False
    ally = _alliance_of(conn, a)
    return ally == b


async def _handle_ally_command(ws, session: dict, text: str) -> None:
    """Handles /ally <warband_name> and /unally. Leader-only. Server
    enforces one-pact-per-warband and the 60s mutual-handshake window."""
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "You are not in a warband."})
            return
        clan = conn.execute("SELECT leader_id, name FROM clans WHERE id=?",
                            (cid,)).fetchone()
        if not clan or clan["leader_id"] != session["id"]:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Only the warband leader can do that."})
            return
        # /unally
        if text == "/unally":
            cur_ally = _alliance_of(conn, cid)
            if not cur_ally:
                await _send(ws, {"type": "chat", "username": "System",
                                 "text": "Your warband has no ally."})
                return
            conn.execute(
                "DELETE FROM warband_alliances "
                "WHERE warband_a = ? OR warband_b = ?", (cid, cid))
            conn.commit()
            other_name_row = conn.execute(
                "SELECT name FROM clans WHERE id=?", (cur_ally,)).fetchone()
            other_name = str(other_name_row["name"]) if other_name_row else cur_ally
            _broadcast({"type": "chat", "username": "System",
                        "text": f"{clan['name']} and {other_name} are no "
                                f"longer allied."})
            return
        # /ally <name>
        target_name = text[len("/ally "):].strip()
        if not target_name:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Usage: /ally <warband name>"})
            return
        target_row = conn.execute(
            "SELECT id, leader_id FROM clans WHERE name = ? COLLATE NOCASE",
            (target_name,)).fetchone()
        if not target_row:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": f"No warband named '{target_name}'."})
            return
        target_cid = str(target_row["id"])
        if target_cid == cid:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "You cannot ally with your own warband."})
            return
        # One-pact rule.
        if _alliance_of(conn, cid):
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Your warband already has an ally. "
                                     "Use /unally to break the pact first."})
            return
        if _alliance_of(conn, target_cid):
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "That warband already has an ally."})
            return
        now = time.time()
        # Reciprocal check — did the OTHER leader call /ally on US recently?
        their_offer = _pending_ally_offers.get(target_cid)
        if their_offer and their_offer[0] == cid and their_offer[1] >= now:
            # Pact forged — canonical (min, max) row.
            a, b = (cid, target_cid) if cid < target_cid else (target_cid, cid)
            conn.execute(
                "INSERT INTO warband_alliances (warband_a, warband_b, pacted_at) "
                "VALUES (?, ?, ?)",
                (a, b, now))
            conn.commit()
            _pending_ally_offers.pop(target_cid, None)
            _pending_ally_offers.pop(cid, None)
            our_name_row = conn.execute(
                "SELECT name FROM clans WHERE id=?", (cid,)).fetchone()
            _broadcast({"type": "chat", "username": "System",
                        "text": f"⚔ {our_name_row['name']} and "
                                f"{target_row['leader_id'] and target_name} "
                                f"have forged an alliance."})
            return
        # First leader to propose — record offer, await reciprocal.
        _pending_ally_offers[cid] = (target_cid, now + ALLY_OFFER_TIMEOUT)
        await _send(ws, {"type": "chat", "username": "System",
                         "text": f"Alliance offered to {target_name}. "
                                 f"Their leader has 60s to accept by typing "
                                 f"/ally {clan['name']}."})
        # Notify the target leader if online.
        tws = _ws_for_player(str(target_row["leader_id"]))
        if tws is not None:
            await _send(tws, {"type": "chat", "username": "System",
                              "text": f"{clan['name']} offers your warband "
                                      f"an alliance. Type /ally "
                                      f"{clan['name']} within 60s to accept."})


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


# Maps the per-town pledge quest id to its town_id slug. Five towns total.
# Used by _maybe_apply_pledge AND by the shop-tax skim to look up which
# warband should be credited on a sale.
_PLEDGE_QUEST_TO_TOWN = {
    "q_pledge_kjelvik":   "kjelvik",
    "q_pledge_bjorn":     "bjorn",
    "q_pledge_frostheim": "frostheim",
    "q_pledge_ironwood":  "ironwood",
    "q_pledge_eastmark":  "eastmark",
}


def _maybe_apply_pledge(conn, session: dict, quest_id: str, now: float) -> None:
    """If `quest_id` is one of the five pledge quests, UPSERT a row in
    town_pledges so the completer's warband becomes the new holder of
    that town. Players not in a warband (rare since quests are gated by
    Construction + the Warrant indirectly) get a chat warning but the
    quest still completes — the pledge just doesn't bind."""
    town_id = _PLEDGE_QUEST_TO_TOWN.get(quest_id)
    if not town_id:
        return
    cid = _clan_id_for_player(conn, session["id"])
    if cid is None:
        return
    conn.execute(
        "INSERT INTO town_pledges (town_id, warband_id, pledged_at, path) "
        "VALUES (?, ?, ?, 'diplomatic') "
        "ON CONFLICT(town_id) DO UPDATE SET "
        "  warband_id = excluded.warband_id, "
        "  pledged_at = excluded.pledged_at",
        (town_id, cid, now))
    print(f"[pledge] {session['username']}'s warband {cid} now holds {town_id}")
    # Seal lifecycle — pledge change might give one warband all five
    # towns (triggering the seal to charge) or break a prior hold
    # (triggering dormant). Cheap recompute.
    _refresh_seal_after_pledge_change()


def _warband_holding_town(conn, town_id: str) -> str:
    """Returns the warband_id holding `town_id`, or '' if unpledged."""
    row = conn.execute(
        "SELECT warband_id FROM town_pledges WHERE town_id=?",
        (town_id,)).fetchone()
    return str(row["warband_id"]) if row else ""


# ── Seal of Kings / World-Eater (Phase A foundation) ──────────────────────
#
# State is owned by `seal_state` (single-row config) + `world_entities`
# rows of kind='seal_statue' / 'world_eater'. The lifecycle is driven by:
#
#   * `_compute_ruling_warband()` — runs whenever a pledge changes. If a
#     single warband holds all 5 town pledges, the statue spawns at the
#     capital (Kjelvik) in 'charged' state. If no warband does, the statue
#     is cleared and the seal goes back to 'dormant'.
#   * Player click on a 'charged' statue with all 5 High Seat Tokens
#     starts 'breaking' (statue takes damage). When integrity hits 0 the
#     statue is destroyed, the World-Eater spawns at the statue's site
#     ('walking' state), and the ruling warband becomes the doomed_warband.
#   * AI tick walks the World-Eater toward the doomed warband's structures
#     (banners, outposts, strongholds) and town pledge rows. When all are
#     gone it transitions to 'boss' (vulnerable).
#
# This pass ships: state table, aggregator, statue spawn/despawn, click
# handler, World-Eater entity scaffold + Phase 1 walk tick. The Phase 2
# boss combat reuses the existing monster_join/damage pipeline once the
# entity becomes vulnerable — no new combat code needed.

ALL_TOWN_IDS = ["bjorn", "kjelvik", "frostheim", "ironwood", "eastmark"]
SEAL_STATUE_POS = (2780.0, 3760.0)   # Kjelvik capital seat


def _read_seal_state(conn) -> dict:
    row = conn.execute("SELECT * FROM seal_state WHERE id=1").fetchone()
    if row is None:
        return {
            "state": "dormant", "ruling_warband": "", "doomed_warband": "",
            "awakened_by": "", "awakened_at": 0.0, "world_eater_id": "",
        }
    return {k: row[k] for k in row.keys()}


def _write_seal_state(conn, **kwargs) -> None:
    cur = _read_seal_state(conn)
    cur.update(kwargs)
    conn.execute(
        "UPDATE seal_state SET state=?, ruling_warband=?, doomed_warband=?, "
        "awakened_by=?, awakened_at=?, world_eater_id=? WHERE id=1",
        (str(cur["state"]), str(cur["ruling_warband"]),
         str(cur["doomed_warband"]), str(cur["awakened_by"]),
         float(cur["awakened_at"]), str(cur["world_eater_id"])))


def _compute_ruling_warband(conn) -> str:
    """Returns the warband id that holds all 5 town pledges, or '' if no
    single warband does. Cheap — one query, 5-row max."""
    rows = conn.execute(
        "SELECT town_id, warband_id FROM town_pledges").fetchall()
    if len(rows) != len(ALL_TOWN_IDS):
        return ""
    held = {str(r["town_id"]): str(r["warband_id"]) for r in rows}
    if set(held.keys()) != set(ALL_TOWN_IDS):
        return ""
    warbands = set(held.values())
    if len(warbands) != 1:
        return ""
    return next(iter(warbands))


def _spawn_seal_statue(conn, warband_id: str) -> str:
    """Place (or replace) the seal statue at the capital coords. The
    statue is a world_entity (so all existing client visual / click
    plumbing works) with `kind='seal_statue'`. data carries:
      { warband_id, integrity (0-100), state ('charged'/'breaking') }
    Returns the new entity id."""
    # Remove any prior seal statue first — only one exists at a time.
    conn.execute("DELETE FROM world_entities WHERE kind='seal_statue'")
    eid = "a:" + secrets.token_hex(8)
    x, y = SEAL_STATUE_POS
    data = {"warband_id": warband_id, "integrity": 100, "state": "charged"}
    conn.execute(
        "INSERT INTO world_entities (id, kind, subtype, x, y, data) "
        "VALUES (?, 'seal_statue', 'seal_statue', ?, ?, ?)",
        (eid, x, y, json.dumps(data)))
    _broadcast({"type": "world_entity_add", "entity": {
        "id": eid, "kind": "seal_statue", "subtype": "seal_statue",
        "x": x, "y": y, "data": data,
    }})
    print(f"[seal] statue spawned at {SEAL_STATUE_POS} for warband {warband_id}")
    return eid


def _despawn_seal_statue(conn) -> None:
    rows = conn.execute(
        "SELECT id FROM world_entities WHERE kind='seal_statue'").fetchall()
    for r in rows:
        conn.execute("DELETE FROM world_entities WHERE id=?", (str(r["id"]),))
        _broadcast({"type": "world_entity_remove", "id": str(r["id"])})


def _refresh_seal_after_pledge_change() -> None:
    """Called by every pledge handler (apply / remove). Recomputes ruling
    warband and synchronizes statue + seal_state. Locked-from-other-world
    semantics (multi-world rule) are NOT enforced — by design (see plan
    doc 'Multi-world rule deferred')."""
    with _db() as conn:
        seal = _read_seal_state(conn)
        # Don't fiddle with the statue/seal while a break is in progress
        # or the World-Eater is active.
        if seal["state"] in ("breaking", "walking", "boss"):
            return
        ruler = _compute_ruling_warband(conn)
        if ruler == "":
            if seal["state"] != "dormant":
                _despawn_seal_statue(conn)
                _write_seal_state(conn, state="dormant", ruling_warband="")
                conn.commit()
                print("[seal] no ruling warband — back to dormant")
            return
        # Ruler exists. If it changed or seal was dormant, refresh the
        # statue and flip to charged.
        if ruler != seal["ruling_warband"] or seal["state"] != "charged":
            _spawn_seal_statue(conn, ruler)
            _write_seal_state(conn, state="charged", ruling_warband=ruler)
            conn.commit()
            print(f"[seal] charged — ruling warband: {ruler}")


async def _handle_seal_awaken(ws, session, _msg: dict) -> None:
    """Player attempts to awaken the seal. Requirements:
    1. Player possesses all 5 High Seat Tokens (q_token_*).
    2. Player is NOT in the ruling warband.
    3. Seal is currently 'charged' (not already breaking or dormant).
    Multi-world locking is intentionally not enforced — single world."""
    if session is None:
        return
    REQUIRED = ["frost_token", "iron_token", "sea_token",
                "heart_token", "fifth_token"]
    pid = session["id"]
    for tok in REQUIRED:
        if not _player_has_item(pid, tok, 1):
            await _send(ws, {"type": "chat", "username": "System",
                "text": "The seal does not stir for the unworthy. "
                        "(All 5 Tokens of the High Seat required.)"})
            return
    with _db() as conn:
        seal = _read_seal_state(conn)
        if seal["state"] != "charged":
            await _send(ws, {"type": "chat", "username": "System",
                "text": "The seal cannot be awakened right now."})
            return
        cid = _clan_id_for_player(conn, pid)
        if cid == seal["ruling_warband"]:
            await _send(ws, {"type": "chat", "username": "System",
                "text": "You cannot awaken your own seal."})
            return
        # Flip the statue to 'breaking' — its data.state becomes attackable.
        row = conn.execute(
            "SELECT id, data FROM world_entities WHERE kind='seal_statue'"
        ).fetchone()
        if not row:
            await _send(ws, {"type": "chat", "username": "System",
                "text": "The seal statue is missing."})
            return
        eid = str(row["id"])
        try:
            data = json.loads(row["data"] or "{}")
        except Exception:
            data = {}
        data["state"] = "breaking"
        data["integrity"] = max(1, int(data.get("integrity", 100)))
        conn.execute("UPDATE world_entities SET data=? WHERE id=?",
            (json.dumps(data), eid))
        _write_seal_state(conn, state="breaking",
            awakened_by=session["username"], awakened_at=time.time())
        conn.commit()
    _broadcast({"type": "world_entity_update", "id": eid, "data": data})
    # Alert ALL members of the ruling warband — their seal is being broken.
    _broadcast({"type": "chat", "username": "System",
        "text": "⚔  The Seal of Kings is being broken by %s!"
                % session["username"]})
    print(f"[seal] AWAKENED by {session['username']} "
          f"(warband under attack: {seal['ruling_warband']})")


async def _handle_seal_attack(ws, session, msg: dict) -> None:
    """Damage the breaking seal. Anyone outside the ruling warband can
    contribute. amount caps at 25 per hit so the break takes a few
    swings. When integrity hits 0 the World-Eater spawns."""
    if session is None:
        return
    amount = max(1, min(25, int(msg.get("amount", 5))))
    with _db() as conn:
        seal = _read_seal_state(conn)
        if seal["state"] != "breaking":
            return
        cid = _clan_id_for_player(conn, session["id"])
        if cid and cid == seal["ruling_warband"]:
            await _send(ws, {"type": "chat", "username": "System",
                "text": "You cannot strike your own seal."})
            return
        row = conn.execute(
            "SELECT id, x, y, data FROM world_entities "
            "WHERE kind='seal_statue'").fetchone()
        if not row:
            return
        eid = str(row["id"])
        try:
            data = json.loads(row["data"] or "{}")
        except Exception:
            data = {}
        new_integ = max(0, int(data.get("integrity", 100)) - amount)
        data["integrity"] = new_integ
        if new_integ > 0:
            conn.execute("UPDATE world_entities SET data=? WHERE id=?",
                (json.dumps(data), eid))
            conn.commit()
            _broadcast({"type": "world_entity_update", "id": eid, "data": data})
            return
        # ── Seal shatters → World-Eater spawns ──
        sx, sy = float(row["x"]), float(row["y"])
        conn.execute("DELETE FROM world_entities WHERE id=?", (eid,))
        _broadcast({"type": "world_entity_remove", "id": eid})
        we_id = _spawn_world_eater(conn, sx, sy)
        _write_seal_state(conn,
            state="walking",
            doomed_warband=seal["ruling_warband"],
            world_eater_id=we_id)
        conn.commit()
    _broadcast({"type": "chat", "username": "System",
        "text": ("⚡  The Seal of Kings shatters! "
                 "The World-Eater walks the realm.")})
    print(f"[seal] SHATTERED — World-Eater spawned. "
          f"Doomed warband: {seal['ruling_warband']}")


def _spawn_world_eater(conn, x: float, y: float) -> str:
    """Create the world_eater entity in world_entities. The slow-walk
    tick reads from this row each AI tick to advance position and pick
    its next structure target."""
    eid = "a:" + secrets.token_hex(8)
    data = {"phase": 1, "hp": 0, "max_hp": 5000, "target_kind": "", "target_id": ""}
    conn.execute(
        "INSERT INTO world_entities (id, kind, subtype, x, y, data) "
        "VALUES (?, 'world_eater', 'world_eater', ?, ?, ?)",
        (eid, x, y, json.dumps(data)))
    _broadcast({"type": "world_entity_add", "entity": {
        "id": eid, "kind": "world_eater", "subtype": "world_eater",
        "x": x, "y": y, "data": data,
    }})
    return eid


# Routed in _route_message below.


WORLD_EATER_STEP_PX = 16.0     # px per tick (~2s) — slow ominous walk
WORLD_EATER_REACH_PX = 48.0    # destroy a target within this radius


def _pick_world_eater_target(conn, doomed_warband: str) -> tuple:
    """Find the nearest doomed-warband structure to chase. Returns
    (kind, entity_id, x, y) or (None, None, 0, 0) if nothing left.

    Search order matches the design doc: banners + outposts + strongholds
    by world_entities.data.warband_id == doomed; town pledges as the
    fallback when no structure remains."""
    we_row = conn.execute(
        "SELECT x, y FROM world_entities WHERE kind='world_eater'"
    ).fetchone()
    if not we_row:
        return (None, None, 0, 0)
    wx, wy = float(we_row["x"]), float(we_row["y"])
    rows = conn.execute(
        "SELECT id, kind, x, y, data FROM world_entities "
        "WHERE kind IN ('banner', 'outpost', 'stronghold')").fetchall()
    nearest = None
    nearest_d2 = float("inf")
    for r in rows:
        try:
            d = json.loads(r["data"] or "{}")
        except Exception:
            continue
        if str(d.get("warband_id", "")) != doomed_warband:
            continue
        rx, ry = float(r["x"]), float(r["y"])
        d2 = (rx - wx) ** 2 + (ry - wy) ** 2
        if d2 < nearest_d2:
            nearest_d2 = d2
            nearest = (str(r["kind"]), str(r["id"]), rx, ry)
    if nearest is not None:
        return nearest
    # No structures left — fall back to walking to town pledge sites.
    # Town centers (matching client `Lore.gd` town coords roughly).
    TOWN_CENTERS = {
        "bjorn":     (7823.0, 4488.0),
        "kjelvik":   (2780.0, 3760.0),
        "frostheim": (1390.0,  944.0),
        "ironwood":  (3580.0, 4960.0),
        "eastmark":  (5944.0, 5872.0),
    }
    pledge_rows = conn.execute(
        "SELECT town_id FROM town_pledges WHERE warband_id=?",
        (doomed_warband,)).fetchall()
    nearest = None
    nearest_d2 = float("inf")
    for pr in pledge_rows:
        tid = str(pr["town_id"])
        if tid not in TOWN_CENTERS:
            continue
        rx, ry = TOWN_CENTERS[tid]
        d2 = (rx - wx) ** 2 + (ry - wy) ** 2
        if d2 < nearest_d2:
            nearest_d2 = d2
            nearest = ("town_pledge", tid, rx, ry)
    return nearest if nearest else (None, None, 0, 0)


def _world_eater_tick() -> None:
    """Per-tick movement + destruction for the active World-Eater. Only
    runs while seal_state == 'walking'; transitions to 'boss' (Phase 2)
    when the doomed warband has nothing left to destroy."""
    with _db() as conn:
        seal = _read_seal_state(conn)
        if seal["state"] != "walking":
            return
        we_row = conn.execute(
            "SELECT id, x, y, data FROM world_entities WHERE kind='world_eater'"
        ).fetchone()
        if not we_row:
            return
        we_id = str(we_row["id"])
        wx, wy = float(we_row["x"]), float(we_row["y"])
        kind, target_id, tx, ty = _pick_world_eater_target(
            conn, seal["doomed_warband"])
        if kind is None:
            # Phase 2 — boss. Make the entity vulnerable. Real boss combat
            # will use the standard monster_join pipeline; for the
            # foundation pass we just flip the phase and broadcast.
            try:
                data = json.loads(we_row["data"] or "{}")
            except Exception:
                data = {}
            data["phase"] = 2
            data["hp"] = int(data.get("max_hp", 5000))
            conn.execute("UPDATE world_entities SET data=? WHERE id=?",
                (json.dumps(data), we_id))
            _write_seal_state(conn, state="boss")
            conn.commit()
            _broadcast({"type": "world_entity_update",
                "id": we_id, "data": data})
            _broadcast({"type": "chat", "username": "System",
                "text": ("⚡  The World-Eater's hunger is sated. "
                         "It turns to face the world.")})
            print("[seal] World-Eater Phase 1 complete → Phase 2 boss")
            return
        # In reach → destroy the target and clear it from the world.
        d2 = (tx - wx) ** 2 + (ty - wy) ** 2
        if d2 <= WORLD_EATER_REACH_PX ** 2:
            if kind == "town_pledge":
                conn.execute("DELETE FROM town_pledges WHERE town_id=?",
                    (target_id,))
                _broadcast({"type": "chat", "username": "System",
                    "text": f"⚡  The pledge of {target_id} is unmade."})
            else:
                conn.execute("DELETE FROM world_entities WHERE id=?",
                    (target_id,))
                _broadcast({"type": "world_entity_remove", "id": target_id})
                _broadcast({"type": "chat", "username": "System",
                    "text": f"⚡  A {kind} falls to the World-Eater."})
            conn.commit()
            return
        # Walk one tick step toward the target.
        dist = math.sqrt(d2) if d2 > 0 else 1.0
        nx = wx + (tx - wx) / dist * WORLD_EATER_STEP_PX
        ny = wy + (ty - wy) / dist * WORLD_EATER_STEP_PX
        conn.execute("UPDATE world_entities SET x=?, y=? WHERE id=?",
            (nx, ny, we_id))
        conn.commit()
        # Broadcast the position update so clients render the slow
        # approach. We reuse the existing world_entity_move plumbing.
        _broadcast({"type": "world_entity_move", "id": we_id, "x": nx, "y": ny})


def _town_of_shopkeeper(npc_id: str, npc_name: str) -> str:
    """Resolve a shopkeeper's town_id for tax-skim lookups. We map by NPC
    name (matches client-side `Lore.town_of_npc` table); npc_id is kept in
    the signature for future per-shop overrides."""
    name_to_town = {
        # Bjorn's Landing
        "Sea Captain Valdis": "bjorn",
        "Fish Trader Knud": "bjorn",
        "Sigrid the Fishmonger": "bjorn",
        "Merchant Eydis": "bjorn",
        # Kjelvik
        "Elder Bjarne": "kjelvik",
        "Trader Hroar": "kjelvik",
        "Merchant Dalla": "kjelvik",
        "Old Brynjar": "kjelvik",
        # Frostheim
        "Hunter Ragnhild": "frostheim",
        "Merchant Bera": "frostheim",
        "Brynhildr the Apothecary": "frostheim",
        # Ironwood Keep
        "Blacksmith Ulfr": "ironwood",
        "Trader Thorvald": "ironwood",
        "Torsten the Wanderer": "ironwood",
        # Eastmark Post
        "Scout Halfdan": "eastmark",
        "Wandering Merchant Freyja": "eastmark",
        "Captain Sten": "eastmark",
    }
    return name_to_town.get(npc_name, "")


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
        # Pledge side-effect: if this is a pledge quest, the completer's
        # warband becomes the holder of that town. UPSERT against the
        # existing row so transferring a pledge replaces the old warband.
        _maybe_apply_pledge(conn, session, quest_id, now)
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
            # NEVER restore combat state from disk. Aggro / target_player
            # are session-scoped — a monster mid-chase when the server was
            # killed must NOT come back chasing the next player who logs in.
            # The prior bug: SQLite preserved state="aggro" with target
            # cleared, then any monster_join would re-target whoever
            # engaged. Combined with the home-leash skip on aggro state,
            # the monster chased forever from across the map. Force-reset
            # state to idle + wander targets back to home so every reboot
            # starts the world quiet.
            monsters_state[mid] = {
                "x": float(r["pos_x"]), "y": float(r["pos_y"]),
                "home_x": float(r["home_x"]), "home_y": float(r["home_y"]),
                "monster_type": mtype,
                "level": lvl,
                "hostile": bool(int(r["hostile"] or 0)),
                "is_boss": is_boss,
                "state": "idle",
                "target_player": None,
                "max_hp": db_max_hp,
                "hp": hp,
                "alive": bool(int(r["alive"] or 1)),
                "participants": [], "damage": {},
                "last_attack_at": 0.0,
                "next_wander_at": now,
                "wander_x": float(r["home_x"]),
                "wander_y": float(r["home_y"]),
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


# ── Structure state persistence (v17 migration) ──────────────────────────────
# Same partial-persist shape as monsters_state. `structures_state` is the
# authoritative RAM copy; the SQLite table survives restarts so damaged
# walls don't magically go back to full HP whenever the server bounces.
_structure_state_dirty: set = set()


def _mark_structure_dirty(eid: str) -> None:
    if eid:
        _structure_state_dirty.add(eid)


def _load_structure_state_from_db() -> None:
    """Rehydrate `structures_state` from SQLite at boot. Runs AFTER the
    orphan-monster purge so all entity_ids being loaded are still backed
    by world_entities rows. Silently skips any row whose parent entity
    was deleted (broadcast + local cleanup handled by prior admin_delete)."""
    try:
        with _db() as conn:
            rows = conn.execute(
                "SELECT entity_id, hp, max_hp, alive, subtype, x, y, owner, wood "
                "FROM structure_state").fetchall()
            # Look up which entity_ids still exist so we can skip orphans.
            existing = {
                str(r["id"]) for r in conn.execute(
                    "SELECT id FROM world_entities").fetchall()
            }
        loaded = 0
        for r in rows:
            eid = str(r["entity_id"])
            if eid not in existing:
                continue
            structures_state[eid] = {
                "hp":      int(r["hp"]),
                "max_hp":  int(r["max_hp"]),
                "alive":   bool(int(r["alive"] or 1)),
                "subtype": str(r["subtype"]),
                "x":       float(r["x"]),
                "y":       float(r["y"]),
                "owner":   str(r["owner"] or ""),
                "wood":    str(r["wood"] or "oak"),
            }
            loaded += 1
        if loaded:
            print(f"[boot] loaded {loaded} structure_state row(s) from SQLite")
    except Exception as e:
        print(f"[boot] structure_state load failed: {e}")


def _flush_structure_state() -> int:
    """Drain _structure_state_dirty and UPSERT each entry. Any entry whose
    RAM record is gone (admin-deleted) is DELETEd from the mirror too."""
    if not _structure_state_dirty:
        return 0
    ids = list(_structure_state_dirty)
    _structure_state_dirty.clear()
    wrote = 0
    try:
        with _db() as conn:
            for eid in ids:
                st = structures_state.get(eid)
                if st is None:
                    conn.execute(
                        "DELETE FROM structure_state WHERE entity_id=?", (eid,))
                    continue
                conn.execute(
                    "INSERT OR REPLACE INTO structure_state "
                    "(entity_id, hp, max_hp, alive, subtype, x, y, owner, wood) "
                    "VALUES (?,?,?,?,?,?,?,?,?)",
                    (eid,
                     int(st.get("hp", 0)),
                     int(st.get("max_hp", 1)),
                     1 if st.get("alive", True) else 0,
                     str(st.get("subtype", "")),
                     float(st.get("x", 0.0)),
                     float(st.get("y", 0.0)),
                     str(st.get("owner", "")),
                     str(st.get("wood", "oak"))))
                wrote += 1
            conn.commit()
    except Exception as e:
        print(f"[structure_state] flush failed: {e}")
    return wrote


async def _structure_state_flush_loop() -> None:
    """5s batched flush, mirroring _monster_state_flush_loop."""
    while True:
        await asyncio.sleep(5.0)
        _flush_structure_state()

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
MONSTER_DE_AGGRO        = 1200.0  # break aggro if target > this from monster home.
                                  # Raised from 250 so player-initiated combat
                                  # via the "Attack" popup can engage from up to
                                  # ~600 px away without the monster giving up
                                  # mid-walk. The leash is measured from the
                                  # monster's home (spawn point), so this gives
                                  # ~1200 px of player movement headroom before
                                  # the chase is officially abandoned.
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
# Water-only monsters can ONLY step onto tiles the terrain bitmap reports as
# impassable — i.e., water. They also can't step onto land. Everything else
# is inverse: passable-only. If the bitmap isn't loaded, the check is a no-op
# and water-only monsters wander freely (initial-server behavior).
WATER_ONLY_MONSTERS = {"shark"}


def _monster_can_step(monster_type: str, x: float, y: float) -> bool:
    """Terrain gate for monster movement. Land monsters accept passable
    tiles; water-only monsters (WATER_ONLY_MONSTERS) accept impassable
    tiles (which are the water ones under our bitmap convention). No
    bitmap loaded → both classes are unrestricted."""
    if not terrain.is_loaded():
        return True
    passable = terrain.is_passable(x, y)
    if monster_type in WATER_ONLY_MONSTERS:
        return not passable
    return passable


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
        # Only persist to SQLite when this is a REAL combat engagement (Attack
        # click). seed_only joins are ephemeral client-visibility registrations
        # — dirtying them would resurrect ghost rows across restarts. If this
        # monster later engages combat (seed_only=False), the aggro-flip path
        # dirties it then.
        if not bool(msg.get("seed_only", False)):
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
    # Force-aggro the engaging player. The new client flow opens combat the
    # instant the player picks "Attack" from the popup — there is no
    # proximity walk. The server therefore has to flip the monster into
    # aggro chase mode pointed at THIS player so it starts walking toward
    # them, even if they're 600+ px away. `last_attack_at` is left alone so
    # an already-aggroed monster doesn't get its swing timer reset.
    #
    # `seed_only` = the caller is chunk-load / login-burst AI registration,
    # NOT a combat engagement. Skip the aggro flip so login and interior
    # exit don't drag every monster in the area toward the player.
    seed_only = bool(msg.get("seed_only", False))
    if not seed_only and _is_ai_seeded(st) and st.get("alive", True):
        st["state"] = "aggro"
        st["target_player"] = session["username"]
        st.setdefault("last_attack_at", 0.0)
    await _send(ws, {"type": "monster_state", "id": mid,
                     "hp": st["hp"], "max_hp": st["max_hp"], "alive": True})


async def _handle_structure_repair(ws, session: dict, msg: dict) -> None:
    """Owner + warband-member repair. Consumes materials proportional to
    missing HP: 1 wood per 20 HP restored (rounded up). For v1 we don't
    verify inventory materials — that's on the client's honor. Ships as a
    quality-of-life MVP; balance is a live-play question."""
    eid = str(msg.get("id", ""))
    st = structures_state.get(eid)
    if st is None or not st.get("alive", True):
        return
    if st.get("hp", 0) >= st.get("max_hp", 0):
        return
    # Owner OR warband-member gate. Admins bypass.
    is_admin = _is_admin(session) if "_is_admin" in globals() else False
    same_owner = st.get("owner", "") == session.get("username", "")
    # Warband membership check — reuse clan_members table if it exists.
    same_warband = False
    if not same_owner and not is_admin:
        try:
            with _db() as conn:
                cid = _clan_id_for_player(conn, session["id"])
                if cid is not None:
                    owner_row = conn.execute(
                        "SELECT id FROM players WHERE username=?",
                        (st.get("owner", ""),)).fetchone()
                    if owner_row is not None:
                        owner_cid = _clan_id_for_player(conn, owner_row["id"])
                        same_warband = (owner_cid == cid)
        except Exception:
            pass
    if not (same_owner or same_warband or is_admin):
        await _send(ws, {"type": "chat", "username": "System",
                         "text": "Only the owner or warband can repair."})
        return
    # Restore HP — full heal for MVP. A future tuning pass can prorate.
    st["hp"] = st["max_hp"]
    _mark_structure_dirty(eid)
    _broadcast({"type": "structure_hp_changed", "id": eid,
                "hp": st["hp"], "max_hp": st["max_hp"], "alive": True})
    print(f"[structure] {session['username']} repaired {st['subtype']} "
          f"({eid}) to full HP")


async def _handle_structure_damage(ws, session: dict, msg: dict) -> None:
    """Player-dealt damage against a placed structure. Range check + HP
    deduction + destroy broadcast. Follows the monster_damage shape but
    without participants/xp — structures give no XP for v1."""
    eid = str(msg.get("id", ""))
    amt = max(0, int(msg.get("amount", 0)))
    st = structures_state.get(eid)
    if st is None or not st.get("alive", True) or amt <= 0:
        return
    # Range gate — the player must be at the hitbox edge. Server-side check
    # mirrors the client-side "must be at edge" requirement so a fast-clicker
    # can't strike from across the map.
    size = _STRUCTURE_SIZES.get(st["subtype"], (32, 32))
    half_w = size[0] / 2.0
    half_h = size[1] / 2.0
    p_x = float(session.get("x", 0.0))
    p_y = float(session.get("y", 0.0))
    reach = MELEE_HIT_RANGE if "MELEE_HIT_RANGE" in globals() else 60.0
    # Distance to nearest hitbox edge (0 if inside, positive if outside).
    dx = max(0.0, abs(p_x - st["x"]) - half_w)
    dy = max(0.0, abs(p_y - st["y"]) - half_h)
    if dx * dx + dy * dy > reach * reach:
        return
    st["hp"] = max(0, st["hp"] - amt)
    _mark_structure_dirty(eid)
    _broadcast({"type": "structure_hp_changed", "id": eid,
                "hp": st["hp"], "max_hp": st["max_hp"], "alive": st["alive"]})
    if st["hp"] <= 0 and st.get("alive", True):
        st["alive"] = False
        _mark_structure_dirty(eid)
        _broadcast({"type": "structure_destroyed", "id": eid})
        print(f"[structure] {session['username']} destroyed "
              f"{st['subtype']} ({eid}) at ({st['x']:.0f},{st['y']:.0f})")


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
    if st is None:
        return
    pid = session["id"]
    if pid in st["participants"]:
        st["participants"].remove(pid)
    # If the leaving player was the aggro target, drop aggro. If other
    # participants remain (co-op), repoint at the next still-online
    # participant so the fight doesn't lose its target mid-swing. If no
    # one is left, return the monster to idle so it doesn't chase nobody.
    if st.get("target_player") == session["username"]:
        new_target_user = None
        for other_pid in list(st["participants"]):
            other_ws = _ws_for_player(other_pid)
            if other_ws is not None and other_ws in sessions:
                new_target_user = sessions[other_ws]["username"]
                break
        if new_target_user is not None:
            st["target_player"] = new_target_user
        else:
            st["state"] = "idle"
            st["target_player"] = None
            st["wander_x"] = st.get("home_x", st["x"])
            st["wander_y"] = st.get("home_y", st["y"])
            st["next_wander_at"] = time.time() + random.uniform(
                *_wander_interval_for(st.get("monster_type", "")))


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


# ── Entity-existence caches (safety net for ghost-monster cleanup) ──────────
# `_purged_entity_ids` is the authoritative "this id is deleted" set. It
# starts populated from `entity_edits.deleted=1` (procedural monsters that
# admins deleted in prior sessions) and grows whenever `_handle_admin_delete`
# runs. The monster AI loop checks it every tick — any mid in this set gets
# purged and skipped, even if some prior code path forgot to call
# `_purge_monster_state` directly.
#
# `_known_admin_entity_ids` mirrors the `world_entities` table for `a:...`
# placeable entities. If an admin-placed monster's id is NOT in here, the
# loop treats it as deleted. This catches the case where the world_entities
# row was removed (admin_delete → DB delete) but somehow monsters_state still
# had a leftover entry.
_purged_entity_ids: set = set()
_known_admin_entity_ids: set = set()


def _load_entity_existence_caches() -> None:
    """Hydrate both caches from SQLite at boot. Called once from main()."""
    global _purged_entity_ids, _known_admin_entity_ids
    with _db() as conn:
        del_rows = conn.execute(
            "SELECT id FROM entity_edits WHERE deleted=1").fetchall()
        _purged_entity_ids = {str(r["id"]) for r in del_rows}
        we_rows = conn.execute(
            "SELECT id FROM world_entities WHERE id LIKE 'a:%'").fetchall()
        _known_admin_entity_ids = {str(r["id"]) for r in we_rows}
    print(f"[existence] loaded {len(_purged_entity_ids)} purged ids, "
          f"{len(_known_admin_entity_ids)} admin entities")


def _is_entity_marked_dead(mid: str) -> bool:
    """True if the AI loop should skip + purge this monster id.
    Cheap O(1) set lookups — safe to call every tick per monster."""
    if mid in _purged_entity_ids:
        return True
    if mid.startswith("a:") and mid not in _known_admin_entity_ids:
        return True
    return False


def _purge_monster_state(mid: str) -> bool:
    """Hard-delete a monster from the live AI / combat / persistence layer.
    Must be called from every admin-delete path (admin panel + slash commands
    + admin_delete message). Without it `monsters_state[mid]` keeps ticking:
    the AI loop chases players invisibly, attack broadcasts fire from a
    monster the client already despawned, and respawn rolls in 30s.

    Steps (must run synchronously, no awaits between them):
      1. Pop the monsters_state entry. AI loop's per-tick snapshot
         (`list(monsters_state.items())`) won't pick it up again next tick.
      2. The popped entry took `participants` + `damage` + `target_player`
         with it — no separate aggro / participant lookup tables exist.
      3. Synchronously DELETE the SQLite monster_state row so a server
         restart doesn't rehydrate the corpse.
      4. Drop the id from the dirty set so the next flush doesn't try to
         re-UPSERT it (the flush already handles "popped" gracefully via
         the `st is None` branch, but skipping the work is cheaper).
      5. Broadcast `monster_died` GLOBALLY (not _broadcast_near) — admin
         deletes happen from arbitrary positions and any client with the
         monster loaded into their world needs to free the visual.

    Returns True if the monster existed and was purged, False if it wasn't
    in monsters_state at all (caller-side logging only)."""
    st = monsters_state.pop(mid, None)
    _monster_state_dirty.discard(mid)
    # SQLite delete is best-effort — a transient connection failure here
    # shouldn't block the in-memory purge that's already done.
    try:
        with _db() as conn:
            conn.execute(
                "DELETE FROM monster_state WHERE monster_id=?", (mid,))
            conn.commit()
    except Exception as ex:
        print(f"[purge_monster] DB delete failed for {mid}: {ex}")
    # Use monster_died so clients reuse the existing death cleanup path
    # (Events.mob_died → Monster node frees itself). Empty xp_recipients
    # so no one gets credit for an admin delete.
    _broadcast({"type": "monster_died", "id": mid, "killer": "",
                "xp_each": 0, "participants": [], "xp_recipients": []})
    return st is not None


async def _world_tick_loop() -> None:
    """Respawn depleted nodes / dead monsters and tell nearby clients.
    Also drives the slow World-Eater Phase 1 walk when an event is active."""
    we_tick_counter = 0
    while True:
        await asyncio.sleep(1.0)
        now = time.time()
        # World-Eater walks every 2 ticks (= ~2s) to keep the broadcast
        # rate low; movement is intentionally ominous.
        we_tick_counter += 1
        if we_tick_counter % 2 == 0:
            _world_eater_tick()
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
            # Safety net for ghost-monsters. If an admin deleted this entity
            # (entity_edits.deleted=1 OR admin-placed row gone from
            # world_entities), we MUST stop ticking it — otherwise the
            # monster keeps chasing + attacking invisibly while the client
            # has long since freed its visual. Cheap O(1) set check; the
            # full purge (SQLite delete + monster_died broadcast) only runs
            # the first time the safety net triggers.
            if _is_entity_marked_dead(mid):
                print(f"[ai_loop] purging ghost monster {mid} "
                      f"(missed cleanup path)")
                _purge_monster_state(mid)
                continue
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
    # monster too far (idle/wander glitches, server tick stall, etc.). It
    # MUST be skipped during a legitimate aggro chase, otherwise a monster
    # engaged from 400-1000 px away gets yanked home mid-chase before it
    # can ever reach the player. That was the "monster shuffles 2-3 px and
    # never closes the gap" bug — player would press Attack, server flipped
    # state to aggro, the chase started, but after ~300 px from home the
    # leash teleported the monster back and the cycle repeated.
    #
    # The aggro state covers the legitimate case; if target_player went
    # missing the aggro branch below resets to idle naturally. So the only
    # path that needs the leash is "stuck in idle/wander but somehow far
    # from home" — that we keep.
    if st["state"] != "aggro":
        leash2 = MONSTER_HOME_LEASH * MONSTER_HOME_LEASH
        dx, dy = cur_x - home_x, cur_y - home_y
        if dx * dx + dy * dy > leash2:
            # WALK back to home instead of teleporting. Setting the wander
            # target lets _step_toward move the monster incrementally on
            # subsequent ticks — respects terrain, animates smoothly, and
            # avoids the "monster snapped from mid-chase back to spawn" bug
            # the user reported on Flee / de-aggro.
            st["state"] = "idle"
            st["target_player"] = None
            st["wander_x"], st["wander_y"] = home_x, home_y
            st["next_wander_at"] = now
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
        # Chase: step toward target at chase speed. Terrain bitmap (if
        # loaded) rejects steps into impassable tiles — the monster
        # simply doesn't move that tick rather than walking into water.
        # If the path is fully blocked the monster will look stuck;
        # combined with the 1200 px de-aggro leash it eventually gives
        # up. A future pass can layer perpendicular slide attempts here.
        step = MONSTER_CHASE_SPEED * MONSTER_AI_TICK
        # Sharks (and any future water-only monster) get a small chase-speed
        # boost — they surge fast through water while the pathing check
        # keeps them off land. Land monsters use the standard multiplier.
        if st.get("monster_type", "") in WATER_ONLY_MONSTERS:
            step *= 1.2
        candidate_x, candidate_y = _step_toward(cur_x, cur_y, tx, ty, step)
        m_type = st.get("monster_type", "")
        if _monster_can_step(m_type, candidate_x, candidate_y):
            new_x, new_y = candidate_x, candidate_y
        else:
            # Try a 1-axis slide so corners/coastlines don't fully wall
            # the monster. Prefer the axis with the greater remaining
            # delta; if that's also blocked, hold position.
            dx = tx - cur_x
            dy = ty - cur_y
            tried = False
            if abs(dx) >= abs(dy):
                sx, sy = _step_toward(cur_x, cur_y, tx, cur_y, step)
                if _monster_can_step(m_type, sx, sy):
                    new_x, new_y = sx, sy
                    tried = True
            if not tried:
                sx, sy = _step_toward(cur_x, cur_y, cur_x, ty, step)
                if _monster_can_step(m_type, sx, sy):
                    new_x, new_y = sx, sy
                    tried = True
            if not tried:
                new_x, new_y = cur_x, cur_y
                # Fully blocked — check if there's a structure right in
                # front of us. If so, attack it instead of stalling.
                s_reach = MONSTER_ATTACK_RANGE + float(
                    st.get("size", _MONSTER_SIZE_DEFAULT))
                s_eid, _s_dist = _structure_at_edge(cur_x, cur_y, s_reach)
                if s_eid is not None and \
                        now - st["last_attack_at"] >= MONSTER_ATTACK_COOLDOWN:
                    st["last_attack_at"] = now
                    s_st = structures_state.get(s_eid)
                    if s_st is not None:
                        s_st["hp"] = max(0, s_st["hp"] - int(st["attack"]))
                        _mark_structure_dirty(s_eid)
                        _broadcast({
                            "type": "structure_hp_changed",
                            "id": s_eid,
                            "hp": s_st["hp"],
                            "max_hp": s_st["max_hp"],
                            "alive": s_st.get("alive", True),
                        })
                        if s_st["hp"] <= 0 and s_st.get("alive", True):
                            s_st["alive"] = False
                            _mark_structure_dirty(s_eid)
                            _broadcast({
                                "type": "structure_destroyed",
                                "id": s_eid,
                            })
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
            # `monster_type` tag lets the client apply damage-routing rules
            # (e.g. shark bites route to boat HP when target is sailing).
            attack_msgs.append((new_x, new_y, {
                "type": "monster_attack",
                "id": mid,
                "target": tgt["username"],
                "damage": int(st["attack"]),
                "monster_type": st.get("monster_type", ""),
            }))
        return

    # ── Proximity aggro: HOSTILE MONSTERS ONLY ────────────────────────
    # Hostile monsters (server-side flag; passives are chickens + rats)
    # auto-engage when a player walks into `aggro_radius`. Player still has
    # to click Attack to open the combat panel; the AI just starts walking
    # toward them so pursuit isn't purely player-initiated.
    #
    # De-aggro: handled by the aggro branch above via the leash — once the
    # player leaves `aggro_radius * 1.5` (measured as distance from monster
    # home > MONSTER_HOME_LEASH), the monster drops back to idle and walks
    # home via the wander target (Fix 3). No teleport.
    if st.get("hostile", False):
        aggro_r = float(st.get("aggro_radius", 0.0))
        if aggro_r > 0.0:
            best_ws = None
            best_dsq = aggro_r * aggro_r
            for ows, s in sessions.items():
                # Skip players inside interiors — they're not physically
                # near any exterior monster, even if their session x/y is
                # stale from before they entered.
                if str(s.get("interior_id", "")) != "":
                    continue
                dx = cur_x - float(s.get("x", 0.0))
                dy = cur_y - float(s.get("y", 0.0))
                dsq = dx * dx + dy * dy
                if dsq < best_dsq:
                    best_dsq = dsq
                    best_ws = ows
            if best_ws is not None:
                st["state"] = "aggro"
                st["target_player"] = sessions[best_ws]["username"]
                st.setdefault("last_attack_at", 0.0)
                # Dirty since we're transitioning to a real combat state.
                _mark_monster_dirty(mid)
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
        cx, cy = _step_toward(cur_x, cur_y, st["wander_x"], st["wander_y"], step)
        # Terrain gate — same rule as the chase step. A land monster
        # wandering into water just stops at the edge; a water-only monster
        # wandering onto land does the same.
        if _monster_can_step(st.get("monster_type", ""), cx, cy):
            new_x, new_y = cx, cy
        else:
            new_x, new_y = cur_x, cur_y
            # Drop the unreachable wander target so we re-roll next tick.
            st["wander_x"] = cur_x
            st["wander_y"] = cur_y
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
    elif mtype == "request_password_reset":
        await _handle_request_password_reset(ws, msg)
    elif mtype == "verify_password_reset_token":
        await _handle_verify_password_reset_token(ws, msg)
    elif mtype == "complete_password_reset":
        await _handle_complete_password_reset(ws, msg)
    elif mtype == "change_email":
        await _handle_change_email(ws, session, msg)
    elif mtype == "change_password":
        await _handle_change_password(ws, session, msg)
    elif mtype == "get_account_info":
        await _handle_get_account_info(ws, session, msg)
    elif mtype == "set_backstory":
        await _handle_set_backstory(ws, session, msg)
    elif mtype == "set_pet_type":
        await _handle_set_pet_type(ws, session, msg)
    elif mtype == "seal_awaken":
        await _handle_seal_awaken(ws, session, msg)
    elif mtype == "seal_attack":
        await _handle_seal_attack(ws, session, msg)
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
            if text.startswith("/ally ") or text == "/unally":
                await _handle_ally_command(ws, session, text)
                return
            if text == "/wipemonsters":
                await _handle_admin_wipemonsters(ws, session)
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
    elif mtype == "admin_list_accounts":
        await _handle_admin_list_accounts(ws, session, msg)
    elif mtype == "admin_reset_password":
        await _handle_admin_reset_password(ws, session, msg)
    elif mtype == "admin_unlock_account":
        await _handle_admin_unlock_account(ws, session, msg)
    elif mtype == "admin_verify_email":
        await _handle_admin_verify_email(ws, session, msg)
    elif mtype == "admin_upload_terrain":
        await _handle_admin_upload_terrain(ws, session, msg)
    elif mtype == "admin_restore_last_loss":
        await _handle_admin_restore_last_loss(ws, session, msg)
    elif mtype == "admin_tile_set":
        await _handle_admin_tile_set(ws, session, msg)
    elif mtype == "admin_tile_set_bulk":
        await _handle_admin_tile_set_bulk(ws, session, msg)
    elif mtype == "admin_tile_flood_fill":
        await _handle_admin_tile_flood_fill(ws, session, msg)
    elif mtype == "admin_tile_tint":
        await _handle_admin_tile_tint(ws, session, msg)
    elif mtype == "admin_tile_passability":
        await _handle_admin_tile_passability(ws, session, msg)
    elif mtype == "admin_tile_clear":
        await _handle_admin_tile_clear(ws, session, msg)
    elif mtype == "admin_save_map":
        await _handle_admin_save_map(ws, session, msg)
    elif mtype == "build_farm_plot":
        await _handle_build_farm_plot(ws, session, msg)
    elif mtype == "build_wall":
        await _handle_build_wall(ws, session, msg)
    elif mtype == "build_warband_structure":
        await _handle_build_warband_structure(ws, session, msg)
    elif mtype == "banner_raid":
        await _handle_banner_raid(ws, session, msg)
    elif mtype == "banner_reinforce":
        await _handle_banner_reinforce(ws, session, msg)
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
    elif mtype == "structure_damage":
        await _handle_structure_damage(ws, session, msg)
    elif mtype == "structure_repair":
        await _handle_structure_repair(ws, session, msg)
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
    # Hydrate the entity-existence caches BEFORE loading monster state so
    # the AI loop's first-tick safety net has a complete view. Order is
    # idempotent — loading state then loading caches would work too, but
    # this is the natural dependency direction.
    _load_entity_existence_caches()
    # Optional terrain bitmap — when present, monster movement respects
    # passability tiles (no walking into water/coast). When absent,
    # movement is unrestricted (original behavior).
    terrain.load()
    # Rehydrate the AI dict from the persisted mirror. Non-boss monsters
    # reset to full HP per the partial-persist rule; bosses keep their last
    # persisted HP.
    _load_monster_state_from_db()
    # Structure HP mirror rehydrate — walls / towers / halls keep their
    # damaged state across restarts. Runs before the orphan purge so any
    # orphaned rows (world_entities parent gone via admin_delete) get
    # skipped via the existing world_entities existence check inside
    # _load_structure_state_from_db.
    _load_structure_state_from_db()
    # Orphan purge runs AFTER rehydrate so it can see the loaded ghost
    # rows. Any monsters_state entry whose id doesn't have a live
    # world_entities row gets dropped from both RAM and SQLite. Previously
    # this ran BEFORE rehydrate against an empty dict — did nothing, and
    # procedural monsters from before PROCEDURAL_MONSTERS=false lingered
    # in the AI loop count forever.
    _purge_orphan_monster_state()
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
            _structure_state_flush_loop(),
        )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[shutdown] Server stopped.")
