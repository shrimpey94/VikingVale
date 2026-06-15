"""Server-side terrain passability.

Goal: prevent the monster AI from stepping into ocean / coast tiles when
chasing a player. The server doesn't actually generate biomes itself —
that's done procedurally by Ground.gd on the client. Porting the full
GLSL-driven biome formula to Python is multi-day work and locks the two
generators together with every future tweak.

Pragmatic compromise: keep an OPTIONAL passability bitmap on disk
(`server/terrain.bin`). 300×300 bits = ~11 KB. If the file exists, the
monster step function consults it; if it doesn't, the server falls back
to "everything walkable" (current behavior, status quo).

Generating the file is a one-time client task — an admin command bakes
the bitmap from Ground.biome_at_world and uploads it. Done once per
world; permanent until biome generation changes.

API:
    terrain.load() -> bool            — call once at boot
    terrain.is_passable(x, y) -> bool — used by _step_toward
    terrain.save_bitmap(bytes) -> None — admin upload entry point
"""

from __future__ import annotations

from pathlib import Path
import os


TERRAIN_FILE = Path(__file__).parent / "terrain.bin"

# World grid — 300×300 tiles at 32 px each = 9600 px world. Matches
# server.py WORLD_W / WORLD_H. Bumping these constants requires re-baking
# the bitmap.
GRID_W = 300
GRID_H = 300
TILE_PX = 32

_passable: bytearray | None = None


def load() -> bool:
    """Load terrain.bin into memory. Returns True if a bitmap is now
    available. Idempotent; safe to call from boot."""
    global _passable
    if not TERRAIN_FILE.exists():
        _passable = None
        print(f"[terrain] no terrain.bin — monster movement unrestricted")
        return False
    try:
        data = TERRAIN_FILE.read_bytes()
        expected = (GRID_W * GRID_H + 7) // 8
        if len(data) != expected:
            print(f"[terrain] size mismatch: got {len(data)}, expected "
                  f"{expected} — ignoring")
            _passable = None
            return False
        _passable = bytearray(data)
        print(f"[terrain] loaded {len(data)} bytes "
              f"({GRID_W}×{GRID_H} tiles)")
        return True
    except Exception as ex:
        print(f"[terrain] load failed: {ex}")
        _passable = None
        return False


def save_bitmap(raw: bytes) -> bool:
    """Persist a fresh bitmap (uploaded by an admin client). The format
    is 1 bit per tile, row-major, MSB-first within each byte; bit=1 means
    passable. Called from server.py's admin route handler."""
    global _passable
    expected = (GRID_W * GRID_H + 7) // 8
    if len(raw) != expected:
        print(f"[terrain] save rejected: size mismatch "
              f"(got {len(raw)}, expected {expected})")
        return False
    try:
        TERRAIN_FILE.write_bytes(raw)
        _passable = bytearray(raw)
        print(f"[terrain] saved {len(raw)} bytes — now active")
        return True
    except Exception as ex:
        print(f"[terrain] save failed: {ex}")
        return False


def is_passable(world_x: float, world_y: float) -> bool:
    """Returns True if the tile at (world_x, world_y) world coordinates
    can be walked into by a monster. Defaults to True (no blocking) when
    no bitmap is loaded, or when the coords fall outside the grid.

    Per-tile admin-painted passability overrides ALWAYS win — when an
    admin manually paints a tile as impassable via the editor, the
    answer is False regardless of the bitmap. This lets admins block
    individual tiles (chokepoints, bridges) without re-baking the
    bitmap, and also lets them override the bitmap to OPEN water tiles
    that the bitmap blocks (rare but useful)."""
    tx = int(world_x // TILE_PX)
    ty = int(world_y // TILE_PX)
    # Per-tile admin override (admin_tile_passability handler).
    try:
        import server as _server  # late import — avoid circular
        key = f"{tx},{ty}"
        if key in _server.tile_passability:
            return bool(_server.tile_passability[key])
    except Exception:
        pass
    if _passable is None:
        return True
    if tx < 0 or ty < 0 or tx >= GRID_W or ty >= GRID_H:
        return True
    bit_index = ty * GRID_W + tx
    byte_index = bit_index // 8
    bit_offset = 7 - (bit_index % 8)
    return bool((_passable[byte_index] >> bit_offset) & 1)


def is_loaded() -> bool:
    return _passable is not None
