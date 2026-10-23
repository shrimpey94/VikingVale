#!/usr/bin/env python3
"""Restore the 3 accidentally-deleted quest-giver NPCs (Blacksmith Ulfr,
Sea Captain Valdis, Captain Sten) by removing their `deleted` overrides from
entity_edits, so the client _NPCS seed respawns them at their canonical spots.

⚠ RUN WHILE THE SERVER IS STOPPED. A running server caches entity_edits in
memory and would re-apply the deletes / not pick this up until restart. So:
  1. stop server.py   2. run this   3. start server.py

Safe to run more than once (idempotent). Makes a .bak first.
"""
import sqlite3, shutil, os, datetime

DB = os.path.join(os.path.dirname(__file__), "game_server.db")
# n:19 = Blacksmith Ulfr, n:35 = Sea Captain Valdis, n:39 = Captain Sten
TARGETS = ("n:19", "n:35", "n:39")

def main() -> None:
    if not os.path.exists(DB):
        print("game_server.db not found next to this script."); return
    bak = DB + ".bak_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(DB, bak)
    print("backup:", os.path.basename(bak))
    c = sqlite3.connect(DB)
    # show what's there first
    rows = c.execute(
        "select id from entity_edits where id in (?,?,?) and x is null",
        TARGETS).fetchall()
    print("delete-overrides found:", [r[0] for r in rows] or "none")
    c.execute("delete from entity_edits where id in (?,?,?)", TARGETS)
    c.commit()
    print("removed override rows:", c.total_changes)
    c.close()
    print("Done. Start the server — Ulfr, Valdis, and Sten respawn from the seed.")

if __name__ == "__main__":
    main()
