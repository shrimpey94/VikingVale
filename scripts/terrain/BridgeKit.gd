extends RefCounted
## Connected bridge kit v001 (1.7.6): which authored pieces each bridge tile
## shows, plus the kit's atlas frames and materials. Shared by the 2D layer
## (BridgeLayer2D) and the 3D decks (BridgeDeck3D). Values are embedded from
## the kit manifest (exports don't reliably pack JSON).
##
## Per tile (BridgeLayout info): exactly ONE opaque base (span, landing_start or
## landing_end) + rail overlays on the outer sides only, picked from the masks:
##   orientation 0 (axis H): left = N, right = S, start = W, end = E
##   orientation 90 (axis V): left = W, right = E, start = S, end = N
## A landing base is used only where that end meets land (open-water ends stay a
## flat span). A tile landing at BOTH ends (1 tile long) uses a flat span: the
## kit has no dual-landing base yet. Rails beside a landing use that end's
## corner overlay; elsewhere the plain edge overlay. Supports go under interior
## centre tiles every 2nd tile along the run. Kit pieces are never rotated or
## rescaled individually: 2D uses the separately rendered 0/90 frames, 3D
## rotates the piece about +Y (0 or +90 degrees).

const BridgeLayout = preload("res://scripts/terrain/BridgeLayout.gd")
const DIR := "res://assets/authored/terrain/bridge_kit/v001/"
const ATLAS := DIR + "bridge_pieces.png"
## Atlas source is 64 px per metre; the game draws 32 px per metre.
const SPRITE_SCALE := 0.5
## Frame key -> [rect x, y, w, h, pivot x, pivot y] (atlas px). The pivot is the
## tile centre at deck height. support_90 is deliberately empty (under the deck).
const FRAMES := {
	"wood_span_0": [0, 0, 76, 80, 38, 38],
	"wood_span_90": [76, 0, 76, 81, 38, 37],
	"wood_edge_left_0": [152, 0, 76, 39, 38, 57],
	"wood_edge_left_90": [228, 0, 29, 120, 48, 54],
	"wood_edge_right_0": [257, 0, 76, 76, 38, 0],
	"wood_edge_right_90": [333, 0, 29, 121, -19, 54],
	"wood_landing_start_0": [362, 0, 76, 82, 38, 37],
	"wood_landing_start_90": [438, 0, 76, 82, 38, 37],
	"wood_landing_end_0": [514, 0, 76, 82, 38, 37],
	"wood_landing_end_90": [590, 0, 76, 78, 38, 34],
	"wood_corner_start_left_0": [666, 0, 76, 42, 38, 57],
	"wood_corner_start_left_90": [742, 0, 24, 100, 38, 57],
	"wood_corner_start_right_0": [766, 0, 76, 44, 38, 0],
	"wood_corner_start_right_90": [842, 0, 23, 101, -15, 57],
	"wood_corner_end_left_0": [865, 0, 76, 43, 38, 57],
	"wood_corner_end_left_90": [941, 0, 23, 96, 38, 54],
	"wood_corner_end_right_0": [0, 121, 76, 44, 38, 0],
	"wood_corner_end_right_90": [76, 121, 24, 96, -14, 54],
	"wood_support_0": [100, 121, 21, 29, 10, -32],
	"wood_support_90": [121, 121, 4, 4, 80, 76],
	"stone_span_0": [125, 121, 76, 80, 38, 38],
	"stone_span_90": [201, 121, 76, 81, 38, 37],
	"stone_edge_left_0": [277, 121, 79, 59, 41, 57],
	"stone_edge_left_90": [356, 121, 31, 122, 50, 54],
	"stone_edge_right_0": [387, 121, 78, 78, 40, 0],
	"stone_edge_right_90": [465, 121, 32, 122, -19, 54],
	"stone_landing_start_0": [497, 121, 76, 82, 38, 37],
	"stone_landing_start_90": [573, 121, 76, 82, 38, 37],
	"stone_landing_end_0": [649, 121, 76, 82, 38, 37],
	"stone_landing_end_90": [725, 121, 76, 78, 38, 34],
	"stone_corner_start_left_0": [801, 121, 76, 42, 38, 57],
	"stone_corner_start_left_90": [877, 121, 24, 100, 38, 57],
	"stone_corner_start_right_0": [901, 121, 76, 44, 38, 0],
	"stone_corner_start_right_90": [977, 121, 23, 101, -15, 57],
	"stone_corner_end_left_0": [0, 243, 76, 43, 38, 57],
	"stone_corner_end_left_90": [76, 243, 23, 96, 38, 54],
	"stone_corner_end_right_0": [99, 243, 76, 44, 38, 0],
	"stone_corner_end_right_90": [175, 243, 24, 96, -14, 54],
	"stone_support_0": [199, 243, 22, 30, 11, -32],
	"stone_support_90": [221, 243, 4, 4, 80, 76]
}
## GLB surface material name -> [terrain texture set or "", colour multiplier].
const MATERIALS := {
	"Timber": ["timber", Color(0.93, 0.87, 0.77)],
	"Stone": ["flagstone", Color(1.02, 1.03, 1.04)],
	"DarkTimber": ["timber", Color(0.52, 0.46, 0.37)],
	"Iron": ["", Color(0.15, 0.17, 0.18)],
	"WetStone": ["flagstone", Color(0.65, 0.72, 0.67)],
}

static func style(info: Dictionary) -> String:
	return "stone" if int(info["id"]) == BridgeLayout.STONE else "wood"

static func angle(info: Dictionary) -> int:
	return 0 if int(info["axis"]) == BridgeLayout.AXIS_H else 90

## World sides for this tile's roles: {left, right, start, end} (N/E/S/W bits).
static func sides(info: Dictionary) -> Dictionary:
	if int(info["axis"]) == BridgeLayout.AXIS_H:
		return {"left": BridgeLayout.N, "right": BridgeLayout.S, "start": BridgeLayout.W, "end": BridgeLayout.E}
	return {"left": BridgeLayout.W, "right": BridgeLayout.E, "start": BridgeLayout.S, "end": BridgeLayout.N}

## {"base": role, "overlays": [role, ...], "support": bool} for one tile.
static func parts(info: Dictionary) -> Dictionary:
	var sd := sides(info)
	var landing := int(info["landing"])
	var rails := int(info["rails"])
	var at_start := (landing & int(sd["start"])) != 0
	var at_end := (landing & int(sd["end"])) != 0
	var base := "span"
	if at_start and not at_end:
		base = "landing_start"
	elif at_end and not at_start:
		base = "landing_end"
	var overlays: Array = []
	for side: String in ["left", "right"]:
		if rails & int(sd[side]) == 0:
			continue
		if base == "landing_start":
			overlays.append("corner_start_" + side)
		elif base == "landing_end":
			overlays.append("corner_end_" + side)
		else:
			overlays.append("edge_" + side)
	var support := base == "span" and rails == 0 and int(info["ends"]) == 0 and int(info["along"]) % 2 == 1
	return {"base": base, "overlays": overlays, "support": support}
