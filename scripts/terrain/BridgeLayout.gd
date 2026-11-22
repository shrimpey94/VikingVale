extends RefCounted
## Connected bridges (1.7.6): work out which bridge PIECE each bridge tile shows,
## from its neighbours, so adjacent bridge tiles read as one bridge.
##
## Pure layout, no art: the 2D layer (BridgeLayer2D) and 3D decks (BridgeDeck3D)
## draw whatever pieces the art kit provides (placeholders until the kit is
## approved). Visual only: tile ids, passability and collision are untouched.
##
## A bridge is a 4-connected group of wood/stone bridge tiles (ids 48/49). Each
## group gets one run AXIS (horizontal = runs east-west, vertical = north-south):
## the longer side of its bounding box, else the direction with more internal
## links, else the direction with more landings, else horizontal. Per tile, with
## sides N=1 E=2 S=4 W=8 in world directions:
##   conn    sides joined to another tile of the same bridge (no water between)
##   rails   sides ACROSS the run with no bridge neighbour (outer edges: railing)
##   ends    sides ALONG the run with no bridge neighbour (the bridge stops here)
##   landing the subset of `ends` that meet land (not water): a landing/approach
##   piece   centre | edge | span | end | corner | span_end | single
##           (rail count 0/1/2 x end count 0/1/2, see _piece)

const N := 1
const E := 2
const S := 4
const W := 8
const AXIS_H := 0
const AXIS_V := 1
const WOOD := 48
const STONE := 49
const DOCK := 94
const _WATER := [8, 9, 24, 44, 45, 57, 58]

static func is_bridge(id: int) -> bool:
	return id == WOOD or id == STONE

static func is_water(id: int) -> bool:
	return id in _WATER

## ids: one biome id per tile, row-major (cols x rows) — e.g. the R8 bytes of
## Ground's biome lookup image. Returns {"tiles": {idx: info}, "groups": [group]}
## info  = {tx, ty, id, group, axis, conn, rails, ends, landing, piece, along}
## group = {id, axis, tiles: [idx], min: Vector2i, max: Vector2i}
static func classify(ids: PackedByteArray, cols: int, rows: int) -> Dictionary:
	var tiles := {}
	var groups: Array = []
	var seen := {}
	for i in range(mini(ids.size(), cols * rows)):
		if not is_bridge(ids[i]) or seen.has(i):
			continue
		# Flood one bridge (4-connected, wood and stone together).
		var members: Array = []
		var stack: Array = [i]
		seen[i] = true
		var lo := Vector2i(cols, rows)
		var hi := Vector2i(-1, -1)
		var links_h := 0
		var links_v := 0
		while not stack.is_empty():
			var c: int = stack.pop_back()
			members.append(c)
			var cx := c % cols
			@warning_ignore("integer_division")
			var cy := c / cols
			lo = Vector2i(mini(lo.x, cx), mini(lo.y, cy))
			hi = Vector2i(maxi(hi.x, cx), maxi(hi.y, cy))
			if cx + 1 < cols and is_bridge(ids[c + 1]): links_h += 1
			if cy + 1 < rows and is_bridge(ids[c + cols]): links_v += 1
			for nb: int in _neighbours(c, cols, rows):
				if is_bridge(ids[nb]) and not seen.has(nb):
					seen[nb] = true
					stack.append(nb)
		var size := hi - lo + Vector2i.ONE
		var axis := AXIS_H
		if size.y > size.x:
			axis = AXIS_V
		elif size.x == size.y:
			if links_v > links_h:
				axis = AXIS_V
			elif links_v == links_h and _landings(members, ids, cols, rows, AXIS_V) > _landings(members, ids, cols, rows, AXIS_H):
				axis = AXIS_V
		var gid := groups.size()
		members.sort()
		groups.append({"id": gid, "axis": axis, "tiles": members, "min": lo, "max": hi})
		for c: int in members:
			tiles[c] = _tile_info(c, ids, cols, rows, axis, gid, lo)
	return {"tiles": tiles, "groups": groups}

static func _neighbours(c: int, cols: int, rows: int) -> Array:
	var out: Array = []
	var cx := c % cols
	@warning_ignore("integer_division")
	var cy := c / cols
	if cy > 0: out.append(c - cols)
	if cx + 1 < cols: out.append(c + 1)
	if cy + 1 < rows: out.append(c + cols)
	if cx > 0: out.append(c - 1)
	return out

## Neighbour id on `side`, or -1 off-map.
static func _side_id(c: int, side: int, ids: PackedByteArray, cols: int, rows: int) -> int:
	var cx := c % cols
	@warning_ignore("integer_division")
	var cy := c / cols
	match side:
		N: return ids[c - cols] if cy > 0 else -1
		E: return ids[c + 1] if cx + 1 < cols else -1
		S: return ids[c + cols] if cy + 1 < rows else -1
		_: return ids[c - 1] if cx > 0 else -1

static func _landings(members: Array, ids: PackedByteArray, cols: int, rows: int, axis: int) -> int:
	var n := 0
	for c: int in members:
		for side: int in ([E, W] if axis == AXIS_H else [N, S]):
			var nb := _side_id(c, side, ids, cols, rows)
			if nb >= 0 and not is_bridge(nb) and not is_water(nb):
				n += 1
	return n

static func _tile_info(c: int, ids: PackedByteArray, cols: int, rows: int, axis: int, gid: int, lo: Vector2i) -> Dictionary:
	var conn := 0
	var land := 0
	for side: int in [N, E, S, W]:
		var nb := _side_id(c, side, ids, cols, rows)
		if nb >= 0 and is_bridge(nb):
			conn |= side
		elif nb >= 0 and not is_water(nb):
			land |= side
	var along_sides := (E | W) if axis == AXIS_H else (N | S)
	var across_sides := (N | S) if axis == AXIS_H else (E | W)
	var rails := across_sides & ~conn
	var ends := along_sides & ~conn
	var tx := c % cols
	@warning_ignore("integer_division")
	var ty := c / cols
	return {"tx": tx, "ty": ty, "id": int(ids[c]), "group": gid, "axis": axis,
		"conn": conn, "rails": rails, "ends": ends, "landing": ends & land,
		"piece": _piece(rails, ends),
		"along": (tx - lo.x) if axis == AXIS_H else (ty - lo.y)}

static func _bits(m: int) -> int:
	return (m & 1) + ((m >> 1) & 1) + ((m >> 2) & 1) + ((m >> 3) & 1)

## Piece name from how many outer rails / open ends the tile has.
static func _piece(rails: int, ends: int) -> String:
	var r := _bits(rails)
	var e := _bits(ends)
	if e == 0:
		return str(["centre", "edge", "span"][r])
	if e == 1:
		return str(["end", "corner", "span_end"][r])
	return "single"

## Docks (id 94) are NOT bridges: they never join a bridge and get no rails.
## Per dock tile: which sides face open water (edge posts go there), which meet
## land (the 3D deck height comes from those), and its 4-connected dock group.
## Returns {idx: {tx, ty, water, land, group}} (masks are N/E/S/W bits).
static func docks(ids: PackedByteArray, cols: int, rows: int) -> Dictionary:
	var out := {}
	var n := mini(ids.size(), cols * rows)
	var gid := 0
	for i in range(n):
		if ids[i] != DOCK or out.has(i):
			continue
		var stack: Array = [i]
		out[i] = {}
		while not stack.is_empty():
			var c: int = stack.pop_back()
			var water := 0
			var land := 0
			for side: int in [N, E, S, W]:
				var nb := _side_id(c, side, ids, cols, rows)
				if nb < 0 or nb == DOCK:
					continue
				if is_water(nb):
					water |= side
				elif not is_bridge(nb):
					land |= side
			@warning_ignore("integer_division")
			var cy := c / cols
			out[c] = {"tx": c % cols, "ty": cy, "water": water, "land": land, "group": gid}
			for nb: int in _neighbours(c, cols, rows):
				if ids[nb] == DOCK and not out.has(nb):
					out[nb] = {}
					stack.append(nb)
		gid += 1
	return out
