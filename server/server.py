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
import logging
import math
import os
import random
import secrets
import signal
import sqlite3
import time
from pathlib import Path

# Silence the noisy websockets handshake failures ("opening handshake failed" /
# "did not receive a valid HTTP request"). These come from port scanners, tunnel
# keepalives, and browsers hitting http:// instead of ws:// — NOT real players —
# and just flood the console. Real websockets errors still get through.
class _SuppressHandshakeNoise(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        return ("opening handshake failed" not in msg
                and "did not receive a valid HTTP request" not in msg)

logging.getLogger("websockets.server").addFilter(_SuppressHandshakeNoise())

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
# Interiors live in a far-off y band (grid at ty≈375+, world y≈12000-17000).
# Move requests from a player who is INSIDE an interior clamp to this higher
# bound so their true interior position isn't collapsed to the exterior edge
# (which broke co-op visibility between building occupants).
INTERIOR_WORLD_MAX_Y = 20000.0
MAX_DIST_FOR_ACTION  = 160.0
ACTION_RATE_LIMIT_MS = 500
IDLE_EFFICIENCY      = 0.55
MAX_IDLE_SECONDS     = 24 * 3600
# Per-resource overhead representing depleting a node + its respawn before the
# next can be gathered. Keeps idle gathering near live rates (~2 logs/min at
# tier 1) instead of one item per swing.
IDLE_GATHER_RESPAWN  = 22.0
# ── Thrall offline work (V1.5.5 rebalance) ──────────────────────────────────
# Overnight thralls were exploding (12h → 1668 fish, lvl 1→33). Two levers:
# a hard 12h WORK cap (beyond that a thrall "rests" and earns nothing until
# re-set on next login) and a 0.25 yield rate — so a full shift is a quarter
# of the old haul. Applied as a rate divisor on the gather period / kill time.
THRALL_MAX_WORK_SECONDS = 12 * 3600
THRALL_WORK_YIELD       = 0.25
WANDER_RADIUS        = 512.0   # px — 16 tiles; how far from logout the ghost wanders
IDLE_SPEED           = 160.0   # px/s — matches Player.SPEED
IDLE_MOVE_TICK       = 0.5     # seconds between position broadcasts while walking

# Hardcoded admin account. Only this username may place/delete/move world
# entities and use the /gold and /spawn commands.
ADMIN_USERNAME = "Busterrdust"

# Content-bot warband LEADERS — these accounts are granted the Warrant of the
# High Seat server-side on login (persistent, survives the v1.7 inventory change)
# so the AutoContent bots can found warbands without grinding the Five Tokens
# quest. Real players still earn it. Set via env, comma-separated usernames, e.g.
#   set VIKINGVALE_CONTENT_BOT_LEADERS=RavenBot1,WolfBot1
_CONTENT_BOT_LEADERS = {
    u.strip() for u in os.environ.get("VIKINGVALE_CONTENT_BOT_LEADERS", "").split(",")
    if u.strip()
}

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
    # Rebalanced 2026-09-26 to a ~200 h fishing-99 (was ~405 h) — higher xp, tighter
    # swings, + an abyssal_eel top tier so 80-99 isn't stuck on shark.
    ("fish", "small"):   {"skill":"fishing","level":1,  "xp":30,  "swing_time":3.0,"success_at_req":0.75,"success_at_99":0.95,"item_id":"raw_fish",     "item_name":"Raw Fish"},
    ("fish", "salmon"):  {"skill":"fishing","level":20, "xp":50,  "swing_time":3.0,"success_at_req":0.58,"success_at_99":0.92,"item_id":"raw_salmon",   "item_name":"Raw Salmon"},
    ("fish", "lobster"): {"skill":"fishing","level":40, "xp":85,  "swing_time":3.5,"success_at_req":0.45,"success_at_99":0.85,"item_id":"lobster",      "item_name":"Lobster"},
    ("fish", "shark"):   {"skill":"fishing","level":60, "xp":130, "swing_time":4.0,"success_at_req":0.30,"success_at_99":0.78,"item_id":"raw_shark",    "item_name":"Raw Shark"},
    ("fish", "abyssal"): {"skill":"fishing","level":80, "xp":175, "swing_time":4.5,"success_at_req":0.32,"success_at_99":0.80,"item_id":"abyssal_eel",  "item_name":"Abyssal Eel"},
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
    # ── Full bestiary mirror (matches scripts/Monster.gd _apply_type_stats) ──────
    # Added so the SERVER knows every monster's stats — reference now; required
    # once combat authority (anti-cheat B1) computes damage/xp server-side. Kept in
    # sync MANUALLY with Monster.gd (same duplication rule as the quest catalog).
    ("combat", "plague_rat"):       {"skill":"melee","level":10, "xp_kill":55,  "monster_hp":40,  "monster_atk":12, "swing_time":2.5,"item_id":"plague_tooth",   "item_name":"Plague Tooth"},
    ("combat", "nidhogg"):          {"skill":"melee","level":35, "xp_kill":250, "monster_hp":120, "monster_atk":28, "swing_time":2.5,"item_id":"dragon_scale",   "item_name":"Dragon Scale"},
    ("combat", "chicken"):          {"skill":"melee","level":1,  "xp_kill":3,   "monster_hp":3,   "monster_atk":1,  "swing_time":2.5,"item_id":"feather",        "item_name":"Feather"},
    ("combat", "wolf"):             {"skill":"melee","level":6,  "xp_kill":20,  "monster_hp":18,  "monster_atk":8,  "swing_time":2.5,"item_id":"wolf_pelt",      "item_name":"Wolf Pelt"},
    ("combat", "bandit"):           {"skill":"melee","level":15, "xp_kill":45,  "monster_hp":35,  "monster_atk":13, "swing_time":2.5,"item_id":"bandit_hood",    "item_name":"Bandit Hood"},
    ("combat", "guard"):            {"skill":"melee","level":30, "xp_kill":110, "monster_hp":90,  "monster_atk":26, "swing_time":2.5,"item_id":"",               "item_name":""},
    ("combat", "guard_ranger"):     {"skill":"melee","level":40, "xp_kill":150, "monster_hp":85,  "monster_atk":32, "swing_time":2.5,"item_id":"",               "item_name":""},
    ("combat", "guard_magi"):       {"skill":"melee","level":50, "xp_kill":200, "monster_hp":80,  "monster_atk":40, "swing_time":2.5,"item_id":"",               "item_name":""},
    ("combat", "bear"):             {"skill":"melee","level":22, "xp_kill":70,  "monster_hp":60,  "monster_atk":18, "swing_time":2.5,"item_id":"bear_claw",      "item_name":"Bear Claw"},
    ("combat", "troll"):            {"skill":"melee","level":25, "xp_kill":100, "monster_hp":80,  "monster_atk":20, "swing_time":2.5,"item_id":"troll_hide",     "item_name":"Troll Hide"},
    ("combat", "forest_spirit"):    {"skill":"melee","level":30, "xp_kill":85,  "monster_hp":55,  "monster_atk":22, "swing_time":2.5,"item_id":"spirit_essence", "item_name":"Spirit Essence"},
    ("combat", "spider"):           {"skill":"melee","level":24, "xp_kill":65,  "monster_hp":45,  "monster_atk":19, "swing_time":2.5,"item_id":"spider_silk",    "item_name":"Spider Silk"},
    ("combat", "ice_wolf"):         {"skill":"melee","level":40, "xp_kill":130, "monster_hp":90,  "monster_atk":30, "swing_time":2.5,"item_id":"ice_fang",       "item_name":"Ice Fang"},
    ("combat", "frost_giant"):      {"skill":"melee","level":45, "xp_kill":180, "monster_hp":130, "monster_atk":35, "swing_time":2.5,"item_id":"frost_crystal",  "item_name":"Frost Crystal"},
    ("combat", "ice_draugr"):       {"skill":"melee","level":50, "xp_kill":160, "monster_hp":110, "monster_atk":38, "swing_time":2.5,"item_id":"ice_shard",      "item_name":"Ice Shard"},
    ("combat", "fire_imp"):         {"skill":"melee","level":55, "xp_kill":200, "monster_hp":95,  "monster_atk":42, "swing_time":2.5,"item_id":"imp_horn",       "item_name":"Imp Horn"},
    ("combat", "lava_crawler"):     {"skill":"melee","level":60, "xp_kill":240, "monster_hp":140, "monster_atk":48, "swing_time":2.5,"item_id":"lava_carapace",  "item_name":"Lava Carapace"},
    ("combat", "fire_giant"):       {"skill":"melee","level":45, "xp_kill":300, "monster_hp":180, "monster_atk":55, "swing_time":2.5,"item_id":"giant_ember",    "item_name":"Giant Ember"},
    ("combat", "shadow_draugr"):    {"skill":"melee","level":68, "xp_kill":340, "monster_hp":160, "monster_atk":58, "swing_time":2.5,"item_id":"shadow_essence", "item_name":"Shadow Essence"},
    ("combat", "death_knight"):     {"skill":"melee","level":75, "xp_kill":400, "monster_hp":200, "monster_atk":65, "swing_time":2.5,"item_id":"death_rune",     "item_name":"Death Rune"},
    ("combat", "spectral_warrior"): {"skill":"melee","level":80, "xp_kill":450, "monster_hp":220, "monster_atk":72, "swing_time":2.5,"item_id":"spectral_essence","item_name":"Spectral Essence"},
    ("combat", "shark"):            {"skill":"melee","level":30, "xp_kill":95,  "monster_hp":110, "monster_atk":14, "swing_time":2.5,"item_id":"shark_tooth",    "item_name":"Shark Tooth"},
    ("combat", "dire_wolf"):        {"skill":"melee","level":15, "xp_kill":55,  "monster_hp":40,  "monster_atk":12, "swing_time":2.5,"item_id":"wolf_pelt",      "item_name":"Wolf Pelt"},
    ("combat", "elder_bear"):       {"skill":"melee","level":29, "xp_kill":105, "monster_hp":85,  "monster_atk":22, "swing_time":2.5,"item_id":"bear_claw",      "item_name":"Bear Claw"},
    ("combat", "ancient_troll"):    {"skill":"melee","level":44, "xp_kill":200, "monster_hp":140, "monster_atk":34, "swing_time":2.5,"item_id":"troll_hide",     "item_name":"Troll Hide"},
    ("combat", "swamp_troll"):      {"skill":"melee","level":30, "xp_kill":130, "monster_hp":100, "monster_atk":24, "swing_time":2.5,"item_id":"troll_hide",     "item_name":"Troll Hide"},
    ("combat", "ice_troll"):        {"skill":"melee","level":40, "xp_kill":175, "monster_hp":130, "monster_atk":30, "swing_time":2.5,"item_id":"troll_hide",     "item_name":"Troll Hide"},
    ("combat", "cave_troll"):       {"skill":"melee","level":45, "xp_kill":215, "monster_hp":155, "monster_atk":36, "swing_time":2.5,"item_id":"troll_hide",     "item_name":"Troll Hide"},
    ("combat", "frost_wyrm"):       {"skill":"melee","level":62, "xp_kill":310, "monster_hp":190, "monster_atk":50, "swing_time":2.5,"item_id":"ice_shard",      "item_name":"Ice Shard"},
    ("combat", "magma_elemental"):  {"skill":"melee","level":76, "xp_kill":430, "monster_hp":240, "monster_atk":68, "swing_time":2.5,"item_id":"giant_ember",    "item_name":"Giant Ember"},
    ("combat", "drake"):            {"skill":"melee","level":48, "xp_kill":260, "monster_hp":150, "monster_atk":44, "swing_time":2.5,"item_id":"dragon_scale",   "item_name":"Dragon Scale"},
    ("combat", "wyvern"):           {"skill":"melee","level":58, "xp_kill":320, "monster_hp":175, "monster_atk":52, "swing_time":2.5,"item_id":"dragon_scale",   "item_name":"Dragon Scale"},
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
        "chain_next": "q_token_iron",
        "objectives": [
            {"type": "talk", "target_id": "Ironwood Hermit Skade",
             "quantity": 1, "display": "Deliver Bjarne's letter to Skade"},
        ],
        "rewards": {"xp": {"melee": 200, "vitality": 50}, "gold": 150,
                    "items": []},
    },
    "q_token_iron": {
        "title": "The Iron Token",
        "description": "Skade has told you what Bjarne could not write: the High Seat is real, and it cannot be sat without the Five Tokens — one kept by each of the five holds. The Iron Token has rested in Kjelvik for two hundred years; Bjarne will yield it only once you have forged for the wall and cleared the dead beneath the Great Hall.",
        "giver_npc": "Elder Bjarne",
        "required": {"melee": 10, "smithing": 5},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_frost",
        "objectives": [
            {"type": "gather", "target_id": "iron_bar", "quantity": 5,
             "display": "Forge Iron Bars for the wall"},
            {"type": "kill", "target_id": "skeleton", "quantity": 8,
             "display": "Clear skeletons from the Great Hall cellars"},
        ],
        "rewards": {"xp": {"smithing": 400, "melee": 300}, "gold": 300,
                    "items": [{"id": "iron_token", "name": "Iron Token",
                               "qty": 1, "color": [0.62, 0.62, 0.68, 1.0]}]},
    },
    "q_token_frost": {
        "title": "The Frost Token",
        "description": "The second Token lies at Frostheim's glacier shrine, guarded by the great white pack — ice wolves that have already killed three of Ragnhild's hunters. Break the pack and take what they guard. She'd not go up there without a warband at her back, and neither should you.",
        "giver_npc": "Hunter Ragnhild",
        "required": {"melee": 18},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_grove",
        "objectives": [
            {"type": "kill", "target_id": "ice_wolf", "quantity": 6,
             "display": "Break the ice-wolf pack at the glacier shrine"},
        ],
        "rewards": {"xp": {"melee": 600, "defense": 150, "vitality": 100},
                    "gold": 500,
                    "items": [{"id": "frost_token", "name": "Frost Token",
                               "qty": 1, "color": [0.72, 0.90, 0.98, 1.0]}]},
    },
    "q_token_grove": {
        "title": "The Grove Token",
        "description": "The third Token hangs in the deepest dark of the Ironwood, where the last true trees still stand — and the Grove Guardian watches over it. Cut the ancient timber Ulfr needs, then face the thing in the grove.",
        "giver_npc": "Blacksmith Ulfr",
        "required": {"melee": 25, "woodcutting": 30},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_sea",
        "objectives": [
            {"type": "gather", "target_id": "ironwood_log", "quantity": 5,
             "display": "Fell Ironwood in the dark grove"},
            {"type": "kill", "target_id": "ancient_troll", "quantity": 1,
             "display": "Slay the Grove Guardian"},
        ],
        "rewards": {"xp": {"woodcutting": 700, "melee": 400}, "gold": 700,
                    "items": [{"id": "grove_token", "name": "Grove Token",
                               "qty": 1, "color": [0.35, 0.62, 0.28, 1.0]}]},
    },
    "q_token_sea": {
        "title": "The Sea Token",
        "description": "The fourth Token rests at a shrine on the eastern cliffs. Valdis will sail you there only once you have proven yourself a deep-water hand — land a shark from the cold eastern waters, and put down the beast that comes for you when you do.",
        "giver_npc": "Sea Captain Valdis",
        "required": {"fishing": 32},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_token_ash",
        "objectives": [
            {"type": "gather", "target_id": "raw_shark", "quantity": 1,
             "display": "Land a Shark from the eastern waters"},
            {"type": "kill", "target_id": "shark", "quantity": 1,
             "display": "Slay the shark that hunts the shrine"},
        ],
        "rewards": {"xp": {"fishing": 900, "melee": 300}, "gold": 900,
                    "items": [{"id": "sea_token", "name": "Sea Token",
                               "qty": 1, "color": [0.20, 0.55, 0.92, 1.0]}]},
    },
    "q_token_ash": {
        "title": "The Ash Token",
        "description": "Four Tokens. The fifth waits beyond the rim of the Ashlands, where the fire-things nest and the Emberlord walks the burning ground. Clear the imps, break the Emberlord, and carry the last Token off the ash.",
        "giver_npc": "Scout Halfdan",
        "required": {"melee": 40, "vitality": 25},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_warrant",
        "objectives": [
            {"type": "kill", "target_id": "fire_imp", "quantity": 6,
             "display": "Slay Fire Imps beyond the rim"},
            {"type": "kill", "target_id": "fire_giant", "quantity": 1,
             "display": "Break the Emberlord"},
        ],
        "rewards": {"xp": {"melee": 1200, "vitality": 400}, "gold": 1200,
                    "items": [{"id": "ash_token", "name": "Ash Token",
                               "qty": 1, "color": [0.85, 0.35, 0.15, 1.0]}]},
    },
    "q_warrant": {
        "title": "The Warrant of the High Seat",
        "description": "Five Tokens — Iron, Frost, Grove, Sea, and Ash — carried at last to Captain Sten on the Helheim shore. Lay them before him, and he will name you a claimant of the High Seat.",
        "giver_npc": "Captain Sten",
        "required": {"melee": 45},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_pledge_kjelvik",
        "objectives": [
            {"type": "talk", "target_id": "Captain Sten", "quantity": 1,
             "display": "Lay the five Tokens before Sten"},
        ],
        "rewards": {"xp": {"melee": 2000, "vitality": 500, "magic": 400},
                    "gold": 2000,
                    "items": [
                        # Marker item — server checks for this id to unlock
                        # warband creation. Don't drop on death.
                        {"id": "high_seat_warrant",
                         "name": "Warrant of the High Seat", "qty": 1,
                         "color": [0.95, 0.85, 0.30, 1.0]},
                    ]},
    },
    "q_pledge_kjelvik": {
        "title": "Pledge of Kjelvik",
        "description": "The Warrant is yours. To pledge Kjelvik to your warband, forge 15 iron bars to rebuild the wall and clear 10 skeletons from the Great Hall cellars. Then swear the oath at the cracked stone seat.",
        "giver_npc": "Elder Bjarne",
        "required": {"melee": 45, "smithing": 40},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_pledge_frostheim",
        "objectives": [
            {"type": "gather", "target_id": "iron_bar", "quantity": 15,
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
    "q_pledge_frostheim": {
        "title": "Pledge of Frostheim",
        "description": "Frostheim pledges when the goblin push is broken at the high passes. Slay 12 Goblins and 5 Ice Wolves, and bring Ragnhild 10 Frost Logs for the palisade. Then swear the oath at the mountain shrine.",
        "giver_npc": "Hunter Ragnhild",
        "required": {"melee": 50, "woodcutting": 50},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_pledge_ironwood",
        "objectives": [
            {"type": "kill", "target_id": "goblin", "quantity": 12,
             "display": "Slay Goblins at the high passes"},
            {"type": "kill", "target_id": "ice_wolf", "quantity": 5,
             "display": "Slay Ice Wolves"},
            {"type": "gather", "target_id": "frost_log", "quantity": 10,
             "display": "Gather Frost Logs for the palisade"},
            {"type": "talk", "target_id": "Hunter Ragnhild", "quantity": 1,
             "display": "Swear the oath at the mountain shrine"},
        ],
        "rewards": {"xp": {"melee": 1600, "woodcutting": 800, "defense": 450},
                    "gold": 3200,
                    "items": [{"id": "pledge_frostheim",
                               "name": "Pledge of Frostheim", "qty": 1,
                               "color": [0.72, 0.90, 0.98, 1.0]}]},
    },
    "q_pledge_ironwood": {
        "title": "Pledge of Ironwood Keep",
        "description": "Ironwood pledges when Ulfr's forge is stocked for winter and his grove holds. Bring him 12 Ironwood Logs and clear 10 Wolves from the dark grove. Then swear the oath at the last Ironwood Tree.",
        "giver_npc": "Blacksmith Ulfr",
        "required": {"melee": 53, "smithing": 50, "woodcutting": 45},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_pledge_bjorn",
        "objectives": [
            {"type": "gather", "target_id": "ironwood_log", "quantity": 12,
             "display": "Gather Ironwood Logs"},
            {"type": "kill", "target_id": "wolf", "quantity": 10,
             "display": "Clear wolves from the dark grove"},
            {"type": "talk", "target_id": "Blacksmith Ulfr", "quantity": 1,
             "display": "Swear the oath at the Ironwood Tree"},
        ],
        "rewards": {"xp": {"smithing": 1600, "woodcutting": 900, "melee": 700},
                    "gold": 3400,
                    "items": [{"id": "pledge_ironwood",
                               "name": "Pledge of Ironwood Keep", "qty": 1,
                               "color": [0.28, 0.14, 0.08, 1.0]}]},
    },
    "q_pledge_bjorn": {
        "title": "Pledge of Bjorn's Landing",
        "description": "The harbor pledges when the eastern lane is safe again. Bring Valdis 5 Raw Sharks and scatter 8 Bandits from the coast road. Then swear the oath at the dock-end shrine.",
        "giver_npc": "Sea Captain Valdis",
        "required": {"melee": 45, "fishing": 56},
        "repeatable": False, "daily": False, "boss": False,
        "chain_next": "q_pledge_eastmark",
        "objectives": [
            {"type": "gather", "target_id": "raw_shark", "quantity": 5,
             "display": "Bring Valdis Raw Sharks"},
            {"type": "kill", "target_id": "bandit", "quantity": 8,
             "display": "Clear the coast-road bandits"},
            {"type": "talk", "target_id": "Sea Captain Valdis", "quantity": 1,
             "display": "Swear the oath at the dock-end shrine"},
        ],
        "rewards": {"xp": {"fishing": 1400, "melee": 1100, "defense": 450},
                    "gold": 3600,
                    "items": [{"id": "pledge_bjorn",
                               "name": "Pledge of Bjorn's Landing", "qty": 1,
                               "color": [0.20, 0.55, 0.92, 1.0]}]},
    },
    "q_pledge_eastmark": {
        "title": "Pledge of Eastmark Post",
        "description": "The last pledge, and the hardest. Eastmark swears when the Ashlands road is walkable again — clear 10 Draugr on the patrol route and 5 Fire Imps beyond the rim. Then swear the oath at the perimeter watchstone.",
        "giver_npc": "Scout Halfdan",
        "required": {"melee": 60, "vitality": 35},
        "repeatable": False, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "draugr", "quantity": 10,
             "display": "Clear Draugr on the Ashlands patrol"},
            {"type": "kill", "target_id": "fire_imp", "quantity": 5,
             "display": "Slay Fire Imps beyond the rim"},
            {"type": "talk", "target_id": "Scout Halfdan", "quantity": 1,
             "display": "Swear the oath at the perimeter watchstone"},
        ],
        "rewards": {"xp": {"melee": 1900, "vitality": 550, "defense": 550},
                    "gold": 4000,
                    "items": [{"id": "pledge_eastmark",
                               "name": "Pledge of Eastmark Post", "qty": 1,
                               "color": [0.85, 0.30, 0.18, 1.0]}]},
    },

    # ── Repeatable field bounties (1.6.4) — MIRROR of QuestData.gd; keep in sync.
    #    Small re-doable kill/gather jobs; XP-forward, light gold. Needs target
    #    monsters placed near each town (see the placement list).
    "q_daily_eastmark_trolls": {
        "title": "Trolls at the Pass",
        "description": "Two trolls have blocked the mountain pass above Eastmark Post. Clear them out.",
        "giver_npc": "Scout Halfdan",
        "required": {"melee": 15},
        "repeatable": True, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "troll", "quantity": 2,
             "display": "Slay Trolls at the mountain pass"},
        ],
        "rewards": {"xp": {"melee": 260, "defense": 60}, "gold": 120, "items": []},
    },
    "q_daily_bjorn_wolves": {
        "title": "Wolves in the Hills",
        "description": "The Bjorn Mountains are thick with wolves this season. Thin the pack — five should do.",
        "giver_npc": "Merchant Eydis",
        "required": {},
        "repeatable": True, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "wolf", "quantity": 5,
             "display": "Slay Wolves in the Bjorn Mountains"},
        ],
        "rewards": {"xp": {"melee": 130, "vitality": 30}, "gold": 60, "items": []},
    },
    "q_daily_kjelvik_skeletons": {
        "title": "Cellar Sweep",
        "description": "Skeletons keep crawling up from the Kjelvik cellars. Put six back down.",
        "giver_npc": "Elder Bjarne",
        "required": {"melee": 5},
        "repeatable": True, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "skeleton", "quantity": 6,
             "display": "Clear Skeletons from the cellars"},
        ],
        "rewards": {"xp": {"melee": 170}, "gold": 80, "items": []},
    },
    "q_daily_frostheim_icewolves": {
        "title": "White Fangs",
        "description": "Ice wolves are stalking the Frostheim high passes. Drive four off.",
        "giver_npc": "Hunter Ragnhild",
        "required": {"melee": 10},
        "repeatable": True, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "ice_wolf", "quantity": 4,
             "display": "Slay Ice Wolves on the high passes"},
        ],
        "rewards": {"xp": {"melee": 190, "defense": 40}, "gold": 90, "items": []},
    },
    "q_daily_ironwood_bears": {
        "title": "Grove Guardians",
        "description": "Bears have turned the Ironwood dark grove into a den. Cull three.",
        "giver_npc": "Blacksmith Ulfr",
        "required": {"melee": 12},
        "repeatable": True, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "bear", "quantity": 3,
             "display": "Slay Bears in the dark grove"},
        ],
        "rewards": {"xp": {"melee": 210, "vitality": 40}, "gold": 110, "items": []},
    },
    "q_daily_bjorn_bandits": {
        "title": "Coast Road Toll",
        "description": "Bandits are shaking down travellers on the Bjorn coast road. Scatter five.",
        "giver_npc": "Sea Captain Valdis",
        "required": {"melee": 8},
        "repeatable": True, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "kill", "target_id": "bandit", "quantity": 5,
             "display": "Clear Bandits from the coast road"},
        ],
        "rewards": {"xp": {"melee": 170, "ranged": 40}, "gold": 90, "items": []},
    },
    "q_daily_palisade_logs": {
        "title": "Timber for the Walls",
        "description": "The Kjelvik palisade needs shoring up. Bring Halvdan 20 Oak Logs.",
        "giver_npc": "Castellan Halvdan",
        "required": {},
        "repeatable": True, "daily": False, "boss": False, "chain_next": "",
        "objectives": [
            {"type": "gather", "target_id": "oak_log", "quantity": 20,
             "display": "Gather Oak Logs for the palisade"},
        ],
        "rewards": {"xp": {"construction": 150, "woodcutting": 60}, "gold": 50, "items": []},
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
    # Jewelcrafting gems (Phase 1) — mirror of ItemPrices.gd.
    "opal": 1200, "amethyst": 4000, "diamond": 12000,
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
    # Farming crop dishes (1.6.2)
    "barley_porridge": 18, "steamed_cabbage": 20, "dark_bread": 24, "roasted_corn": 26,
    "boiled_potato": 30, "garden_salad": 60, "sweet_loaf": 55, "farmers_stew": 95,
    "ale": 60, "stuffed_pepper": 80, "melon_slice": 130, "apple_pie": 180,
    "berry_fruit_bowl": 200, "peach_cobbler": 260, "fine_wine": 420,
    "wheat_bread": 20, "carrot_stew": 55, "moonwheat_loaf": 180,
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
    "earthworm": 3, "shrimp_bait": 15, "fatty_lard": 50, "calming_chum": 40,
    "glimmer_roe": 220, "runic_lure": 2500, "trophy_spoon": 3500,
    "serpent_lure": 4000, "kraken_bait": 5000,
    # Farming — seeds (buy/base) scale with tier; crops (sell/base) a touch higher.
    "wheat_seed": 8, "carrot_seed": 8, "barley_seed": 12, "cabbage_seed": 12,
    "rye_seed": 16, "corn_seed": 22, "potato_seed": 30, "cotton_seed": 45,
    "pepper_seed": 60, "sugarcane_seed": 80, "hops_seed": 100, "tomato_seed": 130,
    "moonwheat_seed": 170, "blueberry_seed": 210, "lingonberry_seed": 240,
    "strawberry_seed": 280, "peach_seed": 340, "apple_seed": 430,
    "watermelon_seed": 550, "grape_seed": 800,
    "wheat": 12, "carrot": 12, "barley": 16, "cabbage": 18, "rye": 22, "corn": 30,
    "potato": 40, "cotton": 55, "pepper": 75, "sugarcane": 95, "hops": 120,
    "tomato": 150, "moonwheat": 200, "blueberry": 240, "lingonberry": 270,
    "strawberry": 320, "peach": 400, "apple": 500, "watermelon": 650, "grape": 950,
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
            {"id": "wheat_seed",          "name": "Wheat Seed",          "color": [0.90, 0.80, 0.30, 1.0], "max":  40, "restock_per_tick":  4.0},
            {"id": "carrot_seed",         "name": "Carrot Seed",         "color": [0.90, 0.55, 0.20, 1.0], "max":  40, "restock_per_tick":  4.0},
            {"id": "barley_seed",         "name": "Barley Seed",         "color": [0.82, 0.72, 0.40, 1.0], "max":  30, "restock_per_tick":  3.0},
            {"id": "cabbage_seed",        "name": "Cabbage Seed",        "color": [0.45, 0.72, 0.36, 1.0], "max":  30, "restock_per_tick":  3.0},
            {"id": "rye_seed",            "name": "Rye Seed",            "color": [0.72, 0.62, 0.32, 1.0], "max":  25, "restock_per_tick":  2.5},
            {"id": "corn_seed",           "name": "Corn Seed",           "color": [0.92, 0.80, 0.25, 1.0], "max":  20, "restock_per_tick":  2.0},
            {"id": "potato_seed",         "name": "Potato Seed",         "color": [0.72, 0.56, 0.36, 1.0], "max":  20, "restock_per_tick":  2.0},
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
        # Practice-makes-perfect — per-recipe attempt counter feeding the
        # success formula for Cooking / Smithing / Farming. Client owns
        # the counter and increments per attempt; server stores as JSON
        # blob alongside skill_xp so it survives relog.
        try:
            conn.execute("ALTER TABLE players ADD COLUMN recipe_counts TEXT DEFAULT '{}'")
        except Exception:
            pass
        # PvP Tokens (Phase 1d) — a SERVER-OWNED currency spent at the
        # PvP-Token NPC to permanently upgrade gear. Server-authoritative so an
        # edited client can't fake the balance or mint free upgrades.
        try:
            conn.execute("ALTER TABLE players ADD COLUMN pvp_tokens INTEGER DEFAULT 0")
        except Exception:
            pass
        # Personal gold reserve (Phase 3 #3) — banked gold, server-owned like
        # carried gold. Deposit/withdraw move between players.gold and this.
        try:
            conn.execute("ALTER TABLE players ADD COLUMN bank_gold INTEGER DEFAULT 0")
        except Exception:
            pass
        # Thrall roster (Phase 10) — how many thrall slots the player owns (2-5).
        try:
            conn.execute("ALTER TABLE players ADD COLUMN thrall_slots INTEGER DEFAULT 2")
        except Exception:
            pass
        # Fast-travel unlocks — towns discovered on foot. Server-owned so the 1-time
        # unlock is account-persistent across logouts + devices (was client-cfg only).
        try:
            conn.execute("ALTER TABLE players ADD COLUMN discovered_towns TEXT DEFAULT '[]'")
        except Exception:
            pass
        # Phase 10b — timestamp of the player's last logout, used to credit each
        # assigned thrall's offline work on next login (0 = no pending window).
        try:
            conn.execute("ALTER TABLE players ADD COLUMN thrall_logout_at REAL DEFAULT 0")
        except Exception:
            pass
        # V1.5.5 — the town a thrall is sent to when assigned; drives its visible
        # work-spot on the map. Empty = unassigned / no town chosen yet.
        try:
            conn.execute("ALTER TABLE thralls ADD COLUMN town TEXT DEFAULT ''")
        except Exception:
            pass
        # Tiled clan bank (Phase 3 #2). bank_tabs = how many 20-slot tabs are
        # unlocked (1-3). clan_members gains per-member withdraw permissions +
        # a manual clan-gold withdraw allowance.
        for _sql in (
            "ALTER TABLE clans ADD COLUMN bank_tabs INTEGER DEFAULT 1",
            "ALTER TABLE clan_members ADD COLUMN withdraw_tabs TEXT DEFAULT '[]'",
            "ALTER TABLE clan_members ADD COLUMN gold_limit INTEGER DEFAULT 0",
            "ALTER TABLE clan_members ADD COLUMN gold_withdrawn INTEGER DEFAULT 0",
        ):
            try:
                conn.execute(_sql)
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
        # Thralls (Phase 10) — collectible offline workers owned by a player.
        # tier (from the monster that dropped it) caps task difficulty; level is
        # uncapped prestige. Combat thralls have hp + a backpack (food you stock +
        # loot they collect); a thrall row is DELETED when it dies.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS thralls (
                id         TEXT PRIMARY KEY,
                owner_id   TEXT NOT NULL,
                name       TEXT NOT NULL,
                tier       INTEGER DEFAULT 1,
                level      INTEGER DEFAULT 1,
                xp         INTEGER DEFAULT 0,
                job        TEXT DEFAULT '',
                target     TEXT DEFAULT '',
                appearance TEXT DEFAULT '',
                hp         INTEGER DEFAULT 30,
                max_hp     INTEGER DEFAULT 30,
                backpack   TEXT DEFAULT '[]',
                created_at REAL NOT NULL
            )
        """)
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_thralls_owner ON thralls(owner_id)")
        # Reputation (Phase 5a) — standing per player per town, plus a
        # warband-level standing per town. A member's EFFECTIVE standing blends
        # their personal value with a share of their warband's (see
        # _rep_effective), which is what makes a warband's actions move every
        # member's reputation.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS reputation (
                player_id TEXT NOT NULL,
                town_id   TEXT NOT NULL,
                value     INTEGER DEFAULT 0,
                PRIMARY KEY (player_id, town_id)
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS warband_reputation (
                warband_id TEXT NOT NULL,
                town_id    TEXT NOT NULL,
                value      INTEGER DEFAULT 0,
                PRIMARY KEY (warband_id, town_id)
            )
        """)
        # Player↔warband standing (Phase 5c) — the third reputation axis, born
        # from warband caravans: raiding a warband's caravan makes you hostile
        # to them. Only rows that have moved off zero exist / show in the tab.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS warband_standing (
                player_id  TEXT NOT NULL,
                warband_id TEXT NOT NULL,
                value      INTEGER DEFAULT 0,
                PRIMARY KEY (player_id, warband_id)
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
                y       REAL,
                rot     REAL DEFAULT 0
            )
        """)
        # v1.6.1 — rotation edit for PRE-EXISTING entities (admin rotate tool).
        # Admin-placed (a:) entities store rotation in world_entities.data["rot"].
        try:
            conn.execute("ALTER TABLE entity_edits ADD COLUMN rot REAL DEFAULT 0")
        except Exception:
            pass
        # v1.7 — DATA override for PRE-EXISTING entities (admin edit tool): lets
        # procedural NPCs/bosses (n:/b:) carry an editable name/dialogue/level
        # server-side without converting them to a: rows (preserves move/delete).
        try:
            conn.execute("ALTER TABLE entity_edits ADD COLUMN data TEXT")
        except Exception:
            pass
        # v1.6.1 — server-persisted terrain HEIGHT sculpt (3D client). idx = ty*300+tx;
        # delta layers on the biome base. Sparse (only sculpted tiles). Synced to all
        # clients like tile_overrides so admin height edits aren't client-local.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS terrain_heights (
                idx   INTEGER PRIMARY KEY,
                delta REAL NOT NULL
            )
        """)
        # v1.6.9 — admin-drawn ROAD/PATH network (dots + edges). The whole graph
        # is stored as one JSON doc {"nodes":[{id,x,y}], "edges":[[a,b],...]} in a
        # single pinned row. Admin edits it in-world via the Roads tab; the
        # autoplay bot follows it for real road-based town-to-town travel. Synced
        # to every client on login + on each edit (never client-local).
        conn.execute("""
            CREATE TABLE IF NOT EXISTS road_graph (
                id   INTEGER PRIMARY KEY CHECK (id = 1),
                data TEXT NOT NULL
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


def _migrate_v18(conn) -> None:
    """Fishing biggest-catch leaderboard (1.6.3). `fishing_records` = the global
    biggest catch per species (the record holder). `fishing_journal` = each
    player's personal best per species."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS fishing_records (
            species      TEXT PRIMARY KEY,
            species_name TEXT NOT NULL DEFAULT '',
            weight       REAL NOT NULL,
            holder_id    TEXT NOT NULL,
            holder_name  TEXT NOT NULL,
            caught_at    REAL NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS fishing_journal (
            player_id    TEXT NOT NULL,
            species      TEXT NOT NULL,
            species_name TEXT NOT NULL DEFAULT '',
            best_weight  REAL NOT NULL,
            caught_at    REAL NOT NULL,
            PRIMARY KEY (player_id, species)
        )
    """)


_MIGRATIONS = [
    _migrate_v1, _migrate_v2, _migrate_v3, _migrate_v4,
    _migrate_v5, _migrate_v6, _migrate_v7, _migrate_v8,
    _migrate_v9, _migrate_v10, _migrate_v11, _migrate_v12, _migrate_v13,
    _migrate_v14, _migrate_v15, _migrate_v16, _migrate_v17, _migrate_v18,
]


def _hash(password: str, salt: str) -> str:
    return hashlib.sha256((password + salt).encode()).hexdigest()


# ── Session / idle stores ──────────────────────────────────────────────────────
sessions:         dict = {}   # ws → {id, username, x, y, last_action_ms}
# Read-only observers (auto_studio recording bots). ws → {target, id}. A
# spectator receives every world broadcast but has NO entry in `sessions`, so
# it never spawns a character, never triggers the duplicate-login kick, and is
# rejected by every gameplay message handler (session is None). See
# _handle_spectate + the spectator fan-out in _broadcast / _broadcast_near /
# _broadcast_monster_positions.
spectators:       dict = {}   # ws → {"target": username, "id": resolved player id}
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
    # Mirror every world broadcast to read-only spectators (recording bots) so
    # they render the live world (joins/leaves/moves/chat) without a session.
    for ws in list(spectators):
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


# Canonical 15-skill set for the character-level average. Mirrors the CLIENT's
# GameManager.player_skill_xp (which swapped foraging → jewelcrafting when
# Foraging merged into Farming), so a player's nameplate level matches the
# Character Level they see in their own skills tab.
_LEVEL_SKILLS = (
    "woodcutting", "mining", "fishing", "farming",
    "smithing", "cooking", "crafting", "construction", "jewelcrafting",
    "melee", "ranged", "magic", "defense", "vitality", "soul",
)


# Character-level weighting — EXACT mirror of GameManager (CL_* consts). Combat
# skills pull 3× harder; normalized so all-99 → 150 (not the 1485 sum).
_CL_COMBAT_SKILLS = ("melee", "ranged", "magic", "defense", "vitality")
_CL_COMBAT_WEIGHT = 3
_CL_OTHER_WEIGHT = 1
_CL_TARGET_MAX = 150


def _character_level(skill_xp: dict) -> int:
    """Combat-weighted overall level. Mirrors GameManager.get_character_level
    (incl. GDScript's round = floor(x+0.5)) so a nameplate matches the owner's
    own skills-tab Character Level."""
    weighted = 0
    max_weighted = 0
    for s in _LEVEL_SKILLS:
        w = _CL_COMBAT_WEIGHT if s in _CL_COMBAT_SKILLS else _CL_OTHER_WEIGHT
        weighted += _calc_level(int(skill_xp.get(s, 0))) * w
        max_weighted += 99 * w
    if max_weighted == 0:
        return 1
    return max(1, int(math.floor(weighted / max_weighted * _CL_TARGET_MAX + 0.5)))


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
    # SECURITY (v1.7) — never let a new account resolve to ANY admin rank. Rank is
    # matched by case-folded username (_admin_rank), so without this a case/space
    # variant of the owner ("BUSTERRDUST") or any rank-holder would INHERIT their
    # rank. The only path to rank is the OWNER granting it in-game.
    if _admin_rank(username) != "":
        await _send(ws, {"type": "register_fail", "reason": "Name not allowed."})
        return
    if len(password) < 4:
        await _send(ws, {"type": "register_fail", "reason": "Password must be at least 4 characters."})
        return
    if email and not _looks_like_email(email):
        await _send(ws, {"type": "register_fail", "reason": "Email doesn't look right."})
        return
    with _db() as conn:
        # Case-INSENSITIVE uniqueness — "BUSTERRDUST" must collide with
        # "Busterrdust" (both to stop impersonation AND because rank is matched
        # case-folded; see the _admin_rank guard above).
        if conn.execute("SELECT 1 FROM players WHERE username=? COLLATE NOCASE", (username,)).fetchone():
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

    # Phase 10b — credit assigned thralls' offline work for the logged-out
    # window (grants player skill XP + thrall levels + backpack loot, may kill
    # a starved combat thrall). Re-read the row so the login payload reflects
    # the granted skill XP. `thrall_summary` is pushed after the bursts below.
    thrall_summary = _simulate_thralls(player_id, now)
    if thrall_summary:
        with _db() as conn:
            _fresh = conn.execute("SELECT * FROM players WHERE id=?",
                                  (player_id,)).fetchone()
        if _fresh is not None:
            row = _fresh

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
        # v1.7 B1 — cached for server-authoritative combat damage. Refreshed on
        # every save. (Still client-influenced until B4 locks skill_xp.)
        "skill_xp":       json.loads(row["skill_xp"] or "{}"),
        "last_action_ms": 0,
        "interior_id":    cur_interior_id,
        "interior_x":     cur_interior_x,
        "interior_y":     cur_interior_y,
        # Restore the return coord from the DB so an exit after relog
        # teleports the player back to their pre-entry exterior position,
        # not to (0, 0) / world corner.
        "interior_return_x": cur_interior_return_x,
        "interior_return_y": cur_interior_return_y,
        # PvP state — client-side toggle mirrored here so attacks can be
        # server-gated (only mutually-flagged players in range can hit
        # each other). Not persisted across logout; a fresh login starts
        # unflagged, matching the WoW mental model.
        "pvp_flagged":       False,
        "pvp_locked_until":  0.0,
        # A returning offender gets a short grace before the watch can engage, so a
        # hostile player can log in + walk out instead of being mass-killed on entry.
        "watch_cooldown_until": time.time() + WATCH_LOGIN_GRACE,
        # Overall character level, shown on other players' nameplates. Computed
        # at login + refreshed on save (see _handle_save).
        "character_level":   _character_level(json.loads(row["skill_xp"] or "{}")),
    }
    with _db() as conn:
        conn.execute("UPDATE players SET last_seen=? WHERE id=?", (time.time(), player_id))
        conn.commit()

    pending_summary = idle_summaries.pop(player_id, None)
    task_queue      = json.loads(row["task_queue"] or "[]")

    # Content-bot leaders: grant the Warrant of the High Seat server-side (once,
    # persisted) so the AutoContent bots can found warbands. Real players earn it.
    _inventory = json.loads(row["inventory"] or "[]")
    if (row["username"] in _CONTENT_BOT_LEADERS and not any(
            isinstance(it, dict) and it.get("id") == "high_seat_warrant"
            for it in _inventory)):
        _inventory.append({"id": "high_seat_warrant",
                           "name": "Warrant of the High Seat",
                           "qty": 1, "color": [0.95, 0.85, 0.30, 1.0]})
        with _db() as conn:
            conn.execute("UPDATE players SET inventory=? WHERE id=?",
                         (json.dumps(_inventory), player_id))
            conn.commit()
        print(f"[content-bot] granted High Seat Warrant to {row['username']}")

    player_data = {
        "id":           player_id,
        "username":     row["username"],
        "x":            float(row["x"]),
        "y":            float(row["y"]),
        "skill_xp":     json.loads(row["skill_xp"]  or "{}"),
        # Practice-makes-perfect per-recipe counters. Empty {} for a fresh
        # account. Client reads on populate + increments on every craft
        # attempt (success or fail), sends back via send_save.
        "recipe_counts": json.loads(row["recipe_counts"] or "{}") if "recipe_counts" in row.keys() else {},
        "inventory":    _inventory,
        "bank":         json.loads(row["bank"]       or "[]"),
        "gold":         int(row["gold"] or 0),
        # Server-owned PvP-Token balance (Phase 1d). Column may be absent on a
        # very old row mid-migration — default 0 defensively.
        "pvp_tokens":   int(row["pvp_tokens"] or 0) if "pvp_tokens" in row.keys() else 0,
        "bank_gold":    int(row["bank_gold"] or 0) if "bank_gold" in row.keys() else 0,
        # Fast-travel towns discovered on foot — persistent 1-time unlocks.
        "discovered_towns": json.loads((row["discovered_towns"] if "discovered_towns" in row.keys() else None) or "[]"),
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

    # Send currently online players. Include the live PvP flag so a client that
    # joins AFTER someone flagged still renders them red (Phase 8) — the flag is
    # session state, not part of the appearance blob.
    for ows, s in sessions.items():
        if ows is not ws:
            await _send(ws, {"type": "player_join",
                             "id": s["id"], "username": s["username"],
                             "x": s["x"],   "y": s["y"],
                             "appearance": s.get("appearance", {}),
                             "equipment":  s.get("equipment", {}),
                             "flagged":    bool(s.get("pvp_flagged", False)),
                             "level":      int(s.get("character_level", 1)),
                             # Which building interior they're in ("" = outside).
                             # The client only renders same-interior occupants.
                             "interior_id": str(s.get("interior_id", ""))})

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
                "appearance": appearance, "equipment": equipment,
                "level": _character_level(json.loads(row["skill_xp"] or "{}")),
                "interior_id": cur_interior_id},
               exclude_ws=ws)

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
    # Admin terrain height sculpt (3D client) — synced like tile_overrides.
    await _send(ws, {"type": "terrain_heights", "tiles": _load_terrain_heights()})
    # Admin-drawn road/path network (dots + edges) — the autoplay bot follows it.
    _rg = _load_road_graph()
    await _send(ws, {"type": "road_graph", "nodes": _rg["nodes"], "edges": _rg["edges"]})
    # Farm plot state burst — one entry per active plot with its current
    # ripen stage so the client renders the right sprite the moment the
    # plot appears. Plots with `seed_id` empty (freshly harvested) are
    # skipped since the default stage is 0.
    farm_burst: list = []
    _now = time.time()
    for eid, entry in farm_plots.items():
        farm_burst.append(_farm_burst_entry(eid, entry, _now))
    _append_town_plot_burst(farm_burst, player_id)   # this player's town crops
    if farm_burst:
        await _send(ws, {"type": "farm_plot_burst", "plots": farm_burst})

    # Town standing (Phase 5a) for the Reputation tab.
    await _send_reputation(ws, player_id)
    # Fishing biggest-catch records + this player's journal (1.6.3).
    await _send(ws, {"type": "fishing_data",
                     "records": _fishing_records_all(),
                     "journal": _fishing_journal_for(player_id)})
    # Thrall roster (Phase 10) + the offline-work report from _simulate_thralls.
    await _send_thralls(ws, player_id)
    if thrall_summary:
        await _send(ws, {"type": "thrall_summary", "summary": thrall_summary})

    print(f"[login] {username}  ({len(sessions)} online)")


def _spectate_state_for(username: str) -> dict:
    """A watched player's shown-off state for the spectator HUD: skills (→ level +
    max HP on the client), inventory (what they've gathered/crafted) and worn gear
    (what they're wielding). Read from the DB, which every `save` keeps current, so
    it works whether the target is online or briefly offline. {} if unknown."""
    if not username:
        return {}
    with _db() as conn:
        row = conn.execute(
            "SELECT skill_xp, inventory, equipment, bank FROM players "
            "WHERE username=? COLLATE NOCASE", (username,)).fetchone()
    if not row:
        return {}
    try:
        return {
            "skill_xp":  json.loads(row["skill_xp"]  or "{}"),
            "inventory": json.loads(row["inventory"] or "[]"),
            "equipment": json.loads(row["equipment"] or "{}"),
            "bank":      json.loads(row["bank"]      or "[]"),
        }
    except Exception:
        return {}


async def _push_spectate_state(username: str) -> None:
    """Send a fresh `spectate_state` to every observer watching `username`. Cheap
    no-op when nobody is spectating that player, so it's safe to call from `save`."""
    if not spectators or not username:
        return
    watching = [ws for ws, spec in list(spectators.items())
                if str(spec.get("target", "")).lower() == username.lower()]
    if not watching:
        return
    state = _spectate_state_for(username)
    if not state:
        return
    payload = {"type": "spectate_state", "target": username, **state}
    for ws in watching:
        await _send(ws, payload)   # _send json.dumps; _safe_send needs a STRING


async def _handle_spectate(ws, msg: dict) -> None:
    """Read-only observer connection (auto_studio recording bot).

    Registers the socket in `spectators` (NOT `sessions`), so it receives every
    world broadcast but never spawns a playable character, never replaces or
    kicks the target's real play session, and is rejected by every gameplay
    handler (session stays None). `target` is the username to center the camera
    on; we resolve it to a player id so the client can follow that entity, but
    the id is optional — the client also matches the target by username as
    live joins arrive, so spectating works even if the target is offline now
    and logs in later.
    """
    target = str(msg.get("target", "")).strip()
    target_id = ""
    if target:
        with _db() as conn:
            trow = conn.execute(
                "SELECT id FROM players WHERE username=? COLLATE NOCASE",
                (target,)).fetchone()
            if trow:
                target_id = trow["id"]
    spectators[ws] = {"target": target, "id": target_id}
    await _send(ws, {"type": "spectate_ok",
                     "target": target, "target_id": target_id})
    # Roster of everyone currently visible so the observer can render the world
    # (same shape as the login burst — live PvP flag + level included).
    for ows, s in sessions.items():
        await _send(ws, {"type": "player_join",
                         "id": s["id"], "username": s["username"],
                         "x": s["x"], "y": s["y"],
                         "appearance": s.get("appearance", {}),
                         "equipment": s.get("equipment", {}),
                         "flagged": bool(s.get("pvp_flagged", False)),
                         "level": int(s.get("character_level", 1))})
    for pid, info in idle_info.items():
        await _send(ws, {"type": "player_join",
                         "id": info["id"], "username": info["username"],
                         "x": info["x"], "y": info["y"], "idle": True})
    # World-state burst (admin entities / painted tiles / edits / farm plots),
    # identical to what a logging-in client receives.
    await _send(ws, {"type": "world_entities", "entities": _load_world_entities()})
    await _send(ws, {"type": "tile_overrides", "overrides": _load_tile_overrides()})
    await _send(ws, {"type": "entity_edits", "edits": _load_entity_edits()})
    await _send(ws, {"type": "terrain_heights", "tiles": _load_terrain_heights()})
    _rg2 = _load_road_graph()
    await _send(ws, {"type": "road_graph", "nodes": _rg2["nodes"], "edges": _rg2["edges"]})
    farm_burst: list = []
    _now = time.time()
    for eid, entry in farm_plots.items():
        farm_burst.append(_farm_burst_entry(eid, entry, _now))
    _append_town_plot_burst(farm_burst, target_id)   # show the watched player's town crops
    if farm_burst:
        await _send(ws, {"type": "farm_plot_burst", "plots": farm_burst})
    # Initial player-HUD state (skills/inventory/gear) so the observer can render
    # a real-player-looking HUD for the target right away.
    await _push_spectate_state(target)
    print(f"[spectate] watching '{target}' "
          f"(id={target_id or '?'}, {len(spectators)} observer(s))")


async def _handle_move(ws, session: dict, msg: dict) -> None:
    x = msg.get("x", session["x"])
    y = msg.get("y", session["y"])
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        return
    iid = str(session.get("interior_id", ""))
    # Don't clamp interior occupants to the exterior world height (see the
    # INTERIOR_WORLD_MAX_Y note) — otherwise their broadcast Y pins to the map
    # edge and same-building players can't see each other.
    y_max = INTERIOR_WORLD_MAX_Y if iid else WORLD_H
    session["x"] = max(0.0, min(WORLD_W, float(x)))
    session["y"] = max(0.0, min(y_max, float(y)))
    session["boat"] = str(msg.get("boat", ""))
    _broadcast({"type": "player_move",
                "id": session["id"], "x": session["x"], "y": session["y"],
                "boat": session["boat"], "interior_id": iid}, exclude_ws=ws)
    _maybe_provoke_watch(session)


def _maybe_provoke_watch(session: dict) -> None:
    """Two of the three guard triggers (Phase 5b) are passive states rather
    than actions, so they're sampled as the player moves through the city:
    walking the walls PvP-flagged, or being Hostile/Hated with Kjelvik.
    Throttled — this runs off the 10 Hz move stream."""
    x = float(session.get("x", 0.0))
    y = float(session.get("y", 0.0))
    tid = _town_at_world(x, y)   # any town now, not just the castle (v1.6.2)
    if not tid:
        return
    now = time.time()
    if now - float(session.get("watch_check_at", 0.0)) < 3.0:
        return
    session["watch_check_at"] = now
    pid = session["id"]
    # The watch engages an offender ONCE to death, then stands down — so DON'T
    # re-provoke while (a) on cooldown after a prior downing / a fresh-login grace,
    # or (b) an alert is already live on this player. This is what stops the death
    # loop + the guard-spam flood that lagged the server.
    if now < float(session.get("watch_cooldown_until", 0.0)):
        return
    if guard_alerts.get(pid) is not None:
        return
    # Being PvP-flagged only provokes in the no-PvP castle (Kjelvik); other towns
    # allow PvP, so there it's only hostile STANDING with that town that draws the watch.
    provoke = tid == "kjelvik" and bool(session.get("pvp_flagged"))
    if not provoke:
        try:
            with _db() as conn:
                personal = _rep_map(conn, "reputation", "player_id", pid).get(tid, 0)
            # PERSONAL standing ONLY. A member is NEVER drawn on for their warband's
            # (or another member's) reputation with a town — one player's bad rep must
            # not get their warband-mates mass-killed (live-bug fix).
            provoke = int(personal) < -1000
        except Exception as e:
            print(f"[watch] rep check failed for {pid}: {e!r}")
            return
    if provoke:
        _guard_alert(pid, x, y, WATCH_ENGAGE_SQUAD)


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


# ═══ ⑧ THE FLIP — server-validated save ═════════════════════════════════════
# `_handle_save` no longer TRUSTS the client's inventory/XP. It caps them to what
# the player could legitimately hold: (their PREVIOUS saved state) + (server grants
# since the last save, tracked in session grant_inv/grant_xp). Removals + moves
# (eat/drop/equip/bank) are always allowed (fewer/rearranged items ≤ ceiling), so
# no per-action handler is needed. Injection/duplication is capped away.
# Ship with the season reset (everyone starts clean, so the ceiling starts honest).
SAVE_VALIDATION = True


def _count_units(items) -> dict:
    c: dict = {}
    if isinstance(items, list):
        for it in items:
            if isinstance(it, dict):
                iid = str(it.get("id", ""))
                if iid:
                    c[iid] = c.get(iid, 0) + int(it.get("qty", 1))
    return c


def _count_equip(eq) -> dict:
    """Equipment is {slot: item_id} — count each occupied slot as one unit."""
    c: dict = {}
    if isinstance(eq, dict):
        for v in eq.values():
            iid = str(v.get("id", "")) if isinstance(v, dict) else str(v or "")
            if iid:
                c[iid] = c.get(iid, 0) + 1
    return c


def _remove_units(items: list, iid: str, n: int) -> int:
    """Remove up to n units of iid from an inventory/bank list. Returns leftover."""
    i = len(items) - 1
    while i >= 0 and n > 0:
        it = items[i]
        if isinstance(it, dict) and str(it.get("id", "")) == iid:
            q = int(it.get("qty", 1))
            take = min(q, n)
            q -= take
            n -= take
            if q <= 0:
                items.pop(i)
            else:
                it["qty"] = q
        i -= 1
    return n


def _cap_save_to_ceiling(new_inv: list, new_bank: list, new_eq: dict,
                         prev_inv: list, prev_eq: dict, prev_bank: list,
                         grant_inv: dict) -> dict:
    """Cap the client's item totals (inventory+bank+equipment) to
    prev-totals + granted. Strips excess from inventory first, then bank
    (equipment is counted but not stripped). Mutates new_inv/new_bank in place;
    returns {item_id: excess} of anything capped (for logging)."""
    allowed = _count_units(prev_inv)
    for iid, q in _count_equip(prev_eq).items():
        allowed[iid] = allowed.get(iid, 0) + q
    for iid, q in _count_units(prev_bank).items():
        allowed[iid] = allowed.get(iid, 0) + q
    for iid, q in (grant_inv or {}).items():
        allowed[iid] = allowed.get(iid, 0) + int(q)
    have = _count_units(new_inv)
    for iid, q in _count_equip(new_eq).items():
        have[iid] = have.get(iid, 0) + q
    for iid, q in _count_units(new_bank).items():
        have[iid] = have.get(iid, 0) + q
    capped: dict = {}
    for iid, hv in have.items():
        al = allowed.get(iid, 0)
        if hv > al:
            excess = hv - al
            capped[iid] = excess
            left = _remove_units(new_inv, iid, excess)
            if left > 0:
                left = _remove_units(new_bank, iid, left)
            # any remainder is in an equipment slot — left in place (can't inject
            # meaningfully via equip; the count check still bounded it)
    return capped


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
        new_eq2 = session.get("equipment", {}) or {}
        new_bank = msg.get("bank", []) if isinstance(msg.get("bank"), list) else []
        new_xp = msg.get("skill_xp", {}) if isinstance(msg.get("skill_xp"), dict) else {}
        # ⑧ THE FLIP — validate the client's inventory/XP against the server ceiling
        # (previous save + grant ledger). Caps injected items + clamps XP so it can't
        # exceed what was actually granted, and never drops below what's persisted.
        if SAVE_VALIDATION:
            with _db() as _pc:
                prow = _pc.execute(
                    "SELECT inventory, equipment, bank, skill_xp FROM players WHERE id=?",
                    (session["id"],)).fetchone()
            _pinv  = json.loads(prow["inventory"] or "[]") if prow else []
            _peq   = json.loads(prow["equipment"] or "{}") if prow else {}
            _pbank = json.loads(prow["bank"] or "[]") if prow else []
            _pxp   = json.loads(prow["skill_xp"] or "{}") if prow else {}
            _gi = session.get("grant_inv", {})
            _gx = session.get("grant_xp", {})
            _capped = _cap_save_to_ceiling(new_inv, new_bank, new_eq2,
                                           _pinv, _peq, _pbank, _gi)
            # XP: clamp each skill to [prev, prev+granted] — no injection, no loss.
            _cxp = dict(_pxp)
            for _sk, _v in (new_xp.items() if isinstance(new_xp, dict) else []):
                _ceil = int(_pxp.get(_sk, 0)) + int(_gx.get(_sk, 0))
                _cxp[str(_sk)] = max(int(_pxp.get(_sk, 0)), min(int(_v), _ceil))
            new_xp = _cxp
            if _capped:
                print(f"[save] {session['username']} injection capped: {_capped}")
            session["grant_inv"] = {}
            session["grant_xp"] = {}
        # Keep the server caches current with the validated values.
        session["inventory"] = new_inv
        session["skill_xp"] = new_xp
        # recipe_counts is the practice-makes-perfect counter. Client
        # increments on every craft attempt (success or fail); server
        # trusts + persists. Absent key = keep whatever was there.
        rc_raw = msg.get("recipe_counts", None)
        with _db() as conn:
            if isinstance(rc_raw, dict):
                conn.execute(
                    "UPDATE players SET x=?,y=?,skill_xp=?,inventory=?,bank=?,equipment=?,recipe_counts=?,last_seen=? WHERE id=?",
                    (session["x"], session["y"],
                     json.dumps(new_xp),
                     json.dumps(new_inv),
                     json.dumps(new_bank),
                     json.dumps(new_eq2),
                     json.dumps(rc_raw),
                     time.time(), session["id"])
                )
            else:
                conn.execute(
                    "UPDATE players SET x=?,y=?,skill_xp=?,inventory=?,bank=?,equipment=?,last_seen=? WHERE id=?",
                    (session["x"], session["y"],
                     json.dumps(new_xp),
                     json.dumps(new_inv),
                     json.dumps(new_bank),
                     json.dumps(new_eq2),
                     time.time(), session["id"])
                )
            conn.commit()
        # Refresh the cached character level from the just-saved skill_xp; if it
        # changed (a level-up crossed a boundary), tell everyone so the player's
        # nameplate updates live instead of only on relog.
        sx = msg.get("skill_xp", None)
        if isinstance(sx, dict):
            new_level = _character_level(sx)
            if new_level != int(session.get("character_level", 1)):
                session["character_level"] = new_level
                _broadcast({"type": "player_level",
                            "id": session["id"], "level": new_level})
        # Refresh any spectator HUD watching this player (their inventory/gear
        # just changed — new crafts/catches show up on camera within a save tick).
        await _push_spectate_state(session["username"])
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
    """Full admin — rank 'owner' or 'admin'. Gates economy, item grants,
    account admin, /wipemonsters, and /promote-/demote. Does NOT include
    the restricted 'mapper' rank; use _can_edit_map for map-building
    handlers that mappers also need."""
    r = _admin_rank(session.get("username", ""))
    return r == "owner" or r == "admin"


def _is_owner(session: dict) -> bool:
    """Owner-only checks (promote/demote/grant-mapper)."""
    return _admin_rank(session.get("username", "")) == "owner"


def _is_mapper(session: dict) -> bool:
    """Restricted rank — can build the world (tiles + entity placement +
    zone editor) but NOT touch economy, items, accounts, or ranks."""
    return _admin_rank(session.get("username", "")) == "mapper"


def _can_edit_map(session: dict) -> bool:
    """Composite gate — owner, admin, OR mapper. Every map-building
    handler (admin_tile_*, admin_place, admin_move, admin_delete,
    admin_save_map, admin_upload_terrain, admin_spawn) uses this so a
    mapper-ranked tester can build the world without touching the
    dangerous handlers that remain _is_admin-gated."""
    r = _admin_rank(session.get("username", ""))
    return r == "owner" or r == "admin" or r == "mapper"


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


async def _handle_admin_grant_mapper(ws, session: dict, msg: dict) -> None:
    """Owner-only — mark a username as 'mapper' rank, granting map-build
    access (tiles/entities/zones) without full admin. Live-pushes the new
    rank so the target's F10 panel unlocks without a relog. UI trigger:
    the Accounts tab's per-row Grant Mapper button."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Only the owner can grant the mapper rank.")
        return
    target_raw = str(msg.get("username", "")).strip()
    if not target_raw:
        await _admin_confirm(ws, "grant_mapper: username required.")
        return
    target = _normalized_admin_name(target_raw)
    if target == _normalized_admin_name(ADMIN_USERNAME):
        await _admin_confirm(ws, "The owner already outranks mapper.")
        return
    with _db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO admins (username, rank) VALUES (?, 'mapper')",
            (target,))
        conn.commit()
    await _admin_confirm(ws, f"Granted mapper rank to {target_raw}.")
    for tws, tsess in sessions.items():
        if _normalized_admin_name(tsess.get("username", "")) == target:
            await _send(tws, {"type": "admin_rank_changed", "rank": "mapper"})
            await _send(tws, {"type": "chat", "username": "Server",
                              "text": "You have been granted mapper rank — you can now edit the world."})
            break
    print(f"[admin] {session['username']} granted mapper to {target_raw}")


async def _handle_admin_revoke_mapper(ws, session: dict, msg: dict) -> None:
    """Owner-only — remove mapper rank (or admin — same DELETE). The
    server never differentiates on revoke; the row goes away and the
    target reverts to plain player."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Only the owner can revoke the mapper rank.")
        return
    target_raw = str(msg.get("username", "")).strip()
    if not target_raw:
        await _admin_confirm(ws, "revoke_mapper: username required.")
        return
    target = _normalized_admin_name(target_raw)
    if target == _normalized_admin_name(ADMIN_USERNAME):
        await _admin_confirm(ws, "The owner cannot be revoked.")
        return
    with _db() as conn:
        cur = conn.execute(
            "DELETE FROM admins WHERE username=? AND rank='mapper'",
            (target,))
        conn.commit()
        removed = cur.rowcount > 0
    if removed:
        await _admin_confirm(ws, f"Revoked mapper rank from {target_raw}.")
        for tws, tsess in sessions.items():
            if _normalized_admin_name(tsess.get("username", "")) == target:
                await _send(tws, {"type": "admin_rank_changed", "rank": ""})
                await _send(tws, {"type": "chat", "username": "Server",
                                  "text": "Your mapper rank has been revoked."})
                break
        print(f"[admin] {session['username']} revoked mapper from {target_raw}")
    else:
        await _admin_confirm(ws, f"{target_raw} was not a mapper.")


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


def _name_wall_by_town(subtype: str, x: float, y: float, data: dict) -> None:
    """Name a wall / tower / gate after the town it stands in (in place). Leaves
    non-town walls with whatever name they were built with (e.g. a warband's)."""
    if not any(h in str(subtype) for h in ("wall", "gate", "tower")):
        return
    town = _town_at_world(float(x), float(y))
    if town:
        data["display_name"] = TOWN_NAMES.get(town, town.capitalize()) + " Wall"


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
        _name_wall_by_town(str(r["subtype"]), float(r["x"]), float(r["y"]), data)
        out.append({"id": eid, "kind": r["kind"], "subtype": r["subtype"],
                    "x": float(r["x"]), "y": float(r["y"]), "data": data})
    return out


async def _admin_confirm(ws, text: str) -> None:
    await _send(ws, {"type": "chat", "username": "Admin", "text": text})


async def _handle_admin_place(ws, session: dict, msg: dict) -> None:
    if not _can_edit_map(session):
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
        mark_caravan_routes_dirty()   # new wall may block a road → reroute caravans
        if any(h in subtype for h in _WALL_SUBTYPE_HINTS):
            _recompute_town_bounds()   # this wall may extend the town limit
        # Reflect the seed HP into the entity's data dict so the client
        # gets it in the world_entity_add broadcast below.
        data["hp"] = max_hp_s
        data["max_hp"] = max_hp_s
        data["alive"] = True
    _name_wall_by_town(subtype, x, y, data)   # town walls are named after their town
    entity = {"id": eid, "kind": kind, "subtype": subtype, "x": x, "y": y, "data": data}
    _broadcast({"type": "world_entity_add", "entity": entity})
    # Tell the placer the new id so their client's Undo stack can reverse it.
    await _send(ws, {"type": "admin_placed", "id": eid, "kind": kind,
                     "subtype": subtype, "x": x, "y": y})
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
        rows = conn.execute("SELECT id, deleted, x, y, rot, data FROM entity_edits").fetchall()
    out = []
    for r in rows:
        edit = {"id": r["id"], "deleted": bool(r["deleted"]),
                "x": (None if r["x"] is None else float(r["x"])),
                "y": (None if r["y"] is None else float(r["y"])),
                "rot": (0.0 if r["rot"] is None else float(r["rot"]))}
        if r["data"]:
            try:
                dd = json.loads(r["data"])
                if isinstance(dd, dict) and dd:
                    edit["data"] = dd
            except Exception:
                pass
        out.append(edit)
    return out


async def _handle_admin_delete(ws, session: dict, msg: dict) -> None:
    if not _can_edit_map(session):
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
        mark_caravan_routes_dirty()   # a removed wall may reopen a shorter road
        _recompute_town_bounds()      # a removed wall may shrink the town limit
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
    if not _can_edit_map(session):
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
        mark_caravan_routes_dirty()   # a moved wall changes the blocked footprint
        _recompute_town_bounds()      # a moved wall changes the town limit
    else:
        with _db() as conn:
            conn.execute(
                "INSERT INTO entity_edits (id, deleted, x, y) VALUES (?,0,?,?) "
                "ON CONFLICT(id) DO UPDATE SET x=excluded.x, y=excluded.y, deleted=0",
                (eid, x, y))
            conn.commit()
        _broadcast({"type": "entity_edit", "id": eid, "x": x, "y": y, "deleted": False})


async def _handle_admin_rotate(ws, session: dict, msg: dict) -> None:
    """Admin rotate tool (v1.6.1). Persists a Y-axis rotation (radians) and
    broadcasts it so every client (2D + 3D) shows it. Admin-placed (a:) entities
    store rotation in world_entities.data['rot']; pre-existing (t:/n:/b:/kc:…)
    entities store it in entity_edits.rot — mirroring the admin MOVE plumbing."""
    if not _can_edit_map(session):
        return
    eid = str(msg.get("id", "")).strip()
    if not eid:
        return
    # Normalise to [0, 2π) so the stored value stays bounded.
    rot = float(msg.get("rot", 0.0)) % (2.0 * math.pi)
    if eid.startswith("a:"):
        with _db() as conn:
            row = conn.execute("SELECT data FROM world_entities WHERE id=?", (eid,)).fetchone()
            if row is None:
                return
            try:
                data = json.loads(row["data"]) if row["data"] else {}
            except Exception:
                data = {}
            if not isinstance(data, dict):
                data = {}
            data["rot"] = rot
            conn.execute("UPDATE world_entities SET data=? WHERE id=?", (json.dumps(data), eid))
            conn.commit()
    else:
        with _db() as conn:
            conn.execute(
                "INSERT INTO entity_edits (id, deleted, rot) VALUES (?,0,?) "
                "ON CONFLICT(id) DO UPDATE SET rot=excluded.rot, deleted=0",
                (eid, rot))
            conn.commit()
    _broadcast({"type": "world_entity_rotate", "id": eid, "rot": rot})


async def _handle_admin_edit_entity(ws, session: dict, msg: dict) -> None:
    """Live property edit of an admin-placed (a:) entity (Inspect tool).
    Merges msg['patch'] into the stored data JSON, persists, and RE-EMITS the
    entity (world_entity_remove + world_entity_add) so every client rebuilds
    the node with the new values. Monster edits re-seed the server AI at the
    (possibly new) level. Only a: entities are editable — procedural entities
    (t:/n:/kc:…) have no arbitrary-field override table."""
    if not _can_edit_map(session):
        return
    eid = str(msg.get("id", "")).strip()
    patch = msg.get("patch", {})
    if not eid or not isinstance(patch, dict) or not patch:
        return
    if not eid.startswith("a:"):
        # Pre-existing entity (n:/b:/kc:/t:…) — store a DATA override in
        # entity_edits (merged) and broadcast it so clients apply it live. Keeps
        # the roster in code but makes name/dialogue/level editable + persisted.
        with _db() as conn:
            row = conn.execute("SELECT data FROM entity_edits WHERE id=?", (eid,)).fetchone()
            cur = {}
            if row is not None and row["data"]:
                try:
                    cur = json.loads(row["data"])
                except Exception:
                    cur = {}
            if not isinstance(cur, dict):
                cur = {}
            for k, v in patch.items():
                cur[str(k)] = v
            conn.execute(
                "INSERT INTO entity_edits (id, data) VALUES (?,?) "
                "ON CONFLICT(id) DO UPDATE SET data=excluded.data",
                (eid, json.dumps(cur)))
            conn.commit()
        _broadcast({"type": "entity_data_edit", "id": eid, "data": cur})
        await _admin_confirm(ws, "Edited entity.")
        print(f"[admin] {session['username']} data-edited {eid} fields={list(patch.keys())}")
        return
    with _db() as conn:
        row = conn.execute(
            "SELECT kind, subtype, x, y, data FROM world_entities WHERE id=?",
            (eid,)).fetchone()
        if row is None:
            await _admin_confirm(ws, "Entity not found (already removed?).")
            return
        try:
            data = json.loads(row["data"]) if row["data"] else {}
        except Exception:
            data = {}
        if not isinstance(data, dict):
            data = {}
        # Merge the changed fields. Admin-gated, so we trust the keys, but keep
        # values JSON-serialisable (the client only ever sends scalars/strings).
        for k, v in patch.items():
            data[str(k)] = v
        kind = str(row["kind"])
        subtype = str(row["subtype"])
        x = float(row["x"]); y = float(row["y"])
        conn.execute("UPDATE world_entities SET data=? WHERE id=?",
                     (json.dumps(data), eid))
        conn.commit()
    # Tear the old node down on every client, then re-add the fresh one.
    _broadcast({"type": "world_entity_remove", "id": eid})
    if kind == "monster":
        # Purge + re-seed so a level change actually re-scales the live AI.
        _purge_monster_state(eid)
        monster_type = str(data.get("monster_type", subtype) or subtype)
        level = max(1, int(data.get("level", 1)))
        attack = _heuristic_attack(level)
        max_hp = _heuristic_max_hp(level)
        st = {
            "x": x, "y": y, "max_hp": max_hp, "hp": max_hp, "alive": True,
            "participants": [], "damage": {},
            "xp_reward": max(1, level * 10), "respawn_until": 0.0,
        }
        _seed_monster_ai(st, x, y, monster_type, level, attack)
        monsters_state[eid] = st
        _mark_monster_dirty(eid)
        _purged_entity_ids.discard(eid)   # it lives again — clear the tombstone
    entity = {"id": eid, "kind": kind, "subtype": subtype,
              "x": x, "y": y, "data": data}
    _broadcast({"type": "world_entity_add", "entity": entity})
    await _admin_confirm(ws, f"Edited {kind} '{subtype}'.")
    print(f"[admin] {session['username']} edited {eid} fields={list(patch.keys())}")


def _load_terrain_heights() -> dict:
    """All sculpted tile height deltas as {idx_str: delta} for the login burst."""
    with _db() as conn:
        rows = conn.execute("SELECT idx, delta FROM terrain_heights").fetchall()
    return {str(r["idx"]): float(r["delta"]) for r in rows}


async def _handle_admin_sculpt(ws, session: dict, msg: dict) -> None:
    """Admin terrain height sculpt (v1.6.1). `tiles` = {idx_str: delta}. Persists
    each tile's absolute delta (deletes the row when ~0) and broadcasts so every
    3D client applies it. 2D clients ignore the broadcast (flat terrain)."""
    if not _can_edit_map(session):
        return
    tiles = msg.get("tiles", {})
    if not isinstance(tiles, dict) or not tiles:
        return
    if len(tiles) > 20000:        # sanity cap — a stroke touches at most a few hundred
        return
    clean: dict = {}
    with _db() as conn:
        for k, v in tiles.items():
            try:
                idx = int(k)
                delta = float(v)
            except (TypeError, ValueError):
                continue
            if idx < 0 or idx >= 300 * 300:
                continue
            if abs(delta) < 1e-4:
                conn.execute("DELETE FROM terrain_heights WHERE idx=?", (idx,))
                clean[str(idx)] = 0.0
            else:
                conn.execute(
                    "INSERT INTO terrain_heights (idx, delta) VALUES (?,?) "
                    "ON CONFLICT(idx) DO UPDATE SET delta=excluded.delta", (idx, delta))
                clean[str(idx)] = delta
        conn.commit()
    if clean:
        _broadcast({"type": "terrain_height_set", "tiles": clean})


def _load_road_graph() -> dict:
    """The admin-drawn road network as {"nodes":[{id,x,y}], "edges":[[a,b],...]}.
    Empty graph if nothing's been drawn yet."""
    with _db() as conn:
        row = conn.execute("SELECT data FROM road_graph WHERE id=1").fetchone()
    if not row:
        return {"nodes": [], "edges": []}
    try:
        g = json.loads(row["data"])
        if not isinstance(g, dict):
            return {"nodes": [], "edges": []}
        g.setdefault("nodes", [])
        g.setdefault("edges", [])
        return g
    except (ValueError, TypeError):
        return {"nodes": [], "edges": []}


async def _handle_admin_road_set(ws, session: dict, msg: dict) -> None:
    """Store the full admin-drawn road graph + broadcast it to every client.
    Map-editing gate (mappers included). The client sends the whole doc on each
    edit (the graph is small — dozens of nodes), so there's no id negotiation."""
    if not _can_edit_map(session):
        return
    nodes_in = msg.get("nodes", [])
    edges_in = msg.get("edges", [])
    if not isinstance(nodes_in, list) or not isinstance(edges_in, list):
        return
    if len(nodes_in) > 4000 or len(edges_in) > 8000:   # sanity cap
        return
    # Sanitise nodes → {id:int, x:float, y:float}; keep the id set for edge validation.
    clean_nodes: list = []
    ids: set = set()
    for n in nodes_in:
        if not isinstance(n, dict):
            continue
        try:
            nid = int(n.get("id"))
            nx = float(n.get("x"))
            ny = float(n.get("y"))
        except (TypeError, ValueError):
            continue
        if nid in ids:
            continue
        ids.add(nid)
        clean_nodes.append({"id": nid, "x": nx, "y": ny})
    # Edges reference existing node ids only; store undirected, de-duplicated.
    clean_edges: list = []
    seen_edges: set = set()
    for e in edges_in:
        if not isinstance(e, (list, tuple)) or len(e) != 2:
            continue
        try:
            a = int(e[0]); b = int(e[1])
        except (TypeError, ValueError):
            continue
        if a == b or a not in ids or b not in ids:
            continue
        key = (a, b) if a < b else (b, a)
        if key in seen_edges:
            continue
        seen_edges.add(key)
        clean_edges.append([key[0], key[1]])
    graph = {"nodes": clean_nodes, "edges": clean_edges}
    with _db() as conn:
        conn.execute(
            "INSERT INTO road_graph (id, data) VALUES (1, ?) "
            "ON CONFLICT(id) DO UPDATE SET data=excluded.data",
            (json.dumps(graph),))
        conn.commit()
    _broadcast({"type": "road_graph", "nodes": clean_nodes, "edges": clean_edges})


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


async def _handle_admin_tokens(ws, session: dict, msg: dict) -> None:
    # Grant/deduct PvP Tokens (Phase 1d). Mirrors _handle_admin_gold — needed
    # for testing upgrades before the PvP kill loop is wired (Phase 8).
    if not _is_admin(session):
        return
    target = str(msg.get("target", "")).strip()
    amount = int(msg.get("amount", 0))
    with _db() as conn:
        row = conn.execute(
            "SELECT id, pvp_tokens FROM players WHERE username=? COLLATE NOCASE",
            (target,)).fetchone()
        if not row:
            await _admin_confirm(ws, f"No such player: {target}")
            return
        new_bal = max(0, int(row["pvp_tokens"] or 0) + amount)
        conn.execute("UPDATE players SET pvp_tokens=? WHERE id=?", (new_bal, row["id"]))
        conn.commit()
        tid = row["id"]
    tws = _ws_for_player(tid)
    if tws is not None:
        await _send(tws, {"type": "pvp_tokens_set", "pvp_tokens": new_bal})
    await _admin_confirm(ws, f"Gave {amount} PvP Tokens to {target} (now {new_bal}).")
    print(f"[admin] {session['username']} /tokens {target} {amount}")


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
                 qty: int, color, meta: dict = None) -> int:
    """Add `qty` of an item to inventory. Stacks onto existing entry for
    stackable ids; otherwise appends a new entry per unit, capped at INV_CAP.
    Returns the number of units actually added (may be < qty if cap hit).
    `meta` (e.g. a fish's {weight, wnorm, trophy}) is merged onto each appended
    NON-stackable entry — mirrors the client's GameManager.add_item(extra);
    ignored for stackables (a stack can't hold per-unit meta)."""
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
        entry = {"id": item_id, "name": item_name, "qty": 1, "color": col}
        if meta:
            entry.update(meta)
        inventory.append(entry)
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
        # Fetch every admin rank ONCE up front using this same connection.
        # (Previously called _admin_rank() per row, which opened a NESTED
        # _db() connection mid-transaction and threw a WAL/lock error —
        # crashing the handler so the client got no response = empty list.)
        rank_map: dict = {}
        for ar in conn.execute("SELECT username, rank FROM admins").fetchall():
            rank_map[_normalized_admin_name(str(ar["username"]))] = str(ar["rank"])
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
                # Admin rank ("" if none) — from the pre-fetched rank_map
                # (no nested DB connection). Client renders it as a chip +
                # gates the Grant/Revoke Mapper button off it.
                "admin_rank": rank_map.get(_normalized_admin_name(str(r["username"])), ""),
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


async def _handle_admin_delete_account(ws, session: dict, msg: dict) -> None:
    """Owner-only — PERMANENTLY delete a player account and the rows it owns.
    Refuses to delete the owner or the caller. Cascades: clan membership (with
    leader hand-off / disband), thralls, friendships, AH listings, admin rank.
    Kicks the target if they're online. Modelled on _handle_admin_revoke_mapper
    + the clan-leave leader-promotion logic."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Only the owner can delete accounts.")
        return
    target_raw = str(msg.get("username", "")).strip()
    if not target_raw:
        await _admin_confirm(ws, "delete_account: username required.")
        return
    if _normalized_admin_name(target_raw) == _normalized_admin_name(ADMIN_USERNAME):
        await _admin_confirm(ws, "The owner account cannot be deleted.")
        return
    broadcast_cid = None
    with _db() as conn:
        prow = conn.execute(
            "SELECT id, username FROM players WHERE username=? COLLATE NOCASE",
            (target_raw,)).fetchone()
        if not prow:
            await _admin_confirm(ws, f"No account named {target_raw!r}.")
            return
        pid = prow["id"]
        uname = prow["username"]
        if pid == session["id"]:
            await _admin_confirm(ws, "You can't delete your own account.")
            return
        # Clan hand-off / disband if the target belonged to one (mirror
        # _handle_clan_leave so we never orphan a leaderless clan).
        cid = _clan_id_for_player(conn, pid)
        if cid is not None:
            clan = conn.execute("SELECT leader_id FROM clans WHERE id=?", (cid,)).fetchone()
            was_leader = bool(clan) and clan["leader_id"] == pid
            conn.execute("DELETE FROM clan_members WHERE clan_id=? AND player_id=?", (cid, pid))
            remaining = conn.execute(
                "SELECT player_id FROM clan_members WHERE clan_id=? ORDER BY joined_at",
                (cid,)).fetchall()
            if not remaining:
                # Last member gone — disband the clan + drop its diplomacy/holdings.
                conn.execute("DELETE FROM clans WHERE id=?", (cid,))
                conn.execute("DELETE FROM town_pledges WHERE warband_id=?", (cid,))
                conn.execute("DELETE FROM warband_alliances WHERE warband_a=? OR warband_b=?", (cid, cid))
            elif was_leader:
                new_leader = remaining[0]["player_id"]
                conn.execute("UPDATE clans SET leader_id=? WHERE id=?", (new_leader, cid))
                conn.execute("UPDATE clan_members SET role='leader' WHERE clan_id=? AND player_id=?",
                             (cid, new_leader))
                broadcast_cid = cid
            else:
                broadcast_cid = cid
        # Player-owned rows.
        conn.execute("DELETE FROM thralls WHERE owner_id=?", (pid,))
        conn.execute("DELETE FROM friendships WHERE player_id=? OR friend_id=?", (pid, pid))
        conn.execute("DELETE FROM ah_listings WHERE seller_id=?", (pid,))
        conn.execute("DELETE FROM admins WHERE username=?", (_normalized_admin_name(uname),))
        conn.execute("DELETE FROM players WHERE id=?", (pid,))
        conn.commit()
    # Kick the target if online (reuse the duplicate-login kick shape).
    for tws, tsess in list(sessions.items()):
        if tsess.get("id") == pid:
            await _send(tws, {"type": "kicked", "reason": "This account has been deleted."})
            await tws.close()
            sessions.pop(tws, None)
            break
    if broadcast_cid is not None:
        await _broadcast_clan_info(broadcast_cid)
    print(f"[admin] {session['username']} DELETED account {uname!r} (id={pid})")
    await _admin_confirm(ws, f"Deleted account {uname!r}.")


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


async def _handle_admin_upload_node_map(ws, session: dict, msg: dict) -> None:
    """Owner-only — accept the baked node→drop map from the admin client (B2a).
    The client snapshots every gatherable node's {skill,level,drop,xp,regen}
    keyed by its stable id; the server then GRANTS from this on every gather so
    the client can't mint loot. One-time bake, re-run when generation changes."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Node-map upload is owner-only.")
        return
    raw = msg.get("map", {})
    if not isinstance(raw, dict):
        await _admin_confirm(ws, "Bad node map.")
        return
    global node_drops
    node_drops = raw
    _save_node_drops()
    _forage = node_drops.get("_forage_seeds", [])
    n_nodes = len(node_drops) - (1 if "_forage_seeds" in node_drops else 0)
    await _admin_confirm(ws, f"Baked node map saved — {n_nodes} nodes now server-authoritative.")
    print(f"[gather] {session['username']} uploaded {n_nodes} baked node drops "
          f"+ forage table ({len(_forage) if isinstance(_forage, list) else 0} seeds)")


async def _handle_admin_upload_monster_loot(ws, session: dict, msg: dict) -> None:
    """Owner-only — baked monster-loot table (B3). Server rolls from it on kill."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Monster-loot upload is owner-only.")
        return
    raw = msg.get("map", {})
    if not isinstance(raw, dict):
        await _admin_confirm(ws, "Bad monster-loot map.")
        return
    global monster_loot
    monster_loot = raw
    _save_monster_loot()
    n = len([k for k in monster_loot if not k.startswith("_")])
    await _admin_confirm(ws, f"Baked monster loot saved — {n} monsters now server-authoritative.")
    print(f"[loot] {session['username']} uploaded monster loot for {n} monsters")


# ── Seasonal / major-update RESET (owner-only) ──────────────────────────────
# Wipes selected player state back to a clean slate across ALL accounts. Each
# field is opt-in from the client's checkboxes (preset to all). Backs the DB up
# first, then kicks everyone so no stale in-memory session re-saves old data.
# `x=7823, y=4488` = the default spawn (Bjorn's Landing) in the players schema.
_SEASON_RESET_COLS = {
    "skill_xp":         ("skill_xp = '{}'",          "levels"),
    "inventory":        ("inventory = '[]'",         "backpack"),
    "bank":             ("bank = '[]'",              "bank items"),
    "equipment":        ("equipment = '{}'",         "equipment"),
    "gold":             ("gold = 0",                 "gold"),
    "bank_gold":        ("bank_gold = 0",            "bank gold"),
    "pvp_tokens":       ("pvp_tokens = 0",           "pvp tokens"),
    "position":         ("x = 7823, y = 4488",       "position"),
    "recipe_counts":    ("recipe_counts = '{}'",     "recipe practice"),
    "discovered_towns": ("discovered_towns = '[]'",  "map discovery"),
}
_SEASON_RESET_TABLES = {
    "quests":     (["DELETE FROM quests"],                                   "quests"),
    "reputation": (["DELETE FROM reputation", "DELETE FROM warband_reputation"], "reputation"),
    "thralls":    (["DELETE FROM thralls"],                                  "thralls"),
}


async def _handle_admin_season_reset(ws, session: dict, msg: dict) -> None:
    if not _is_owner(session):
        await _admin_confirm(ws, "Season reset is owner-only.")
        return
    fields = msg.get("fields", [])
    if not isinstance(fields, list) or not fields:
        await _admin_confirm(ws, "Season reset: nothing selected.")
        return
    # Safety net — snapshot the DB before a destructive wipe.
    try:
        import shutil
        backup = DB_PATH.with_suffix(f".pre_reset_{int(time.time())}.db")
        shutil.copy2(DB_PATH, backup)
        print(f"[reset] backed up DB → {backup.name}")
    except Exception as e:
        print(f"[reset] backup failed: {e}")
    done: list = []
    set_clauses = [_SEASON_RESET_COLS[f][0] for f in fields if f in _SEASON_RESET_COLS]
    with _db() as conn:
        if set_clauses:
            conn.execute("UPDATE players SET " + ", ".join(set_clauses))
            done += [_SEASON_RESET_COLS[f][1] for f in fields if f in _SEASON_RESET_COLS]
        for f in fields:
            if f in _SEASON_RESET_TABLES:
                for sql in _SEASON_RESET_TABLES[f][0]:
                    try:
                        conn.execute(sql)
                    except Exception:
                        pass
                done.append(_SEASON_RESET_TABLES[f][1])
        conn.commit()
    print(f"[admin] {session['username']} SEASON RESET fields={fields}")
    await _admin_confirm(ws, "Season reset applied: " + ", ".join(done)
                         + ". Kicking everyone to reload…")
    # Kick ALL sessions (incl. the owner) — in-memory state is now stale and a
    # save would otherwise re-write the old data. Everyone relogs into the reset.
    for kws in list(sessions.keys()):
        try:
            await _send(kws, {"type": "kicked", "reason": "Season reset — log back in for a fresh start."})
            await kws.close()
        except Exception:
            pass
        sessions.pop(kws, None)


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


async def _handle_admin_upload_recipes(ws, session: dict, msg: dict) -> None:
    """Owner-only — baked craft-recipe table (⑤). Server crafts from it."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Recipe upload is owner-only.")
        return
    raw = msg.get("map", {})
    if not isinstance(raw, dict):
        await _admin_confirm(ws, "Bad recipe map.")
        return
    global craft_recipes
    craft_recipes = raw
    _save_craft_recipes()
    await _admin_confirm(ws, f"Baked craft recipes saved — {len(craft_recipes)} now server-authoritative.")
    print(f"[craft] {session['username']} uploaded {len(craft_recipes)} recipes")


def _craft_success_chance(skill: str, lv: int, req_lv: int) -> float:
    """Server mirror of HUD._recipe_success_chance's BASE curve (no client
    practice bonus — that's client-only state and only ever helps the player,
    so dropping it can't be exploited). 'crafting' never burns."""
    if skill == "crafting" or not skill:
        return 1.0
    base = 0.60 + max(0.0, min((lv - req_lv) / 40.0, 0.35))
    return max(0.15, min(base, 0.99))


async def _handle_craft(ws, session: dict, msg: dict) -> None:
    """SERVER-authoritative craft (⑤). Validates skill + materials against the DB
    inventory, consumes inputs, ROLLS success/burn server-side, grants the output
    (on success) + XP, and pushes the authoritative inventory. Uses the BAKED
    recipe (authoritative); falls back to the client's claim only if unbaked (so
    crafting never breaks before the bake button is clicked). Covers
    smithing/cooking/crafting/runes — any recipe shaped
    {skill, req_lv, xp, out_id, out_name, out_color, input:[{id,qty}]}."""
    recipe_id = str(msg.get("recipe_id", "")).strip()
    r = craft_recipes.get(recipe_id)
    if not r:
        if craft_recipes:
            # Table is baked → ONLY baked recipes craft. No client claims are
            # trusted once the owner has locked the recipes in (anti-cheat).
            await _send(ws, {"type": "craft_result", "ok": False, "reason": "Unknown recipe."})
            return
        # Pre-bake transitional: trust the client's normalized recipe so
        # crafting keeps working until the owner clicks Bake.
        claim = msg.get("recipe")
        r = claim if isinstance(claim, dict) else None
    if not r:
        await _send(ws, {"type": "craft_result", "ok": False, "reason": "Unknown recipe."})
        return
    skill     = str(r.get("skill", ""))
    req_lv    = int(r.get("req_lv", 1))
    inputs    = r.get("input", []) if isinstance(r.get("input"), list) else []
    out_id    = str(r.get("out_id", recipe_id))
    out_name  = str(r.get("out_name", out_id))
    out_color = r.get("out_color", [0.7, 0.7, 0.7, 1.0])
    out_qty   = max(1, int(r.get("out_qty", 1)))
    xp        = int(r.get("xp", 0))
    with _db() as conn:
        row = conn.execute("SELECT inventory, skill_xp FROM players WHERE id=?",
                           (session["id"],)).fetchone()
        if not row:
            return
        inventory = json.loads(row["inventory"] or "[]")
        skill_xp  = json.loads(row["skill_xp"]  or "{}")
        lv = _calc_level(skill_xp.get(skill, 0)) if skill else 99
        if skill and lv < req_lv:
            await _send(ws, {"type": "craft_result", "ok": False,
                             "reason": f"Requires {skill} level {req_lv}."})
            return
        for ing in inputs:
            if _inv_count(inventory, str(ing.get("id", ""))) < int(ing.get("qty", 1)):
                await _send(ws, {"type": "craft_result", "ok": False,
                                 "reason": "Not enough materials."})
                return
        # Capacity pre-check for the success case, so we never consume inputs
        # and then fail to grant the output. Stackable items always fold in.
        if not _is_stackable(out_id) and len(inventory) >= INV_CAP:
            await _send(ws, {"type": "craft_result", "ok": False,
                             "reason": "Your inventory is full."})
            return
        for ing in inputs:
            _inv_take_qty(inventory, str(ing.get("id", "")), int(ing.get("qty", 1)))
        burned = random.random() > _craft_success_chance(skill, lv, req_lv)
        if burned:
            xp_award = xp * 15 // 100   # 15% consolation, matches the client
        else:
            _inv_add_qty(inventory, out_id, out_name, out_qty, out_color)
            xp_award = xp
        if skill:
            skill_xp[skill] = int(skill_xp.get(skill, 0)) + xp_award
        conn.execute("UPDATE players SET inventory=?, skill_xp=? WHERE id=?",
                     (json.dumps(inventory), json.dumps(skill_xp), session["id"]))
        conn.commit()
    session["inventory"] = inventory
    session["skill_xp"]  = skill_xp
    await _send(ws, {"type": "admin_inventory_set", "inventory": inventory})
    await _send(ws, {"type": "craft_result", "ok": True, "burned": burned,
                     "skill": skill, "xp": xp_award, "out_name": out_name,
                     "out_qty": out_qty})


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


# ── Kjelvik castle wall ring (server-authoritative HP) ───────────────────────
# The castle ring is CLIENT-generated geometry (World._kjelvik_castle_nodes),
# so it isn't in world_entities. To make it attackable / repairable / rep-gated
# like every other town wall, we seed structures_state["kc:N"] directly. The
# generation order below MUST mirror the client EXACTLY so index i == the
# client's kc:i (otherwise a hit lands on the wrong wall's hitbox).
# ⚠ Keep _KC_* in sync with World.gd's constants (and Ground._is_town Kjelvik).
_KC_LEFT_TX, _KC_RIGHT_TX = 71, 96
_KC_TOP_TY,  _KC_BOT_TY   = 105, 128
_KC_GAP_N = (77, 78, 79)                          # N road → Frostheim
_KC_GAP_S = (84, 85, 86)                          # S road → Ironwood
_KC_GAP_E = (109, 110, 111, 112, 113, 114, 115)   # both E roads


def _kjelvik_castle_structures() -> list:
    """(subtype, world_x, world_y) rows in the SAME order the client generates
    kc:N — so index i here is the client's kc:i."""
    out = []

    def tc(tx: int, ty: int) -> tuple:
        return (tx * 32 + 16.0, ty * 32 + 16.0)

    for tx in range(_KC_LEFT_TX, _KC_RIGHT_TX + 1):
        if tx not in _KC_GAP_N:
            out.append(("fortified_wall",) + tc(tx, _KC_TOP_TY))
        if tx not in _KC_GAP_S:
            out.append(("fortified_wall",) + tc(tx, _KC_BOT_TY))
    for ty in range(_KC_TOP_TY + 1, _KC_BOT_TY):
        out.append(("fortified_wall",) + tc(_KC_LEFT_TX, ty))
        if ty not in _KC_GAP_E:
            out.append(("fortified_wall",) + tc(_KC_RIGHT_TX, ty))
    for cx, cy in [(_KC_LEFT_TX + 2, _KC_TOP_TY + 1), (_KC_RIGHT_TX - 2, _KC_TOP_TY + 1),
                   (_KC_LEFT_TX + 2, _KC_BOT_TY - 1), (_KC_RIGHT_TX - 2, _KC_BOT_TY - 1)]:
        out.append(("watchtower",) + tc(cx, cy))
    out.append(("guard_tower",) + tc(_KC_LEFT_TX + 2,
                                     int((_KC_TOP_TY + _KC_BOT_TY) * 0.5)))
    return out


def _seed_castle_structures() -> None:
    """Register Kjelvik's castle ring in structures_state so it's attackable /
    repairable. Only fills ids MISSING from the (already-loaded) mirror, so a
    besieged castle keeps its damaged HP across a restart."""
    seeded = 0
    for i, row in enumerate(_kjelvik_castle_structures()):
        subtype, x, y = row[0], float(row[1]), float(row[2])
        eid = "kc:%d" % i
        if eid in structures_state:
            continue
        mhp = _structure_max_hp(subtype, "ancient")   # capital walls = tankiest tier
        structures_state[eid] = {
            "hp": mhp, "max_hp": mhp, "alive": True,
            "subtype": subtype, "x": x, "y": y,
            "owner": "kjelvik", "wood": "ancient",
        }
        seeded += 1
    if seeded:
        print(f"[boot] seeded {seeded} Kjelvik castle wall structure(s)")


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
        # Per-building interior plot. Prefer the STABLE building id (`t:N`, an
        # index into World._TOWN_NODES) so the room follows the building when an
        # admin MOVES it — a position-derived key would orphan the room at the
        # old spot. Two different taverns still key differently (distinct ids).
        # Fall back to rounded position only if no id was sent (legacy path).
        if door_id:
            key = f"{interior_id_hint}:{door_id}"
        else:
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
# ── Dungeons (foundation, v1.5.3) ────────────────────────────────────────────
# A dungeon is a designed multi-room region deep in the far interior band. The
# SERVER owns the canonical layout and PUSHES it to the client on entry (client
# renders + collides from it — one source of truth, no duplicated map data). It
# reuses the interior enter/exit machinery for teleport + session tracking +
# co-op, and seeds the monsters/ore as ordinary world_entities so the entire
# combat / gather / respawn pipeline is reused, not rebuilt.
#
# Foundation = ONE PUBLIC dungeon: Frostmaw Hollow, a cave near Bjorn's Landing.
# `kind`/`reset` are per-dungeon settings so personal/warband instancing can be
# layered on later without touching this shell. Rooms are [cx, cy, w, h] in cell
# coords; the client fills the grid with wall, carves the rooms, then carves an
# L-corridor between each CONSECUTIVE room's centre — so connectivity from the
# entry room to the boss chamber is guaranteed by construction. Monster/ore
# spawns are placed at room-relative cells (always on carved floor).
DUNGEON_BAND_TY = 558   # region origin row, safely below the interior plots

DUNGEONS = {
    "bjorn_cave": {
        "name": "Frostmaw Hollow",
        "kind": "public",       # public | personal | warband (foundation: public)
        "reset": "respawn",     # monsters respawn on the normal monster timer
        "region_tx": 20, "region_ty": DUNGEON_BAND_TY,
        "w": 60, "h": 44,
        "entry_cell": [7, 39],
        # Overworld cave mouth WEST of Bjorn's Landing, nestled in the
        # mountains/cliffs (tile 229,154). It's an ordinary world_entity, so an
        # admin can still drag it; the seed below re-homes it here only if it's
        # still sitting at the old (mistaken) town-square spot.
        "entrance": [7328.0, 4928.0],
        "old_entrance": [7680.0, 4360.0],   # migrate rows still at the old spot
        # Entry room first, boss chamber LAST (the corridor chain runs in order).
        "rooms": [
            [2, 36, 10, 6],     # 0 entry
            [4, 23, 12, 8],     # 1
            [20, 30, 11, 8],    # 2
            [24, 14, 12, 8],    # 3
            [42, 20, 11, 8],    # 4
            [40, 3, 17, 11],    # 5 boss chamber
        ],
        # Spawns: [room_index, dx, dy, monster_type, level]. dx/dy are cell
        # offsets inside that room, so they always land on floor.
        "monsters": [
            [1, 3, 3, "goblin", 32], [1, 8, 4, "goblin", 33],
            [2, 3, 3, "skeleton", 38], [2, 7, 5, "goblin", 36],
            [3, 3, 3, "skeleton", 42], [3, 8, 4, "skeleton", 44],
            [4, 3, 3, "goblin", 40], [4, 7, 5, "skeleton", 46],
            [5, 8, 5, "troll", 50],   # boss
        ],
        # Ore veins: [room_index, dx, dy, rock_id, display, level].
        "ore": [
            [2, 5, 2, "gold_rock", "Gold Rock", 40],
            [4, 4, 6, "mithril_rock", "Mithril Rock", 50],
            [4, 8, 6, "mithril_rock", "Mithril Rock", 50],
        ],
        # The boss's rare drop (added to the troll's loot at seed time).
        "boss_drop": {"id": "troll_heart", "name": "Frostmaw Heart",
                      "color": [0.55, 0.20, 0.65, 1.0]},
    },
    "kjelvik_cellars": {
        "name": "Great Hall Cellars",
        "kind": "public",
        "reset": "respawn",
        # Its own slice of the dungeon band, right of bjorn_cave (tx 20-80).
        "region_tx": 90, "region_ty": DUNGEON_BAND_TY,
        "w": 40, "h": 30,
        "entry_cell": [8, 25],
        # Cellar stair-mouth under Kjelvik's Great Hall (node ~2624,3552). Ordinary
        # world_entity — admin can drag it; ⚠ VERIFY it sits at the hall in-game.
        "entrance": [2688.0, 3600.0],
        # Entry room first, old crypt LAST (the corridor chain runs in order).
        "rooms": [
            [3, 23, 10, 5],     # 0 entry (stair down)
            [16, 22, 11, 6],    # 1 storeroom
            [4, 12, 12, 7],     # 2 lower cellar
            [20, 10, 12, 7],    # 3 flooded vault
            [6, 2, 16, 7],      # 4 old crypt (boss)
        ],
        # Skeletons crawl the cellars — this is where q_token_iron /
        # q_pledge_kjelvik send the player to "clear the Great Hall cellars".
        "monsters": [
            [1, 3, 3, "skeleton", 10], [1, 8, 4, "skeleton", 11],
            [2, 3, 3, "skeleton", 12], [2, 8, 5, "skeleton", 12],
            [3, 3, 3, "skeleton", 14], [3, 9, 5, "skeleton", 15],
            [4, 5, 3, "skeleton", 16], [4, 11, 5, "draugr", 22],   # crypt guardian
        ],
        # A little iron in the old workings.
        "ore": [
            [2, 6, 2, "iron_rock", "Iron Rock", 15],
            [3, 9, 2, "iron_rock", "Iron Rock", 15],
        ],
    },
}

_ORE_COLORS = {
    "gold_rock":    [0.85, 0.72, 0.20, 1.0],
    "mithril_rock": [0.40, 0.62, 0.55, 1.0],
    "iron_rock":    [0.55, 0.55, 0.60, 1.0],
}


def _dungeon_cell_world(d: dict, cx: float, cy: float) -> tuple:
    """Cell (cx,cy) → world pixel centre for dungeon `d`."""
    return ((d["region_tx"] + cx + 0.5) * 32.0, (d["region_ty"] + cy + 0.5) * 32.0)


def _dungeon_layout_payload(d: dict) -> dict:
    """What the client needs to build + render the dungeon scene."""
    return {"region_tx": d["region_tx"], "region_ty": d["region_ty"],
            "w": d["w"], "h": d["h"], "rooms": d["rooms"],
            "entry_cell": d["entry_cell"], "name": d["name"]}


def _seed_dungeons() -> None:
    """Idempotently place every dungeon's overworld entrance + interior
    monsters/ore as persistent world_entities (fixed ids, INSERT OR IGNORE). Run
    once on boot — reuses the whole admin-entity pipeline for rendering, combat,
    gather and respawn."""
    with _db() as conn:
        for did, d in DUNGEONS.items():
            # Overworld cave-mouth entrance (a resource-kind interactable).
            ent_id = f"dg:{did}:entrance"
            edata = {"type_str": "dungeon_entrance", "display_name": d["name"],
                     "skill": "soul", "level": 1, "action": "Enter",
                     "color": [0.18, 0.16, 0.22, 1.0], "dungeon_id": did}
            conn.execute(
                "INSERT OR IGNORE INTO world_entities (id, kind, subtype, x, y, data) "
                "VALUES (?,?,?,?,?,?)",
                (ent_id, "resource", "dungeon_entrance",
                 float(d["entrance"][0]), float(d["entrance"][1]), json.dumps(edata)))
            # One-time reposition: bjorn_cave's mouth was first seeded in the
            # town square (7680,4360). Move any entrance still parked at its old
            # default to the current canonical spot; leaves admin-dragged rows be.
            old = d.get("old_entrance")
            if old:
                conn.execute(
                    "UPDATE world_entities SET x=?, y=? WHERE id=? AND x=? AND y=?",
                    (float(d["entrance"][0]), float(d["entrance"][1]), ent_id,
                     float(old[0]), float(old[1])))
            rooms = d["rooms"]
            # Monsters.
            for i, (ri, dx, dy, mtype, lv) in enumerate(d["monsters"]):
                rx, ry = rooms[ri][0], rooms[ri][1]
                wx, wy = _dungeon_cell_world(d, rx + dx, ry + dy)
                mdata = {"monster_type": mtype, "level": lv, "dungeon": did}
                if [ri, dx, dy, mtype, lv] == d["monsters"][-1] and "boss_drop" in d:
                    mdata["extra_drop"] = d["boss_drop"]
                conn.execute(
                    "INSERT OR IGNORE INTO world_entities (id, kind, subtype, x, y, data) "
                    "VALUES (?,?,?,?,?,?)",
                    (f"dg:{did}:m{i}", "monster", mtype, wx, wy, json.dumps(mdata)))
            # Ore veins.
            for i, (ri, dx, dy, rid, disp, lv) in enumerate(d["ore"]):
                rx, ry = rooms[ri][0], rooms[ri][1]
                wx, wy = _dungeon_cell_world(d, rx + dx, ry + dy)
                odata = {"type_str": "rock", "display_name": disp, "skill": "mining",
                         "level": lv, "action": "Mine",
                         "color": _ORE_COLORS.get(rid, [0.6, 0.6, 0.6, 1.0])}
                conn.execute(
                    "INSERT OR IGNORE INTO world_entities (id, kind, subtype, x, y, data) "
                    "VALUES (?,?,?,?,?,?)",
                    (f"dg:{did}:r{i}", "resource", "rock", wx, wy, json.dumps(odata)))
        conn.commit()
    print(f"[dungeon] seeded {len(DUNGEONS)} dungeon(s)")


async def _handle_dungeon_enter(ws, session: dict, msg: dict) -> None:
    """Enter a dungeon via its overworld entrance entity. Reuses the interior
    session fields (interior_id/x/y/return) so exit + the move-clamp + co-op
    filtering all work unchanged."""
    if session.get("interior_id", ""):
        await _send(ws, {"type": "interior_error", "reason": "You're already inside."})
        return
    ent_id = str(msg.get("entrance_id", "")).strip()
    with _db() as conn:
        row = conn.execute("SELECT x, y, data FROM world_entities WHERE id=?",
                           (ent_id,)).fetchone()
    if not row:
        await _send(ws, {"type": "interior_error", "reason": "No such entrance."})
        return
    try:
        edata = json.loads(row["data"] or "{}")
    except Exception:
        edata = {}
    did = str(edata.get("dungeon_id", ""))
    d = DUNGEONS.get(did)
    if not d:
        await _send(ws, {"type": "interior_error", "reason": "That cave is collapsed."})
        return
    # Proximity gate — must be near the cave mouth.
    dx = float(session.get("x", 0.0)) - float(row["x"])
    dy = float(session.get("y", 0.0)) - float(row["y"])
    if dx * dx + dy * dy > (DOOR_INTERACT_RANGE * 2.5) ** 2:
        await _send(ws, {"type": "interior_error",
                         "reason": "You're too far from the entrance."})
        return
    ex, ey = _dungeon_cell_world(d, d["entry_cell"][0], d["entry_cell"][1])
    rx = float(session.get("x", 0.0))
    ry = float(session.get("y", 0.0))
    iid = f"dungeon:{did}"
    session["interior_id"] = iid
    session["interior_x"] = ex
    session["interior_y"] = ey
    session["interior_return_x"] = rx
    session["interior_return_y"] = ry
    with _db() as conn:
        conn.execute(
            "UPDATE players SET interior_id=?, interior_x=?, interior_y=?, "
            "interior_return_x=?, interior_return_y=? WHERE id=?",
            (iid, ex, ey, rx, ry, session["id"]))
        conn.commit()
    await _send(ws, {
        "type": "dungeon_entered",
        "dungeon_id": did,
        "interior_id": iid,
        "layout": _dungeon_layout_payload(d),
        "x": ex, "y": ey, "return_x": rx, "return_y": ry,
    })
    print(f"[dungeon] {session['username']} entered {did}")


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


## ── PvP death piles ──────────────────────────────────────────────────────────
## Mirrors the gold_pile design. On PvP kill the loser's client sends a
## `pvp_death` payload of drops (bones + pvp_tokens + inventory copy). The
## server materialises one server-tracked pile per stack + broadcasts each
## to nearby clients so any player can pick them up. First-click-wins is
## enforced by the `claimed` flag same as gold_pile.
pvp_piles: dict = {}
PVP_PILE_LIFETIME = 180.0          # a bit longer than gold — victim needs time
PVP_PILE_PICKUP_RANGE = 48.0

def _spawn_pvp_pile(x: float, y: float, item_id: str,
                    item_name: str, qty: int,
                    color_rgba: list) -> str:
    if qty <= 0:
        return ""
    pile_id = "p:" + secrets.token_hex(6)
    pvp_piles[pile_id] = {
        "x": float(x), "y": float(y),
        "item_id":   item_id,
        "item_name": item_name,
        "qty":       int(qty),
        "color":     list(color_rgba),
        "expires_at": time.time() + PVP_PILE_LIFETIME,
        "claimed":   False,
    }
    _broadcast_near(x, y, {
        "type":      "pvp_pile_spawn",
        "id":        pile_id,
        "x":         float(x),
        "y":         float(y),
        "item_id":   item_id,
        "item_name": item_name,
        "qty":       int(qty),
        "color":     list(color_rgba),
    })
    return pile_id

async def _handle_pvp_pile_pickup(ws, session: dict, msg: dict) -> None:
    pile_id = str(msg.get("id", ""))
    p = pvp_piles.get(pile_id)
    if p is None or p.get("claimed"):
        return
    dx = float(session.get("x", 0.0)) - p["x"]
    dy = float(session.get("y", 0.0)) - p["y"]
    if dx * dx + dy * dy > PVP_PILE_PICKUP_RANGE * PVP_PILE_PICKUP_RANGE:
        return
    p["claimed"] = True
    # Send the grant, GameManager.add_item applies it, next autosave persists.
    await _send(ws, {
        "type":      "pvp_pile_pickup_ok",
        "item_id":   p["item_id"],
        "item_name": p["item_name"],
        "qty":       int(p["qty"]),
        "color":     list(p["color"]),
    })
    # ⑧ — server-authoritative claim → feed the grant ledger so the save-ceiling
    # allows this picked-up item (the pile is single-claim, so no dupe).
    _grant_to_session(session, str(p["item_id"]), str(p["item_name"]),
                      list(p["color"]), "", 0, int(p["qty"]))
    _broadcast_near(p["x"], p["y"],
        {"type": "pvp_pile_remove", "id": pile_id})

async def _handle_pvp_death(ws, session: dict, msg: dict) -> None:
    # Trust the client's drop list (same trust model as monster loot). The
    # `pvp_token` grant is server-owned so an edited client can't inflate
    # its bounty. Bones + inventory items are just LootDrops on the ground
    # — no server-side inventory state to inflate.
    if not session.get("pvp_flagged"):
        return
    # Drop the flag + clear any lockout. This implements the client-side
    # "safe mode" on the server side: further pvp_attack messages that
    # target this player get rejected (target not pvp_flagged) until the
    # player re-enables PvP. Also broadcast so other clients update.
    session["pvp_flagged"] = False
    session["pvp_locked_until"] = 0.0
    _broadcast({"type": "pvp_flag",
                "id":       session["id"],
                "username": session["username"],
                "flagged":  False})
    # Kill credit — locate killer's session and grant XP in the style used
    # plus the auto-token via a pvp_kill_credit message. Client applies
    # both server-side inputs so an edited client can't hand itself xp.
    killer_id = str(msg.get("killer_id", ""))   # TEXT hex id, not int
    style = str(msg.get("style", "melee"))
    if style not in ("melee", "ranged", "magic"):
        style = "melee"
    if killer_id and killer_id != session["id"]:
        # Credit PvP Tokens to the killer's server-owned balance (Phase 1d).
        # Done in the DB so it survives relog and can't be inflated client-side.
        new_token_bal = None
        try:
            with _db() as conn:
                conn.execute(
                    "UPDATE players SET pvp_tokens = COALESCE(pvp_tokens,0)+? WHERE id=?",
                    (PVP_KILL_TOKENS, killer_id))
                conn.commit()
                trow = conn.execute(
                    "SELECT pvp_tokens FROM players WHERE id=?",
                    (killer_id,)).fetchone()
                if trow is not None:
                    new_token_bal = int(trow["pvp_tokens"] or 0)
        except Exception as e:
            print(f"[pvp_death tokens] {e!r}")
        for kws, ksess in list(sessions.items()):
            if ksess.get("id") == killer_id:
                credit = {
                    "type":            "pvp_kill_credit",
                    "style":           style,
                    "xp":              PVP_KILL_XP,
                    "tokens":          PVP_KILL_TOKENS,
                    "victim_username": session["username"],
                }
                if new_token_bal is not None:
                    credit["pvp_tokens"] = new_token_bal
                await _send(kws, credit)
                break
    # 25% of the victim's carried gold drops as a gold pile at the death
    # point — reuses the existing gold_pile infrastructure so the pickup
    # flow + expiration are identical to monster gold drops.
    gold_carried = max(0, int(msg.get("gold_carried", 0)))
    gold_drop = int(gold_carried * PVP_DEATH_GOLD_FRAC)
    px = float(msg.get("x", session.get("x", 0.0)))
    py = float(msg.get("y", session.get("y", 0.0)))
    drops = msg.get("drops", [])
    if not isinstance(drops, list):
        return
    # Always drop bones. The PvP Token is no longer a ground pickup (Phase 1d)
    # — it's a server-owned currency credited to the killer's balance above.
    _spawn_pvp_pile(px, py, "bone", "Bone", 1, [0.90, 0.88, 0.75, 1.0])
    # Gold pile — server-side deduction from the DB so an edited client
    # can't lie about how much they were carrying. Client already
    # subtracted its own local `gold` and will resync on next save.
    if gold_drop > 0:
        try:
            with _db() as conn:
                row = conn.execute(
                    "SELECT gold FROM players WHERE id=?",
                    (session["id"],)).fetchone()
                actual_gold = int(row["gold"] or 0) if row else 0
                actual_drop = min(actual_gold,
                                  int(actual_gold * PVP_DEATH_GOLD_FRAC))
                if actual_drop > 0:
                    new_gold = actual_gold - actual_drop
                    conn.execute("UPDATE players SET gold=? WHERE id=?",
                                 (new_gold, session["id"]))
                    conn.commit()
                    _spawn_gold_pile(px, py, actual_drop)
                    await _send(ws, {"type": "gold_set", "gold": new_gold})
        except Exception as e:
            print(f"[pvp_death gold] {e!r}")
    # Client-declared normal death drops — inventory items the victim was
    # carrying. Capped to a sane per-death count so a malicious client
    # can't flood the world.
    for i, d in enumerate(drops[:20]):
        if not isinstance(d, dict):
            continue
        iid = str(d.get("id", ""))
        if not iid or iid == "pvp_token":  # tokens can't be dropped by cheat
            continue
        qty = max(1, min(999, int(d.get("qty", 1))))
        name = str(d.get("name", iid))
        col = d.get("color", [1, 1, 1, 1])
        if not isinstance(col, list) or len(col) < 3:
            col = [1, 1, 1, 1]
        # Spread piles a little so they don't all stack visually on top
        # of one another at the death point.
        ox = (i % 5) * 12.0 - 24.0
        oy = (i // 5) * 12.0 - 12.0
        _spawn_pvp_pile(px + ox, py + oy, iid, name, qty, col)

## ── Farm plots ────────────────────────────────────────────────────────────
## Scaffold for the Farming skill. Each plot is a world_entity of kind
## "resource" + type_str "farm_plot" (placed by admin/mapper via
## admin_place). Live state — what's planted + when — lives here, keyed
## by the entity id. Autosaves to disk on the shop-stock cadence so a
## restart doesn't reset every player's harvest timer.
farm_plots: dict = {}   # eid → {"seed_id", "planted_at", "owner_id"}
# Absolute path via __file__ (matches TILE_OVERRIDES_FILE / SHOP_STOCK_FILE)
# so the save works regardless of the server's launch directory. A bare
# relative "server/farm_plots.json" only resolves when cwd == repo root.
FARM_PLOT_STATE_PATH = Path(__file__).parent / "farm_plots.json"

## Farming roster — MIRRORS scripts/Farming.gd SEEDS (keep the two in sync). Growth
## seconds (ripe when effective grow ≥ this; watering boosts it), required Farming
## level to plant, and the harvested crop + xp + yield.
FARM_GROWTH_SEC: dict = {
    "wheat_seed": 50.0, "carrot_seed": 52.0, "barley_seed": 58.0, "cabbage_seed": 62.0,
    "rye_seed": 68.0, "corn_seed": 78.0, "potato_seed": 92.0, "cotton_seed": 108.0,
    "pepper_seed": 122.0, "sugarcane_seed": 138.0, "hops_seed": 150.0, "tomato_seed": 160.0,
    "moonwheat_seed": 175.0, "blueberry_seed": 185.0, "lingonberry_seed": 190.0,
    "strawberry_seed": 200.0, "peach_seed": 215.0, "apple_seed": 235.0,
    "watermelon_seed": 260.0, "grape_seed": 300.0,
}
_FARM_REQ_LV: dict = {
    "wheat_seed": 1, "carrot_seed": 1, "barley_seed": 5, "cabbage_seed": 5,
    "rye_seed": 8, "corn_seed": 10, "potato_seed": 15, "cotton_seed": 20,
    "pepper_seed": 25, "sugarcane_seed": 30, "hops_seed": 35, "tomato_seed": 40,
    "moonwheat_seed": 45, "blueberry_seed": 50, "lingonberry_seed": 52,
    "strawberry_seed": 55, "peach_seed": 60, "apple_seed": 68,
    "watermelon_seed": 75, "grape_seed": 90,
}
FARM_CROP_OF: dict = {
    "wheat_seed":       {"id": "wheat",       "name": "Wheat",       "xp": 20,  "yield": 3},
    "carrot_seed":      {"id": "carrot",      "name": "Carrot",      "xp": 22,  "yield": 3},
    "barley_seed":      {"id": "barley",      "name": "Barley",      "xp": 28,  "yield": 3},
    "cabbage_seed":     {"id": "cabbage",     "name": "Cabbage",     "xp": 30,  "yield": 2},
    "rye_seed":         {"id": "rye",         "name": "Rye",         "xp": 34,  "yield": 3},
    "corn_seed":        {"id": "corn",        "name": "Corn",        "xp": 40,  "yield": 2},
    "potato_seed":      {"id": "potato",      "name": "Potato",      "xp": 50,  "yield": 3},
    "cotton_seed":      {"id": "cotton",      "name": "Cotton",      "xp": 60,  "yield": 2},
    "pepper_seed":      {"id": "pepper",      "name": "Pepper",      "xp": 70,  "yield": 2},
    "sugarcane_seed":   {"id": "sugarcane",   "name": "Sugarcane",   "xp": 80,  "yield": 2},
    "hops_seed":        {"id": "hops",        "name": "Hops",        "xp": 90,  "yield": 2},
    "tomato_seed":      {"id": "tomato",      "name": "Tomato",      "xp": 100, "yield": 2},
    "moonwheat_seed":   {"id": "moonwheat",   "name": "Moonwheat",   "xp": 115, "yield": 2},
    "blueberry_seed":   {"id": "blueberry",   "name": "Blueberry",   "xp": 125, "yield": 2},
    "lingonberry_seed": {"id": "lingonberry", "name": "Lingonberry", "xp": 130, "yield": 2},
    "strawberry_seed":  {"id": "strawberry",  "name": "Strawberry",  "xp": 140, "yield": 2},
    "peach_seed":       {"id": "peach",       "name": "Peach",       "xp": 155, "yield": 1},
    "apple_seed":       {"id": "apple",       "name": "Apple",       "xp": 175, "yield": 2},
    "watermelon_seed":  {"id": "watermelon",  "name": "Watermelon",  "xp": 200, "yield": 1},
    "grape_seed":       {"id": "grape",       "name": "Grape",       "xp": 250, "yield": 2},
}

# Watering (repeatable): each watering gives 2× growth speed for the next
# FARM_WATER_BOOST seconds, and you can re-water once that window elapses
# (cooldown == boost window). Effective grow = real elapsed + the boosted-second
# bonus. Windows are ≥ cooldown apart so they never overlap.
FARM_WATER_BOOST = 300.0      # 5 min of 2× per watering
FARM_WATER_COOLDOWN = 300.0   # can re-water 5 min after the last watering


def _farm_effective_grow(entry: dict, now: float) -> float:
    """Matured seconds so far, counting the 2× watering bonus."""
    planted = float(entry.get("planted_at", 0.0))
    total = now - planted
    for t in entry.get("water_times", []):
        total += min(FARM_WATER_BOOST, max(0.0, now - float(t)))
    return total


def _farm_stage_for(entry: dict) -> int:
    """0 = empty (no seed_id), 1 = growing, 2 = ripe."""
    seed_id = str(entry.get("seed_id", ""))
    if not seed_id:
        return 0
    growth = float(FARM_GROWTH_SEC.get(seed_id, 60.0))
    return 2 if _farm_effective_grow(entry, time.time()) >= growth else 1


def _farm_state_payload(eid: str, entry: dict, now: float = 0.0) -> dict:
    """A farm_plot_state message carrying the bar fields (grow/eff/boost) so the
    client can render the growth + water bars locally (relative → no clock skew)."""
    if now <= 0.0:
        now = time.time()
    seed_id = str(entry.get("seed_id", ""))
    grow = float(FARM_GROWTH_SEC.get(seed_id, 60.0))
    wt = entry.get("water_times", [])
    last_w = max(wt) if wt else 0.0
    boost = max(0.0, FARM_WATER_BOOST - (now - last_w)) if last_w else 0.0
    return {"type": "farm_plot_state", "id": str(eid),
            "stage": _farm_stage_for(entry), "seed_id": seed_id,
            "grow": grow, "eff": _farm_effective_grow(entry, now), "boost": boost}


def _farm_burst_entry(eid: str, entry: dict, now: float = 0.0) -> dict:
    """A login-burst plot entry — same bar fields as _farm_state_payload, no type."""
    p = _farm_state_payload(eid, entry, now)
    p.pop("type", None)
    return p

def _load_farm_plots_from_disk() -> None:
    """One-shot load at boot. Missing file → empty dict (no plots yet)."""
    global farm_plots
    try:
        with open(FARM_PLOT_STATE_PATH, "r") as f:
            data = json.load(f)
        if isinstance(data, dict):
            farm_plots = data
    except (FileNotFoundError, json.JSONDecodeError):
        farm_plots = {}

def _save_farm_plots_to_disk() -> None:
    try:
        with open(FARM_PLOT_STATE_PATH, "w") as f:
            json.dump(farm_plots, f)
    except OSError as e:
        print(f"[farm] save failed: {e}")


# ── Town farm plots — server-seeded + PER-PLAYER state ───────────────────────
# Town plots are seeded into world_entities (so every client spawns them) but
# their crop state is per-player: each player sees ONLY their own crop, so a town
# plot is never "occupied" by someone else and everyone can always farm. ids are
# "ft:<town>:<i>". Kjelvik + Frostheim get none. Positions are tiles INSIDE each
# town's walls, off-centre (⚠ eyeball in-game; move via admin drag if any land on
# a building). Player-BUILT plots (a: ids) stay the single-owner global model.
_TOWN_FARM_PLOT_TILES = {
    "ironwood": [(107, 151), (110, 151), (116, 151),
                 (107, 160), (112, 160), (116, 160)],   # 6, inside walls, not middle
    "eastmark": [(181, 180), (190, 187)],               # 2
    "bjorn":    [(242, 134)],                            # 1
}
# eid -> {player_id(str) -> entry}   (entry shape matches farm_plots)
farm_plots_town: dict = {}
FARM_PLOT_TOWN_STATE_PATH = Path(__file__).parent / "farm_plots_town.json"


def _is_town_plot(eid: str) -> bool:
    return eid.startswith("ft:")


def _seed_town_farm_plots() -> None:
    """INSERT (idempotent) the town farm plots into world_entities so all clients
    spawn them. Per-player crop state lives in farm_plots_town, not here."""
    seeded = 0
    with _db() as conn:
        for town, tiles in _TOWN_FARM_PLOT_TILES.items():
            for i, (tx, ty) in enumerate(tiles):
                eid = f"ft:{town}:{i}"
                if conn.execute("SELECT 1 FROM world_entities WHERE id=?",
                                (eid,)).fetchone():
                    continue
                data = {"type_str": "farm_plot", "display_name": "Farm Plot",
                        "skill": "farming", "level": 1, "action": "Tend",
                        "color": [0.42, 0.30, 0.16, 1.0], "town_plot": True}
                conn.execute(
                    "INSERT INTO world_entities (id, kind, subtype, x, y, data) "
                    "VALUES (?,?,?,?,?,?)",
                    (eid, "farm_plot", "farm_plot",
                     tx * 32 + 16.0, ty * 32 + 16.0, json.dumps(data)))
                seeded += 1
        conn.commit()
    if seeded:
        print(f"[boot] seeded {seeded} town farm plot(s)")


def _load_farm_plots_town_from_disk() -> None:
    global farm_plots_town
    try:
        with open(FARM_PLOT_TOWN_STATE_PATH, "r") as f:
            data = json.load(f)
        if isinstance(data, dict):
            farm_plots_town = data
    except (FileNotFoundError, json.JSONDecodeError):
        farm_plots_town = {}


def _save_farm_plots_town_to_disk() -> None:
    try:
        with open(FARM_PLOT_TOWN_STATE_PATH, "w") as f:
            json.dump(farm_plots_town, f)
    except OSError as e:
        print(f"[farm] town save failed: {e}")


def _append_town_plot_burst(farm_burst: list, pid) -> None:
    """Add player `pid`'s own town-plot crop states to a login burst list."""
    p = str(pid or "")
    if not p:
        return
    now = time.time()
    for eid, pslot in farm_plots_town.items():
        entry = pslot.get(p)
        if entry:
            farm_burst.append(_farm_burst_entry(eid, entry, now))

async def _handle_farm_plant(ws, session: dict, msg: dict) -> None:
    """Client planting a seed. Trusts the client's seed_id claim
    (inventory removal happens client-side); server tracks plant time so
    the ripen check is authoritative. Rejects if the plot is already
    planted (players have to harvest first)."""
    eid = str(msg.get("id", ""))
    seed_id = str(msg.get("seed_id", ""))
    if not eid or seed_id not in FARM_GROWTH_SEC:
        return
    # Farming-level gate — read the stored skill so a modified client can't plant
    # above its level. Reject carries seed_id so the client re-grants the seed it
    # optimistically removed (otherwise a rejected plant silently eats the seed).
    with _db() as conn:
        prow = conn.execute("SELECT skill_xp FROM players WHERE id=?",
                            (session["id"],)).fetchone()
    psx = json.loads(prow["skill_xp"] or "{}") if prow else {}
    farming_lv = _calc_level(int(psx.get("farming", 0)))
    req_lv = int(_FARM_REQ_LV.get(seed_id, 1))
    if farming_lv < req_lv:
        await _send(ws, {"type": "farm_reject",
                         "reason": f"Requires Farming level {req_lv} to plant that.",
                         "seed_id": seed_id})
        return
    pid = str(session["id"])
    # TOWN plot — per-player state; the stage goes ONLY to this player (nobody
    # else's crop is affected, and they never see it occupied).
    if _is_town_plot(eid):
        pslot = farm_plots_town.setdefault(eid, {})
        if _farm_stage_for(pslot.get(pid, {})) != 0:
            await _send(ws, {"type": "farm_reject",
                             "reason": "You already have a crop growing here.",
                             "seed_id": seed_id})
            return
        pslot[pid] = {"seed_id": seed_id, "planted_at": time.time(),
                      "owner_id": pid, "water_times": []}
        await _send(ws, _farm_state_payload(eid, pslot[pid]))
        return
    entry = farm_plots.get(eid, {})
    if _farm_stage_for(entry) != 0:
        await _send(ws, {"type": "farm_reject", "reason": "Plot is already planted.",
                         "seed_id": seed_id})
        return
    farm_plots[eid] = {
        "seed_id":    seed_id,
        "planted_at": time.time(),
        "owner_id":   pid,
        "water_times": [],
    }
    _broadcast(_farm_state_payload(eid, farm_plots[eid]))

async def _handle_farm_water(ws, session: dict, msg: dict) -> None:
    """Water a growing crop for a 2× speed boost. Repeatable every
    FARM_WATER_COOLDOWN (5 min). Town plots resolve to the caller's own slot;
    the refreshed state goes only to them, built/admin plots broadcast."""
    eid = str(msg.get("id", ""))
    is_town = _is_town_plot(eid)
    pid = str(session["id"])
    if is_town:
        entry = farm_plots_town.get(eid, {}).get(pid)
    else:
        entry = farm_plots.get(eid)
    if entry is None or _farm_stage_for(entry) != 1:
        return   # only a growing (not empty / ripe) crop can be watered
    now = time.time()
    wt = entry.setdefault("water_times", [])
    last_w = max(wt) if wt else 0.0
    if last_w and now - last_w < FARM_WATER_COOLDOWN:
        left = int(FARM_WATER_COOLDOWN - (now - last_w))
        await _send(ws, {"type": "farm_reject",
                         "reason": f"Already watered — try again in {left}s."})
        return
    wt.append(now)
    payload = _farm_state_payload(eid, entry, now)
    if is_town:
        await _send(ws, payload)
    else:
        _broadcast(payload)


async def _handle_farm_harvest(ws, session: dict, msg: dict) -> None:
    """Client harvesting a ripe plot. Only the plot's owner_id can
    harvest — matches how gold piles are single-claim but scoped to the
    planter here so shared plots don't get sniped.

    Failure model (playtest ask):
      • ROT — if the harvest happens more than 2× growth_sec past the
        ripen point, the crop rotted; forced fail, plot resets to empty.
      • BURN — otherwise, roll success against the same formula as
        cook/smith (base + skill scaling + practice bonus). On fail,
        crop lost but +15% XP granted for the attempt.
    Both paths increment the client's practice counter via the
    harvest_ok / harvest_fail payload so ripening the same seed 100+
    times gradually reduces the wither rate."""
    eid = str(msg.get("id", ""))
    is_town = _is_town_plot(eid)
    pid = str(session["id"])
    if is_town:
        pslot = farm_plots_town.get(eid, {})
        entry = pslot.get(pid)
    else:
        entry = farm_plots.get(eid)
    if entry is None or _farm_stage_for(entry) != 2:
        return
    # Built/admin plots are single-owner (str compare — player ids are TEXT hex,
    # never int() them). Town plots are always the caller's own slot, no check.
    if not is_town and str(entry.get("owner_id", "")) != pid:
        await _send(ws, {"type": "farm_reject", "reason": "That's not your plot."})
        return
    seed_id = str(entry["seed_id"])
    crop = FARM_CROP_OF.get(seed_id, {})
    if not crop:
        return
    # Success roll — mirrors the cook/smith formula. Farming level +
    # per-recipe practice count (sent from the client — the same
    # recipe_counts we persist) blend into the chance.
    growth = float(FARM_GROWTH_SEC.get(seed_id, 60.0))
    ripened_at = float(entry.get("planted_at", 0.0)) + growth
    overripe = time.time() - ripened_at   # 0 when just ripe
    rot_deadline = growth  # rot if overripe > 1× growth window past ripe
    rotted = overripe > rot_deadline
    # Skill-based base + practice bonus derived from the client's fresh
    # recipe_counts. Practice bonus formula matches the client (every
    # 100 attempts +5%, cap +30%).
    farming_lv = int(msg.get("farming_lv", 1))
    rc = msg.get("recipe_counts", {})
    seed_attempts = int(rc.get(seed_id, 0)) if isinstance(rc, dict) else 0
    practice = min(0.30, (seed_attempts // 100) * 0.05)
    req_lv = int(_FARM_REQ_LV.get(seed_id, 1))
    base = 0.60 + max(0.0, min(0.35, (farming_lv - req_lv) / 40.0))
    p_success = max(0.15, min(0.99, base + max(0.0, min(0.30, practice))))
    fail = rotted or (random.random() > p_success)
    if is_town:
        pslot.pop(pid, None)
        if not pslot:
            farm_plots_town.pop(eid, None)
    else:
        del farm_plots[eid]
    if fail:
        reason = "rotted" if rotted else "withered"
        await _send(ws, {"type": "farm_harvest_fail",
                         "id":       eid,
                         "seed_id":  seed_id,
                         "reason":   reason,
                         "xp":       int(crop["xp"]) * 15 // 100})
    else:
        await _send(ws, {"type": "farm_harvest_ok",
                         "id":       eid,
                         "seed_id":  seed_id,
                         "item_id":  crop["id"],
                         "item_name": crop["name"],
                         "qty":      int(crop.get("yield", 1)),
                         "xp":       int(crop["xp"])})
        # ⑧ — record the harvested crop + farming XP in the grant ledger.
        _grant_to_session(session, str(crop["id"]), str(crop["name"]),
                          [0.7, 0.7, 0.7, 1.0], "farming",
                          int(crop["xp"]), int(crop.get("yield", 1)))
    # Reset the plot visual — town plots only to this player (per-player state);
    # built/admin plots broadcast so everyone sees them empty again.
    reset = {"type": "farm_plot_state", "id": eid, "stage": 0, "seed_id": ""}
    if is_town:
        await _send(ws, reset)
    else:
        _broadcast(reset)

async def _farm_plots_autosave_loop() -> None:
    """Same cadence as shop stock — every 60 s. Cheap dict write."""
    while True:
        await asyncio.sleep(60.0)
        _save_farm_plots_to_disk()
        _save_farm_plots_town_to_disk()

def _load_tile_overrides() -> list:
    """Login bulk format. Reads from the in-memory dict (the file/SQLite was
    already loaded into it at startup)."""
    return _tile_overrides_to_list()


async def _handle_admin_tile_set(ws, session: dict, msg: dict) -> None:
    global tile_overrides_dirty
    if not _can_edit_map(session):
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
    if not _can_edit_map(session):
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
    if not _can_edit_map(session):
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
    if not _can_edit_map(session):
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
    if not _can_edit_map(session):
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
    if not _can_edit_map(session):
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
    if not _can_edit_map(session):
        return
    if tile_overrides_dirty:
        _save_tile_overrides_to_disk()
        await _send(ws, {"type": "chat", "username": "Admin",
                         "text": f"Map saved ({len(tile_overrides)} tile edits)."})
    else:
        await _send(ws, {"type": "chat", "username": "Admin",
                         "text": "Nothing to save — no unsaved changes."})


async def _handle_admin_spawn(ws, session: dict, msg: dict) -> None:
    if not _can_edit_map(session):
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
    # Warband walls are named after the clan that raised them. Baked in here (not
    # re-derived on load like town walls) so the name survives relog — the load
    # path has no builder context. A town wall still wins via _name_wall_by_town
    # below (players can only build in their own banner turf, i.e. outside towns).
    with _db() as conn:
        _wall_clan = _clan_name(conn, _clan_id_for_player(conn, session["id"]))
    if _wall_clan:
        display_name = f"{_wall_clan} Wall"
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
    mark_caravan_routes_dirty()   # player-built wall may block a road → reroute
    if any(h in subtype for h in _WALL_SUBTYPE_HINTS):
        _recompute_town_bounds()  # extend the town limit before naming this wall
    data["hp"] = max_hp_s
    data["max_hp"] = max_hp_s
    data["alive"] = True
    _name_wall_by_town(subtype, x, y, data)   # town walls are named after their town
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
        "min_construction": 5,
        "min_warband_size": 1,
        "per_warband_cap":  12,
        # Banner non-overlap: each banner claims a 16-tile radius (512 px),
        # so two banners must be at LEAST 1024 px (32 tiles) apart so their
        # claim circles don't intersect.
        "spacing_px":       1024.0,
    },
    "outpost": {
        "min_construction": 5,
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


def _clan_name(conn, clan_id) -> str:
    """Warband/clan display name for an id, or '' if unknown."""
    if not clan_id:
        return ""
    row = conn.execute("SELECT name FROM clans WHERE id=?", (clan_id,)).fetchone()
    return str(row["name"]) if row and row["name"] else ""


# ── Tiled clan bank (Phase 3 #2) ────────────────────────────────────────────
CLAN_TAB_SLOTS = 20                       # distinct items per tab (bank stacks by id)
CLAN_MAX_TABS = 3
CLAN_TAB_COST = {2: 20000, 3: 100000}     # clan-pool gold to unlock tab N (1-based)


def _clan_tabs(bank_raw) -> list:
    """Normalize clans.bank into a list-of-tabs. Legacy flat item list → tab 0."""
    data = json.loads(bank_raw or "[]") if isinstance(bank_raw, str) else (bank_raw or [])
    if not isinstance(data, list) or not data:
        return [[]]
    if isinstance(data[0], dict):
        return [data]
    return [t if isinstance(t, list) else [] for t in data]


def _clan_tabs_padded(bank_raw, tab_count: int) -> list:
    tabs = _clan_tabs(bank_raw)
    while len(tabs) < max(1, tab_count):
        tabs.append([])
    return tabs


def _clan_bank_add(tab_items: list, item_id: str, item_name: str, qty: int, color) -> bool:
    """Bank semantics: merge by id (one slot per distinct item); cap CLAN_TAB_SLOTS."""
    for it in tab_items:
        if isinstance(it, dict) and it.get("id") == item_id:
            it["qty"] = int(it.get("qty", 0)) + qty
            return True
    if len(tab_items) >= CLAN_TAB_SLOTS:
        return False
    tab_items.append({"id": item_id, "name": item_name, "qty": qty,
                      "color": _color_to_list(color)})
    return True


def _clan_member_row(conn, cid, pid):
    return conn.execute(
        "SELECT role, withdraw_tabs, gold_limit, gold_withdrawn "
        "FROM clan_members WHERE clan_id=? AND player_id=?", (cid, pid)).fetchone()


def _clan_can_withdraw_tab(mrow, tab: int) -> bool:
    if mrow is None:
        return False
    if str(mrow["role"]) == "leader":
        return True
    try:
        return tab in json.loads(mrow["withdraw_tabs"] or "[]")
    except Exception:
        return False


def _build_clan_info(conn, clan_id: str) -> dict:
    clan = conn.execute("SELECT * FROM clans WHERE id=?", (clan_id,)).fetchone()
    if not clan:
        return {}
    rows = conn.execute(
        "SELECT cm.player_id AS pid, cm.role AS role, p.username AS uname, "
        "cm.withdraw_tabs AS wt, cm.gold_limit AS gl, cm.gold_withdrawn AS gw "
        "FROM clan_members cm JOIN players p ON p.id = cm.player_id "
        "WHERE cm.clan_id=? ORDER BY (cm.role='leader') DESC, p.username COLLATE NOCASE",
        (clan_id,)
    ).fetchall()
    members = []
    for r in rows:
        keys = r.keys()
        try:
            wt = json.loads(r["wt"] or "[]") if "wt" in keys else []
        except Exception:
            wt = []
        members.append({
            "username":       r["uname"],
            "role":           r["role"],
            "online":         _is_online(r["pid"]),
            "withdraw_tabs":  wt,
            "gold_limit":     int(r["gl"] or 0) if "gl" in keys else 0,
            "gold_withdrawn": int(r["gw"] or 0) if "gw" in keys else 0,
        })
    leader_row = conn.execute("SELECT username FROM players WHERE id=?",
                              (clan["leader_id"],)).fetchone()
    ckeys = clan.keys()
    tab_count = int(clan["bank_tabs"] or 1) if "bank_tabs" in ckeys else 1
    tabs = _clan_tabs_padded(clan["bank"], tab_count)
    return {
        "id":        clan["id"],
        "name":      clan["name"],
        "leader":    leader_row["username"] if leader_row else "?",
        "gold":      int(clan["gold"] or 0),
        "bank_tabs": tab_count,
        "tab_slots": CLAN_TAB_SLOTS,
        "tab_costs": CLAN_TAB_COST,
        "tabs":      tabs,
        "bank":      tabs[0] if tabs else [],   # back-compat: tab 0
        "members":   members,
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
    # Any member can deposit into any unlocked tab. Slots are per-tab (20).
    item_id = str(msg.get("item_id", "")).strip()
    qty     = int(msg.get("qty", 0))
    tab     = max(0, int(msg.get("tab", 0)))
    if not item_id or qty <= 0:
        return
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        clan = conn.execute("SELECT bank, bank_tabs FROM clans WHERE id=?", (cid,)).fetchone()
        tab_count = int(clan["bank_tabs"] or 1)
        if tab >= tab_count:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "That tab isn't unlocked."})
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
        tabs = _clan_tabs_padded(clan["bank"], tab_count)
        if not _clan_bank_add(tabs[tab], item_id, item_name, qty, _color_for_item(item_id)):
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "That bank tab is full."})
            return
        _inv_remove_qty(inv, item_id, qty)
        conn.execute("UPDATE players SET inventory=? WHERE id=?", (json.dumps(inv), session["id"]))
        conn.execute("UPDATE clans SET bank=? WHERE id=?", (json.dumps(tabs), cid))
        conn.commit()
    await _send(ws, {"type": "clan_bank_result", "ok": True, "inventory": inv})
    await _broadcast_clan_info(cid)


async def _handle_clan_bank_withdraw(ws, session: dict, msg: dict) -> None:
    # Withdraw is gated: leader always, members only from tabs they're granted.
    item_id = str(msg.get("item_id", "")).strip()
    qty     = int(msg.get("qty", 0))
    tab     = max(0, int(msg.get("tab", 0)))
    if not item_id or qty <= 0:
        return
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        if not _clan_can_withdraw_tab(_clan_member_row(conn, cid, session["id"]), tab):
            await _send(ws, {"type": "clan_result", "ok": False,
                             "reason": "You don't have withdraw rights on that tab."})
            return
        clan = conn.execute("SELECT bank, bank_tabs FROM clans WHERE id=?", (cid,)).fetchone()
        tab_count = int(clan["bank_tabs"] or 1)
        if tab >= tab_count:
            return
        tabs = _clan_tabs_padded(clan["bank"], tab_count)
        item_name = ""
        have = 0
        for it in tabs[tab]:
            if isinstance(it, dict) and it.get("id") == item_id:
                have = int(it.get("qty", 0))
                item_name = str(it.get("name", item_id))
                break
        if have < qty:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "Not enough in that tab."})
            return
        _inv_remove_qty(tabs[tab], item_id, qty)
        prow = conn.execute("SELECT inventory FROM players WHERE id=?", (session["id"],)).fetchone()
        inv  = json.loads(prow["inventory"] or "[]") if prow else []
        _inv_add_qty(inv, item_id, item_name, qty, _color_for_item(item_id))
        conn.execute("UPDATE players SET inventory=? WHERE id=?", (json.dumps(inv), session["id"]))
        conn.execute("UPDATE clans SET bank=? WHERE id=?", (json.dumps(tabs), cid))
        conn.commit()
    await _send(ws, {"type": "clan_bank_result", "ok": True, "inventory": inv})
    await _broadcast_clan_info(cid)


# ── Clan bank: tab purchase + gold pool + permissions (Phase 3 #2/#3b) ────────
async def _handle_clan_buy_tab(ws, session: dict, msg: dict) -> None:
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        clan = conn.execute("SELECT leader_id, gold, bank_tabs FROM clans WHERE id=?", (cid,)).fetchone()
        if str(clan["leader_id"]) != session["id"]:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "Only the leader can buy tabs."})
            return
        cur = int(clan["bank_tabs"] or 1)
        nxt = cur + 1
        if nxt > CLAN_MAX_TABS:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "All tabs already unlocked."})
            return
        cost = CLAN_TAB_COST.get(nxt, 0)
        pool = int(clan["gold"] or 0)
        if pool < cost:
            await _send(ws, {"type": "clan_result", "ok": False,
                             "reason": f"Clan pool needs {cost}g (has {pool})."})
            return
        conn.execute("UPDATE clans SET gold=?, bank_tabs=? WHERE id=?", (pool - cost, nxt, cid))
        conn.commit()
    await _send(ws, {"type": "clan_result", "ok": True, "reason": f"Unlocked bank tab {nxt}."})
    await _broadcast_clan_info(cid)


async def _handle_clan_gold_deposit(ws, session: dict, msg: dict) -> None:
    amount = max(0, int(msg.get("amount", 0)))
    if amount <= 0:
        return
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        prow = conn.execute("SELECT gold FROM players WHERE id=?", (session["id"],)).fetchone()
        gold = int(prow["gold"] or 0) if prow else 0
        move = min(amount, gold)
        if move <= 0:
            return
        crow = conn.execute("SELECT gold FROM clans WHERE id=?", (cid,)).fetchone()
        new_pool = int(crow["gold"] or 0) + move
        conn.execute("UPDATE players SET gold=? WHERE id=?", (gold - move, session["id"]))
        conn.execute("UPDATE clans SET gold=? WHERE id=?", (new_pool, cid))
        conn.commit()
    await _send(ws, {"type": "gold_set", "gold": gold - move})
    await _broadcast_clan_info(cid)


async def _handle_clan_gold_withdraw(ws, session: dict, msg: dict) -> None:
    amount = max(0, int(msg.get("amount", 0)))
    if amount <= 0:
        return
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        mrow = _clan_member_row(conn, cid, session["id"])
        if mrow is None:
            return
        is_leader = str(mrow["role"]) == "leader"
        crow = conn.execute("SELECT gold FROM clans WHERE id=?", (cid,)).fetchone()
        pool = int(crow["gold"] or 0)
        allow = amount
        if not is_leader:
            remaining = max(0, int(mrow["gold_limit"] or 0) - int(mrow["gold_withdrawn"] or 0))
            allow = min(allow, remaining)
            if allow <= 0:
                await _send(ws, {"type": "clan_result", "ok": False,
                                 "reason": "Your clan-gold withdraw allowance is used up."})
                return
        move = min(allow, pool)
        if move <= 0:
            await _send(ws, {"type": "clan_result", "ok": False, "reason": "The clan pool is empty."})
            return
        prow = conn.execute("SELECT gold FROM players WHERE id=?", (session["id"],)).fetchone()
        pgold = int(prow["gold"] or 0) if prow else 0
        conn.execute("UPDATE clans SET gold=? WHERE id=?", (pool - move, cid))
        conn.execute("UPDATE players SET gold=? WHERE id=?", (pgold + move, session["id"]))
        if not is_leader:
            conn.execute("UPDATE clan_members SET gold_withdrawn=? WHERE clan_id=? AND player_id=?",
                         (int(mrow["gold_withdrawn"] or 0) + move, cid, session["id"]))
        conn.commit()
    await _send(ws, {"type": "gold_set", "gold": pgold + move})
    await _broadcast_clan_info(cid)


async def _handle_clan_set_perm(ws, session: dict, msg: dict) -> None:
    # Leader toggles a member's withdraw right for a tab.
    target = str(msg.get("username", "")).strip()
    tab = max(0, int(msg.get("tab", 0)))
    allow = bool(msg.get("allow", False))
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        clan = conn.execute("SELECT leader_id FROM clans WHERE id=?", (cid,)).fetchone()
        if str(clan["leader_id"]) != session["id"]:
            return
        trow = conn.execute("SELECT id FROM players WHERE username=? COLLATE NOCASE", (target,)).fetchone()
        if not trow:
            return
        mrow = _clan_member_row(conn, cid, trow["id"])
        if mrow is None:
            return
        try:
            tabs = set(json.loads(mrow["withdraw_tabs"] or "[]"))
        except Exception:
            tabs = set()
        if allow:
            tabs.add(tab)
        else:
            tabs.discard(tab)
        conn.execute("UPDATE clan_members SET withdraw_tabs=? WHERE clan_id=? AND player_id=?",
                     (json.dumps(sorted(tabs)), cid, trow["id"]))
        conn.commit()
    await _broadcast_clan_info(cid)


async def _handle_clan_set_gold_limit(ws, session: dict, msg: dict) -> None:
    # Leader sets a member's cumulative clan-gold withdraw allowance.
    target = str(msg.get("username", "")).strip()
    limit = max(0, int(msg.get("limit", 0)))
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            return
        clan = conn.execute("SELECT leader_id FROM clans WHERE id=?", (cid,)).fetchone()
        if str(clan["leader_id"]) != session["id"]:
            return
        trow = conn.execute("SELECT id FROM players WHERE username=? COLLATE NOCASE", (target,)).fetchone()
        if not trow:
            return
        conn.execute("UPDATE clan_members SET gold_limit=? WHERE clan_id=? AND player_id=?",
                     (limit, cid, trow["id"]))
        conn.commit()
    await _broadcast_clan_info(cid)


# ── Shared world state (resource nodes) ───────────────────────────────────────
# Geometry is deterministic on the client (shared chunk seeds), so the server only
# owns *mutable* state, keyed by the client's stable entity_id. Default = available;
# we only store entries for nodes that are currently locked or depleted (lazy).
# entity_id -> {"x": float, "y": float, "depleted_until": float, "lock": player_id|None}
nodes_state: dict = {}
# ADMIN-placed gatherables (a: ids) wander a little on respawn instead of returning
# to the exact same pixel — feels alive, like procedural scatter — but never onto an
# impassable tile. Anchor = the placed position (seeded from the first gather), so it
# re-rolls AROUND the placement each cycle and never drifts away.
admin_node_anchor: dict = {}          # eid -> (anchor_x, anchor_y)
_NODE_WANDER_PX = 88.0                 # ~2-3 tiles at 32 px/tile


def _reroll_node_pos(ax: float, ay: float) -> tuple:
    """A random passable spot within ~2-3 tiles of the anchor; anchor if none found."""
    for _ in range(8):
        ang = random.random() * 6.28318
        rad = random.uniform(24.0, _NODE_WANDER_PX)
        nx = ax + math.cos(ang) * rad
        ny = ay + math.sin(ang) * rad
        if terrain.is_passable(nx, ny):
            return (nx, ny)
    return (ax, ay)

# v1.7 B2a — SERVER-AUTHORITATIVE gather. The client can no longer mint gathered
# loot/XP: the server decides the drop. `node_drops` maps a node id →
# {skill, level, drop_id, drop_name, xp, regen}. Procedural nodes (r:cx:cy:i) are
# filled by the admin BAKE (client snapshots them + uploads — like the terrain
# bitmap); admin nodes (a:) are resolved live from world_entities.data.
NODE_DROPS_FILE = Path(__file__).parent / "node_drops.json"
node_drops: dict = {}


def _load_node_drops() -> None:
    global node_drops
    try:
        if NODE_DROPS_FILE.exists():
            node_drops = json.loads(NODE_DROPS_FILE.read_text())
            print(f"[gather] loaded {len(node_drops)} baked node drops")
    except Exception as e:
        print(f"[gather] node_drops load failed: {e}")
        node_drops = {}


def _save_node_drops() -> None:
    try:
        NODE_DROPS_FILE.write_text(json.dumps(node_drops))
    except Exception as e:
        print(f"[gather] node_drops save failed: {e}")


# v1.7 B3 (loot) — SERVER-authoritative monster loot. `monster_loot` maps
# monster_type → {loot:[{id,name,color}], boot:{...,chance}, gem:{...,chance}}
# plus a universal "_soul" {chance, tiers}. Baked by the admin (client uploads),
# rolled on kill in _monster_die, pushed to the killer. Client stops rolling loot.
MONSTER_LOOT_FILE = Path(__file__).parent / "monster_loot.json"
monster_loot: dict = {}


def _load_monster_loot() -> None:
    global monster_loot
    try:
        if MONSTER_LOOT_FILE.exists():
            monster_loot = json.loads(MONSTER_LOOT_FILE.read_text())
            print(f"[loot] loaded {len(monster_loot)} baked monster-loot entries")
    except Exception as e:
        print(f"[loot] monster_loot load failed: {e}")
        monster_loot = {}


def _save_monster_loot() -> None:
    try:
        MONSTER_LOOT_FILE.write_text(json.dumps(monster_loot))
    except Exception as e:
        print(f"[loot] monster_loot save failed: {e}")


# v1.7 B3 (craft ⑤) — SERVER-authoritative crafting. `craft_recipes` maps a
# recipe id → {skill, req_lv, xp, out_id, out_name, out_color, input:[{id,qty}]}.
# Baked by the admin (client uploads all HUD recipe consts). Server validates
# skill + materials against the DB inventory, consumes, grants the output + XP,
# and pushes — the client can no longer mint crafted items or XP.
CRAFT_RECIPES_FILE = Path(__file__).parent / "craft_recipes.json"
craft_recipes: dict = {}


def _load_craft_recipes() -> None:
    global craft_recipes
    try:
        if CRAFT_RECIPES_FILE.exists():
            craft_recipes = json.loads(CRAFT_RECIPES_FILE.read_text())
            print(f"[craft] loaded {len(craft_recipes)} baked recipes")
    except Exception as e:
        print(f"[craft] recipe load failed: {e}")
        craft_recipes = {}


def _save_craft_recipes() -> None:
    try:
        CRAFT_RECIPES_FILE.write_text(json.dumps(craft_recipes))
    except Exception as e:
        print(f"[craft] recipe save failed: {e}")


# v1.7 ⑥ (fishing) — SERVER-authoritative catches. `fish_species` maps a
# species id → {base_xp, wr_lv, min_catch_lv, name, color}. Baked by the admin
# (client uploads _BOAT_FISH + _DEEP_FISH). Server validates the species + level
# gate, CLAMPS the client's weight into the species range, recomputes wnorm +
# trophy, grants the fish item (with meta) + fishing XP + weight-scaled gold, and
# pushes — the client can no longer mint fish/XP. Pre-bake it trusts the claim.
FISH_SPECIES_FILE = Path(__file__).parent / "fish_species.json"
fish_species: dict = {}
_FISH_TROPHY_NORM = 0.85


def _load_fish_species() -> None:
    global fish_species
    try:
        if FISH_SPECIES_FILE.exists():
            fish_species = json.loads(FISH_SPECIES_FILE.read_text())
            print(f"[fishing] loaded {len(fish_species)} baked fish species")
    except Exception as e:
        print(f"[fishing] fish_species load failed: {e}")
        fish_species = {}


def _save_fish_species() -> None:
    try:
        FISH_SPECIES_FILE.write_text(json.dumps(fish_species))
    except Exception as e:
        print(f"[fishing] fish_species save failed: {e}")


def _fish_weight_range(wr_lv: int) -> tuple:
    """Mirror of Fishing.weight_range: median = 0.5 + wr_lv²·0.04, span [0.4x,1.8x]."""
    median = 0.5 + float(wr_lv * wr_lv) * 0.04
    return (median * 0.4, median * 1.8)


def _fish_weight_norm(wr_lv: int, weight: float) -> float:
    lo, hi = _fish_weight_range(wr_lv)
    return max(0.0, min((weight - lo) / max(0.001, hi - lo), 1.0))


# v1.7 ⑥ (sea combat) — SERVER-authoritative boat-fight rewards. `sea_loot` maps a
# sea-monster type → {name, xp_reward, loot:[{id,name,qty,color}]}. The fight is a
# client minigame (server can't referee it), so the server trusts the "I won vs X"
# claim but owns WHAT is granted — baked loot + xp, never client-claimed items.
SEA_LOOT_FILE = Path(__file__).parent / "sea_loot.json"
sea_loot: dict = {}


def _load_sea_loot() -> None:
    global sea_loot
    try:
        if SEA_LOOT_FILE.exists():
            sea_loot = json.loads(SEA_LOOT_FILE.read_text())
            print(f"[sea] loaded {len(sea_loot)} baked sea-monster loot entries")
    except Exception as e:
        print(f"[sea] sea_loot load failed: {e}")
        sea_loot = {}


def _save_sea_loot() -> None:
    try:
        SEA_LOOT_FILE.write_text(json.dumps(sea_loot))
    except Exception as e:
        print(f"[sea] sea_loot save failed: {e}")


def _inv_count(inventory: list, item_id: str) -> int:
    return sum(int(it.get("qty", 0)) for it in inventory
               if isinstance(it, dict) and it.get("id") == item_id)


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

    # Reputation (Phase 5a) — a quest belongs to its giver's town, so finishing
    # it raises standing there (and a quarter of it with the player's warband).
    # Always granted, even on a diminished boss repeat.
    granted_rep = 0
    rep_town = _town_of_npc(str(q.get("giver_npc", "")))
    if rep_town:
        granted_rep = int(q.get("rewards", {}).get("rep", REP_PER_QUEST))
        if granted_rep:
            _rep_add(conn, pid, rep_town, granted_rep)

    return {
        "gold":        granted_gold,
        "new_gold":    gold,
        "items":       granted_items,
        "xp":          granted_xp,
        "diminished":  diminished,
        "new_inv":     inv,
        "rep_town":    rep_town,
        "rep_town_name": TOWN_NAMES.get(rep_town, ""),
        "rep":         granted_rep,
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
                "grove_token", "ash_token"]
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


# NPC name → town_id. Used by the shop tax skim AND by reputation (Phase 5a) to
# resolve which town a QUEST belongs to from its giver_npc. Mirrors the
# client-side `Lore.town_of_npc` table — keep both in sync.
_NPC_TO_TOWN = {
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
    "Ironwood Hermit Skade": "ironwood",
    # Eastmark Post
    "Scout Halfdan": "eastmark",
    "Wandering Merchant Freyja": "eastmark",
    "Captain Sten": "eastmark",
}


def _town_of_npc(npc_name: str) -> str:
    """town_id for an NPC name, or '' when it belongs to no town."""
    return _NPC_TO_TOWN.get(npc_name, "")


def _town_of_shopkeeper(npc_id: str, npc_name: str) -> str:
    """Resolve a shopkeeper's town_id for tax-skim lookups. We map by NPC
    name; npc_id is kept in the signature for future per-shop overrides."""
    return _town_of_npc(npc_name)


# ── Kjelvik castle safe zone (Phase 5b) ──────────────────────────────────────
# The ONLY no-PvP zone in the world. User call 2026-07-23: "No where should be
# PvP gated. PvP should only be gated by the toggle by the player. The castle
# city can be PvP gated now that it has a wall." So the other four towns are NOT
# safe — PvP everywhere else is purely the attacker's/target's own toggle.
# Bounds mirror Ground._is_town's Kjelvik range AND World._KC_* wall ring
# (tx 71-96, ty 105-128) — keep all three in sync.
CASTLE_SAFE_X0 = 71 * 32.0
CASTLE_SAFE_Y0 = 105 * 32.0
CASTLE_SAFE_X1 = 97 * 32.0    # tx 96 inclusive
CASTLE_SAFE_Y1 = 129 * 32.0   # ty 128 inclusive


def _in_castle_safe_zone(x: float, y: float) -> bool:
    return (CASTLE_SAFE_X0 <= x <= CASTLE_SAFE_X1
            and CASTLE_SAFE_Y0 <= y <= CASTLE_SAFE_Y1)


# ── Kjelvik city watch (Phase 5b) ────────────────────────────────────────────
# Guards are ephemeral MONSTERS — they reuse the whole monster pipeline for
# damage / death / AI / projectiles — with a bespoke command layer on top:
#   * they only ever exist inside the castle walls,
#   * they answer in escalating WAVES and tier up as they fall,
#   * past the cap the rangers and magi come out,
#   * and they will NOT chase you out of the city (see the guard leash in
#     _tick_monster_ai) — they hold the walls, they don't hunt.
# Intent (locked with the user): a player can win a fight but never the war —
# they should go down before exhausting the 8-guard cap.
GUARD_TYPES = ("guard", "guard_ranger", "guard_magi")
GUARD_MAX_CONCURRENT = 8      # hard cap on live guards per offender
GUARD_REINFORCE      = 2      # how many answer when one of their own falls
GUARD_BASE_LEVEL     = 30
GUARD_LEVEL_STEP     = 6      # each fallen guard stiffens the next wave
GUARD_ALERT_TIMEOUT  = 120.0  # alert decays after this long with no offence
GUARD_SPAWN_MIN_D    = 90.0
GUARD_SPAWN_MAX_D    = 150.0
# Live-bug fix: the watch's penalty for low standing is combat-to-death ONCE, not
# a death loop. After the watch downs an offender we stand it down and hold a
# cooldown before it will engage them again; a fresh login gets a short grace so a
# hostile player can actually log in + move instead of being mass-killed on entry.
WATCH_ENGAGE_SQUAD   = 3      # guards posted in the single engagement (was up to 8+)
WATCH_COOLDOWN       = 90.0   # stand-down window after an offender is downed once
WATCH_LOGIN_GRACE    = 20.0   # grace after login before the watch can engage
# HARD global ceiling on live guards server-wide. Even if every trigger misfired,
# the watch can never explode into the thousands + freeze the server (death-swarm
# live bug). Well above any legit engagement (a few offenders × a squad each).
GUARD_GLOBAL_CAP     = 40

# offender player_id -> {"killed": int, "active": set(eid), "last_at": float}
guard_alerts: dict = {}
# guard entity id -> offender player_id, so _monster_die can find the alert
guard_owner: dict = {}

# v1.6.4 "the watch defends YOU inside the walls": monster_id -> {"at", "guard_eid"}.
# When a monster attacks a player inside a town, a guard is posted next to it as a
# VISUAL PROP (broadcast only — NOT added to monsters_state, so it never attacks
# anyone), then the AI loop dispatches the monster a beat later and despawns the
# guard. Towns become genuine safe zones.
guard_defends: dict = {}
GUARD_DEFEND_DELAY = 1.8   # seconds a monster survives once a guard shows up
GUARD_DEFEND_HP_FRAC = 0.60   # watch only helps a player who's dropped to ≤60% HP


def _is_guard_entity(eid: str) -> bool:
    return eid in guard_owner


def _guard_type_for(killed: int) -> str:
    """The escalation ladder. Melee watch answers first; once a few have
    fallen the rangers join; past the full cap the magi come out."""
    if killed >= GUARD_MAX_CONCURRENT:
        return random.choice(("guard_magi", "guard_magi", "guard_ranger", "guard"))
    if killed >= 4:
        return random.choice(("guard_ranger", "guard"))
    return "guard"


def _guard_spawn_point(px: float, py: float, tid: str) -> tuple:
    """Somewhere near the offender but still inside `tid`'s walls."""
    x0, y0, x1, y1 = _town_world_bounds(tid)
    for _ in range(8):
        ang = random.uniform(0.0, 2.0 * math.pi)
        d = random.uniform(GUARD_SPAWN_MIN_D, GUARD_SPAWN_MAX_D)
        gx = px + math.cos(ang) * d
        gy = py + math.sin(ang) * d
        if x0 <= gx <= x1 and y0 <= gy <= y1:
            return gx, gy
    return ((x0 + x1) * 0.5, (y0 + y1) * 0.5)


def _guard_alert(player_id: str, px: float, py: float, count: int = 1) -> None:
    """Raise (or refresh) the watch on an offender and post `count` guards.
    No-op outside a town — EVERY town's watch now defends its own walls (v1.6.2).
    The offence town is remembered on the alert for the spawn zone + chase leash."""
    tid = _town_at_world(px, py)
    if not tid:
        return
    now = time.time()
    alert = guard_alerts.get(player_id)
    if alert is None:
        alert = {"killed": 0, "active": set(), "last_at": now, "town": tid}
        guard_alerts[player_id] = alert
    alert["last_at"] = now
    alert["town"] = tid
    for _ in range(max(1, count)):
        if len(alert["active"]) >= GUARD_MAX_CONCURRENT:
            return
        if len(guard_owner) >= GUARD_GLOBAL_CAP:   # hard server-wide ceiling
            return
        gtype = _guard_type_for(alert["killed"])
        level = GUARD_BASE_LEVEL + alert["killed"] * GUARD_LEVEL_STEP
        gx, gy = _guard_spawn_point(px, py, tid)
        eid = "g:" + secrets.token_hex(6)
        entity = {"id": eid, "kind": "monster", "subtype": gtype,
                  "x": gx, "y": gy,
                  "data": {"monster_type": gtype, "level": level, "guard": True}}
        # Ephemeral on purpose: broadcast only, never written to
        # world_entities, so a restart can't leave the city full of orphans.
        _broadcast({"type": "world_entity_add", "entity": entity})
        alert["active"].add(eid)
        guard_owner[eid] = player_id


def _guard_on_death(eid: str) -> None:
    """A guard fell — the watch answers harder. Reinforcements come in at a
    higher level and further along the melee→ranger→magi ladder."""
    pid = guard_owner.pop(eid, "")
    alert = guard_alerts.get(pid)
    if alert is None:
        return
    alert["active"].discard(eid)
    alert["killed"] += 1
    alert["last_at"] = time.time()
    sess = next((s for s in sessions.values() if s.get("id") == pid), None)
    if sess is None:
        return
    _guard_alert(pid, float(sess.get("x", 0.0)), float(sess.get("y", 0.0)),
                 GUARD_REINFORCE)


def _guard_clear(pid: str) -> None:
    """Stand the watch down — despawn every guard posted against `pid`."""
    alert = guard_alerts.pop(pid, None)
    if not alert:
        return
    for eid in list(alert["active"]):
        guard_owner.pop(eid, None)
        monsters_state.pop(eid, None)
        _broadcast({"type": "world_entity_remove", "id": eid})


def _guard_defend_start(mid: str, st: dict, px: float, py: float) -> None:
    """A monster is attacking a player INSIDE a town — post a guard to dispatch it.
    The guard is a broadcast-only VISUAL (never added to monsters_state, so it can't
    attack anyone); `_monster_ai_loop` kills the monster after GUARD_DEFEND_DELAY and
    despawns the guard. No-op for guards themselves, outside towns, or if already set."""
    if _is_guard_entity(mid) or mid in guard_defends:
        return
    if not _town_at_world(px, py):
        return
    eid = "g:" + secrets.token_hex(6)
    entity = {"id": eid, "kind": "monster", "subtype": _guard_type_for(0),
              "x": float(st["x"]) + 26.0, "y": float(st["y"]),
              "data": {"monster_type": _guard_type_for(0),
                       "level": GUARD_BASE_LEVEL, "guard": True}}
    _broadcast({"type": "world_entity_add", "entity": entity})
    guard_defends[mid] = {"at": time.time(), "guard_eid": eid}


async def _guard_decay_loop() -> None:
    """Stands the watch down once the offender leaves the walls, logs off, or
    simply stops offending for GUARD_ALERT_TIMEOUT — AND sweeps orphan guards."""
    while True:
        await asyncio.sleep(10.0)
        now = time.time()
        for pid in list(guard_alerts.keys()):
            alert = guard_alerts.get(pid)
            if alert is None:
                continue
            sess = next((s for s in sessions.values() if s.get("id") == pid), None)
            # Stand down once the offender leaves the town they offended in (guards
            # hold their own walls; they don't hunt across the map).
            gone = sess is None or _town_at_world(
                float(sess.get("x", 0.0)), float(sess.get("y", 0.0)),
                margin=5) != alert.get("town", "")
            if gone or now - alert["last_at"] > GUARD_ALERT_TIMEOUT:
                _guard_clear(pid)
        # SAFETY SWEEP — despawn any guard ('g:') sitting in monsters_state that is
        # NOT owned by a live alert. These orphans (from a reboot, a dropped session,
        # or any accumulation bug) are otherwise unkillable and swarm the respawn
        # point forever — the live death-swarm bug. Bounds guards to real alerts.
        orphans = [m for m in list(monsters_state.keys())
                   if m.startswith("g:") and m not in guard_owner]
        for mid in orphans:
            monsters_state.pop(mid, None)
            _broadcast({"type": "world_entity_remove", "id": mid})
        if orphans:
            print(f"[watch] swept {len(orphans)} orphan guard(s)")


# ── Town wall auto-repair (v1.6.2) ───────────────────────────────────────────
# A town keeps its own walls standing: any damaged wall / tower / gate inside a
# town's bounds slowly heals back (tended by the townsfolk) — but NOT while it's
# under active attack (a recent hit pauses repair) so raids still land.
WALL_REPAIR_TICK     = 15.0     # seconds between repair sweeps
WALL_REPAIR_DELAY    = 25.0     # no repair until this long after the last hit
WALL_REBUILD_DELAY   = 45.0     # a RAZED town wall is rebuilt this long after it fell
WALL_REPAIR_FRACTION = 0.06     # heal this fraction of max HP per sweep
_WALL_SUBTYPE_HINTS = ("wall", "gate", "tower")


def _is_town_wall_structure(st: dict) -> bool:
    sub = str(st.get("subtype", ""))
    return any(h in sub for h in _WALL_SUBTYPE_HINTS)


# town_id -> {"eid": str, "x": float, "y": float}. A visible "Wall-Keeper" NPC
# stands at a damaged wall while it mends, then vanishes once the town is whole.
town_repairers: dict = {}


def _ensure_wall_repairer(town: str, wx: float, wy: float) -> None:
    rx, ry = wx + 40.0, wy + 40.0   # stand a step off the wall so it doesn't overlap
    cur = town_repairers.get(town)
    if cur is None:
        eid = "wr:" + town
        _broadcast({"type": "world_entity_add", "entity": {
            "id": eid, "kind": "npc", "subtype": "worker", "x": rx, "y": ry,
            "data": {"npc_type": "worker", "npc_name": "Wall-Keeper",
                     "wander_radius": 0.0, "quest_text": "", "shop_id": ""}}})
        town_repairers[town] = {"eid": eid, "x": rx, "y": ry}
    elif abs(cur["x"] - rx) > 8.0 or abs(cur["y"] - ry) > 8.0:
        _broadcast({"type": "world_entity_move", "id": cur["eid"], "x": rx, "y": ry})
        cur["x"], cur["y"] = rx, ry


def _remove_wall_repairer(town: str) -> None:
    cur = town_repairers.pop(town, None)
    if cur is not None:
        _broadcast({"type": "world_entity_remove", "id": cur["eid"]})


async def _town_wall_repair_loop() -> None:
    while True:
        await asyncio.sleep(WALL_REPAIR_TICK)
        now = time.time()
        tending: dict = {}   # town -> (wx, wy) a wall being mended this sweep
        for eid, st in list(structures_state.items()):
            mhp = int(st.get("max_hp", 0))
            if mhp <= 0 or not _is_town_wall_structure(st):
                continue
            town = _town_at_world(float(st.get("x", 0.0)), float(st.get("y", 0.0)))
            if not town:
                continue
            since = now - float(st.get("last_damaged_at", 0.0))
            if not st.get("alive", True):
                # RAZED town wall — the town rebuilds it (comes back at 25% HP, then
                # heals up the normal way). Fixes walls that were stuck at 0/destroyed.
                if since < WALL_REBUILD_DELAY:
                    continue
                st["alive"] = True
                st["hp"] = max(1, int(mhp * 0.25))
                _mark_structure_dirty(eid)
                _broadcast({"type": "structure_hp_changed", "id": eid,
                            "hp": st["hp"], "max_hp": mhp, "alive": True})
                tending[town] = (float(st["x"]), float(st["y"]))
                continue
            hp = int(st.get("hp", 0))
            if hp >= mhp or since < WALL_REPAIR_DELAY:
                continue
            st["hp"] = min(mhp, hp + max(1, int(mhp * WALL_REPAIR_FRACTION)))
            _mark_structure_dirty(eid)
            _broadcast({"type": "structure_hp_changed", "id": eid,
                        "hp": st["hp"], "max_hp": mhp, "alive": True})
            tending.setdefault(town, (float(st["x"]), float(st["y"])))
        # Show a visible repairer at each town with work; retire the rest.
        for town, (wx, wy) in tending.items():
            _ensure_wall_repairer(town, wx, wy)
        for town in [t for t in town_repairers if t not in tending]:
            _remove_wall_repairer(town)


# ── Trade caravans (Phase 5c) ────────────────────────────────────────────────
# Two council caravans run a fixed circuit between the five towns, hugging the
# road centre-lines (Ground._is_road, extended in this phase so every town is
# actually reachable). Server-authoritative: position, stops, loot roll, and the
# whole wreck lifecycle live here so every client sees the same wagon.
#
# Attacking one is a rep sink: the standing hit lands on the town the caravan
# most recently LEFT (its cargo was theirs). Caravans are untouchable while
# parked at a town — you have to ambush them in transit.
CARAVAN_SPEED        = 38.0     # px/s along the route — a stately roll
CARAVAN_STOP_SEC     = 120.0    # parked at each town (~2 min)
CARAVAN_MAX_HP       = 140
CARAVAN_WRECK_INTACT = 120.0    # wreck sits whole (~2 min)
CARAVAN_DISSOLVE_SEC = 600.0    # then dissolves slowly (~10 min)
CARAVAN_GONE_SEC     = 600.0    # then absent (~10 min) before respawning
REP_CARAVAN_RAID     = -500     # standing hit with the town it just left
CARAVAN_GUARD_CHANCE = 0.15     # ...but ONLY when the cargo was rare

# Warband caravans (Phase 5c) — a leader hires one from the clan gold pool; it
# runs the same circuit but every arrival PAYS the warband. Raiding it costs the
# attacker player↔warband standing (not town rep — it's the warband's cargo).
WB_CARAVAN_COST      = 5000     # gold from the clan pool to hire one
WB_CARAVAN_CAP       = 2        # per warband
WB_CARAVAN_PAY_MIN   = 300      # gold to the pool per town arrival
WB_CARAVAN_PAY_MAX   = 900
WB_CARAVAN_TOWN_REP  = 40       # warband↔town standing per arrival
WB_CARAVAN_RARE_MATS = ["mithril_bar", "runite_bar", "gold_ore", "diamond",
                        "amethyst", "raw_shark", "ancient_log"]
WB_CARAVAN_RARE_CHANCE = 0.25   # chance an arrival also banks a rare stack
REP_WB_CARAVAN_RAID  = -600     # attacker's standing hit with the warband

# Route stops, in circuit order. Coordinates sit ON the road centre-lines so the
# wagon never strays more than a tile or two from the path.
# Circuit of town stops, in order (the caravan loops it; Kjelvik is the hub, so
# it recurs between outlying runs). Routes BETWEEN consecutive stops are computed
# by BFS over the REAL road tiles (below) so a caravan physically follows the
# drawn roads instead of hand-guessed waypoints that drifted off the map.
CARAVAN_CIRCUIT = ["kjelvik", "frostheim", "kjelvik", "ironwood",
                   "kjelvik", "eastmark", "bjorn"]

# Town centre tiles — a caravan pulls into the market to stop.
_TOWN_CENTER_TILE = {
    "kjelvik": (83, 116), "frostheim": (43, 29), "ironwood": (111, 155),
    "eastmark": (185, 183), "bjorn": (246, 138),
}


# Ported verbatim from Ground._is_town / _is_road so the server can pathfind on
# the SAME tiles the client draws. ⚠ Keep in sync with Ground.gd.
def _tile_is_town(tx: int, ty: int) -> bool:
    if 71 <= tx <= 96 and 105 <= ty <= 128:   return True
    if 37 <= tx <= 50 and 23 <= ty <= 36:     return True
    if 105 <= tx <= 118 and 149 <= ty <= 162: return True
    if 179 <= tx <= 192 and 177 <= ty <= 190: return True
    if 240 <= tx <= 253 and 132 <= ty <= 145: return True
    return False


def _tile_is_road(tx: int, ty: int) -> bool:
    if 77 <= tx <= 79 and 36 <= ty <= 109:    return True
    if 50 <= tx <= 77 and 76 <= ty <= 78:     return True
    if 50 <= tx <= 52 and 36 <= ty <= 77:     return True
    if 84 <= tx <= 86 and 122 <= ty <= 149:   return True
    if 86 <= tx <= 106 and 147 <= ty <= 149:  return True
    if 90 <= tx <= 179 and 113 <= ty <= 115:  return True
    if 177 <= tx <= 179 and 115 <= ty <= 178: return True
    if 90 <= tx <= 239 and 109 <= ty <= 111:  return True
    if 239 <= tx <= 241 and 109 <= ty <= 132: return True
    if 192 <= tx <= 243 and 132 <= ty <= 134: return True
    return False


def _caravan_passable(tx: int, ty: int) -> bool:
    return _tile_is_road(tx, ty) or _tile_is_town(tx, ty)


def _bfs_road_tiles(a: tuple, b: tuple) -> list:
    """Shortest 4-dir path over passable (road ∪ town) tiles, a → b."""
    from collections import deque
    start = (int(a[0]), int(a[1]))
    goal = (int(b[0]), int(b[1]))
    if not _caravan_passable(*start) or not _caravan_passable(*goal):
        return [start, goal]
    came = {start: None}
    q = deque([start])
    while q:
        cur = q.popleft()
        if cur == goal:
            break
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nt = (cur[0] + dx, cur[1] + dy)
            if (nt not in came and 0 <= nt[0] < 300 and 0 <= nt[1] < 300
                    and _caravan_passable(nt[0], nt[1])):
                came[nt] = cur
                q.append(nt)
    if goal not in came:
        return [start, goal]
    path = []
    c = goal
    while c is not None:
        path.append(c)
        c = came[c]
    path.reverse()
    return path


def _caravan_structure_blocked() -> set:
    """Tiles covered by a live blocking structure (walls, buildings…) so caravans
    route AROUND them instead of clipping through. Footprints from _STRUCTURE_SIZES."""
    blocked = set()
    with _db() as conn:
        rows = conn.execute(
            "SELECT subtype, x, y FROM world_entities WHERE kind='resource'").fetchall()
    for r in rows:
        sub = str(r["subtype"])
        if sub not in _STRUCTURE_SIZES:
            continue
        w, h = _STRUCTURE_SIZES[sub]
        cx, cy = float(r["x"]), float(r["y"])
        tx0 = int((cx - w / 2.0) // 32); tx1 = int((cx + w / 2.0) // 32)
        ty0 = int((cy - h / 2.0) // 32); ty1 = int((cy + h / 2.0) // 32)
        for tx in range(tx0, tx1 + 1):
            for ty in range(ty0, ty1 + 1):
                blocked.add((tx, ty))
    return blocked


def _caravan_tile_cost(tx: int, ty: int, blocked: set):
    """Step cost onto a tile, or None if impassable. Road/town tiles are cheap so
    the caravan HUGS the road; open ground is allowed but expensive (detour only);
    walls + admin-impassable tiles are blocked."""
    if (tx, ty) in blocked:
        return None
    if not tile_passability.get(f"{tx},{ty}", True):
        return None
    if _tile_is_road(tx, ty) or _tile_is_town(tx, ty):
        return 1.0
    return 7.0


def _caravan_pathfind(a: tuple, b: tuple, blocked: set) -> list:
    """Weighted 4-dir shortest path (Dijkstra) that prefers road/town tiles but
    detours over open ground to skirt walls / impassable tiles. [] if unreachable."""
    import heapq
    start = (int(a[0]), int(a[1])); goal = (int(b[0]), int(b[1]))
    dist = {start: 0.0}
    came = {start: None}
    pq = [(0.0, start)]
    while pq:
        d, cur = heapq.heappop(pq)
        if cur == goal:
            break
        if d > dist.get(cur, 1e18):
            continue
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nt = (cur[0] + dx, cur[1] + dy)
            if not (0 <= nt[0] < 300 and 0 <= nt[1] < 300):
                continue
            c = _caravan_tile_cost(nt[0], nt[1], blocked)
            if c is None:
                continue
            nd = d + c
            if nd < dist.get(nt, 1e18):
                dist[nt] = nd; came[nt] = cur
                heapq.heappush(pq, (nd, nt))
    if goal not in came:
        return []
    path = []
    c = goal
    while c is not None:
        path.append(c)
        c = came[c]
    path.reverse()
    return path


def _simplify_tiles(tiles: list) -> list:
    """Collapse collinear runs to their turning points."""
    if len(tiles) <= 2:
        return list(tiles)
    out = [tiles[0]]
    for i in range(1, len(tiles) - 1):
        d1 = (tiles[i][0] - tiles[i - 1][0], tiles[i][1] - tiles[i - 1][1])
        d2 = (tiles[i + 1][0] - tiles[i][0], tiles[i + 1][1] - tiles[i][1])
        if d1 != d2:
            out.append(tiles[i])
    out.append(tiles[-1])
    return out


def _tile_center_world(t: tuple) -> tuple:
    return (t[0] * 32.0 + 16.0, t[1] * 32.0 + 16.0)


_caravan_routes: dict = {}   # (from_town, to_town) -> [world waypoints]
_caravan_routes_dirty: bool = False   # a structure changed → rebuild routes on next depart


def _build_caravan_routes() -> None:
    """Precompute each circuit leg's waypoints, road-preferring + skirting walls /
    impassable tiles. Falls back to road-only BFS then a straight line if a leg is
    somehow unreachable (so a caravan never stalls)."""
    global _caravan_routes_dirty
    _caravan_routes.clear()
    blocked = _caravan_structure_blocked()
    for i in range(len(CARAVAN_CIRCUIT)):
        a = CARAVAN_CIRCUIT[i]
        b = CARAVAN_CIRCUIT[(i + 1) % len(CARAVAN_CIRCUIT)]
        if (a, b) in _caravan_routes:
            continue
        tiles = _caravan_pathfind(
            _TOWN_CENTER_TILE[a], _TOWN_CENTER_TILE[b], blocked)
        if not tiles:                       # unreachable via weighted → road-only
            tiles = _bfs_road_tiles(_TOWN_CENTER_TILE[a], _TOWN_CENTER_TILE[b])
        _caravan_routes[(a, b)] = [_tile_center_world(t) for t in _simplify_tiles(tiles)]
    _caravan_routes_dirty = False
    print(f"[caravan] built {len(_caravan_routes)} weighted road routes")


def mark_caravan_routes_dirty() -> None:
    """Called when a structure is placed / moved / removed so caravan routes
    rebuild (lazily, on the next depart) to skirt the new wall footprint."""
    global _caravan_routes_dirty
    _caravan_routes_dirty = True

# Council trade goods. `rare` cargo is what occasionally travels with a guard.
CARAVAN_CARGO = [
    {"id": "fur_bundle",   "name": "Fur Bundle",    "rare": False},
    {"id": "salt_sack",    "name": "Sack of Salt",  "rare": False},
    {"id": "ale_keg",      "name": "Ale Keg",       "rare": False},
    {"id": "wool_cloth",   "name": "Wool Cloth",    "rare": False},
    {"id": "oak_log",      "name": "Oak Log",       "rare": False},
    {"id": "raw_fish",     "name": "Raw Fish",      "rare": False},
    {"id": "iron_ore",     "name": "Iron Ore",      "rare": False},
    {"id": "mithril_bar",  "name": "Mithril Bar",   "rare": True},
    {"id": "runite_bar",   "name": "Runite Bar",    "rare": True},
    {"id": "diamond",      "name": "Diamond",       "rare": True},
    {"id": "amethyst",     "name": "Amethyst",      "rare": True},
]

# caravan id -> full state dict
caravans: dict = {}


def _caravan_roll_cargo() -> list:
    """3-5 stacks of trade goods; rare stock is deliberately uncommon."""
    out = []
    for _ in range(random.randint(3, 5)):
        pick = random.choice(CARAVAN_CARGO)
        if pick["rare"] and random.random() > 0.25:
            pick = random.choice([c for c in CARAVAN_CARGO if not c["rare"]])
        out.append({"id": pick["id"], "name": pick["name"],
                    "qty": random.randint(1, 4) if pick["rare"] else random.randint(3, 12),
                    "rare": pick["rare"]})
    return out


def _caravan_init(cid: str, circuit_i: int, warband_id: str = "") -> dict:
    circuit_i %= len(CARAVAN_CIRCUIT)
    tid = CARAVAN_CIRCUIT[circuit_i]
    sx, sy = _tile_center_world(_TOWN_CENTER_TILE[tid])
    return {
        "id": cid, "x": sx, "y": sy,
        "circuit_i": circuit_i,
        "state": "stopped",          # stopped | travel | wreck | dissolving | gone
        "timer": CARAVAN_STOP_SEC,
        "path": [], "path_i": 0,
        "hp": CARAVAN_MAX_HP, "max_hp": CARAVAN_MAX_HP,
        "last_town": tid,            # whose cargo it carries — the rep target
        "next_town": tid,
        "cargo": _caravan_roll_cargo(),
        # "" for the two council caravans; a clan id for a hired warband caravan.
        "warband_id": warband_id,
    }


def _caravan_public(c: dict) -> dict:
    return {"id": c["id"], "x": c["x"], "y": c["y"], "state": c["state"],
            "hp": c["hp"], "max_hp": c["max_hp"],
            "last_town": c["last_town"], "next_town": c["next_town"],
            # Fraction remaining, so the client can drive the dissolve visual.
            "decay": (c["timer"] / CARAVAN_DISSOLVE_SEC)
                     if c["state"] == "dissolving" else 1.0}


def _caravan_depart(c: dict) -> None:
    """Leave the current stop for the next town on the circuit, following the
    precomputed road route."""
    if _caravan_routes_dirty:       # a structure changed since last build → refresh
        _build_caravan_routes()
    from_tid = CARAVAN_CIRCUIT[c["circuit_i"]]
    nxt = (c["circuit_i"] + 1) % len(CARAVAN_CIRCUIT)
    to_tid = CARAVAN_CIRCUIT[nxt]
    c["circuit_i"] = nxt
    c["last_town"] = from_tid       # cargo belongs to the town just left
    c["next_town"] = to_tid
    c["path"] = list(_caravan_routes.get((from_tid, to_tid), []))
    c["path_i"] = 0
    c["state"] = "travel"


def _caravan_is_attackable(c: dict) -> bool:
    """Only in transit — parked caravans are under town protection."""
    return c["state"] == "travel" and c["hp"] > 0


def _caravan_step(c: dict, dt: float) -> None:
    """One tick of the route / wreck state machine."""
    st = c["state"]
    if st == "stopped":
        c["timer"] -= dt
        if c["timer"] <= 0.0:
            _caravan_depart(c)
        return
    if st == "travel":
        if c["path_i"] >= len(c["path"]):
            # Arrived — park and re-stock for the next haul.
            c["state"] = "stopped"
            c["timer"] = CARAVAN_STOP_SEC
            c["hp"] = c["max_hp"]
            c["cargo"] = _caravan_roll_cargo()
            # A warband caravan PAYS its owners on every safe arrival.
            if c.get("warband_id"):
                _warband_caravan_payout(c)
            return
        tx, ty = c["path"][c["path_i"]]
        dx, dy = tx - c["x"], ty - c["y"]
        dist = math.hypot(dx, dy)
        step = CARAVAN_SPEED * dt
        if dist <= step or dist < 1.0:
            c["x"], c["y"] = tx, ty
            c["path_i"] += 1
        else:
            c["x"] += dx / dist * step
            c["y"] += dy / dist * step
        return
    # Wreck lifecycle: intact → dissolving → gone → respawn at the destination.
    c["timer"] -= dt
    if c["timer"] > 0.0:
        return
    if st == "wreck":
        c["state"] = "dissolving"
        c["timer"] = CARAVAN_DISSOLVE_SEC
    elif st == "dissolving":
        c["state"] = "gone"
        c["timer"] = CARAVAN_GONE_SEC
    elif st == "gone":
        # Respawns at the town it had been heading for when it was destroyed.
        idx = 0
        for i, tid in enumerate(CARAVAN_CIRCUIT):
            if tid == c["next_town"]:
                idx = i
                break
        fresh = _caravan_init(c["id"], idx)
        c.update(fresh)


async def _caravan_loop() -> None:
    """Drives both caravans and broadcasts their state. One message per tick
    for the whole set — there are only two, so no interest filtering."""
    for i in range(2):
        # Stagger them across the circuit so they aren't a convoy.
        cid = "cv:%d" % i
        caravans[cid] = _caravan_init(
            cid, (i * len(CARAVAN_CIRCUIT)) // 2)
    tick = 0.5
    while True:
        await asyncio.sleep(tick)
        for c in caravans.values():
            try:
                _caravan_step(c, tick)
            except Exception as e:
                print(f"[caravan] step failed for {c.get('id')}: {e!r}")
        if sessions or spectators:
            _broadcast({"type": "caravans",
                        "caravans": [_caravan_public(c) for c in caravans.values()]})


async def _handle_caravan_damage(ws, session: dict, msg: dict) -> None:
    """Ambush a caravan. Destroying it drops its cargo, tanks standing with the
    town it just LEFT, spawns a surviving driver, and — only when the cargo was
    rare — has a small chance to drop ONE bodyguard (never a scaling wave; that
    escalation belongs to the city watch, not the road)."""
    cid = str(msg.get("id", ""))
    amt = max(0, min(999, int(msg.get("amount", 0))))
    c = caravans.get(cid)
    if c is None or amt <= 0:
        return
    if not _caravan_is_attackable(c):
        await _send(ws, {"type": "chat", "username": "System",
                         "text": "The caravan is under town protection here."})
        return
    c["hp"] = max(0, c["hp"] - amt)
    _broadcast({"type": "caravan_hit", "id": cid, "hp": c["hp"],
                "max_hp": c["max_hp"], "amount": amt,
                "by": session["username"]})
    if c["hp"] > 0:
        return

    town = str(c.get("last_town", ""))
    had_rare = any(bool(it.get("rare")) for it in c.get("cargo", []))
    c["state"] = "wreck"
    c["timer"] = CARAVAN_WRECK_INTACT
    _broadcast({"type": "caravan_destroyed", "id": cid,
                "x": c["x"], "y": c["y"], "by": session["username"],
                "town": town, "rare": had_rare})

    # Cargo spills onto the road as world loot piles.
    for it in c.get("cargo", []):
        _spawn_pvp_pile(c["x"] + random.uniform(-40, 40),
                        c["y"] + random.uniform(-40, 40),
                        str(it["id"]), str(it["name"]), int(it["qty"]),
                        _color_for_item(str(it["id"])))
    # A surviving driver stumbles clear of the wreck.
    _broadcast({"type": "caravan_survivor", "id": cid,
                "x": c["x"] + random.uniform(-50, 50),
                "y": c["y"] + random.uniform(-50, 50),
                "name": random.choice(THRALL_NAMES)})
    # Rare cargo travelled with a bodyguard — one, never a wave.
    if had_rare and random.random() < CARAVAN_GUARD_CHANCE:
        gx = c["x"] + random.uniform(-60, 60)
        gy = c["y"] + random.uniform(-60, 60)
        eid = "g:" + secrets.token_hex(6)
        _broadcast({"type": "world_entity_add", "entity": {
            "id": eid, "kind": "monster", "subtype": "guard",
            "x": gx, "y": gy,
            "data": {"monster_type": "guard", "level": GUARD_BASE_LEVEL,
                     "guard": True}}})
        # Deliberately NOT registered in guard_owner: no alert, no escalation.
    # Standing consequence. A warband caravan's cargo is the WARBAND'S, so
    # raiding it makes you hostile to them — not to a town. A council caravan
    # costs you standing with the town it just left.
    wid = str(c.get("warband_id", ""))
    if wid:
        with _db() as conn:
            _wb_standing_add(conn, session["id"], wid, REP_WB_CARAVAN_RAID)
            wb = conn.execute("SELECT name FROM clans WHERE id=?", (wid,)).fetchone()
            conn.commit()
        await _send_reputation(ws, session["id"])
        await _send(ws, {"type": "chat", "username": "Server",
                         "text": f"You raided the {str(wb['nm']) if wb and 'nm' in wb.keys() else 'warband'}'s "
                                 f"caravan. They will not forget."
                         if wb else "You raided a warband caravan. They will not forget."})
        # Warn the owning warband's online members.
        with _db() as conn:
            members = conn.execute(
                "SELECT player_id FROM clan_members WHERE clan_id=?", (wid,)).fetchall()
        for m in members:
            mws = _ws_for_player(m["player_id"])
            if mws is not None:
                await _send(mws, {"type": "chat", "username": "Server",
                    "text": f"⚠ Your warband's caravan was raided by {session['username']}!"})
    elif town:
        with _db() as conn:
            _rep_add(conn, session["id"], town, REP_CARAVAN_RAID)
            conn.commit()
        await _send_reputation(ws, session["id"])
        await _send(ws, {"type": "chat", "username": "Server",
                         "text": f"You raided a {TOWN_NAMES.get(town, town)} "
                                 f"caravan. Word travels fast."})


def _warband_caravan_payout(c: dict) -> None:
    """A warband caravan reached a town safely — pay the owners: gold to the
    clan pool, warband standing with the arrival town, and occasionally a rare
    materials stack into the clan bank. Silent-fails on a bad clan row."""
    wid = str(c.get("warband_id", ""))
    town = str(c.get("next_town", ""))   # the town just reached
    if not wid:
        return
    gold = random.randint(WB_CARAVAN_PAY_MIN, WB_CARAVAN_PAY_MAX)
    mat = None
    try:
        with _db() as conn:
            row = conn.execute("SELECT gold, bank FROM clans WHERE id=?",
                               (wid,)).fetchone()
            if row is None:
                # Warband disbanded mid-run — retire the caravan.
                c["warband_id"] = ""
                return
            new_gold = int(row["gold"] or 0) + gold
            tabs = _clan_tabs(row["bank"])
            if random.random() < WB_CARAVAN_RARE_CHANCE:
                mid = random.choice(WB_CARAVAN_RARE_MATS)
                _clan_bank_add(tabs[0], mid, mid.replace("_", " ").title(),
                               random.randint(1, 3), _color_for_item(mid))
                mat = mid
            conn.execute("UPDATE clans SET gold=?, bank=? WHERE id=?",
                         (new_gold, json.dumps(tabs), wid))
            _warband_town_rep_add(conn, wid, town, WB_CARAVAN_TOWN_REP)
            conn.commit()
            members = conn.execute(
                "SELECT player_id FROM clan_members WHERE clan_id=?", (wid,)).fetchall()
    except Exception as e:
        print(f"[wb-caravan] payout failed for {wid}: {e!r}")
        return
    note = f"Your caravan reached {TOWN_NAMES.get(town, town)}: +{gold}g to the pool"
    if mat:
        note += f", +{mat.replace('_', ' ')} to the vault"
    note += "."
    for m in members:
        mws = _ws_for_player(m["player_id"])
        if mws is not None:
            asyncio.ensure_future(_send(mws, {"type": "chat",
                "username": "Server", "text": note}))
    # Refresh the clan panel (gold + bank moved).
    asyncio.ensure_future(_broadcast_clan_info(wid))


async def _handle_warband_caravan_create(ws, session: dict, msg: dict) -> None:
    """Leader-only — hire a warband caravan, paid from the clan gold pool."""
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        if cid is None:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "You're not in a warband."})
            return
        clan = conn.execute("SELECT leader_id, gold FROM clans WHERE id=?",
                            (cid,)).fetchone()
        if not clan or str(clan["leader_id"]) != session["id"]:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": "Only the warband leader can hire a caravan."})
            return
        active = sum(1 for c in caravans.values() if c.get("warband_id") == cid)
        if active >= WB_CARAVAN_CAP:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": f"Your warband already runs {WB_CARAVAN_CAP} caravans."})
            return
        if int(clan["gold"] or 0) < WB_CARAVAN_COST:
            await _send(ws, {"type": "chat", "username": "System",
                             "text": f"Need {WB_CARAVAN_COST}g in the clan pool to hire a caravan."})
            return
        conn.execute("UPDATE clans SET gold = gold - ? WHERE id=?",
                     (WB_CARAVAN_COST, cid))
        conn.commit()
    new_id = "wc:" + secrets.token_hex(5)
    # Start it a few stops along so it isn't stacked on a council caravan.
    caravans[new_id] = _caravan_init(new_id, random.randrange(len(CARAVAN_CIRCUIT)), cid)
    await _broadcast_clan_info(cid)
    await _send(ws, {"type": "chat", "username": "Server",
                     "text": "Your warband caravan sets out on the trade roads."})


async def _handle_warband_caravan_disband(ws, session: dict, msg: dict) -> None:
    """Leader-only — retire the warband's caravans (no refund)."""
    with _db() as conn:
        cid = _clan_id_for_player(conn, session["id"])
        clan = conn.execute("SELECT leader_id FROM clans WHERE id=?",
                            (cid,)).fetchone() if cid else None
    if cid is None or not clan or str(clan["leader_id"]) != session["id"]:
        await _send(ws, {"type": "chat", "username": "System",
                         "text": "Only the warband leader can recall a caravan."})
        return
    removed = 0
    for c in list(caravans.values()):
        if c.get("warband_id") == cid:
            _broadcast({"type": "caravan_remove", "id": c["id"]})
            caravans.pop(c["id"], None)
            removed += 1
    await _send(ws, {"type": "chat", "username": "Server",
                     "text": f"Recalled {removed} warband caravan(s)." if removed
                             else "Your warband has no caravans."})
# ── Killable town NPCs (Phase 5b) ────────────────────────────────────────────
# EVERY town NPC can be cut down — bankers and quest-givers included — so the
# respawn is deliberately QUICK: a dead service NPC must never soft-lock content
# for the whole server. Laying hands on one raises the city watch immediately
# (the third guard trigger); KILLING one costs standing with that NPC's town.
# Authoritative here, not on the client, so the rep hit can't be dodged.
NPC_MAX_HP      = 60
NPC_RESPAWN_SEC = 30.0
REP_NPC_KILL    = -350
# A town's walls/towers belong to it — smashing one is an act of war on the town.
REP_STRUCTURE_DESTROY = -400
REP_STRUCTURE_DAMAGE  = -30    # per-hit standing hit for attacking (not razing) a wall
STRUCTURE_HIT_COOLDOWN = 1.5   # seconds between a player's structure hits (anti-spam)
STRUCT_MELEE_REACH  = 64.0     # 2 tiles — a melee attacker must be AT the wall
STRUCT_RANGED_REACH = 240.0    # ranged / magic can strike the wall from range

# Town footprints for OWNERSHIP checks (walls/towers → which town). Padded 3
# tiles beyond _tile_is_town so a wall ring sitting just outside the town core
# still reads as that town's. Mirrors Ground._is_town — keep in sync.
_TOWN_TILE_BOUNDS = {
    "kjelvik":   (71, 96, 105, 128),
    "frostheim": (37, 50, 23, 36),
    "ironwood":  (105, 118, 149, 162),
    "eastmark":  (179, 192, 177, 190),
    "bjorn":     (240, 253, 132, 145),
}

# The static bounds above are just the town CORE (buildings). The admin-placed
# perimeter WALLS often ring out well past that core, and those walls are the
# real town limit — so we EXPAND each town's effective bounds to include every
# wall/gate/tower entity that clusters around its center. Without this, the
# outer wall ring falls outside the town → it isn't named "<Town> Wall" and
# attacking it fires no guards / no rep. Recomputed at boot + whenever a wall is
# placed / moved / removed. A wall is claimed by the NEAREST town center within
# this radius (towns are ~60 tiles apart, so this never cross-assigns).
TOWN_WALL_CLAIM_TILES = 40
_town_bounds_dyn: dict = {}   # tid -> (x0, x1, y0, y1) in tiles; walls-expanded


def _recompute_town_bounds() -> None:
    """Rebuild `_town_bounds_dyn` = each town's core bounds expanded to enclose
    every wall/gate/tower entity that clusters around it. Cheap; DB-backed."""
    global _town_bounds_dyn
    dyn = {tid: list(b) for tid, b in _TOWN_TILE_BOUNDS.items()}   # [x0,x1,y0,y1]
    try:
        with _db() as conn:
            rows = conn.execute(
                "SELECT subtype, x, y FROM world_entities").fetchall()
    except Exception as e:
        print(f"[town] bounds recompute failed: {e}")
        _town_bounds_dyn = {tid: tuple(b) for tid, b in dyn.items()}
        return
    r2 = TOWN_WALL_CLAIM_TILES * TOWN_WALL_CLAIM_TILES
    for r in rows:
        sub = str(r["subtype"] or "")
        if not any(h in sub for h in _WALL_SUBTYPE_HINTS):
            continue
        tx = int(float(r["x"]) // 32.0)
        ty = int(float(r["y"]) // 32.0)
        best, best_d = "", r2 + 1
        for tid, (cx, cy) in _TOWN_CENTER_TILE.items():
            d = (tx - cx) * (tx - cx) + (ty - cy) * (ty - cy)
            if d < best_d:
                best_d, best = d, tid
        if not best:
            continue   # a far-flung warband wall, not a town's
        b = dyn[best]
        b[0] = min(b[0], tx); b[1] = max(b[1], tx)
        b[2] = min(b[2], ty); b[3] = max(b[3], ty)
    _town_bounds_dyn = {tid: tuple(b) for tid, b in dyn.items()}


def _bounds_of(tid: str) -> tuple:
    """Effective (walls-expanded) tile bounds for a town, static fallback."""
    return _town_bounds_dyn.get(tid) or _TOWN_TILE_BOUNDS[tid]


def _town_at_world(x: float, y: float, margin: int = 3) -> str:
    """Which town owns a world position (walls/towers), or '' for none."""
    tx = int(x // 32.0)
    ty = int(y // 32.0)
    bounds = _town_bounds_dyn or _TOWN_TILE_BOUNDS
    for tid, (x0, x1, y0, y1) in bounds.items():
        if x0 - margin <= tx <= x1 + margin and y0 - margin <= ty <= y1 + margin:
            return tid
    return ""


def _town_world_bounds(tid: str, tile_margin: int = 0) -> tuple:
    """World AABB (x0, y0, x1, y1) for a town, expanded by `tile_margin` tiles.
    Used for guard spawn zones + the chase leash (town + 5 tiles)."""
    x0, x1, y0, y1 = _bounds_of(tid)
    m = tile_margin
    return ((x0 - m) * 32.0, (y0 - m) * 32.0,
            (x1 + 1 + m) * 32.0, (y1 + 1 + m) * 32.0)

# npc entity id ("n:N") -> {hp, max_hp, alive, respawn_at, name, town}
npc_state: dict = {}


def _npc_entry(nid: str, name: str) -> dict:
    """Lazily register an NPC the first time anyone swings at it — the client
    owns the roster, the server only tracks the ones that get hit."""
    st = npc_state.get(nid)
    if st is None:
        st = {"hp": NPC_MAX_HP, "max_hp": NPC_MAX_HP, "alive": True,
              "respawn_at": 0.0, "name": name, "town": _town_of_npc(name)}
        npc_state[nid] = st
    elif name and not st.get("name"):
        st["name"] = name
        st["town"] = _town_of_npc(name)
    return st


async def _handle_npc_damage(ws, session: dict, msg: dict) -> None:
    nid = str(msg.get("id", "")).strip()
    name = str(msg.get("name", "")).strip()
    amt = max(0, min(999, int(msg.get("amount", 0))))
    if not nid or amt <= 0:
        return
    st = _npc_entry(nid, name)
    if not st["alive"]:
        return
    st["hp"] = max(0, st["hp"] - amt)
    _broadcast({"type": "npc_hit", "id": nid, "hp": st["hp"],
                "max_hp": st["max_hp"], "amount": amt,
                "by": session["username"]})
    # Third guard trigger. _guard_alert no-ops outside the castle walls, so
    # roughing up a villager in an unwalled town brings no watch — guards only
    # exist in Kjelvik by design.
    _guard_alert(session["id"], float(session.get("x", 0.0)),
                 float(session.get("y", 0.0)), 1)
    if st["hp"] > 0:
        return
    st["alive"] = False
    st["respawn_at"] = time.time() + NPC_RESPAWN_SEC
    _broadcast({"type": "npc_died", "id": nid,
                "respawn_in": NPC_RESPAWN_SEC, "by": session["username"]})
    town = str(st.get("town", ""))
    if not town:
        return
    with _db() as conn:
        _rep_add(conn, session["id"], town, REP_NPC_KILL)
        conn.commit()
    await _send_reputation(ws, session["id"])
    await _send(ws, {"type": "chat", "username": "Server",
                     "text": f"You murdered {st['name']}. "
                             f"{TOWN_NAMES.get(town, town)} will remember this."})


async def _npc_respawn_loop() -> None:
    """Quick revival so a murdered banker/quest-giver is back fast."""
    while True:
        await asyncio.sleep(5.0)
        now = time.time()
        for nid, st in list(npc_state.items()):
            if st.get("alive", True) or now < float(st.get("respawn_at", 0.0)):
                continue
            st["alive"] = True
            st["hp"] = st["max_hp"]
            _broadcast({"type": "npc_respawned", "id": nid})


# ── Reputation (Phase 5a) ────────────────────────────────────────────────────
# Standing with each of the five towns. Sources so far: completing a town's
# quests (below). The four locked SINKS — attacking town guards/NPCs, looting
# caravans, encroaching on a town's border, raiding a town-allied warband —
# land in 5b/5c once guards and caravans exist; _rep_add is the single entry
# point they'll all call.
TOWN_NAMES = {
    "kjelvik":   "Kjelvik",
    "frostheim": "Frostheim",
    "ironwood":  "Ironwood Keep",
    "eastmark":  "Eastmark Post",
    "bjorn":     "Bjorn's Landing",
}
REP_FLOOR = -6000
REP_CEIL  = 12000
# (threshold, name) ascending — tier = the last entry whose threshold <= value.
REP_TIERS = [
    (REP_FLOOR, "Hated"), (-3000, "Hostile"), (-1000, "Unfriendly"),
    (0, "Neutral"), (1000, "Friendly"), (3000, "Honored"),
    (6000, "Revered"), (REP_CEIL, "Exalted"),
]
# Default standing granted for completing a town's quest (a quest may override
# with rewards.rep). The warband gets a quarter of it, so a member's deeds lift
# the whole warband's standing a little.
REP_PER_QUEST = 250
REP_WARBAND_SHARE = 4


def _rep_tier(value: int) -> str:
    name = REP_TIERS[0][1]
    for threshold, tname in REP_TIERS:
        if value >= threshold:
            name = tname
    return name


def _rep_next_threshold(value: int):
    """Next tier threshold above `value`, or None at max tier."""
    for threshold, _ in REP_TIERS:
        if value < threshold:
            return threshold
    return None


def _rep_effective(personal: int, warband: int) -> int:
    """A member's standing blends their own deeds with a share of their
    warband's — this is what makes warband actions move every member."""
    return max(REP_FLOOR, min(REP_CEIL, personal + warband // REP_WARBAND_SHARE))


def _rep_map(conn, table: str, key_col: str, key: str) -> dict:
    rows = conn.execute(
        f"SELECT town_id, value FROM {table} WHERE {key_col}=?", (key,)).fetchall()
    return {str(r["town_id"]): int(r["value"] or 0) for r in rows}


def _rep_add(conn, player_id: str, town_id: str, delta: int,
             share_to_warband: bool = True) -> None:
    """Single entry point for every reputation change. Clamps to the tier
    range and (optionally) credits a share to the player's warband."""
    if not town_id or town_id not in TOWN_NAMES or delta == 0:
        return
    cur = conn.execute(
        "SELECT value FROM reputation WHERE player_id=? AND town_id=?",
        (player_id, town_id)).fetchone()
    base = int(cur["value"] or 0) if cur else 0
    new_val = max(REP_FLOOR, min(REP_CEIL, base + delta))
    conn.execute(
        "INSERT INTO reputation (player_id, town_id, value) VALUES (?,?,?) "
        "ON CONFLICT(player_id, town_id) DO UPDATE SET value=excluded.value",
        (player_id, town_id, new_val))
    if not share_to_warband:
        return
    cid = _clan_id_for_player(conn, player_id)
    if cid is None:
        return
    wdelta = int(delta / REP_WARBAND_SHARE)
    if wdelta == 0:
        return
    wcur = conn.execute(
        "SELECT value FROM warband_reputation WHERE warband_id=? AND town_id=?",
        (cid, town_id)).fetchone()
    wnew = max(REP_FLOOR, min(REP_CEIL,
        (int(wcur["value"] or 0) if wcur else 0) + wdelta))
    conn.execute(
        "INSERT INTO warband_reputation (warband_id, town_id, value) VALUES (?,?,?) "
        "ON CONFLICT(warband_id, town_id) DO UPDATE SET value=excluded.value",
        (cid, town_id, wnew))


def _warband_town_rep_add(conn, warband_id: str, town_id: str, delta: int) -> None:
    """Move a warband's OWN standing with a town directly (no player share).
    Used by warband-caravan payouts, which credit the warband, not a player."""
    if not warband_id or town_id not in TOWN_NAMES or delta == 0:
        return
    cur = conn.execute(
        "SELECT value FROM warband_reputation WHERE warband_id=? AND town_id=?",
        (warband_id, town_id)).fetchone()
    new = max(REP_FLOOR, min(REP_CEIL, (int(cur["value"] or 0) if cur else 0) + delta))
    conn.execute(
        "INSERT INTO warband_reputation (warband_id, town_id, value) VALUES (?,?,?) "
        "ON CONFLICT(warband_id, town_id) DO UPDATE SET value=excluded.value",
        (warband_id, town_id, new))


def _wb_standing_add(conn, player_id: str, warband_id: str, delta: int) -> int:
    """Player↔warband standing (Phase 5c). Returns the new value."""
    if not player_id or not warband_id or delta == 0:
        return 0
    cur = conn.execute(
        "SELECT value FROM warband_standing WHERE player_id=? AND warband_id=?",
        (player_id, warband_id)).fetchone()
    new = max(REP_FLOOR, min(REP_CEIL, (int(cur["value"] or 0) if cur else 0) + delta))
    conn.execute(
        "INSERT INTO warband_standing (player_id, warband_id, value) VALUES (?,?,?) "
        "ON CONFLICT(player_id, warband_id) DO UPDATE SET value=excluded.value",
        (player_id, warband_id, new))
    return new


def _wb_standing_list(conn, player_id: str) -> list:
    """Every warband the player has a non-zero standing with, named + tiered."""
    rows = conn.execute(
        "SELECT ws.warband_id AS wid, ws.value AS val, c.name AS nm "
        "FROM warband_standing ws LEFT JOIN clans c ON c.id = ws.warband_id "
        "WHERE ws.player_id=? AND ws.value != 0", (player_id,)).fetchall()
    out = []
    for r in rows:
        v = int(r["val"] or 0)
        out.append({"id": str(r["wid"]), "name": str(r["nm"] or "A warband"),
                    "value": v, "tier": _rep_tier(v),
                    "floor": REP_FLOOR, "ceil": REP_CEIL})
    return out


def _reputation_payload(conn, player_id: str) -> dict:
    """Full standing snapshot for the client's Reputation tab."""
    personal = _rep_map(conn, "reputation", "player_id", player_id)
    cid = _clan_id_for_player(conn, player_id)
    warband = _rep_map(conn, "warband_reputation", "warband_id", cid) if cid else {}
    towns = []
    for tid in ALL_TOWN_IDS:
        p = int(personal.get(tid, 0))
        w = int(warband.get(tid, 0))
        eff = _rep_effective(p, w)
        holder = _warband_holding_town(conn, tid)
        towns.append({
            "id": tid, "name": TOWN_NAMES.get(tid, tid),
            "personal": p, "warband": w, "effective": eff,
            "tier": _rep_tier(eff),
            "next_at": _rep_next_threshold(eff),
            "floor": REP_FLOOR, "ceil": REP_CEIL,
            # True when the player's own warband holds this town's pledge.
            "held_by_us": bool(cid) and holder == cid,
        })
    return {"towns": towns, "in_warband": bool(cid),
            "warbands": _wb_standing_list(conn, player_id)}


async def _send_reputation(ws, player_id: str) -> None:
    with _db() as conn:
        payload = _reputation_payload(conn, player_id)
    payload["type"] = "reputation"
    await _send(ws, payload)


async def _handle_reputation_request(ws, session, msg: dict) -> None:
    await _send_reputation(ws, session["id"])


async def _handle_admin_rep(ws, session: dict, target: str, town_id: str,
                            amount: int) -> None:
    """/rep <player> <town> <amount> — owner/admin test grant."""
    if not _is_admin(session):
        return
    if town_id not in TOWN_NAMES:
        await _admin_confirm(ws, f"Unknown town {town_id!r}. "
                                 f"One of: {', '.join(ALL_TOWN_IDS)}")
        return
    with _db() as conn:
        row = conn.execute(
            "SELECT id FROM players WHERE username=? COLLATE NOCASE",
            (target,)).fetchone()
        if not row:
            await _admin_confirm(ws, f"No such player: {target}")
            return
        _rep_add(conn, row["id"], town_id, amount)
        conn.commit()
        tid = row["id"]
    tws = _ws_for_player(tid)
    if tws is not None:
        await _send_reputation(tws, tid)
    await _admin_confirm(ws, f"{amount:+d} {TOWN_NAMES[town_id]} rep to {target}.")


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
        if int(result.get("rep", 0)) and result.get("rep_town_name"):
            bits.append(f"+{int(result['rep'])} {result['rep_town_name']} standing")
        suffix = ""
        if result.get("diminished"):
            suffix = "  (boss repeat: XP only)"
        await _send(ws, {"type": "chat", "username": "Quests",
                         "text": f"« {q['title']} — Rewards: "
                                 + ", ".join(bits) + suffix})
        # Refresh the Reputation tab with the new standing.
        if int(result.get("rep", 0)):
            await _send_reputation(ws, session["id"])
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
    # The watch's penalty is death ONCE: stand it down + hold a cooldown so guards
    # don't instantly re-spawn and re-kill the offender when they respawn in the
    # same hostile town (the death-loop live bug).
    pid = session["id"]
    if guard_alerts.get(pid) is not None:
        _guard_clear(pid)
        session["watch_cooldown_until"] = time.time() + WATCH_COOLDOWN
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
        # ⑧ — let the dying player RECOVER their own death drops (the server
        # already removed them from the DB): add them to the grant ledger so the
        # save-ceiling permits re-picking them up (client-side) up to what dropped.
        _grant_to_session(session, iid, str(it.get("name", iid)),
                          it.get("color", [0.7, 0.7, 0.7, 1.0]), "", 0,
                          int(it.get("qty", 1)))
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
    # ⑧ — the item left the DB; add it to the grant ledger so the dropper can
    # pick their OWN drop back up (client-side) without the save-ceiling capping
    # it. Others picking it up are capped (cross-player giving → use trade).
    _grant_to_session(session, item_id, item_name, color, "", 0, removed)
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
    # Spectators aren't interest-filtered (their camera position isn't tracked
    # server-side), so they get every near-broadcast — mob deaths/respawns,
    # node locks/depletes, loot piles — keeping the recorded world fully live.
    for ws in list(spectators):
        if ws is exclude_ws:
            continue
        asyncio.ensure_future(_safe_send(ws, data))


## Generic "mime an action" relay (v1.6.5). A client (e.g. a content bot) tells
## nearby clients — importantly the recording spectator — that it's doing
## something the server doesn't otherwise broadcast, so the watched avatar's HUD
## can OPEN the matching window on camera (banking / crafting) at the right moment
## instead of guessing from delayed save state. Allowed actions are whitelisted.
_MIME_ACTIONS = {"bank", "craft", "cook", "smith", "gather"}


async def _handle_player_mime(ws, session: dict, msg: dict) -> None:
    action = str(msg.get("action", ""))
    if action not in _MIME_ACTIONS:
        return
    x = float(msg.get("x", session.get("x", 0.0)))
    y = float(msg.get("y", session.get("y", 0.0)))
    out = {"type": "player_action", "id": session["id"],
           "action": action, "x": x, "y": y}
    if action == "gather":
        # Carry the tool so the spectated avatar swings the right implement
        # (axe/pick/rod/bare-hand) when a bot re-broadcasts its gather swing.
        out["tool"] = str(msg.get("tool", ""))
    _broadcast_near(x, y, out, exclude_ws=ws)


_SPECTATE_EVENT_KINDS = {"xp", "level", "item",
                         "combat", "combat_start", "combat_end"}


async def _send_spectate_event(username: str, payload: dict) -> None:
    """Relay one per-action feedback event ONLY to the spectators watching
    `username`, so the recording spectator replays the exact floating toast the
    real client would show (per-action, never batched)."""
    watching = [ws for ws, spec in list(spectators.items())
                if str(spec.get("target", "")).lower() == username.lower()]
    # DIAGNOSTIC: show whether the event found a spectator to relay to. If this
    # says 0 while a spectator is recording, the target name doesn't match the
    # bot's session username (the relay's dead hop).
    print(f"[spectate_event] relay '{payload.get('kind')}' from '{username}' → "
          f"{len(watching)} watcher(s); targets={[str(s.get('target','')) for s in spectators.values()]}")
    # BUGFIX: _safe_send does `ws.send(data)` which needs a JSON STRING. Passing the
    # raw dict raised a TypeError that _safe_send swallowed — so the relay logged a
    # watcher but NOTHING was ever sent (no toasts/combat on the spectator). Use
    # `_send`, which json.dumps for us (matches every other caller).
    for ws in watching:
        await _send(ws, payload)


async def _handle_spectate_event(ws, session: dict, msg: dict) -> None:
    """A directed content bot reports a real-player action (xp/level/item) so the
    spectator can fire the matching floating toast the instant it happens."""
    kind = str(msg.get("kind", ""))
    # DIAGNOSTIC: prove the event reached the server from the bot.
    print(f"[spectate_event] recv from session={session.get('username') if session else None} "
          f"kind={kind} msg={msg}")
    if kind not in _SPECTATE_EVENT_KINDS:
        return
    payload = {"type": "spectate_event", "kind": kind}
    if kind == "xp":
        payload["skill"] = str(msg.get("skill", ""))
        payload["amount"] = int(msg.get("amount", 0))
        if payload["amount"] <= 0 or not payload["skill"]:
            return
    elif kind == "level":
        payload["skill"] = str(msg.get("skill", ""))
        payload["level"] = int(msg.get("level", 0))
        if payload["level"] <= 0 or not payload["skill"]:
            return
    elif kind == "item":
        payload["name"] = str(msg.get("name", ""))
        payload["qty"] = int(msg.get("qty", 1))
        if not payload["name"]:
            return
    elif kind == "combat":
        payload["name"] = str(msg.get("name", "monster"))
        payload["amount"] = int(msg.get("amount", 0))
        payload["mine"] = bool(msg.get("mine", True))
        payload["mx"] = float(msg.get("mx", 0.0))
    elif kind == "combat_start":
        payload["name"] = str(msg.get("name", "monster"))
        payload["level"] = int(msg.get("level", 0))
        payload["mx"] = float(msg.get("mx", 0.0))
    elif kind == "combat_end":
        payload["name"] = str(msg.get("name", "monster"))
        payload["result"] = str(msg.get("result", "win"))
    await _send_spectate_event(session["username"], payload)


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
    # Lock it to this player. `locked_at` = anti-spam floor so a cheater can't
    # fire gather_complete instantly (B2a).
    nodes_state[eid] = {"x": x, "y": y, "depleted_until": 0.0,
                        "lock": session["id"], "locked_at": now}
    # Admin gatherables wander on respawn — seed the anchor from the placed position
    # (first gather = placement, before any wander) so it re-rolls around it, no drift.
    if eid.startswith("a:") and eid not in admin_node_anchor:
        admin_node_anchor[eid] = (x, y)
    await _send(ws, {"type": "gather_grant", "id": eid})
    _broadcast_near(x, y, {"type": "node_locked", "id": eid, "x": x, "y": y,
                           "username": session["username"]}, exclude_ws=ws)
    # Animate the gatherer for nearby clients (incl. the recording spectator) —
    # they see the player SWING at the node for a few seconds instead of standing
    # motionless while it gathers (v1.6.4).
    _broadcast_near(x, y, {"type": "player_action", "id": session["id"],
                           "action": "gather", "x": x, "y": y,
                           "tool": str(msg.get("tool", ""))}, exclude_ws=ws)


# Anti-spam floor: a real gather is seconds of swinging. Reject completes that
# arrive faster than this after the lock (B2a).
_MIN_GATHER_SECONDS = 2.0


# ── ⑥ Gather SECONDARIES (server-rolled) ─────────────────────────────────────
# The client used to roll these in Interactable._deplete (essence→magic bonus XP,
# herb→forage seed, rock≥30→gem+jewelcrafting XP). Now the SERVER rolls them so
# they can't be faked. Seed odds come from the baked `_forage_seeds` table
# (uploaded with the node map — no Python dual-maintenance); the gem weights are
# a tiny fixed ladder mirrored from Interactable._roll_mining_gem.
_GEM_NAMES = {"opal": "Opal", "amethyst": "Amethyst", "diamond": "Diamond"}
_GEM_COLS = {"opal": [0.82, 0.90, 0.95, 1.0], "amethyst": [0.62, 0.38, 0.85, 1.0],
             "diamond": [0.85, 0.95, 1.00, 1.0]}


def _roll_mining_gem(rock_lv: int) -> str:
    if random.random() > 0.05:
        return ""
    r = random.random()
    if rock_lv >= 85:
        return "diamond" if r < 0.35 else ("amethyst" if r < 0.75 else "opal")
    if rock_lv >= 70:
        return "diamond" if r < 0.12 else ("amethyst" if r < 0.55 else "opal")
    if rock_lv >= 50:
        return "amethyst" if r < 0.25 else "opal"
    return "amethyst" if r < 0.08 else "opal"


def _roll_forage_seed() -> dict:
    """Mirror of Farming.roll_forage_seed: iterate seeds high→low level, each
    with a 1-in-(5·1.0606^lv) chance; first hit wins. Table is baked."""
    seeds = node_drops.get("_forage_seeds", [])
    if not isinstance(seeds, list):
        return {}
    for s in sorted(seeds, key=lambda x: int(x.get("lv", 1)), reverse=True):
        lv = int(s.get("lv", 1))
        if random.random() < 1.0 / (5.0 * (1.0606 ** lv)):
            return s
    return {}


def _gather_secondaries(session: dict, gdef: dict) -> list:
    """Return extra gather_reward payloads (item and/or XP) for a baked node,
    based on its `type` + `level` + the player's Magic level."""
    out = []
    ntype = str(gdef.get("type", ""))
    level = int(gdef.get("level", 1))
    if ntype == "essence":
        mlv = _calc_level(session.get("skill_xp", {}).get("magic", 0))
        out.append({"drop_id": "", "drop_name": "", "color": [0.7, 0.7, 0.7, 1.0],
                    "skill": "magic", "xp": min(30, 5 + mlv // 4)})
    elif ntype == "herb":
        s = _roll_forage_seed()
        if s:
            out.append({"drop_id": str(s.get("seed", "")),
                        "drop_name": str(s.get("seed_name", "")),
                        "color": s.get("color", [0.7, 0.7, 0.4, 1.0]),
                        "skill": "", "xp": 0})
    elif ntype == "rock" and level >= 30:
        gem = _roll_mining_gem(level)
        if gem:
            out.append({"drop_id": gem, "drop_name": _GEM_NAMES.get(gem, gem),
                        "color": _GEM_COLS.get(gem, [0.7, 0.7, 0.7, 1.0]),
                        "skill": "jewelcrafting", "xp": 5})
    return out


def _grant_to_session(session: dict, item_id: str, item_name: str, color,
                      skill: str, xp: int, qty: int = 1) -> None:
    """⑧ — record a PUSH-ONLY grant (gather/loot/farm) in the per-session grant
    LEDGER. The save (_handle_save) validates the client's inventory/XP against
    (previous save + this ledger) and caps anything above it — blocking item/XP
    injection while letting all removals/moves (eat/drop/equip) through untouched.
    (Direct-DB grants like craft/fishing/sea/shop/quest are already in `previous`,
    so they DON'T feed this ledger — that would double-count.)"""
    if item_id and qty > 0:
        gi = session.setdefault("grant_inv", {})
        gi[item_id] = int(gi.get(item_id, 0)) + int(qty)
    if skill and xp > 0:
        gx = session.setdefault("grant_xp", {})
        gx[skill] = int(gx.get(skill, 0)) + int(xp)


async def _handle_gather_complete(ws, session: dict, msg: dict) -> None:
    eid = str(msg.get("id", ""))
    st = nodes_state.get(eid)
    if st is None or st["lock"] != session["id"]:
        return  # not the locking player — ignore
    now = time.time()
    # SERVER decides the drop (B2a). Prefer the BAKED map; fall back to the
    # client's claim whenever the bake has no entry (pre-bake OR a node the bake
    # missed) so gathering NEVER breaks. NOTE: the anti-spam + skill gates were
    # PULLED — they false-rejected legit gathers (stale cached skill_xp / lock
    # timing), same failure mode as combat's range gate. Re-add as tuned
    # hardening once verified they don't drop real gathers.
    gdef = node_drops.get(eid)
    if gdef and str(gdef.get("drop_id", "")):
        drop_id   = str(gdef.get("drop_id", ""))
        drop_name = str(gdef.get("drop_name", drop_id))
        skill     = str(gdef.get("skill", ""))
        xp        = int(gdef.get("xp", 0))
        color     = gdef.get("color", [0.7, 0.7, 0.7, 1.0])
        regen     = max(1.0, float(gdef.get("regen", 30.0)))
    else:
        drop_id   = str(msg.get("drop_id", "")).strip()
        drop_name = str(msg.get("drop_name", drop_id)).strip()
        skill     = str(msg.get("skill", "")).strip()
        xp        = max(0, int(msg.get("xp", 0)))
        color     = msg.get("color", [0.7, 0.7, 0.7, 1.0])
        regen     = max(1.0, float(msg.get("regen", 30.0)))
    # Deplete + SERVER-timed regen (was client-supplied — cheatable).
    st["lock"] = None
    st["depleted_until"] = now + regen
    _broadcast_near(st["x"], st["y"],
                    {"type": "node_depleted", "id": eid, "respawn_in": regen},
                    exclude_ws=ws)
    # Push the reward — the client adds EXACTLY this (it no longer mints its own).
    if drop_id:
        await _send(ws, {"type": "gather_reward", "id": eid, "ok": True,
                         "drop_id": drop_id, "drop_name": drop_name,
                         "skill": skill, "xp": xp, "color": color})
        _grant_to_session(session, drop_id, drop_name, color, skill, xp)  # ⑧ session feed
        # ⑥ — server-rolled secondaries (essence magic XP / herb seed / rock gem).
        # Only for BAKED nodes (gdef known); each is pushed as its own reward the
        # client applies. Un-baked nodes skip these (authoritative post-bake).
        if gdef:
            for sec in _gather_secondaries(session, gdef):
                await _send(ws, {"type": "gather_reward", "id": eid, "ok": True,
                                 "drop_id": str(sec.get("drop_id", "")),
                                 "drop_name": str(sec.get("drop_name", "")),
                                 "skill": str(sec.get("skill", "")),
                                 "xp": int(sec.get("xp", 0)),
                                 "color": sec.get("color", [0.7, 0.7, 0.7, 1.0])})
                _grant_to_session(session, str(sec.get("drop_id", "")),
                                  str(sec.get("drop_name", "")),
                                  sec.get("color", [0.7, 0.7, 0.7, 1.0]),
                                  str(sec.get("skill", "")), int(sec.get("xp", 0)))
        if _quest_progress(session["id"], "gather", drop_id, 1):
            await _push_quest_state(ws, session)
    else:
        print(f"[gather] no drop resolved for {eid} "
              f"(baked={eid in node_drops}) — client sent {msg.get('drop_id', '?')!r}")


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
    """Tag a monster for persistence flush. O(1) — set membership. GUARDS ('g:')
    are ephemeral watch entities — NEVER persist them, or thousands reload on boot
    as unkillable orphans (the death-swarm live bug)."""
    if mid and not mid.startswith("g:"):
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
        guard_rows = 0
        for r in rows:
            mid = str(r["monster_id"])
            if mid.startswith("g:"):
                # Guards must never persist; scrub any that slipped into the table
                # so they can't reload as an unkillable swarm.
                guard_rows += 1
                continue
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
        if guard_rows:
            with _db() as conn:
                conn.execute("DELETE FROM monster_state WHERE monster_id LIKE 'g:%'")
                conn.commit()
            print(f"[boot] scrubbed {guard_rows} stray guard row(s) from monster_state")
        if rows:
            print(f"[boot] loaded {len(rows) - guard_rows} monster_state row(s) from SQLite")
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
            # kc:N are the client-generated castle walls (not in world_entities);
            # they're re-seeded at boot, but keep any persisted damaged HP.
            if eid not in existing and not eid.startswith("kc:"):
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

# STANDOFF (v1.7 combat-feel) — a monster stops a body-width short of the player
# so their sprites don't overlap (they'd draw on top of each other). The monster
# chases toward a point `standoff` px BEFORE the player instead of onto them.
# standoff = monster body (size) + player half + small gap; always kept a few px
# INSIDE melee reach (20 + size), so the monster can still land its hit from here.
_PLAYER_BODY_HALF       = 14.0
_MONSTER_STANDOFF_GAP   = 3.0     # the 2–4 px visual gap the user asked for

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
    # slim dragons (V1.5.4) — between large and giant
    "drake": 26, "wyvern": 28,
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

# Placed structures (walls/towers/gates) aren't in terrain.bin, so a monster used
# to walk straight through a town wall. We cache the set of TILES covered by live
# blocking structures and reject a land-monster step onto one. Rebuilt on a short
# timer from `structures_state` (cheap; membership test is O(1) per step).
_struct_blocked_tiles: set = set()
_struct_blocked_at: float = 0.0
STRUCT_BLOCK_REFRESH = 2.0   # secs — picks up new/destroyed walls within this


def _refresh_struct_blocked_tiles(now: float) -> None:
    """Rebuild the blocked-tile set from live structures if the cache is stale.
    Called once per monster-AI tick, not per monster."""
    global _struct_blocked_at, _struct_blocked_tiles
    if now - _struct_blocked_at < STRUCT_BLOCK_REFRESH:
        return
    _struct_blocked_at = now
    tiles: set = set()
    for st in structures_state.values():
        if not st.get("alive", True):
            continue
        sub = st.get("subtype", "")
        if sub not in _STRUCTURE_SIZES:
            continue
        w, h = _STRUCTURE_SIZES[sub]
        cx, cy = float(st.get("x", 0.0)), float(st.get("y", 0.0))
        tx0 = int((cx - w / 2.0) // 32)
        tx1 = int((cx + w / 2.0 - 0.001) // 32)
        ty0 = int((cy - h / 2.0) // 32)
        ty1 = int((cy + h / 2.0 - 0.001) // 32)
        for tx in range(tx0, tx1 + 1):
            for ty in range(ty0, ty1 + 1):
                tiles.add((tx, ty))
    _struct_blocked_tiles = tiles


def _monster_can_step(monster_type: str, x: float, y: float) -> bool:
    """Movement gate for monsters. Land monsters accept passable terrain tiles;
    water-only monsters (WATER_ONLY_MONSTERS) accept impassable (water) tiles. In
    BOTH cases land monsters must also NOT step onto a placed wall/structure tile
    (walls aren't in terrain.bin). No bitmap loaded → terrain check is a no-op."""
    if monster_type not in WATER_ONLY_MONSTERS:
        if (int(x // 32), int(y // 32)) in _struct_blocked_tiles:
            return False       # a town/player wall is here — don't walk through it
    if not terrain.is_loaded():
        return True
    passable = terrain.is_passable(x, y)
    if monster_type in WATER_ONLY_MONSTERS:
        return not passable
    return passable


## Per-monster-type attack profile — starter set of ranged/magic mobs.
## Missing entries → defaults to melee (attack_range 32, no projectile).
## Values must stay in sync with client Monster.gd's _apply_type_stats.
_MONSTER_ATTACK: dict = {
    "bandit": {
        "style": "ranged", "range": 200,
        "color": [0.90, 0.85, 0.65],
    },
    "fire_imp": {
        "style": "magic", "range": 220,
        "color": [1.00, 0.50, 0.10],
    },
    "nidhogg": {
        "style": "magic", "range": 260,
        "color": [1.00, 0.60, 0.15],
        "spread_orbs": 3,  # visual only — 3 orbs in a tight spread
    },
    "drake": {
        "style": "magic", "range": 220,
        "color": [1.00, 0.60, 0.15],
    },
    "wyvern": {
        "style": "magic", "range": 240,
        "color": [0.60, 0.95, 0.35],
    },
}
_ATTACK_STYLE_DEFAULT = "melee"
_ATTACK_RANGE_DEFAULT = 32


def _monster_attack_profile(monster_type: str) -> dict:
    return _MONSTER_ATTACK.get(monster_type, {
        "style": _ATTACK_STYLE_DEFAULT,
        "range": _ATTACK_RANGE_DEFAULT,
        "color": [1.0, 1.0, 1.0],
    })


## Line-of-sight test between two world points. Samples every 16 px along
## the segment; if any sample lands on an impassable tile (water / hill /
## cliff / wall via the bitmap) the shot is blocked. `terrain.is_loaded()`
## must be true — without a baked bitmap we have no obstacle data, so
## return True (assume clear).
_LOS_STEP_PX = 16.0

def _los_clear(x0: float, y0: float, x1: float, y1: float) -> bool:
    if not terrain.is_loaded():
        return True
    dx = x1 - x0
    dy = y1 - y0
    dist = (dx * dx + dy * dy) ** 0.5
    if dist < 0.5:
        return True
    steps = max(1, int(dist / _LOS_STEP_PX))
    for i in range(1, steps):  # skip endpoints
        t = i / steps
        sx = x0 + dx * t
        sy = y0 + dy * t
        if not terrain.is_passable(sx, sy):
            return False
    return True


## 8-direction chase candidate offsets — used when the direct step is
## blocked. Ordered from smallest deviation (±22.5°) outward so the
## monster prefers the straightest detour. Applied on the intended
## step vector via 2D rotation.
_CHASE_DETOUR_ANGLES = [
    0.3927,   -0.3927,     # ±22.5°
    0.7854,   -0.7854,     # ±45°
    1.1781,   -1.1781,     # ±67.5°
    1.5708,   -1.5708,     # ±90°
]


def _try_chase_step(monster_type: str, cx: float, cy: float,
                    tx: float, ty: float, step: float) -> tuple:
    """Advance from (cx, cy) toward (tx, ty) by up to `step` px, trying
    a widening cone of alternative directions when the direct path is
    blocked. Returns the chosen (new_x, new_y). If nothing works, stays
    put — the caller may fall back to an attack-in-place decision."""
    import math as _math
    dx = tx - cx
    dy = ty - cy
    d = (dx * dx + dy * dy) ** 0.5
    if d < 0.001:
        return cx, cy
    ux = dx / d
    uy = dy / d
    # Direct step first.
    for ang in [0.0] + _CHASE_DETOUR_ANGLES:
        cos_a = _math.cos(ang)
        sin_a = _math.sin(ang)
        rx = ux * cos_a - uy * sin_a
        ry = ux * sin_a + uy * cos_a
        nx = cx + rx * step
        ny = cy + ry * step
        if _monster_can_step(monster_type, nx, ny):
            # Bonus: this candidate must ALSO not increase distance to
            # the target — reject purely backward detours.
            new_d2 = (tx - nx) * (tx - nx) + (ty - ny) * (ty - ny)
            if new_d2 <= d * d:
                return nx, ny
    return cx, cy


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
    # Guards ('g:') are server-owned watch entities. A client must NEVER be able to
    # register one as a fightable monster — doing so seeds it into monsters_state,
    # where the AI loop then makes it ATTACK the nearest player (the "guards help
    # kill the mob then kill me inside town" bug). The watch is not a combat target.
    if mid.startswith("g:"):
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
    # City watch (Phase 5b): guards are spawned specifically TO engage an
    # offender, so they lock on the moment their AI registers — the client
    # seeds them with seed_only=True (no aggro), which would otherwise leave
    # them standing around idle.
    elif _is_guard_entity(mid) and st.get("alive", True):
        offender = guard_owner.get(mid, "")
        osess = next((s for s in sessions.values() if s.get("id") == offender), None)
        if osess is not None:
            st["state"] = "aggro"
            st["target_player"] = osess["username"]
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
    # Attack COOLDOWN — a 1.5s buffer per player so a wall can't be spam-clicked to
    # dust in a second (v1.6.2). Authoritative; throttles both damage + the toast.
    now = time.time()
    if now - float(session.get("struct_hit_at", 0.0)) < STRUCTURE_HIT_COOLDOWN:
        return
    session["struct_hit_at"] = now
    # Reach by attack STYLE: melee must be within 2 tiles of the wall edge; ranged /
    # magic reach further. Out of range → a "get closer" toast + no damage.
    size = _STRUCTURE_SIZES.get(st["subtype"], (32, 32))
    half_w = size[0] / 2.0
    half_h = size[1] / 2.0
    p_x = float(session.get("x", 0.0))
    p_y = float(session.get("y", 0.0))
    style = str(msg.get("style", "melee"))
    reach = STRUCT_RANGED_REACH if style in ("ranged", "magic") else STRUCT_MELEE_REACH
    # Distance to nearest hitbox edge (0 if inside, positive if outside).
    dx = max(0.0, abs(p_x - st["x"]) - half_w)
    dy = max(0.0, abs(p_y - st["y"]) - half_h)
    if dx * dx + dy * dy > reach * reach:
        await _send(ws, {"type": "toast",
                         "text": "Get closer to attack the "
                                 + str(st.get("subtype", "wall")).replace("_", " ") + "."})
        return
    st["hp"] = max(0, st["hp"] - amt)
    st["last_damaged_at"] = time.time()   # pauses the town auto-repair (v1.6.2)
    _mark_structure_dirty(eid)
    _broadcast({"type": "structure_hp_changed", "id": eid,
                "hp": st["hp"], "max_hp": st["max_hp"], "alive": st["alive"]})
    # Attacking a town's wall/tower is aggression — bring its watch + hit standing.
    town = _town_at_world(float(st["x"]), float(st["y"]))
    if town:
        # Alert from the WALL's position (which is inside the town) — the attacker
        # may stand just outside the town margin, which would no-op the alert.
        _guard_alert(session["id"], float(st["x"]), float(st["y"]), 1)
        # Per-hit rep hit for attacking (throttled so a click flurry doesn't nuke
        # standing instantly). The killing blow gives the bigger DESTROY hit below.
        now = time.time()
        if st["hp"] > 0 and now - float(session.get("wall_rep_at", 0.0)) >= 3.0:
            session["wall_rep_at"] = now
            with _db() as conn:
                _rep_add(conn, session["id"], town, REP_STRUCTURE_DAMAGE)
                conn.commit()
            await _send_reputation(ws, session["id"])
    if st["hp"] <= 0 and st.get("alive", True):
        st["alive"] = False
        _mark_structure_dirty(eid)
        _broadcast({"type": "structure_destroyed", "id": eid})
        print(f"[structure] {session['username']} destroyed "
              f"{st['subtype']} ({eid}) at ({st['x']:.0f},{st['y']:.0f})")
        # A town's walls/towers belong to it — destroying one tanks your
        # standing there (v1.5.3).
        if town:
            with _db() as conn:
                _rep_add(conn, session["id"], town, REP_STRUCTURE_DESTROY)
                conn.commit()
            await _send_reputation(ws, session["id"])
            await _send(ws, {"type": "chat", "username": "Server",
                             "text": f"You razed {TOWN_NAMES.get(town, town)}'s "
                                     f"defences. They won't forget it."})


# ── v1.7 B1: SERVER-AUTHORITATIVE combat damage ──────────────────────────────
# The client no longer sends a damage number — it sends an attack INTENT (id +
# style). The server computes the hit here: fresh formula from the attacker's
# combat level + weapon tier vs the monster's level, with server-owned miss/crit.
_WEAPON_TIERS = ["copper", "bronze", "iron", "steel", "black", "mithril",
                 "adamant", "rune", "runite", "dragon", "frost", "ancient"]


def _weapon_tier(weapon_id: str) -> int:
    """0 (unarmed) .. N — parsed from the weapon id keyword. Cheap stand-in for a
    full gear-stats mirror; the id already encodes the material tier."""
    wl = str(weapon_id).lower()
    tier = 0
    for i, kw in enumerate(_WEAPON_TIERS):
        if kw in wl:
            tier = i + 1
    return tier


def _combat_level_of(skill_xp: dict) -> int:
    return max(_calc_level(skill_xp.get("melee", 0)),
              _calc_level(skill_xp.get("ranged", 0)),
              _calc_level(skill_xp.get("magic", 0)))


def _infer_attack_style(session: dict) -> str:
    wl = str(session.get("equipment", {}).get("weapon", "")).lower()
    if "bow" in wl or "sling" in wl:
        return "ranged"
    if "staff" in wl or "wand" in wl:
        return "magic"
    return "melee"


def _compute_player_hit(session: dict, style: str, st: dict) -> dict:
    """Fresh damage formula (tunable). Returns {amount, crit, missed}."""
    sx = session.get("skill_xp", {}) or {}
    skill_key = style if style in ("melee", "ranged", "magic") else "melee"
    lv = _calc_level(sx.get(skill_key, 0))
    wtier = _weapon_tier(session.get("equipment", {}).get("weapon", ""))
    mlevel = int(st.get("level", 1) or 1)
    # Base attack: floor + level scaling + weapon-tier bonus.
    base_atk = 2.0 + lv * 0.9 + wtier * 2.5
    # Defence mitigation (soft-capped so high-level mobs aren't immune).
    mdef = mlevel * 0.8
    mitig = mdef / (mdef + base_atk + 8.0)
    dmg = base_atk * (1.0 - 0.6 * mitig)
    dmg *= random.uniform(0.80, 1.0)
    # Level-gap penalty — swinging far above your combat level guts damage.
    gap = mlevel - _combat_level_of(sx)
    if gap > 8:
        dmg *= max(0.05, 1.0 - (gap - 8) * 0.10)
    # Hit chance from level + weapon vs monster level.
    hit_chance = min(0.95, max(0.15,
                     0.60 + lv * 0.004 + wtier * 0.02 - mlevel * 0.006))
    if random.random() > hit_chance:
        return {"amount": 0, "crit": False, "missed": True}
    crit = random.random() < 0.08
    if crit:
        dmg *= 1.5
    return {"amount": max(1, int(round(dmg))), "crit": crit, "missed": False}


# Anti-spam floor between a player's swings (below the ~2s legit cadence; leaves
# slack for latency). A cheater firing every tick is clamped to this.
_PLAYER_ATTACK_MIN_GAP = 1.1


async def _handle_monster_damage(ws, session: dict, msg: dict) -> None:
    mid = str(msg.get("id", ""))
    st = monsters_state.get(mid)
    if st is None or not st["alive"]:
        return
    style = str(msg.get("style", "")).strip().lower()
    if style not in ("melee", "ranged", "magic"):
        style = _infer_attack_style(session)
    # NOTE: range + attack-cooldown gates were pulled out of B1 — they were
    # false-rejecting legit swings (position-sync slop). The core anti-cheat is
    # that damage is SERVER-COMPUTED below (client can't inject a number). Re-add
    # range/cooldown as a hardening pass once verified they don't drop real hits.
    # A very loose sanity cap only: ignore an attack from absurdly far (stale id).
    dx = float(session.get("x", 0.0)) - float(st["x"])
    dy = float(session.get("y", 0.0)) - float(st["y"])
    if dx * dx + dy * dy > 4000.0 * 4000.0:
        return
    # ⑦/⑧ — per-swing XP into the grant LEDGER, mirroring the client's HUD grant so
    # the save validates it. The client sends the amount (magic's rune-scaled per-hit
    # goes up to ~84); we CLAMP it [0,100] so it's a ceiling, not a blank cheque.
    _swing_xp = max(0, min(int(msg.get("xp", 4)), 100))
    _gx = session.setdefault("grant_xp", {})
    _gx[style] = int(_gx.get(style, 0)) + _swing_xp
    _gx["defense"] = int(_gx.get("defense", 0)) + 1
    hit = _compute_player_hit(session, style, st)
    amt = int(hit["amount"])
    pid = session["id"]
    if pid not in st["participants"]:
        if len(st["participants"]) >= MAX_FIGHTERS:
            return
        st["participants"].append(pid)
        st["damage"].setdefault(pid, 0)
    if amt > 0:
        st["hp"] = max(0, st["hp"] - amt)
        st["damage"][pid] = st["damage"].get(pid, 0) + amt
    # Striking the watch keeps the alert hot (Phase 5b) so it doesn't decay
    # out from under an ongoing fight.
    if _is_guard_entity(mid):
        alert = guard_alerts.get(guard_owner.get(mid, ""))
        if alert is not None:
            alert["last_at"] = time.time()
    _broadcast_near(st["x"], st["y"],
                    {"type": "monster_hit", "id": mid, "x": st["x"], "y": st["y"],
                     "amount": amt, "crit": bool(hit["crit"]),
                     "missed": bool(hit["missed"]), "by": session["username"],
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
    # ⑦/⑧ — record the kill XP in each recipient's grant LEDGER (melee + defense·0.3
    # + vitality·0.3, mirroring the client's _on_mob_died split) so the save can
    # validate it. Same values the client applies, so the ceiling matches exactly.
    _kd = max(1, int(xp_each * 0.3))
    for _pid in xp_recipient_pids:
        _pws = _ws_for_player(_pid)
        _sess = sessions.get(_pws) if _pws is not None else None
        if _sess is not None:
            _gx = _sess.setdefault("grant_xp", {})
            _gx["melee"] = int(_gx.get("melee", 0)) + xp_each
            _gx["defense"] = int(_gx.get("defense", 0)) + _kd
            _gx["vitality"] = int(_gx.get("vitality", 0)) + _kd
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
    # v1.7 B3 — SERVER rolls the KILLER's item loot (was client-rolled) and pushes
    # it. If unbaked, tell the killer to fall back to its own roll so loot never
    # breaks pre-bake. Guards drop no loot (matches the client).
    if killer_pid is not None and not _is_guard_entity(mid):
        kws = _ws_for_player(killer_pid)
        if kws is not None:
            mloot = monster_loot.get(mtype)
            if mloot:
                rewards = list(mloot.get("loot", []))
                boot = mloot.get("boot")
                if boot and random.random() < float(boot.get("chance", 0.0)):
                    rewards.append(boot)
                gem = mloot.get("gem")
                if gem and random.random() < float(gem.get("chance", 0.0)):
                    rewards.append(gem)
                soul = monster_loot.get("_soul", {})
                if random.random() < float(soul.get("chance", 0.5)):
                    for tier in soul.get("tiers", []):
                        if int(st.get("level", 1)) < int(tier[0]):
                            rewards.append({"id": tier[1], "name": tier[2], "color": tier[3]})
                            break
                ksess = sessions.get(kws)
                for r in rewards:
                    rid = str(r.get("id", ""))
                    if rid:
                        await _send(kws, {"type": "loot_reward", "id": rid,
                                          "name": str(r.get("name", rid)),
                                          "color": r.get("color", [0.7, 0.7, 0.7, 1.0])})
                        if ksess is not None:      # ⑧ session feed (killer's inventory)
                            _grant_to_session(ksess, rid, str(r.get("name", rid)),
                                              r.get("color", [0.7, 0.7, 0.7, 1.0]),
                                              "", 0, int(r.get("qty", 1)))
            else:
                # Un-baked — let the killer's client roll loot locally (transition).
                await _send(kws, {"type": "loot_reward", "fallback": True, "monster_id": mid})
    # Phase 5b — a fallen guard summons a stronger wave (see _guard_on_death).
    # Checked before the thrall roll so guards never yield thralls.
    if _is_guard_entity(mid):
        _guard_on_death(mid)
        st["participants"] = []
        st["damage"] = {}
        return
    # Phase 10c — small chance the killer takes a thrall (tier = this monster's
    # level band) if they have a free roster slot.
    if killer_pid is not None:
        await _maybe_drop_thrall(killer_pid, int(st.get("level", 1)))
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
                anchor = admin_node_anchor.get(eid)
                if anchor is not None:
                    # Admin gatherable — wander to a nearby PASSABLE spot on respawn.
                    nx, ny = _reroll_node_pos(anchor[0], anchor[1])
                    st["x"], st["y"] = nx, ny
                    _broadcast_near(nx, ny, {"type": "node_respawned", "id": eid,
                                             "x": nx, "y": ny})
                else:
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
        # PvP piles use the same claimed / expires_at contract as gold piles.
        for pile_id, p in list(pvp_piles.items()):
            if p.get("claimed"):
                del pvp_piles[pile_id]
                continue
            if p["expires_at"] <= now:
                _broadcast_near(p["x"], p["y"],
                    {"type": "pvp_pile_remove", "id": pile_id})
                del pvp_piles[pile_id]


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
    _last_logged_mon_count = -1
    while True:
        await asyncio.sleep(MONSTER_AI_TICK)
        _tick_counter += 1
        # Only log when the live monster count CHANGES (event-driven), so the
        # console isn't flooded with a per-tick heartbeat. A rare keep-alive line
        # every ~10 min confirms the loop is still running.
        _mc = len(monsters_state)
        if _mc != _last_logged_mon_count or _tick_counter % 1200 == 1:
            _last_logged_mon_count = _mc
            print(f"[ai_loop] {_mc} monsters (tick {_tick_counter})")
        now = time.time()
        _refresh_struct_blocked_tiles(now)   # keep the wall/structure block map fresh
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
        # v1.6.4 — the watch dispatches monsters caught attacking someone inside
        # the walls: a beat after the guard appears, kill the monster (no player
        # loot/xp — the GUARD did it) and despawn the guard prop.
        for _mid in list(guard_defends.keys()):
            _info = guard_defends[_mid]
            if now - _info["at"] < GUARD_DEFEND_DELAY:
                continue
            _mst = monsters_state.get(_mid)
            if _mst is not None and _mst.get("alive", True):
                _mst["damage"] = {}          # guards killed it — no player reward
                await _monster_die(_mid, _mst)
            _broadcast({"type": "world_entity_remove", "id": _info["guard_eid"]})
            del guard_defends[_mid]


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
        # City watch leash (v1.6.2) — a guard holds its town's walls, it does not
        # hunt. Once the offender flees more than 5 tiles past the town bounds the
        # guard breaks off and returns to post, however much aggro it was holding.
        if _is_guard_entity(mid):
            _gt = guard_alerts.get(guard_owner.get(mid, ""), {}).get("town", "")
            _out = True
            if _gt:
                bx0, by0, bx1, by1 = _town_world_bounds(_gt, tile_margin=5)
                _out = not (bx0 <= tx <= bx1 and by0 <= ty <= by1)
            if _out:
                st["state"] = "idle"
                st["target_player"] = None
                st["wander_x"], st["wander_y"] = home_x, home_y
                st["next_wander_at"] = now
                return
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
        m_type = st.get("monster_type", "")
        if m_type in WATER_ONLY_MONSTERS:
            step *= 1.2
        # 8-direction chase — try the direct step, then a widening cone
        # of ±22.5° / ±45° / ±67.5° / ±90° detours. First candidate that
        # is passable AND does not increase distance to the target wins.
        # If nothing works, `_try_chase_step` returns (cur_x, cur_y) and
        # the fully-blocked branch below handles structure-in-face attacks.
        # Aim for a point a body-width SHORT of the player (standoff) so the
        # monster halts adjacent instead of walking onto the player's sprite.
        standoff = float(st.get("size", _MONSTER_SIZE_DEFAULT)) \
            + _PLAYER_BODY_HALF + _MONSTER_STANDOFF_GAP
        pdx, pdy = tx - cur_x, ty - cur_y
        pdist = (pdx * pdx + pdy * pdy) ** 0.5
        held_at_standoff = pdist <= standoff
        if held_at_standoff:
            new_x, new_y = cur_x, cur_y          # already adjacent — hold + attack
        else:
            aim_x = tx - (pdx / pdist) * standoff
            aim_y = ty - (pdy / pdist) * standoff
            new_x, new_y = _try_chase_step(m_type, cur_x, cur_y, aim_x, aim_y, step)
        if not held_at_standoff and new_x == cur_x and new_y == cur_y:
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
                    s_st["last_damaged_at"] = now
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
        # City-watch LEASH — a guard never chases more than 5 tiles past its town's
        # walls. Clamp its step to the town AABB + 5 tiles; it holds, doesn't hunt.
        if _is_guard_entity(mid):
            _gt = guard_alerts.get(guard_owner.get(mid, ""), {}).get("town", "")
            if _gt:
                lx0, ly0, lx1, ly1 = _town_world_bounds(_gt, tile_margin=5)
                new_x = min(max(new_x, lx0), lx1)
                new_y = min(max(new_y, ly0), ly1)
        st["x"], st["y"] = new_x, new_y
        # Attack if in range and cooldown elapsed. Melee reach is
        # MONSTER_ATTACK_RANGE + body size; ranged/magic mobs use their
        # per-type `attack_range` from _MONSTER_ATTACK. Ranged/magic
        # additionally require line-of-sight — a fire imp won't lob a
        # ball through a hill just because you're within 220 px.
        atk_prof = _monster_attack_profile(m_type)
        style = atk_prof["style"]
        d2 = (new_x - tx) ** 2 + (new_y - ty) ** 2
        if style == "melee":
            reach = MONSTER_ATTACK_RANGE + float(
                st.get("size", _MONSTER_SIZE_DEFAULT))
            can_hit = d2 <= reach * reach
        else:
            reach = float(atk_prof["range"])
            can_hit = d2 <= reach * reach and _los_clear(new_x, new_y, tx, ty)
        if can_hit and now - st["last_attack_at"] >= MONSTER_ATTACK_COOLDOWN:
            st["last_attack_at"] = now
            attack_msgs.append((new_x, new_y, {
                "type": "monster_attack",
                "id": mid,
                "target": tgt["username"],
                "damage": int(st["attack"]),
                "monster_type": m_type,
            }))
            # Towns are SAFE: a monster attacking someone inside the walls gets
            # dispatched by the watch (v1.6.4) — but only once the player is in real
            # TROUBLE (HP ≤ 60%), so they get to actually fight the monster first
            # instead of the guard one-shotting everything they engage. If the client
            # hasn't reported HP yet, assume full (don't help).
            if not _is_guard_entity(mid) and float(tgt.get("hp_frac", 1.0)) <= GUARD_DEFEND_HP_FRAC:
                _guard_defend_start(mid, st, tx, ty)
            # Ranged / magic get a separate visual broadcast so the
            # client draws a projectile arcing from the mob to the
            # player. Damage still lands via monster_attack (same
            # cadence + trust model) — the projectile is decoration
            # only, sized so its 0.4-s travel matches the swing tick.
            if style != "melee":
                _broadcast_near(new_x, new_y, {
                    "type": "monster_projectile",
                    "id": mid,
                    "from_x": new_x,
                    "from_y": new_y,
                    "to_x": tx,
                    "to_y": ty,
                    "style": style,
                    "color": atk_prof["color"],
                    "spread_orbs": atk_prof.get("spread_orbs", 1),
                })
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
    # Spectators have no tracked camera position to filter against, so push the
    # full snapshot — the followed target could be anywhere in the world.
    if spectators:
        payload_all = json.dumps({"type": "monster_pos_update",
                                  "updates": snapshots})
        for ws in list(spectators):
            asyncio.ensure_future(_safe_send(ws, payload_all))


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


# ── Graceful shutdown (Phase 7 — data-loss prevention) ─────────────────────────
# On SIGINT/SIGTERM (Ctrl+C locally, or the restart script on the server box) we
# must NOT just drop every connection — inventory/skill_xp/equipment are
# client-authoritative and only reach the DB when the client answers a
# request_save. So we broadcast a shutdown notice, ask every online client for a
# final save, wait a short grace window for those saves to arrive + be written,
# and only then let the server close. Without this, any progress since the last
# 60s autosave is lost on a restart.
_shutdown_event = None   # asyncio.Event, created in main() once the loop exists
## How long to wait for clients to push their final save before closing. Covers
## the round-trip (request_save → client save → _handle_save DB write) for
## remote clients, not just localhost.
SHUTDOWN_SAVE_GRACE_SEC = 3.0


async def _save_all_online() -> None:
    online = list(sessions)
    if not online:
        print("[shutdown] no players online — nothing to flush.")
        return
    print(f"[shutdown] flushing final save for {len(online)} online player(s)…")
    # Tell clients we're going down (they show 'reconnecting' + freeze), then
    # ask for a final save. Both messages are best-effort per socket.
    for ws in online:
        await _safe_send(ws, json.dumps({"type": "server_shutdown"}))
        await _safe_send(ws, json.dumps({"type": "request_save"}))
    # The per-connection read loops are still alive inside the serve() context,
    # so this sleep lets them receive + persist the incoming save payloads.
    await asyncio.sleep(SHUTDOWN_SAVE_GRACE_SEC)
    print("[shutdown] save flush complete.")


def _install_shutdown_handlers() -> None:
    if _shutdown_event is None:
        return
    loop = asyncio.get_running_loop()
    def _trip() -> None:
        loop.call_soon_threadsafe(_shutdown_event.set)
    for sig in (getattr(signal, "SIGINT", None), getattr(signal, "SIGTERM", None)):
        if sig is None:
            continue
        # Prefer the loop-native handler (Unix). Fall back to signal.signal so
        # Ctrl+C still trips a clean save-flush on Windows (ProactorEventLoop
        # doesn't implement add_signal_handler).
        try:
            loop.add_signal_handler(sig, _shutdown_event.set)
        except (NotImplementedError, AttributeError, ValueError, RuntimeError):
            try:
                signal.signal(sig, lambda _s, _f: _trip())
            except (ValueError, OSError, RuntimeError):
                pass


# ── Main connection handler ────────────────────────────────────────────────────

## PvP toggle — mirrors the client-side rule in GameManager.request_pvp_toggle:
## turning ON is free and starts a lockout timer; turning OFF is refused until
## the timer elapses. Server is the authority so an edited client can't
## re-flag freely. Broadcasts the new flag so other clients can render the
## flagged silhouette differently and gate their own attack UI.
PVP_COOLDOWN_SEC = 300.0
## Kill payout — flat XP grant to the killer in the style they used
## (melee/ranged/magic). Client also credits +1 pvp_token via the
## pvp_kill_credit message. Matches the user's spec: "xp grant for
## killer is only the exp from the combat skill they used".
PVP_KILL_XP = 200
## PvP Tokens (Phase 1d) granted to the killer per kill. Server-owned
## currency — credited to the DB, never a ground pickup, so it can't be faked.
PVP_KILL_TOKENS = 1
## Token cost to REACH each upgrade level (single step). Mirrors the client's
## Equipment.UPGRADE_COST. Reaching L4 costs 10+20+30+100 = 160 total.
TOKEN_UPGRADE_COST = {1: 10, 2: 20, 3: 30, 4: 100}
TOKEN_UPGRADE_MAX_LEVEL = 4
TOKEN_UPGRADE_TRAITS = ("hp", "def", "atk", "ratk", "matk")
## Fraction of the victim's gold that falls to the ground as a pile
## on death. The rest stays with them through respawn.
PVP_DEATH_GOLD_FRAC = 0.25

async def _handle_pvp_toggle(ws, session, msg: dict) -> None:
    want_on = bool(msg.get("on", False))
    now = time.time()
    if want_on == bool(session.get("pvp_flagged", False)):
        return
    if want_on:
        session["pvp_flagged"] = True
        session["pvp_locked_until"] = now + PVP_COOLDOWN_SEC
    else:
        if now < float(session.get("pvp_locked_until", 0.0)):
            rem = int(session["pvp_locked_until"] - now)
            await _send(ws, {"type": "pvp_locked", "remaining": rem})
            return
        session["pvp_flagged"] = False
    _broadcast({"type": "pvp_flag",
                "id":       session["id"],
                "username": session["username"],
                "flagged":  session["pvp_flagged"]})

## PvP attack — the attacker's client has already computed damage using the
## same combat formula it applies to monsters. Server validates: both
## sessions must be pvp_flagged, target must exist, be within a sane range
## (400 world units — one screen), and not be the same player. On success
## the damage packet forwards to the defender's ws; the defender's client
## applies the HP delta and emits the same hit_flash / floating-number
## effects it does for monster attacks. Distance-cheat guard is server-only;
## the client's own combat range check is advisory.
PVP_ATTACK_RANGE = 400.0

async def _handle_pvp_attack(ws, session, msg: dict) -> None:
    # Player ids are TEXT hex tokens (players.id) — compare as strings. int()
    # would collapse every id to 0 so no session ever matched ("Target not
    # online" for a live target).
    target_id = str(msg.get("target_id", ""))
    dmg = max(0, min(999, int(msg.get("damage", 0))))
    style = str(msg.get("style", "melee"))
    if not target_id or target_id == session["id"]:
        return
    if not session.get("pvp_flagged"):
        await _send(ws, {"type": "pvp_reject", "reason": "You are not PvP-flagged."})
        return
    target_ws = None
    target_sess = None
    for tws, tsess in list(sessions.items()):
        if tsess.get("id") == target_id:
            target_ws = tws
            target_sess = tsess
            break
    if target_sess is None:
        await _send(ws, {"type": "pvp_reject", "reason": "Target not online."})
        return
    if not target_sess.get("pvp_flagged"):
        await _send(ws, {"type": "pvp_reject", "reason": "Target not PvP-flagged."})
        return
    # Kjelvik castle is the ONE no-PvP zone (Phase 5b). Enforced server-side —
    # previously "towns are safe" was client convention only, so it was
    # trivially bypassable. Everywhere else stays toggle-only by design.
    if _in_castle_safe_zone(float(session.get("x", 0.0)),
                            float(session.get("y", 0.0))):
        await _send(ws, {"type": "pvp_reject",
                         "reason": "No fighting inside the castle walls."})
        return
    if _in_castle_safe_zone(float(target_sess.get("x", 0.0)),
                            float(target_sess.get("y", 0.0))):
        await _send(ws, {"type": "pvp_reject",
                         "reason": "They're under the castle's protection."})
        return
    dx = float(session.get("x", 0.0)) - float(target_sess.get("x", 0.0))
    dy = float(session.get("y", 0.0)) - float(target_sess.get("y", 0.0))
    if dx * dx + dy * dy > PVP_ATTACK_RANGE * PVP_ATTACK_RANGE:
        await _send(ws, {"type": "pvp_reject", "reason": "Out of range."})
        return
    # Forward the damage packet to the defender + notify attacker of the
    # confirmed hit for their combat log.
    await _send(target_ws, {"type": "pvp_hit",
                            "attacker_id":       session["id"],
                            "attacker_username": session["username"],
                            "damage":            dmg,
                            "style":             style})
    await _send(ws, {"type": "pvp_hit_confirm",
                     "target_id": target_id,
                     "damage":    dmg})

## ── Token upgrades (Phase 1d) ──────────────────────────────────────────────
## Mirror of the client's Equipment id-suffix scheme. Only the server mints an
## upgraded id, and only after deducting server-owned tokens — so a normal
## client can't fabricate a boost.
def _parse_upgrade(item_id: str):
    i = item_id.find("~u")
    if i < 0:
        return item_id, 0
    base = item_id[:i]
    rest = item_id[i + 2:]
    t = rest.find("~")
    lvl_s = rest if t < 0 else rest[:t]
    try:
        lvl = int(lvl_s)
    except ValueError:
        lvl = 0
    return base, max(0, min(TOKEN_UPGRADE_MAX_LEVEL, lvl))


def _make_upgraded_id(base: str, level: int, trait: str = "") -> str:
    if level <= 0:
        return base
    if level >= TOKEN_UPGRADE_MAX_LEVEL and trait:
        return f"{base}~u{TOKEN_UPGRADE_MAX_LEVEL}~{trait}"
    return f"{base}~u{level}"


async def _handle_token_upgrade(ws, session, msg: dict) -> None:
    item_id = str(msg.get("item_id", ""))
    slot = str(msg.get("slot", ""))
    trait = str(msg.get("trait", ""))
    base, cur = _parse_upgrade(item_id)
    # Sanity: must look like a real gear id ("{tier}_{piece}"), not a currency
    # or junk string. Tokens are the real gate; this just blocks obvious abuse.
    if not base or "_" not in base:
        await _send(ws, {"type": "token_upgrade_reject",
                         "reason": "That item can't be upgraded."})
        return
    target = cur + 1
    if target > TOKEN_UPGRADE_MAX_LEVEL:
        await _send(ws, {"type": "token_upgrade_reject",
                         "reason": "Already at max upgrade (+%d)." % TOKEN_UPGRADE_MAX_LEVEL})
        return
    if target >= TOKEN_UPGRADE_MAX_LEVEL and trait not in TOKEN_UPGRADE_TRAITS:
        await _send(ws, {"type": "token_upgrade_reject",
                         "reason": "Choose a bonus trait for the final upgrade."})
        return
    cost = int(TOKEN_UPGRADE_COST.get(target, 0))
    try:
        with _db() as conn:
            row = conn.execute(
                "SELECT pvp_tokens FROM players WHERE id=?",
                (session["id"],)).fetchone()
            bal = int(row["pvp_tokens"] or 0) if row else 0
            if bal < cost:
                await _send(ws, {"type": "token_upgrade_reject",
                                 "reason": "Not enough PvP Tokens (need %d, have %d)." % (cost, bal),
                                 "pvp_tokens": bal})
                return
            new_bal = bal - cost
            conn.execute("UPDATE players SET pvp_tokens=? WHERE id=?",
                         (new_bal, session["id"]))
            conn.commit()
    except Exception as e:
        print(f"[token_upgrade] {e!r}")
        await _send(ws, {"type": "token_upgrade_reject",
                         "reason": "Upgrade failed — try again."})
        return
    new_id = _make_upgraded_id(base, target, trait if target >= TOKEN_UPGRADE_MAX_LEVEL else "")
    await _send(ws, {
        "type":         "token_upgrade_ok",
        "slot":         slot,
        "old_item_id":  item_id,
        "new_item_id":  new_id,
        "level":        target,
        "pvp_tokens":   new_bal,
    })


# ── Fast travel (Phase 2b) — discover-then-pay ─────────────────────────────
# Client gates the UI on towns it has visited on foot; the server owns the GOLD
# (the regular save doesn't even persist gold), so the fee is deducted here and
# the destination coords are authoritative. Town centers mirror Ground.gd's
# _is_town tile ranges (tile*32 = world px).
_TRAVEL_TOWNS = {
    "kjelvik":   (2672.0, 3696.0),
    "frostheim": (1392.0, 944.0),
    "ironwood":  (3568.0, 4976.0),
    "eastmark":  (5936.0, 5872.0),
    "bjorn":     (7888.0, 4432.0),
}


def _fast_travel_cost(sx: float, sy: float, tx: float, ty: float) -> int:
    dist_tiles = ((tx - sx) ** 2 + (ty - sy) ** 2) ** 0.5 / 32.0
    return max(50, min(300, int(50 + dist_tiles * 2)))


async def _handle_discover_town(ws, session, msg: dict) -> None:
    """Persist a fast-travel town unlock discovered on foot — a 1-time, account-level
    unlock so it survives logouts (was client-cfg only)."""
    town_id = str(msg.get("town_id", "")).lower()
    if town_id not in _TRAVEL_TOWNS:
        return
    with _db() as conn:
        row = conn.execute("SELECT discovered_towns FROM players WHERE id=?",
                           (session["id"],)).fetchone()
        try:
            towns = json.loads((row["discovered_towns"] if row and "discovered_towns" in row.keys() else None) or "[]")
        except Exception:
            towns = []
        if not isinstance(towns, list):
            towns = []
        if town_id not in towns:
            towns.append(town_id)
            conn.execute("UPDATE players SET discovered_towns=? WHERE id=?",
                         (json.dumps(towns), session["id"]))
            conn.commit()


async def _handle_fast_travel(ws, session, msg: dict) -> None:
    town_id = str(msg.get("town_id", "")).lower()
    if town_id not in _TRAVEL_TOWNS:
        await _send(ws, {"type": "fast_travel_reject", "reason": "Unknown destination."})
        return
    tx, ty = _TRAVEL_TOWNS[town_id]
    sx = float(session.get("x", 0.0))
    sy = float(session.get("y", 0.0))
    cost = _fast_travel_cost(sx, sy, tx, ty)
    try:
        with _db() as conn:
            row = conn.execute("SELECT gold FROM players WHERE id=?",
                               (session["id"],)).fetchone()
            gold = int(row["gold"] or 0) if row else 0
            if gold < cost:
                await _send(ws, {"type": "fast_travel_reject",
                                 "reason": f"Need {cost}g to travel there (you have {gold})."})
                return
            new_gold = gold - cost
            conn.execute("UPDATE players SET gold=?, x=?, y=? WHERE id=?",
                         (new_gold, tx, ty, session["id"]))
            conn.commit()
    except Exception as e:
        print(f"[fast_travel] {e!r}")
        await _send(ws, {"type": "fast_travel_reject", "reason": "Travel failed — try again."})
        return
    session["x"] = tx
    session["y"] = ty
    await _send(ws, {"type": "gold_set", "gold": new_gold})
    await _send(ws, {"type": "fast_travel_ok", "town_id": town_id,
                     "x": tx, "y": ty, "cost": cost})


# ── Personal gold bank (Phase 3 #3) ────────────────────────────────────────
# Move gold between carried (players.gold) and the reserve (players.bank_gold),
# server-authoritative so it survives relog + can't be faked. Positive amount
# only; deposit is capped to carried, withdraw to banked.
async def _handle_bank_gold(ws, session, msg: dict, deposit: bool) -> None:
    amount = max(0, int(msg.get("amount", 0)))
    if amount <= 0:
        return
    try:
        with _db() as conn:
            row = conn.execute("SELECT gold, bank_gold FROM players WHERE id=?",
                               (session["id"],)).fetchone()
            gold = int(row["gold"] or 0) if row else 0
            banked = int(row["bank_gold"] or 0) if row else 0
            if deposit:
                move = min(amount, gold)
                gold -= move
                banked += move
            else:
                move = min(amount, banked)
                banked -= move
                gold += move
            if move <= 0:
                await _send(ws, {"type": "gold_set", "gold": gold})
                await _send(ws, {"type": "bank_gold_set", "bank_gold": banked})
                return
            conn.execute("UPDATE players SET gold=?, bank_gold=? WHERE id=?",
                         (gold, banked, session["id"]))
            conn.commit()
    except Exception as e:
        print(f"[bank_gold] {e!r}")
        return
    await _send(ws, {"type": "gold_set", "gold": gold})
    await _send(ws, {"type": "bank_gold_set", "bank_gold": banked})


# ── Live rankings (Phase 3 #4) ─────────────────────────────────────────────
# Real leaderboard over every real account. Ranked by the combat-weighted
# character level (matches nameplates + the skills tab), tie-broken by total
# skill level. Small player base → a full scan per request is fine; add a LIMIT
# + cache if it ever grows.
async def _handle_rankings(ws, msg: dict) -> None:
    entries = []
    try:
        with _db() as conn:
            for r in conn.execute("SELECT username, skill_xp FROM players").fetchall():
                sx = json.loads(r["skill_xp"] or "{}")
                total = sum(_calc_level(int(sx.get(s, 0))) for s in _LEVEL_SKILLS)
                entries.append({
                    "username": str(r["username"]),
                    "level":    _character_level(sx),
                    "total":    total,
                })
    except Exception as e:
        print(f"[rankings] {e!r}")
    entries.sort(key=lambda e: (e["level"], e["total"]), reverse=True)
    await _send(ws, {"type": "rankings", "entries": entries[:25]})


# ── Fishing biggest-catch leaderboard + journal (1.6.3) ──────────────────────
def _fishing_records_all() -> list:
    with _db() as conn:
        rows = conn.execute(
            "SELECT species, species_name, weight, holder_name FROM fishing_records "
            "ORDER BY weight DESC").fetchall()
    return [{"species": r["species"], "name": r["species_name"],
             "weight": float(r["weight"]), "holder": r["holder_name"]} for r in rows]


def _fishing_journal_for(pid: str) -> list:
    with _db() as conn:
        rows = conn.execute(
            "SELECT species, species_name, best_weight FROM fishing_journal "
            "WHERE player_id=? ORDER BY species", (str(pid),)).fetchall()
    return [{"species": r["species"], "name": r["species_name"],
             "weight": float(r["best_weight"])} for r in rows]


async def _handle_admin_upload_fish(ws, session: dict, msg: dict) -> None:
    """Owner-only — baked fish-species table (⑥). Server grants catches from it."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Fish-species upload is owner-only.")
        return
    raw = msg.get("map", {})
    if not isinstance(raw, dict):
        await _admin_confirm(ws, "Bad fish table.")
        return
    global fish_species
    fish_species = raw
    _save_fish_species()
    await _admin_confirm(ws, f"Baked fish table saved — {len(fish_species)} species now server-authoritative.")
    print(f"[fishing] {session['username']} uploaded {len(fish_species)} fish species")


async def _handle_fish_caught(ws, session: dict, msg: dict) -> None:
    """A landed catch (1.6.3 + v1.7 ⑥). SERVER-authoritative when the fish table
    is baked: validates the species + a fishing-level gate, CLAMPS the client's
    weight into the species range, recomputes wnorm + trophy, grants the fish
    ITEM (with weight/wnorm/trophy meta) + fishing XP + weight-scaled bonus gold,
    and pushes the authoritative inventory/gold. Pre-bake (empty table) it trusts
    the client's claim so fishing never breaks. Client stops minting online.
    Client sends {species, species_name, weight, wnorm, xp, color, reeled, bait_mult}."""
    species = str(msg.get("species", "")).strip()
    weight = float(msg.get("weight", 0.0))
    sname = str(msg.get("species_name", species)) or species
    if not species or weight <= 0.0:
        return
    pid = str(session["id"])
    uname = str(session["username"])
    now = time.time()

    sdef = fish_species.get(species)
    if fish_species and not sdef:
        # Table is baked and this isn't a known fish — refuse the grant.
        await _send(ws, {"type": "fish_caught_result", "species": species,
                         "weight": weight, "personal_best": False,
                         "world_record": False, "gold": 0, "ok": False})
        return

    # Resolve the authoritative catch. Baked → recompute from the species table;
    # un-baked → trust the client's claim (transitional, closes once baked).
    if sdef:
        wr_lv     = int(sdef.get("wr_lv", 1))
        base_xp   = int(sdef.get("base_xp", 0))
        min_lv    = int(sdef.get("min_catch_lv", 1))
        color     = sdef.get("color", msg.get("color", [0.7, 0.7, 0.7, 1.0]))
        lo, hi    = _fish_weight_range(wr_lv)
        weight    = max(lo, min(weight, hi))          # clamp cheats into range
        wnorm     = _fish_weight_norm(wr_lv, weight)
        trophy    = wnorm >= _FISH_TROPHY_NORM
        flv       = _calc_level(session.get("skill_xp", {}).get("fishing", 0))
        if flv < min_lv:
            await _send(ws, {"type": "fish_caught_result", "species": species,
                             "weight": weight, "personal_best": False,
                             "world_record": False, "gold": 0, "ok": False,
                             "reason": f"Requires Fishing level {min_lv}."})
            return
        reel_mult = 2.0 if bool(msg.get("reeled", False)) else 1.0
        bait_mult = max(1.0, min(float(msg.get("bait_mult", 1.0)), 1.3))
        xp = int(round(base_xp * (1.0 + wnorm) * reel_mult * bait_mult))
    else:
        wnorm  = max(0.0, min(1.0, float(msg.get("wnorm", 0.0))))
        trophy = wnorm >= _FISH_TROPHY_NORM
        color  = msg.get("color", [0.7, 0.7, 0.7, 1.0])
        xp     = max(0, int(msg.get("xp", 0)))

    new_personal = False
    new_record = False
    bonus = 0
    new_gold = 0
    added = 0
    with _db() as conn:
        prow = conn.execute("SELECT best_weight FROM fishing_journal "
                            "WHERE player_id=? AND species=?", (pid, species)).fetchone()
        if prow is None or weight > float(prow["best_weight"]):
            new_personal = True
            conn.execute(
                "INSERT INTO fishing_journal (player_id, species, species_name, best_weight, caught_at) "
                "VALUES (?,?,?,?,?) ON CONFLICT(player_id, species) DO UPDATE SET "
                "best_weight=excluded.best_weight, species_name=excluded.species_name, "
                "caught_at=excluded.caught_at",
                (pid, species, sname, weight, now))
        rec = conn.execute("SELECT weight FROM fishing_records WHERE species=?",
                          (species,)).fetchone()
        if rec is None or weight > float(rec["weight"]):
            new_record = True
            conn.execute(
                "INSERT INTO fishing_records (species, species_name, weight, holder_id, holder_name, caught_at) "
                "VALUES (?,?,?,?,?,?) ON CONFLICT(species) DO UPDATE SET "
                "weight=excluded.weight, holder_id=excluded.holder_id, "
                "holder_name=excluded.holder_name, species_name=excluded.species_name, "
                "caught_at=excluded.caught_at",
                (species, sname, weight, pid, uname, now))
        # ⑥ — grant the fish ITEM (with meta) + fishing XP + bonus gold, all in
        # this one transaction. Pre-⑧ the client mirrors via the pushes below.
        row = conn.execute("SELECT gold, inventory, skill_xp FROM players WHERE id=?",
                           (pid,)).fetchone()
        gold = int(row["gold"] or 0) if row else 0
        inv = json.loads(row["inventory"] or "[]") if row else []
        skill_xp = json.loads(row["skill_xp"] or "{}") if row else {}
        meta = {"weight": round(weight, 1), "wnorm": round(wnorm, 4), "trophy": bool(trophy)}
        added = _inv_add_qty(inv, species, sname, 1, color, meta=meta)
        if xp > 0:
            skill_xp["fishing"] = int(skill_xp.get("fishing", 0)) + xp
        bonus = int(round(_base_price_for(species) * wnorm))
        new_gold = gold + bonus
        conn.execute("UPDATE players SET gold=?, inventory=?, skill_xp=? WHERE id=?",
                     (new_gold, json.dumps(inv), json.dumps(skill_xp), pid))
        conn.commit()
    session["inventory"] = inv
    session["skill_xp"] = skill_xp
    await _send(ws, {"type": "admin_inventory_set", "inventory": inv})
    if bonus > 0:
        await _send(ws, {"type": "gold_set", "gold": new_gold})
    await _send(ws, {"type": "fish_caught_result", "species": species,
                     "weight": weight, "personal_best": new_personal,
                     "world_record": new_record, "gold": bonus, "ok": True,
                     "xp": xp, "trophy": bool(trophy)})
    if new_record:
        _broadcast({"type": "chat", "username": "Server",
                    "text": f"🎣 {uname} landed a {weight:.1f} kg {sname} — a new record!"})


async def _handle_admin_upload_sea_loot(ws, session: dict, msg: dict) -> None:
    """Owner-only — baked sea-monster loot table (⑥). Server grants boat-fight wins from it."""
    if not _is_owner(session):
        await _admin_confirm(ws, "Sea-loot upload is owner-only.")
        return
    raw = msg.get("map", {})
    if not isinstance(raw, dict):
        await _admin_confirm(ws, "Bad sea-loot table.")
        return
    global sea_loot
    sea_loot = raw
    _save_sea_loot()
    await _admin_confirm(ws, f"Baked sea loot saved — {len(sea_loot)} monsters now server-authoritative.")
    print(f"[sea] {session['username']} uploaded {len(sea_loot)} sea-monster loot entries")


async def _handle_sea_combat_win(ws, session: dict, msg: dict) -> None:
    """SERVER grants a boat-fight win's loot + XP (⑥). The fight itself is a client
    modal we can't referee, so we trust the win but grant only the BAKED loot for a
    KNOWN monster (never client-claimed items). Pre-bake trusts the claim so it
    never breaks. XP splits fishing/melee like the old client path."""
    mtype = str(msg.get("monster_type", "")).strip()
    sdef = sea_loot.get(mtype)
    if sea_loot and not sdef:
        await _send(ws, {"type": "sea_combat_result", "ok": False, "reason": "Unknown sea monster."})
        return
    if not sdef:                                   # pre-bake: trust the client claim
        claim = msg.get("monster")
        sdef = claim if isinstance(claim, dict) else None
    if not sdef:
        return
    loot = sdef.get("loot", []) if isinstance(sdef.get("loot"), list) else []
    xp_reward = int(sdef.get("xp_reward", 0))
    fish_xp = xp_reward // 2
    melee_xp = xp_reward - fish_xp
    with _db() as conn:
        row = conn.execute("SELECT inventory, skill_xp FROM players WHERE id=?",
                           (session["id"],)).fetchone()
        if not row:
            return
        inv = json.loads(row["inventory"] or "[]")
        skill_xp = json.loads(row["skill_xp"] or "{}")
        for it in loot:
            if not isinstance(it, dict):
                continue
            _inv_add_qty(inv, str(it.get("id", "")), str(it.get("name", "")),
                         int(it.get("qty", 1)), it.get("color", [0.7, 0.7, 0.7, 1.0]))
        skill_xp["fishing"] = int(skill_xp.get("fishing", 0)) + fish_xp
        skill_xp["melee"] = int(skill_xp.get("melee", 0)) + melee_xp
        conn.execute("UPDATE players SET inventory=?, skill_xp=? WHERE id=?",
                     (json.dumps(inv), json.dumps(skill_xp), session["id"]))
        conn.commit()
    session["inventory"] = inv
    session["skill_xp"] = skill_xp
    await _send(ws, {"type": "admin_inventory_set", "inventory": inv})
    await _send(ws, {"type": "sea_combat_result", "ok": True,
                     "fishing_xp": fish_xp, "melee_xp": melee_xp,
                     "name": str(sdef.get("name", mtype))})


# ── Thralls (Phase 10) — collectible offline workers ────────────────────────
THRALL_MAX_SLOTS = 5
THRALL_SLOT_COST = {3: 25000, 4: 75000, 5: 150000}   # gold to buy slot N
THRALL_NAMES = (
    "Ragnar", "Sven", "Bjorn", "Inga", "Astrid", "Leif", "Gorm", "Brynja",
    "Ulf", "Sigrun", "Halvard", "Torvald", "Frida", "Eirik", "Solveig",
    "Knut", "Yrsa", "Hemming", "Gudrun", "Arne", "Dagny", "Roskva",
)


def _level_band_tier(level: int) -> int:
    """Map a level requirement / monster level to a thrall tier (1-6)."""
    if level < 15:
        return 1
    if level < 30:
        return 2
    if level < 50:
        return 3
    if level < 70:
        return 4
    if level < 85:
        return 5
    return 6


def _thrall_max_hp(tier: int, level: int) -> int:
    return 30 + tier * 20 + level * 2


# Per-skill offset (in TILES) from a town centre → an assigned thrall's visible
# work spot, so fishers cluster toward the water side, miners toward the hills,
# etc. A small id-derived jitter fans out multiple same-skill thralls.
_THRALL_SPOT_OFFSET = {
    "fishing":     (8, 3),
    "mining":      (-8, -3),
    "woodcutting": (-3, 8),
    "foraging":    (3, -8),
    "melee":       (8, -8),
}


def _thrall_work_spot(town: str, skill: str, tid: str = "") -> tuple:
    """World-pixel spot where an assigned thrall stands to work, near `town`."""
    cx, cy = _TOWN_CENTER_TILE.get(town, _TOWN_CENTER_TILE["bjorn"])
    ox, oy = _THRALL_SPOT_OFFSET.get(skill, (0, 8))
    try:
        h = int(tid[:6], 16)
    except (ValueError, TypeError):
        h = 0
    jx = ((h % 5) - 2) * 0.6
    jy = (((h // 5) % 5) - 2) * 0.6
    return ((cx + ox + jx) * 32.0 + 16.0, (cy + oy + jy) * 32.0 + 16.0)


# Which task tiers each town's surroundings offer (V1.5.5 gating): task ->
# (min_tier, max_tier). A thrall may only be SENT to a town whose range for the
# chosen task covers the target's tier — so low-tier thralls can't be sent to a
# high-tier town (Frostheim), and Frostheim has no fishing at all. Themed per
# town; TUNE as the map's nodes get placed by admins. ⚠ Mirror in
# ThrallManager.TOWN_RESOURCES (client filters the picker; server validates).
TOWN_RESOURCES = {
    "bjorn":     {"fish": (1, 4), "woodcut": (1, 2), "mine": (1, 1), "forage": (1, 2), "combat": (1, 2)},
    "kjelvik":   {"mine": (1, 3), "woodcut": (1, 2), "forage": (1, 2), "combat": (1, 3)},
    "frostheim": {"mine": (4, 6), "woodcut": (4, 5), "combat": (3, 4)},
    "ironwood":  {"woodcut": (2, 5), "forage": (2, 3), "combat": (2, 3)},
    "eastmark":  {"mine": (2, 4), "fish": (2, 3), "combat": (2, 3)},
}


def _town_offers(town: str, task: str, tier: int) -> bool:
    rng = TOWN_RESOURCES.get(town, {}).get(task)
    return bool(rng) and rng[0] <= tier <= rng[1]


def _thrall_to_dict(r) -> dict:
    try:
        pack = json.loads(r["backpack"] or "[]")
    except Exception:
        pack = []
    keys = r.keys()
    town = (r["town"] if "town" in keys else "") or ""
    try:
        appr = json.loads((r["appearance"] if "appearance" in keys else "") or "{}")
    except Exception:
        appr = {}
    job = r["job"] or ""
    target = r["target"] or ""
    reward = TASK_REWARDS.get((job, target))
    skill = str(reward["skill"]) if reward else ""
    # Visible work spot only when the thrall is actually assigned to a town task.
    spot = None
    if town and job and target:
        wx, wy = _thrall_work_spot(town, skill, str(r["id"]))
        spot = [wx, wy]
    return {
        "id":       r["id"],
        "name":     r["name"],
        "tier":     int(r["tier"] or 1),
        "level":    int(r["level"] or 1),
        "xp":       int(r["xp"] or 0),
        "job":      job,
        "target":   target,
        "town":     town,
        "skill":    skill,
        "appearance": appr,
        "work_spot": spot,
        "hp":       int(r["hp"] or 0),
        "max_hp":   int(r["max_hp"] or 0),
        "backpack": pack,
    }


def _random_thrall_appearance() -> str:
    """A random, stored look so each thrall is visibly distinct (V1.5.5). Ranges
    are the CLIENT Appearance palette sizes; the client sanitize() clamps anything
    out of range if those arrays ever shrink."""
    return json.dumps({
        "skin":       random.randint(0, 7),
        "hair_style": random.randint(0, 11),
        "hair_color": random.randint(0, 13),
        "beard":      random.randint(0, 9),
        "body":       random.randint(0, 2),
        "tunic":      random.randint(0, 5),
        "eye_color":  random.randint(0, 7),
    })


def _new_thrall(conn, owner_id: str, tier: int) -> str:
    """Insert a fresh Lv-1 thrall of the given tier. Returns its id."""
    tier = max(1, min(6, int(tier)))
    tid = secrets.token_hex(8)
    name = random.choice(THRALL_NAMES)
    mhp = _thrall_max_hp(tier, 1)
    conn.execute(
        "INSERT INTO thralls (id, owner_id, name, tier, level, xp, job, target, "
        "appearance, hp, max_hp, backpack, created_at) "
        "VALUES (?,?,?,?,1,0,'','',?,?,?,'[]',?)",
        (tid, owner_id, name, tier, _random_thrall_appearance(), mhp, mhp, time.time()))
    return tid


async def _send_thralls(ws, owner_id: str) -> None:
    with _db() as conn:
        rows = conn.execute(
            "SELECT * FROM thralls WHERE owner_id=? ORDER BY created_at",
            (owner_id,)).fetchall()
        srow = conn.execute("SELECT thrall_slots FROM players WHERE id=?",
                            (owner_id,)).fetchone()
        slots = int(srow["thrall_slots"] or 2) if srow else 2
    await _send(ws, {"type": "thralls",
                     "thralls": [_thrall_to_dict(r) for r in rows],
                     "slots": slots, "max_slots": THRALL_MAX_SLOTS})


# ── Thrall offline simulation (Phase 10b) ───────────────────────────────────
# Server-side mirror of GameManager.FOOD_HEAL — how much a combat thrall heals
# per food unit it auto-eats from its backpack. Keep in sync with the client.
_THRALL_FOOD_HEAL = {
    "cooked_fish": 5, "herb_tea": 4, "cooked_salmon": 9, "cooked_lobster": 16,
    "cooked_shark": 22, "eel_stew": 30, "cooked_rat_meat": 3, "roasted_chicken": 4,
    "grilled_trout": 6, "baked_potato": 5, "vegetable_stew": 8, "meat_pie": 12,
    "fish_soup": 11, "hearty_stew": 15, "shark_steak": 20, "honey_glazed_ham": 19,
    "stuffed_boar": 24, "spiced_fish": 22, "dragon_fin_soup": 28,
    "mead_braised_ribs": 27, "frost_trout_fillet": 33, "venison_roast": 31,
    "magma_prawn": 37, "smoked_bear": 36, "elder_fish_platter": 42,
    "giants_feast": 46, "leviathan_stew": 55, "kraken_platter": 66,
    "feast_of_valhalla": 80, "wheat_bread": 5, "carrot_stew": 12,
    "moonwheat_loaf": 40,
    # Farming crop dishes (1.6.2) — keep in sync with GameManager.FOOD_HEAL.
    "barley_porridge": 6, "steamed_cabbage": 6, "dark_bread": 8, "roasted_corn": 8,
    "boiled_potato": 9, "garden_salad": 15, "sweet_loaf": 14, "farmers_stew": 20,
    "ale": 10, "stuffed_pepper": 16, "melon_slice": 24, "apple_pie": 36,
    "berry_fruit_bowl": 30, "peach_cobbler": 42, "fine_wine": 46,
}

# Chance a monster kill yields a thrall (Phase 10c), gated on a free roster slot.
THRALL_DROP_CHANCE = 0.04


def _thrall_efficiency(level: int) -> float:
    """Long-serving thralls work a little faster/richer: +1% yield per level to
    a +50% cap. Tunable."""
    return 1.0 + min(0.5, max(0, level - 1) * 0.01)


def _thrall_level_for_xp(xp: int) -> int:
    """Thrall display level. 1-99 use the standard RuneScape curve; past 99 the
    level is UNCAPPED but each further level costs an extremely large, growing
    amount of XP so 99+ is real prestige."""
    lv = _calc_level(xp)          # caps at 99
    if lv < 99:
        return lv
    over = xp - _XP_TABLE[99]
    extra = 0
    need = 5_000_000             # XP for level 100 past the 99 cap
    while over >= need and extra < 900:
        over -= need
        extra += 1
        need = int(need * 1.15)
    return 99 + extra


def _thrall_eat_one(backpack: list, hp: int, max_hp: int) -> int:
    """Consume ONE food unit from the backpack to heal the thrall. Returns the
    new hp, or -1 if no food is available (so the caller stops trying)."""
    for it in list(backpack):
        if not isinstance(it, dict):
            continue
        heal = _THRALL_FOOD_HEAL.get(str(it.get("id", "")), 0)
        if heal > 0 and int(it.get("qty", 0)) > 0:
            it["qty"] = int(it["qty"]) - 1
            if it["qty"] <= 0:
                backpack.remove(it)
            return min(max_hp, hp + heal)
    return -1


def _simulate_one_thrall(conn, r, elapsed: float, skill_xp: dict) -> dict:
    """Run one assigned thrall's offline work over `elapsed` seconds. Mutates
    `skill_xp` (the player's — persisted by the caller), updates/deletes the
    thrall row, and returns a summary line. Gather tasks are safe; combat tasks
    take damage, auto-eat food, and can PERMADEATH when food runs out."""
    tid    = r["id"]
    name   = str(r["name"])
    tier   = int(r["tier"] or 1)
    job    = str(r["job"] or "")
    target = str(r["target"] or "")
    reward = TASK_REWARDS.get((job, target))
    if not reward:
        return {}

    thrall_xp    = int(r["xp"] or 0)
    level_before = _thrall_level_for_xp(thrall_xp)
    max_hp       = int(r["max_hp"] or _thrall_max_hp(tier, level_before))
    hp           = int(r["hp"] or 0) or max_hp
    try:
        backpack = json.loads(r["backpack"] or "[]")
    except Exception:
        backpack = []
    eff          = _thrall_efficiency(level_before)
    player_skill = str(reward["skill"])
    player_xp    = 0
    loot         = 0
    dead         = False

    if job == "combat":
        swing   = float(reward["swing_time"]) * 1.25
        atk     = max(1, tier * 3 + level_before // 3)   # thrall's damage
        swings_per_kill = max(1, math.ceil(int(reward["monster_hp"]) / atk))
        # V1.5.5: quarter the output — each kill effectively takes 4× longer,
        # so kills/loot/xp (and damage taken) all scale down together.
        time_per_kill   = swings_per_kill * swing / THRALL_WORK_YIELD
        dmg_per_kill    = max(0, int(reward["monster_atk"]) - tier) * swings_per_kill
        xp_kill = int(reward["xp_kill"])
        kills   = 0
        t       = 0.0
        while t + time_per_kill <= elapsed:
            t  += time_per_kill
            hp -= dmg_per_kill
            # Auto-eat below half health while food remains.
            while hp < max_hp // 2:
                healed = _thrall_eat_one(backpack, hp, max_hp)
                if healed < 0:
                    break
                hp = healed
            if hp <= 0:
                dead = True
                break
            kills += 1
            gained = max(1, int(xp_kill * IDLE_EFFICIENCY * eff))
            player_xp += gained
            # Player skill XP: same melee/defense/vitality split as the live
            # idle sim so offline combat progresses defence + hp too.
            for s in ("melee", "defense", "vitality"):
                skill_xp[s] = skill_xp.get(s, 0) + gained // 3
            thrall_xp += gained
            _clan_bank_add(backpack, str(reward["item_id"]), str(reward["item_name"]),
                           1, _color_for_item(str(reward["item_id"])))
            loot += 1
        note = (f"⚠ died fighting {target} — ran out of food"
                if dead else f"killed {kills} {target}")
    else:
        swing  = float(reward["swing_time"]) * 1.25
        chance = min(1.0, _calc_success_chance(reward, skill_xp))
        # V1.5.5: quarter the output by stretching the effective gather period.
        period = (swing / max(0.05, chance) + IDLE_GATHER_RESPAWN) / THRALL_WORK_YIELD
        gathers = int((elapsed / period) * eff)
        per_xp  = max(1, int(int(reward["xp"]) * IDLE_EFFICIENCY))
        for _ in range(gathers):
            skill_xp[player_skill] = skill_xp.get(player_skill, 0) + per_xp
            player_xp += per_xp
            thrall_xp += per_xp
            _clan_bank_add(backpack, str(reward["item_id"]), str(reward["item_name"]),
                           1, _color_for_item(str(reward["item_id"])))
        loot = gathers
        note = f"gathered {gathers} {reward['item_name']}"

    level_after = _thrall_level_for_xp(thrall_xp)
    if dead:
        conn.execute("DELETE FROM thralls WHERE id=?", (tid,))
    else:
        new_max = _thrall_max_hp(tier, level_after)
        hp = max(1, min(hp, new_max))
        conn.execute(
            "UPDATE thralls SET level=?, xp=?, hp=?, max_hp=?, backpack=? WHERE id=?",
            (level_after, thrall_xp, hp, new_max, json.dumps(backpack), tid))
    return {
        "name": name, "tier": tier,
        "level_before": level_before, "level_after": level_after,
        "dead": dead, "note": note,
        "skill": player_skill, "player_xp": player_xp, "loot": loot,
    }


def _simulate_thralls(player_id: str, now: float) -> dict:
    """Phase 10b — credit every ASSIGNED thrall's offline work for the elapsed
    logged-out window. Grants the PLAYER's skill XP (persisted here), raises
    each thrall's own uncapped level, banks loot in the thrall's backpack, and
    runs combat survival (damage/auto-eat/permadeath). Returns a per-thrall
    summary for the client, or {} when nothing happened. Called on login BEFORE
    the payload is built so granted XP is reflected."""
    try:
        with _db() as conn:
            prow = conn.execute(
                "SELECT skill_xp, thrall_logout_at FROM players WHERE id=?",
                (player_id,)).fetchone()
            if not prow:
                return {}
            logout_at = float(prow["thrall_logout_at"] or 0.0)
            # Consume the window unconditionally so we never double-credit.
            conn.execute("UPDATE players SET thrall_logout_at=0 WHERE id=?",
                         (player_id,))
            conn.commit()
            if logout_at <= 0.0:
                return {}
            # Thralls work at most a 12h shift, THEN rest — no credit past the
            # cap no matter how long the owner is away (V1.5.5 rebalance).
            elapsed = max(0.0, min(now - logout_at, THRALL_MAX_WORK_SECONDS))
            if elapsed < 60.0:                     # under a minute — not worth it
                return {}
            trows = conn.execute(
                "SELECT * FROM thralls WHERE owner_id=? AND job!='' AND target!=''",
                (player_id,)).fetchall()
            if not trows:
                return {}
            skill_xp = json.loads(prow["skill_xp"] or "{}")
            reports = []
            for r in trows:
                rep = _simulate_one_thrall(conn, r, elapsed, skill_xp)
                if rep:
                    reports.append(rep)
            conn.execute("UPDATE players SET skill_xp=? WHERE id=?",
                         (json.dumps(skill_xp), player_id))
            conn.commit()
            if not reports:
                return {}
            return {"elapsed_seconds": int(elapsed), "thralls": reports}
    except Exception as e:
        print(f"[thrall-sim] {player_id}: {e!r}")
        return {}


async def _maybe_drop_thrall(owner_id: str, monster_level: int) -> None:
    """Phase 10c — small chance a kill yields a thrall whose tier = the killed
    monster's level band. Only fires when the killer has a free roster slot."""
    if random.random() >= THRALL_DROP_CHANCE:
        return
    tier = _level_band_tier(max(1, int(monster_level)))
    tname = ""
    with _db() as conn:
        prow = conn.execute("SELECT thrall_slots FROM players WHERE id=?",
                            (owner_id,)).fetchone()
        if not prow:
            return
        slots = int(prow["thrall_slots"] or 2)
        crow = conn.execute("SELECT COUNT(*) AS c FROM thralls WHERE owner_id=?",
                            (owner_id,)).fetchone()
        if int(crow["c"] or 0) >= slots:
            return                                 # roster full — no drop
        tid = _new_thrall(conn, owner_id, tier)
        nrow = conn.execute("SELECT name FROM thralls WHERE id=?", (tid,)).fetchone()
        conn.commit()
        tname = nrow["name"] if nrow else "a thrall"
    ows = _ws_for_player(owner_id)
    if ows is not None:
        await _send(ows, {"type": "thrall_drop", "name": tname, "tier": tier})
        await _send_thralls(ows, owner_id)


async def _handle_thralls_list(ws, session, msg: dict) -> None:
    await _send_thralls(ws, session["id"])


async def _handle_thrall_assign(ws, session, msg: dict) -> None:
    tid = str(msg.get("id", ""))
    job = str(msg.get("job", ""))
    target = str(msg.get("target", ""))
    town = str(msg.get("town", ""))
    with _db() as conn:
        row = conn.execute("SELECT tier FROM thralls WHERE id=? AND owner_id=?",
                           (tid, session["id"])).fetchone()
        if not row:
            return
        if job and target:
            reward = TASK_REWARDS.get((job, target))
            if reward is None:
                await _send(ws, {"type": "thrall_result", "ok": False,
                                 "reason": "Unknown task."})
                return
            tgt_tier = _level_band_tier(int(reward.get("level", 1)))
            if tgt_tier > int(row["tier"]):
                await _send(ws, {"type": "thrall_result", "ok": False,
                                 "reason": "That task is above this thrall's tier."})
                return
            # A working thrall must be sent to a town that actually offers this
            # resource at this tier (V1.5.5 gating).
            if not town or town not in TOWN_NAMES:
                await _send(ws, {"type": "thrall_result", "ok": False,
                                 "reason": "Pick a town to send this thrall to."})
                return
            if not _town_offers(town, job, tgt_tier):
                await _send(ws, {"type": "thrall_result", "ok": False,
                                 "reason": "%s doesn't offer that resource." %
                                 TOWN_NAMES.get(town, town)})
                return
        else:
            town = ""   # clearing the task also clears the town
        conn.execute("UPDATE thralls SET job=?, target=?, town=? WHERE id=?",
                     (job, target, town, tid))
        conn.commit()
    await _send_thralls(ws, session["id"])


async def _handle_thrall_buy_slot(ws, session, msg: dict) -> None:
    with _db() as conn:
        prow = conn.execute("SELECT gold, thrall_slots FROM players WHERE id=?",
                            (session["id"],)).fetchone()
        slots = int(prow["thrall_slots"] or 2) if prow else 2
        gold = int(prow["gold"] or 0) if prow else 0
        nxt = slots + 1
        if nxt > THRALL_MAX_SLOTS:
            await _send(ws, {"type": "thrall_result", "ok": False,
                             "reason": "Already at max thrall slots."})
            return
        cost = int(THRALL_SLOT_COST.get(nxt, 0))
        if gold < cost:
            await _send(ws, {"type": "thrall_result", "ok": False,
                             "reason": f"Need {cost}g for slot {nxt} (have {gold})."})
            return
        conn.execute("UPDATE players SET gold=?, thrall_slots=? WHERE id=?",
                     (gold - cost, nxt, session["id"]))
        conn.commit()
    await _send(ws, {"type": "gold_set", "gold": gold - cost})
    await _send_thralls(ws, session["id"])


async def _handle_thrall_backpack(ws, session, msg: dict, deposit: bool) -> None:
    tid = str(msg.get("id", ""))
    item_id = str(msg.get("item_id", ""))
    qty = max(1, int(msg.get("qty", 1)))
    if not tid or not item_id:
        return
    with _db() as conn:
        trow = conn.execute("SELECT backpack FROM thralls WHERE id=? AND owner_id=?",
                           (tid, session["id"])).fetchone()
        if not trow:
            return
        pack = json.loads(trow["backpack"] or "[]")
        prow = conn.execute("SELECT inventory FROM players WHERE id=?",
                           (session["id"],)).fetchone()
        inv = json.loads(prow["inventory"] or "[]") if prow else []
        src = inv if deposit else pack
        dst = pack if deposit else inv
        have = sum(int(it.get("qty", 0)) for it in src
                   if isinstance(it, dict) and it.get("id") == item_id)
        move = min(qty, have)
        if move <= 0:
            return
        item_name = item_id
        for it in src:
            if isinstance(it, dict) and it.get("id") == item_id:
                item_name = str(it.get("name", item_id))
                break
        _inv_remove_qty(src, item_id, move)
        # Bank-style merge-by-id into the destination.
        _clan_bank_add(dst, item_id, item_name, move, _color_for_item(item_id))
        conn.execute("UPDATE players SET inventory=? WHERE id=?",
                     (json.dumps(inv), session["id"]))
        conn.execute("UPDATE thralls SET backpack=? WHERE id=?",
                     (json.dumps(pack), tid))
        conn.commit()
    # clan_bank_result is the existing "server moved items, here's your new
    # inventory" sync the client already applies.
    await _send(ws, {"type": "clan_bank_result", "ok": True, "inventory": inv})
    await _send_thralls(ws, session["id"])


async def _handle_admin_grant_thrall(ws, session, msg: dict) -> None:
    if not _is_admin(session):
        return
    target = str(msg.get("target", "")).strip()
    tier = max(1, min(6, int(msg.get("tier", 1))))
    with _db() as conn:
        trow = conn.execute("SELECT id FROM players WHERE username=? COLLATE NOCASE",
                           (target,)).fetchone()
        if not trow:
            await _admin_confirm(ws, f"No such player: {target}")
            return
        _new_thrall(conn, trow["id"], tier)
        conn.commit()
        tid = trow["id"]
    tws = _ws_for_player(tid)
    if tws is not None:
        await _send_thralls(tws, tid)
    await _admin_confirm(ws, f"Granted a Tier {tier} thrall to {target}.")


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
    elif mtype == "spectate":
        # Read-only observer — handled before the auth gate since a spectator
        # deliberately never holds a session. Every OTHER gameplay message from
        # this socket still falls through to the "Not authenticated" reject.
        await _handle_spectate(ws, msg)
    elif session is None:
        await _send(ws, {"type": "error", "reason": "Not authenticated."})
    elif mtype == "move":
        await _handle_move(ws, session, msg)
    elif mtype == "pvp_toggle":
        await _handle_pvp_toggle(ws, session, msg)
    elif mtype == "pvp_attack":
        await _handle_pvp_attack(ws, session, msg)
    elif mtype == "pvp_death":
        await _handle_pvp_death(ws, session, msg)
    elif mtype == "token_upgrade":
        await _handle_token_upgrade(ws, session, msg)
    elif mtype == "fast_travel":
        await _handle_fast_travel(ws, session, msg)
    elif mtype == "discover_town":
        await _handle_discover_town(ws, session, msg)
    elif mtype == "rankings_request":
        await _handle_rankings(ws, msg)
    elif mtype == "fish_caught":
        await _handle_fish_caught(ws, session, msg)
    elif mtype == "fishing_data_request":
        await _send(ws, {"type": "fishing_data",
                         "records": _fishing_records_all(),
                         "journal": _fishing_journal_for(session["id"])})
    elif mtype == "reputation_request":
        await _handle_reputation_request(ws, session, msg)
    elif mtype == "npc_damage":
        await _handle_npc_damage(ws, session, msg)
    elif mtype == "caravan_damage":
        await _handle_caravan_damage(ws, session, msg)
    elif mtype == "warband_caravan_create":
        await _handle_warband_caravan_create(ws, session, msg)
    elif mtype == "warband_caravan_disband":
        await _handle_warband_caravan_disband(ws, session, msg)
    elif mtype == "bank_gold_deposit":
        await _handle_bank_gold(ws, session, msg, True)
    elif mtype == "bank_gold_withdraw":
        await _handle_bank_gold(ws, session, msg, False)
    elif mtype == "thralls_list":
        await _handle_thralls_list(ws, session, msg)
    elif mtype == "thrall_assign":
        await _handle_thrall_assign(ws, session, msg)
    elif mtype == "thrall_buy_slot":
        await _handle_thrall_buy_slot(ws, session, msg)
    elif mtype == "thrall_backpack_deposit":
        await _handle_thrall_backpack(ws, session, msg, True)
    elif mtype == "thrall_backpack_withdraw":
        await _handle_thrall_backpack(ws, session, msg, False)
    elif mtype == "admin_grant_thrall":
        await _handle_admin_grant_thrall(ws, session, msg)
    elif mtype == "pvp_pile_pickup":
        await _handle_pvp_pile_pickup(ws, session, msg)
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
            # /tokens <player> <amount> — admin grant PvP Tokens (Phase 1d),
            # for testing upgrades before the PvP kill loop lands (Phase 8).
            if text.startswith("/tokens "):
                parts = text.split()
                if _is_admin(session) and len(parts) >= 3:
                    try:
                        await _handle_admin_tokens(ws, session, {
                            "target": parts[1], "amount": int(parts[2])})
                    except ValueError:
                        await _admin_confirm(ws, "Usage: /tokens <player> <amount>")
                return
            # /thrall <player> <tier> — admin grant a thrall for testing (Phase 10).
            if text.startswith("/thrall "):
                parts = text.split()
                if _is_admin(session) and len(parts) >= 3:
                    try:
                        await _handle_admin_grant_thrall(ws, session, {
                            "target": parts[1], "tier": int(parts[2])})
                    except ValueError:
                        await _admin_confirm(ws, "Usage: /thrall <player> <tier 1-6>")
                return
            # /rep <player> <town> <amount> — admin standing grant (Phase 5a).
            if text.startswith("/rep "):
                parts = text.split()
                if _is_admin(session) and len(parts) >= 4:
                    try:
                        await _handle_admin_rep(ws, session, parts[1],
                                                parts[2].lower(), int(parts[3]))
                    except ValueError:
                        await _admin_confirm(ws,
                            "Usage: /rep <player> <town> <amount>")
                elif _is_admin(session):
                    await _admin_confirm(ws,
                        "Usage: /rep <player> <town> <amount>  towns: "
                        + ", ".join(ALL_TOWN_IDS))
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
    elif mtype == "farm_plant":
        await _handle_farm_plant(ws, session, msg)
    elif mtype == "farm_water":
        await _handle_farm_water(ws, session, msg)
    elif mtype == "farm_harvest":
        await _handle_farm_harvest(ws, session, msg)
    elif mtype == "admin_grant_mapper":
        await _handle_admin_grant_mapper(ws, session, msg)
    elif mtype == "admin_revoke_mapper":
        await _handle_admin_revoke_mapper(ws, session, msg)
    elif mtype == "admin_place":
        await _handle_admin_place(ws, session, msg)
    elif mtype == "admin_delete":
        await _handle_admin_delete(ws, session, msg)
    elif mtype == "admin_move":
        await _handle_admin_move(ws, session, msg)
    elif mtype == "admin_rotate":
        await _handle_admin_rotate(ws, session, msg)
    elif mtype == "admin_edit_entity":
        await _handle_admin_edit_entity(ws, session, msg)
    elif mtype == "admin_sculpt":
        await _handle_admin_sculpt(ws, session, msg)
    elif mtype == "admin_road_set":
        await _handle_admin_road_set(ws, session, msg)
    elif mtype == "admin_gold":
        await _handle_admin_gold(ws, session, msg)
    elif mtype == "admin_tokens":
        await _handle_admin_tokens(ws, session, msg)
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
    elif mtype == "admin_delete_account":
        await _handle_admin_delete_account(ws, session, msg)
    elif mtype == "admin_verify_email":
        await _handle_admin_verify_email(ws, session, msg)
    elif mtype == "admin_upload_terrain":
        await _handle_admin_upload_terrain(ws, session, msg)
    elif mtype == "admin_upload_node_map":
        await _handle_admin_upload_node_map(ws, session, msg)
    elif mtype == "admin_upload_monster_loot":
        await _handle_admin_upload_monster_loot(ws, session, msg)
    elif mtype == "admin_upload_recipes":
        await _handle_admin_upload_recipes(ws, session, msg)
    elif mtype == "admin_upload_fish":
        await _handle_admin_upload_fish(ws, session, msg)
    elif mtype == "admin_upload_sea_loot":
        await _handle_admin_upload_sea_loot(ws, session, msg)
    elif mtype == "admin_season_reset":
        await _handle_admin_season_reset(ws, session, msg)
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
    elif mtype == "clan_buy_tab":
        await _handle_clan_buy_tab(ws, session, msg)
    elif mtype == "clan_gold_deposit":
        await _handle_clan_gold_deposit(ws, session, msg)
    elif mtype == "clan_gold_withdraw":
        await _handle_clan_gold_withdraw(ws, session, msg)
    elif mtype == "clan_set_perm":
        await _handle_clan_set_perm(ws, session, msg)
    elif mtype == "clan_set_gold_limit":
        await _handle_clan_set_gold_limit(ws, session, msg)
    elif mtype == "player_mime":
        await _handle_player_mime(ws, session, msg)
    elif mtype == "player_hp":
        # Client reports its HP fraction so the town watch only intervenes when the
        # player is actually in trouble (see GUARD_DEFEND_HP_FRAC).
        try:
            session["hp_frac"] = max(0.0, min(1.0, float(msg.get("frac", 1.0))))
        except Exception:
            pass
    elif mtype == "spectate_event":
        await _handle_spectate_event(ws, session, msg)
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
    elif mtype == "monster_damage" or mtype == "monster_attack":
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
    elif mtype == "craft":
        await _handle_craft(ws, session, msg)
    elif mtype == "sea_combat_win":
        await _handle_sea_combat_win(ws, session, msg)
    elif mtype == "gold_pile_pickup":
        await _handle_gold_pile_pickup(ws, session, msg)
    elif mtype == "enter_interior":
        await _handle_enter_interior(ws, session, msg)
    elif mtype == "exit_interior":
        await _handle_exit_interior(ws, session, msg)
    elif mtype == "dungeon_enter":
        await _handle_dungeon_enter(ws, session, msg)


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
        # Drop any read-only spectator entry for this socket (no play state to
        # clean up — it never held a session).
        spectators.pop(ws, None)
        session = sessions.pop(ws, None)
        if session:
            player_id = session["id"]
            # Phase 10b — stamp the logout time so assigned thralls accrue
            # offline work over this logged-out window (credited on next login).
            try:
                with _db() as conn:
                    conn.execute(
                        "UPDATE players SET thrall_logout_at=? WHERE id=?",
                        (time.time(), player_id))
                    conn.commit()
            except Exception as e:
                print(f"[thrall-logout] {player_id}: {e!r}")
            if player_id in trades:
                await _end_trade(player_id, "Trade partner disconnected.")
            # Stand the city watch down — otherwise logging out mid-fight
            # would strand guards in Kjelvik forever (Phase 5b).
            _guard_clear(player_id)
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
    # Farm plot state — same pattern: reload persisted plot timers so
    # crops that were mid-growth at shutdown resume from where they were.
    _load_farm_plots_from_disk()
    # Town farm plots — seed the 9 world entities (idempotent) + rehydrate the
    # per-player crop state so a restart resumes everyone's town crops.
    _seed_town_farm_plots()
    _load_farm_plots_town_from_disk()
    # Dungeons (v1.5.3) — seed each dungeon's entrance + interior monsters/ore
    # as world_entities (idempotent) before the first login burst goes out.
    _seed_dungeons()
    # Caravan road routes — BFS over the real road tiles, computed once.
    _build_caravan_routes()
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
    _load_node_drops()   # B2a — server-authoritative gather drops (if baked)
    _load_monster_loot() # B3 — server-authoritative monster loot (if baked)
    _load_craft_recipes()  # ⑤ — server-authoritative craft recipes (if baked)
    _load_fish_species()   # ⑥ — server-authoritative fishing catches (if baked)
    _load_sea_loot()       # ⑥ — server-authoritative sea-combat loot (if baked)
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
    # Seed Kjelvik's client-generated castle ring as real structures so it's
    # attackable / repairable like every other town wall (fills only ids the
    # mirror didn't already restore, so damaged HP persists).
    _seed_castle_structures()
    # Expand town bounds to enclose their perimeter walls (so the outer wall
    # ring is named + defended + rep-gated as part of the town). Needs the
    # world_entities rows, which exist by now.
    _recompute_town_bounds()
    for _tid in _TOWN_TILE_BOUNDS:
        _b = _bounds_of(_tid)
        if _b != _TOWN_TILE_BOUNDS[_tid]:
            print(f"[town] {_tid} bounds expanded to {_b} by its walls")
    # Orphan purge runs AFTER rehydrate so it can see the loaded ghost
    # rows. Any monsters_state entry whose id doesn't have a live
    # world_entities row gets dropped from both RAM and SQLite. Previously
    # this ran BEFORE rehydrate against an empty dict — did nothing, and
    # procedural monsters from before PROCEDURAL_MONSTERS=false lingered
    # in the AI loop count forever.
    _purge_orphan_monster_state()
    global _shutdown_event
    _shutdown_event = asyncio.Event()
    _install_shutdown_handlers()
    print(f"VikingVale server  ws://0.0.0.0:{PORT}")
    print("[server-build] spectate-relay+mime-gather · 2026-08-23")
    print("Press Ctrl+C to stop.\n")
    async with serve(handle_connection, "0.0.0.0", PORT) as server:
        # Background loops run as tasks so we can wait on the shutdown signal
        # instead of blocking forever in gather(). serve_forever() is a task
        # too; it's cancelled below once we've flushed saves.
        bg_tasks = [asyncio.create_task(coro) for coro in (
            server.serve_forever(),
            _autosave_loop(),
            _tile_overrides_autosave_loop(),
            _world_tick_loop(),
            _monster_ai_loop(),
            _guard_decay_loop(),
            _town_wall_repair_loop(),
            _npc_respawn_loop(),
            _caravan_loop(),
            _shop_restock_loop(),
            _shop_stock_autosave_loop(),
            _farm_plots_autosave_loop(),
            _uptime_counter_loop(),
            _monster_state_flush_loop(),
            _structure_state_flush_loop(),
        )]
        try:
            await _shutdown_event.wait()
        finally:
            # Data-loss guard: persist every online player BEFORE the server
            # closes. Runs inside the serve() context so connection read loops
            # are still processing the incoming saves.
            print("\n[shutdown] signal received — saving online players first.")
            try:
                await _save_all_online()
            except Exception as e:
                print(f"[shutdown] save flush error: {e!r}")
            for t in bg_tasks:
                t.cancel()
            for t in bg_tasks:
                try:
                    await t
                except (asyncio.CancelledError, Exception):
                    pass
    print("[shutdown] Server stopped cleanly.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[shutdown] Server stopped.")
