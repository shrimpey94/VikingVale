"""Export the login-burst world state from a COPY of a server DB backup as JSON.

The output mirrors the message shapes server.py sends at login (world_entities,
tile_overrides, entity_edits, terrain_heights, road_graph) so an offline client
can replay them into NetworkManager's caches and rebuild the REAL admin map.

Usage:  python -I export_db_snapshot.py <db_copy_path> <out_json>

Read-only. Never point this at the live server DB — copy a backup first.
"""
import json
import sqlite3
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    db_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    if not db_path.is_file():
        print(f"missing db copy: {db_path}")
        return 2
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    # structure_state overlay (server rehydrates structures_state from this table)
    structures = {}
    for r in conn.execute("SELECT entity_id, hp, max_hp, alive FROM structure_state"):
        structures[str(r["entity_id"])] = {
            "hp": int(r["hp"]), "max_hp": int(r["max_hp"]), "alive": bool(r["alive"])}

    entities = []
    for r in conn.execute("SELECT id, kind, subtype, x, y, data FROM world_entities"):
        try:
            data = json.loads(r["data"] or "{}")
        except Exception:
            data = {}
        if not isinstance(data, dict):
            data = {}
        eid = str(r["id"])
        if eid in structures:
            data.update(structures[eid])
        entities.append({"id": eid, "kind": r["kind"], "subtype": r["subtype"],
                         "x": float(r["x"]), "y": float(r["y"]), "data": data})

    overrides = []
    for r in conn.execute(
            "SELECT tx, ty, biome, tint_h, tint_v, passable FROM tile_overrides"):
        overrides.append({"tx": int(r["tx"]), "ty": int(r["ty"]),
                          "biome": str(r["biome"] or ""),
                          "tint_h": int(r["tint_h"] or 0), "tint_v": int(r["tint_v"] or 0),
                          "passable": bool(r["passable"] if r["passable"] is not None else 1)})

    edits = []
    for r in conn.execute("SELECT id, deleted, x, y, rot, data FROM entity_edits"):
        edit = {"id": r["id"], "deleted": bool(r["deleted"]),
                "x": (None if r["x"] is None else float(r["x"])),
                "y": (None if r["y"] is None else float(r["y"])),
                "rot": (0.0 if r["rot"] is None else float(r["rot"]))}
        if r["data"]:
            try:
                d = json.loads(r["data"])
                if isinstance(d, dict) and d:
                    edit["data"] = d
            except Exception:
                pass
        edits.append(edit)

    heights = {str(r["idx"]): float(r["delta"])
               for r in conn.execute("SELECT idx, delta FROM terrain_heights")}

    road = {"nodes": [], "edges": []}
    row = conn.execute("SELECT data FROM road_graph WHERE id=1").fetchone()
    if row:
        try:
            g = json.loads(row["data"])
            if isinstance(g, dict):
                road = {"nodes": g.get("nodes", []), "edges": g.get("edges", [])}
        except Exception:
            pass
    conn.close()

    snapshot = {
        "source_db": db_path.name,
        "counts": {"world_entities": len(entities), "tile_overrides": len(overrides),
                   "entity_edits": len(edits), "terrain_heights": len(heights),
                   "road_nodes": len(road["nodes"])},
        # Same order as the server's login burst.
        "messages": [
            {"type": "world_entities", "entities": entities},
            {"type": "tile_overrides", "overrides": overrides},
            {"type": "entity_edits", "edits": edits},
            {"type": "terrain_heights", "tiles": heights},
            {"type": "road_graph", "nodes": road["nodes"], "edges": road["edges"]},
        ],
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(snapshot), encoding="utf-8")
    print("SNAPSHOT|" + json.dumps(snapshot["counts"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
