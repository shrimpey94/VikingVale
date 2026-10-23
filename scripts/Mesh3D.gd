extends Node

## v1.6 — procedural ROUNDED low-poly, flat/smooth-shaded 3D meshes for world
## objects. Replaces the billboards (flat + slope-clipping) with real geometry
## matching the terrain's flat-colour look. Rounded organic parts (heads,
## shoulders, torsos, boulders, bushes) use smooth-normal ellipsoids; hard-edged
## parts (walls, roofs, boxes) use flat-normal facets. One shared Mesh per type
## KEY (cached) → hundreds of trees reuse ONE Mesh; a single shared material
## reads vertex colour as albedo (like the ground). Units: 1.0 = one tile (32px).

const CharRigScript := preload("res://scripts/CharRig.gd")
const MonsterRigScript := preload("res://scripts/MonsterRig.gd")

var _cache: Dictionary = {}
var mat: StandardMaterial3D

func _init() -> void:
	mat = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

func get_mesh(key: String, builder: Callable) -> Mesh:
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.call(st)
	var m: Mesh = st.commit()
	_cache[key] = m
	return m

func mesh_count() -> int:
	return _cache.size()

# ── primitives ────────────────────────────────────────────────────────────────
## Flat-shaded triangle (per-face normal) — for hard edges.
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var n := (b - a).cross(c - a)
	if n.length() > 1e-6:
		n = n.normalized()
	for v: Vector3 in [a, b, c]:
		st.set_color(col); st.set_normal(n); st.add_vertex(v)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_tri(st, a, b, c, col); _tri(st, a, c, d, col)

## Smooth-shaded triangle (radial normals from `ctr`) — for rounded parts.
func _rtri(st: SurfaceTool, ctr: Vector3, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	for v: Vector3 in [a, b, c]:
		st.set_color(col); st.set_normal((v - ctr).normalized()); st.add_vertex(v)

## Rounded ellipsoid (sphere scaled per-axis) — the workhorse for organic parts.
func _ball(st: SurfaceTool, ctr: Vector3, rad: Vector3, rings: int, segs: int, col: Color) -> void:
	for i in range(rings):
		var v0 := PI * (float(i) / float(rings) - 0.5)
		var v1 := PI * (float(i + 1) / float(rings) - 0.5)
		var y0 := sin(v0); var y1 := sin(v1)
		var c0 := cos(v0); var c1 := cos(v1)
		for j in range(segs):
			var u0 := TAU * float(j) / float(segs)
			var u1 := TAU * float(j + 1) / float(segs)
			var p00 := ctr + Vector3(cos(u0) * c0 * rad.x, y0 * rad.y, sin(u0) * c0 * rad.z)
			var p01 := ctr + Vector3(cos(u1) * c0 * rad.x, y0 * rad.y, sin(u1) * c0 * rad.z)
			var p10 := ctr + Vector3(cos(u0) * c1 * rad.x, y1 * rad.y, sin(u0) * c1 * rad.z)
			var p11 := ctr + Vector3(cos(u1) * c1 * rad.x, y1 * rad.y, sin(u1) * c1 * rad.z)
			_rtri(st, ctr, p00, p10, p11, col)
			_rtri(st, ctr, p00, p11, p01, col)

## Axis-aligned box, base-centre at (cx,cz), rising cy..cy+sy.
func _box(st: SurfaceTool, cx: float, cy: float, cz: float,
		sx: float, sy: float, sz: float, col: Color) -> void:
	var x0 := cx - sx * 0.5; var x1 := cx + sx * 0.5
	var y0 := cy;            var y1 := cy + sy
	var z0 := cz - sz * 0.5; var z1 := cz + sz * 0.5
	var a := Vector3(x0, y0, z0); var b := Vector3(x1, y0, z0)
	var c := Vector3(x1, y0, z1); var d := Vector3(x0, y0, z1)
	var e := Vector3(x0, y1, z0); var f := Vector3(x1, y1, z0)
	var g := Vector3(x1, y1, z1); var h := Vector3(x0, y1, z1)
	_quad(st, e, f, g, h, col); _quad(st, d, c, b, a, col)
	_quad(st, a, b, f, e, col); _quad(st, c, d, h, g, col)
	_quad(st, b, c, g, f, col); _quad(st, d, a, e, h, col)

## Rotated box via a basis (for angled roof planes / limbs / wings).
func _obox(st: SurfaceTool, ctr: Vector3, basis: Basis, half: Vector3, col: Color) -> void:
	var pts: Array = []
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				pts.append(ctr + basis * Vector3(sx * half.x, sy * half.y, sz * half.z))
	# indices into pts (binary xyz): 0=---,1=--+,2=-+-,3=-++,4=+--,5=+-+,6=++-,7=+++
	_quad(st, pts[2], pts[6], pts[7], pts[3], col)   # +y
	_quad(st, pts[1], pts[5], pts[4], pts[0], col)   # -y
	_quad(st, pts[4], pts[5], pts[7], pts[6], col)   # +x
	_quad(st, pts[0], pts[2], pts[3], pts[1], col)   # -x
	_quad(st, pts[1], pts[3], pts[7], pts[5], col)   # +z
	_quad(st, pts[0], pts[4], pts[6], pts[2], col)   # -z

## An oriented "strut" — a thin box spanning a→b (for wing bones / limb struts).
func _strut(st: SurfaceTool, a: Vector3, b: Vector3, thick: float, col: Color) -> void:
	var dir := b - a
	var ln := dir.length()
	if ln < 0.00001:
		return
	dir /= ln
	var up: Vector3 = Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var xa := up.cross(dir).normalized()
	var ya := dir.cross(xa)
	_obox(st, (a + b) * 0.5, Basis(xa, ya, dir), Vector3(thick, thick, ln * 0.5), col)

func _cyl(st: SurfaceTool, cx: float, by: float, cz: float,
		r: float, h: float, sides: int, col: Color) -> void:
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cx + cos(a0) * r, by, cz + sin(a0) * r)
		var b1 := Vector3(cx + cos(a1) * r, by, cz + sin(a1) * r)
		_quad(st, b0, b1, b1 + Vector3(0, h, 0), b0 + Vector3(0, h, 0), col)
	var top := Vector3(cx, by + h, cz)
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		_tri(st, Vector3(cx + cos(a0) * r, by + h, cz + sin(a0) * r),
			Vector3(cx + cos(a1) * r, by + h, cz + sin(a1) * r), top, col)

func _cone(st: SurfaceTool, cx: float, by: float, cz: float,
		r: float, h: float, sides: int, col: Color) -> void:
	var apex := Vector3(cx, by + h, cz)
	var ctr := Vector3(cx, by, cz)
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cx + cos(a0) * r, by, cz + sin(a0) * r)
		var p1 := Vector3(cx + cos(a1) * r, by, cz + sin(a1) * r)
		_tri(st, p0, p1, apex, col)
		_tri(st, ctr, p1, p0, col)

## Gable/ridged roof over a w×d footprint: two sloped planes + two triangular ends.
func _gable(st: SurfaceTool, cx: float, by: float, cz: float,
		w: float, d: float, h: float, col: Color) -> void:
	var x0 := cx - w * 0.5; var x1 := cx + w * 0.5
	var z0 := cz - d * 0.5; var z1 := cz + d * 0.5
	var r0 := Vector3(cx, by + h, z0); var r1 := Vector3(cx, by + h, z1)
	var e0 := Vector3(x0, by, z0); var e1 := Vector3(x1, by, z0)
	var f0 := Vector3(x0, by, z1); var f1 := Vector3(x1, by, z1)
	_quad(st, e0, f0, r1, r0, col)   # left slope
	_quad(st, f1, e1, r0, r1, col)   # right slope
	_tri(st, e0, r0, e1, col)        # front gable
	_tri(st, f1, r1, f0, col)        # back gable

func _pyramid(st: SurfaceTool, cx: float, by: float, cz: float,
		w: float, d: float, h: float, col: Color) -> void:
	var apex := Vector3(cx, by + h, cz)
	var x0 := cx - w * 0.5; var x1 := cx + w * 0.5
	var z0 := cz - d * 0.5; var z1 := cz + d * 0.5
	var c0 := Vector3(x0, by, z0); var c1 := Vector3(x1, by, z0)
	var c2 := Vector3(x1, by, z1); var c3 := Vector3(x0, by, z1)
	_tri(st, c0, c1, apex, col); _tri(st, c1, c2, apex, col)
	_tri(st, c2, c3, apex, col); _tri(st, c3, c0, apex, col)

func _dk(c: Color, a := 0.25) -> Color: return c.darkened(a)
func _lt(c: Color, a := 0.18) -> Color: return c.lightened(a)

# ── resources ─────────────────────────────────────────────────────────────────
func tree(col: Color) -> Mesh:
	return get_mesh("tree:" + col.to_html(false), func(st: SurfaceTool) -> void:
		_cyl(st, 0, 0, 0, 0.2, 1.7, 6, Color(0.40, 0.27, 0.14))
		_ball(st, Vector3(0, 2.4, 0), Vector3(1.35, 1.3, 1.35), 5, 8, col)
		_ball(st, Vector3(0.35, 3.2, 0.1), Vector3(0.8, 0.8, 0.8), 4, 7, _lt(col, 0.1))
		_ball(st, Vector3(-0.35, 3.0, -0.2), Vector3(0.75, 0.75, 0.75), 4, 7, _dk(col, 0.08)))

func pine(col: Color) -> Mesh:
	return get_mesh("pine:" + col.to_html(false), func(st: SurfaceTool) -> void:
		_cyl(st, 0, 0, 0, 0.16, 1.1, 6, Color(0.36, 0.24, 0.12))
		_cone(st, 0, 0.8, 0, 1.05, 1.6, 8, col)
		_cone(st, 0, 1.8, 0, 0.82, 1.5, 8, _lt(col, 0.06))
		_cone(st, 0, 2.8, 0, 0.55, 1.4, 8, _lt(col, 0.12)))

# NOTE: small-resource ball centres are kept ≥ their y-radius so the mesh bottom
# sits at/above y=0 — otherwise the lower half dips below the terrain and clips.
## Ore rock — a FACETED boulder in the tier colour (low-seg balls read as facets),
## dark base + light top + bright ore SPECKS of the tier colour (matches the 2D).
func rock(col: Color) -> Mesh:
	var key := "rock:" + col.to_html(false)
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_ball(st, Vector3(0, 0.46, 0), Vector3(0.84, 0.5, 0.72), 3, 6, _dk(col, 0.22))   # dark base facets
	_ball(st, Vector3(0.06, 0.6, -0.05), Vector3(0.58, 0.5, 0.54), 3, 6, col)         # body
	_ball(st, Vector3(-0.12, 0.74, 0.12), Vector3(0.34, 0.3, 0.32), 3, 5, _lt(col, 0.22))  # top highlight
	var spec := col.lightened(0.45)
	_ball(st, Vector3(0.24, 0.54, 0.3), Vector3(0.07, 0.07, 0.07), 2, 5, spec)        # ore specks
	_ball(st, Vector3(-0.26, 0.7, 0.16), Vector3(0.06, 0.06, 0.06), 2, 5, spec)
	_ball(st, Vector3(0.1, 0.86, -0.22), Vector3(0.055, 0.055, 0.055), 2, 5, spec)
	var m: Mesh = st.commit(); _cache[key] = m; return m

## Herb — green foliage mound + a few blooms in the herb's `col` (Moonbloom purple,
## Herb Patch yellow-green, …), matching the 2D leaf+flower read.
func bush(col: Color) -> Mesh:
	var key := "herb:" + col.to_html(false)
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leaf := Color(0.26, 0.5, 0.22)
	_ball(st, Vector3(0, 0.34, 0), Vector3(0.42, 0.3, 0.4), 4, 7, leaf)
	_ball(st, Vector3(-0.22, 0.42, 0.1), Vector3(0.24, 0.24, 0.24), 3, 6, _dk(leaf, 0.1))
	for p: Vector3 in [Vector3(0.12, 0.56, 0.05), Vector3(-0.14, 0.52, -0.08), Vector3(0.02, 0.62, 0.14)]:
		_ball(st, p, Vector3(0.1, 0.1, 0.1), 3, 6, col)                                # blooms
	var m: Mesh = st.commit(); _cache[key] = m; return m

## Stick — a few crossed twigs on the ground (matches the 2D 3-line twigs).
func stick(col: Color) -> Mesh:
	var key := "stick:" + col.to_html(false)
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_obox(st, Vector3(0, 0.05, 0), Basis(Vector3.UP, 0.35), Vector3(0.3, 0.04, 0.045), col)
	_obox(st, Vector3(0.02, 0.05, 0.03), Basis(Vector3.UP, -0.7), Vector3(0.24, 0.035, 0.04), _dk(col, 0.15))
	_obox(st, Vector3(-0.03, 0.05, -0.02), Basis(Vector3.UP, 1.0), Vector3(0.2, 0.03, 0.035), _lt(col, 0.12))
	var m: Mesh = st.commit(); _cache[key] = m; return m

## Stone — a rounded pebble cluster (matches the 2D overlapping-circles cluster).
func stone(col: Color) -> Mesh:
	var key := "stone:" + col.to_html(false)
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_ball(st, Vector3(0, 0.15, 0), Vector3(0.22, 0.16, 0.2), 3, 6, _dk(col, 0.12))
	_ball(st, Vector3(-0.17, 0.12, 0.08), Vector3(0.16, 0.13, 0.15), 3, 6, col)
	_ball(st, Vector3(0.15, 0.11, -0.05), Vector3(0.13, 0.11, 0.12), 3, 6, _lt(col, 0.06))
	_ball(st, Vector3(0.0, 0.24, 0.02), Vector3(0.07, 0.06, 0.07), 2, 5, _lt(col, 0.18))
	var m: Mesh = st.commit(); _cache[key] = m; return m

func nodelet(col: Color) -> Mesh:   # generic small pickup fallback
	return stone(col)

func fishing(col: Color) -> Mesh:
	var key := "fish:" + col.to_html(false)
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_cyl(st, 0, 0, 0, 0.1, 0.9, 5, Color(0.42, 0.30, 0.16))               # mooring post
	_ball(st, Vector3(0.5, 0.28, 0.0), Vector3(0.26, 0.24, 0.26), 4, 6, col)  # float
	_ball(st, Vector3(0.5, 0.44, 0.0), Vector3(0.1, 0.1, 0.1), 3, 5, _lt(col, 0.2))  # float cap
	var m: Mesh = st.commit(); _cache[key] = m; return m

# ── structures (distinct civic silhouettes) ──────────────────────────────────
const _WOOD := Color(0.34, 0.20, 0.12)
const _ROOF := Color(0.30, 0.17, 0.10)
const _THATCH := Color(0.55, 0.42, 0.22)

## Doors + windows shared by wall boxes (front face at -z).
func _facade(st: SurfaceTool, w: float, tall: float, d: float) -> void:
	_box(st, 0, 0.0, -d * 0.5 - 0.01, w * 0.28, tall * 0.62, 0.06, _dk(_WOOD, 0.1))   # door
	_box(st, -w * 0.3, tall * 0.5, -d * 0.5 - 0.01, w * 0.16, w * 0.16, 0.05, Color(0.72, 0.82, 0.55))
	_box(st,  w * 0.3, tall * 0.5, -d * 0.5 - 0.01, w * 0.16, w * 0.16, 0.05, Color(0.72, 0.82, 0.55))

func _house(st: SurfaceTool, col: Color, w: float, d: float, tall: float) -> void:
	_box(st, 0, 0, 0, w, tall, d, col)
	_gable(st, 0, tall, 0, w + 0.3, d + 0.3, tall * 0.7, _ROOF)
	_facade(st, w, tall, d)

## Dispatch a structure type_str → its shaped mesh (built directly; no lambdas).
func structure(type_str: String, col: Color) -> Mesh:
	var key := "st:%s:%s" % [type_str, col.to_html(false)]
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match type_str:
		"forge":
			_house(st, col, 2.4, 2.4, 1.8)
			_box(st, 0.8, 1.8, 0.4, 0.5, 1.6, 0.5, Color(0.32, 0.32, 0.34))   # chimney
			_ball(st, Vector3(0.8, 3.5, 0.4), Vector3(0.28, 0.3, 0.28), 3, 6, Color(0.95, 0.5, 0.15))
			_box(st, 0, 0.35, -1.25, 0.7, 0.6, 0.15, Color(0.95, 0.45, 0.12))   # forge glow
		"bank":
			_box(st, 0, 0, 0, 3.0, 2.1, 2.6, col)
			_pyramid(st, 0, 2.1, 0, 3.4, 3.0, 0.9, _ROOF)
			for cx: float in [-1.1, -0.55, 0.0, 0.55, 1.1]:
				_cyl(st, cx, 0, -1.45, 0.13, 2.0, 6, _lt(col, 0.12))   # colonnade
			_ball(st, Vector3(0, 2.6, 0), Vector3(0.35, 0.4, 0.35), 4, 7, Color(0.9, 0.75, 0.2))
		"grand_hall", "clan_hall", "large_house", "auction_house":
			_box(st, 0, 0, 0, 2.6, 2.2, 4.2, col)                       # long body
			_gable(st, 0, 2.2, 0, 2.9, 4.5, 1.5, _ROOF)                 # steep long roof
			_box(st, 0, 0, -2.1, 1.2, 1.6, 0.2, _dk(_WOOD, 0.05))       # grand door
			for zz: float in [-1.2, 0.0, 1.2]:
				_box(st, -1.3, 0.4, zz, 0.14, 1.4, 0.16, _WOOD)
		"fire":
			for a: float in [0.0, 1.0, 2.0, 3.0]:
				var an := a * PI * 0.5
				_obox(st, Vector3(cos(an) * 0.25, 0.12, sin(an) * 0.25),
					Basis(Vector3.UP, an), Vector3(0.5, 0.09, 0.09), _WOOD)
			_cone(st, 0, 0.15, 0, 0.4, 0.8, 6, Color(0.98, 0.55, 0.12))
			_cone(st, 0, 0.35, 0, 0.22, 0.6, 6, Color(1.0, 0.82, 0.28))
		"runestone":
			_ball(st, Vector3(0, 1.1, 0), Vector3(0.55, 1.15, 0.28), 4, 6, Color(0.5, 0.5, 0.55))
			_box(st, 0, 0.4, 0.28, 0.5, 1.0, 0.05, col.lightened(0.1))     # rune face glow
		"well":
			_cyl(st, 0, 0, 0, 0.7, 0.7, 8, Color(0.5, 0.5, 0.53))
			_box(st, -0.6, 0.7, 0, 0.12, 1.1, 0.12, _WOOD)
			_box(st, 0.6, 0.7, 0, 0.12, 1.1, 0.12, _WOOD)
			_gable(st, 0, 1.7, 0, 1.7, 0.9, 0.5, _ROOF)
		"market_stall", "armory_rack":
			_box(st, 0, 0.7, 0.3, 1.6, 0.2, 0.7, _WOOD)              # counter top
			_box(st, 0, 0, 0.3, 1.6, 0.7, 0.7, _dk(_WOOD, 0.1))
			for cx2: float in [-0.7, 0.7]:
				_box(st, cx2, 0.9, -0.3, 0.1, 1.0, 0.1, _WOOD)      # posts
			_obox(st, Vector3(0, 1.5, 0.1), Basis(Vector3.RIGHT, -0.5), Vector3(0.9, 0.05, 0.6), col)
		"archery":
			_cyl(st, 0, 0, 0, 0.08, 1.3, 5, _WOOD)
			_ball(st, Vector3(0, 1.5, 0), Vector3(0.5, 0.5, 0.12), 4, 8, Color(0.9, 0.9, 0.88))
			_ball(st, Vector3(0, 1.5, 0.02), Vector3(0.32, 0.32, 0.1), 3, 8, Color(0.85, 0.25, 0.15))
			_ball(st, Vector3(0, 1.5, 0.04), Vector3(0.12, 0.12, 0.08), 3, 6, Color(0.95, 0.85, 0.2))
		"crafting":
			# A workbench: legged top + a vice + a workpiece (small, not a shed).
			for lx: float in [-0.5, 0.5]:
				for lz: float in [-0.26, 0.26]:
					_box(st, lx, 0, lz, 0.1, 0.5, 0.1, _dk(_WOOD, 0.1))   # legs
			_box(st, 0, 0.5, 0, 1.25, 0.14, 0.66, _WOOD)                  # bench top
			_box(st, -0.35, 0.64, 0, 0.14, 0.24, 0.16, Color(0.55, 0.56, 0.6))  # vice
			_box(st, 0.35, 0.63, 0.08, 0.3, 0.08, 0.16, col)             # workpiece
		"construction":
			# A build site: low foundation + scaffold poles/beam + a leaning plank.
			_box(st, 0, 0, 0, 1.4, 0.16, 1.2, _dk(col, 0.12))            # foundation
			for p: Vector3 in [Vector3(-0.6, 0, -0.5), Vector3(0.6, 0, -0.5), Vector3(-0.6, 0, 0.5), Vector3(0.6, 0, 0.5)]:
				_box(st, p.x, 0.16, p.z, 0.09, 1.1, 0.09, _WOOD)         # scaffold poles
			_box(st, 0, 1.2, -0.5, 1.35, 0.09, 0.11, _WOOD)             # scaffold beam
			_obox(st, Vector3(0.35, 0.6, 0.35), Basis(Vector3.RIGHT, 0.7), Vector3(0.5, 0.04, 0.16), _lt(_WOOD, 0.1))
		"fortified_wall":
			_wall_seg(st, col, 2.2)
		"watchtower", "guard_tower":
			_cyl(st, 0, 0, 0, 0.75, 3.0, 7, col)
			_cyl(st, 0, 3.0, 0, 0.9, 0.4, 7, _lt(col, 0.1))
			_cone(st, 0, 3.4, 0, 1.0, 1.1, 7, _ROOF)
		"stronghold", "banner", "outpost":
			_box(st, 0, 0, 0, 1.9, 2.2, 1.9, col)
			_cyl(st, 0, 2.2, 0.0, 0.05, 1.6, 4, _WOOD)              # flagpole
			_obox(st, Vector3(0.4, 3.4, 0), Basis(), Vector3(0.4, 0.25, 0.02), Color(0.8, 0.2, 0.2))
		"seal_statue":
			_box(st, 0, 0, 0, 0.9, 0.5, 0.9, Color(0.5, 0.5, 0.52))
			_ball(st, Vector3(0, 1.6, 0), Vector3(0.4, 1.1, 0.35), 4, 7, col)
		"world_eater":
			_ball(st, Vector3(0, 1.4, 0), Vector3(1.8, 1.5, 1.8), 6, 9, col)
			_ball(st, Vector3(0, 2.6, 0), Vector3(0.9, 0.8, 0.9), 4, 7, _dk(col, 0.15))
		"farm_plot":
			_box(st, 0, 0, 0, 1.4, 0.14, 1.4, col)
			for rz: float in [-0.4, 0.0, 0.4]:
				_box(st, 0, 0.14, rz, 1.3, 0.12, 0.18, _dk(col, 0.15))
		_:
			_house(st, col, 2.4, 2.2, 1.9)   # building/house/tavern/hall/chapel/warehouse…
	var m: Mesh = st.commit()
	_cache[key] = m
	return m

## Covered trade wagon (caravans): bed + arched canopy + 4 wheels + a donkey nub.
func wagon(col: Color) -> Mesh:
	var key := "wagon:" + col.to_html(false)
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, 0, 0.32, 0, 1.5, 0.46, 0.9, col)                                  # bed
	_ball(st, Vector3(-0.1, 0.78, 0), Vector3(0.62, 0.42, 0.48), 4, 8, Color(0.86, 0.82, 0.70))  # canopy
	for wx: float in [-0.55, 0.55]:
		for wz: float in [-0.46, 0.46]:
			_ball(st, Vector3(wx, 0.16, wz), Vector3(0.2, 0.2, 0.09), 3, 7, Color(0.15, 0.1, 0.06))  # wheels
	_ball(st, Vector3(1.0, 0.45, 0), Vector3(0.28, 0.3, 0.22), 4, 6, Color(0.5, 0.36, 0.24))  # donkey
	var m: Mesh = st.commit()
	_cache[key] = m
	return m

## Viking longship (sailing): elongated hull + upturned prow/stern + mast + shields.
func boat(col: Color) -> Mesh:
	var key := "boat:" + col.to_html(false)
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_ball(st, Vector3(0, 0.15, 0), Vector3(0.55, 0.32, 1.5), 5, 9, col)          # hull
	_ball(st, Vector3(0, 0.5, -1.35), Vector3(0.14, 0.32, 0.3), 3, 6, _dk(col, 0.1))  # prow
	_ball(st, Vector3(0, 0.5, 1.35), Vector3(0.14, 0.32, 0.3), 3, 6, _dk(col, 0.1))   # stern
	_cyl(st, 0, 0.2, 0, 0.06, 1.6, 5, _dk(col, 0.2))                             # mast
	_obox(st, Vector3(0, 1.4, 0.2), Basis(), Vector3(0.5, 0.35, 0.02), Color(0.8, 0.82, 0.85))  # sail
	for sz: float in [-0.8, -0.3, 0.3, 0.8]:                                     # shields
		_ball(st, Vector3(0.5, 0.4, sz), Vector3(0.06, 0.2, 0.2), 3, 6, Color(0.7, 0.2, 0.15))
		_ball(st, Vector3(-0.5, 0.4, sz), Vector3(0.06, 0.2, 0.2), 3, 6, Color(0.2, 0.35, 0.6))
	var m: Mesh = st.commit()
	_cache[key] = m
	return m

## A themed interior ROOM (P6): floor + 4 walls (door gap on +z/south) + a dim
## ceiling so it reads enclosed. `w`,`h` in world units; centred on origin, floor y=0.
func room(w: float, h: float, floor_col: Color, wall_col: Color) -> Mesh:
	var key := "room:%d:%d:%s:%s" % [int(w * 10), int(h * 10), floor_col.to_html(false), wall_col.to_html(false)]
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := w * 0.5
	var hh := h * 0.5
	var wh := 3.2                      # wall height
	var t := 0.22                      # wall thickness
	# floor + ceiling
	_quad(st, Vector3(-hw, 0, -hh), Vector3(hw, 0, -hh), Vector3(hw, 0, hh), Vector3(-hw, 0, hh), floor_col)
	_quad(st, Vector3(-hw, wh, hh), Vector3(hw, wh, hh), Vector3(hw, wh, -hh), Vector3(-hw, wh, -hh), _dk(wall_col, 0.35))
	_box(st, 0, 0, -hh, w + t, wh, t, wall_col)          # north wall
	_box(st, hw, 0, 0, t, wh, h, wall_col)               # east
	_box(st, -hw, 0, 0, t, wh, h, wall_col)              # west
	var door := 2.2                                       # south wall with a door gap
	var seg := maxf(0.1, (w - door) * 0.5)
	_box(st, -(door * 0.5 + seg * 0.5), 0, hh, seg, wh, t, wall_col)
	_box(st, (door * 0.5 + seg * 0.5), 0, hh, seg, wh, t, wall_col)
	_box(st, 0, wh - 0.6, hh, door + 0.2, 0.6, t, _dk(wall_col, 0.1))   # lintel over the door
	var m: Mesh = st.commit()
	_cache[key] = m
	return m

func _wall_seg(st: SurfaceTool, col: Color, tall: float) -> void:
	_box(st, 0, 0, 0, 1.2, tall, 1.2, col)
	for mx: float in [-0.4, 0.0, 0.4]:
		_box(st, mx, tall, 0, 0.28, 0.3, 1.3, _lt(col, 0.1))   # crenellations

# ── characters (rounded viking: hair/beard + weapon + gear accents) ──────────
const _SKINS: Array = [
	Color(0.87, 0.70, 0.52), Color(0.80, 0.60, 0.42), Color(0.68, 0.48, 0.32),
	Color(0.55, 0.38, 0.24), Color(0.44, 0.30, 0.20), Color(0.92, 0.78, 0.64),
	Color(0.78, 0.64, 0.50), Color(0.62, 0.44, 0.30)]
const _HAIRS: Array = [
	Color(0.20, 0.14, 0.08), Color(0.45, 0.28, 0.12), Color(0.72, 0.52, 0.20),
	Color(0.85, 0.72, 0.40), Color(0.70, 0.20, 0.10), Color(0.60, 0.60, 0.62),
	Color(0.90, 0.90, 0.90), Color(0.30, 0.22, 0.16), Color(0.10, 0.10, 0.12),
	Color(0.55, 0.35, 0.18), Color(0.78, 0.60, 0.30), Color(0.40, 0.26, 0.14),
	Color(0.65, 0.45, 0.22), Color(0.50, 0.30, 0.15)]
const _TUNICS: Array = [
	Color(0.22, 0.48, 0.82), Color(0.55, 0.20, 0.20), Color(0.28, 0.52, 0.30),
	Color(0.55, 0.42, 0.20), Color(0.40, 0.30, 0.55), Color(0.30, 0.32, 0.36)]
const _METAL := Color(0.60, 0.62, 0.68)

func _pick(arr: Array, i: int) -> Color:
	return arr[((i % arr.size()) + arr.size()) % arr.size()] as Color

func character(appr: Dictionary) -> Mesh:
	var skin := _pick(_SKINS, int(appr.get("skin", 0)))
	var hair := _pick(_HAIRS, int(appr.get("hair_color", 0)))
	var tunic := _pick(_TUNICS, int(appr.get("tunic", 0)))
	var beard := int(appr.get("beard", 0)) > 0
	var key := "char:%d:%d:%d:%d" % [int(appr.get("skin", 0)),
		int(appr.get("hair_color", 0)), int(appr.get("tunic", 0)), int(appr.get("beard", 0))]
	return get_mesh(key, func(st: SurfaceTool) -> void:
		_body(st, skin, hair, tunic, beard, true, 1.0))

## Shared humanoid builder (used by players/NPCs + humanoid monsters).
func _body(st: SurfaceTool, skin: Color, hair: Color, tunic: Color,
		beard: bool, armed: bool, s: float) -> void:
	var trouser := Color(0.24, 0.20, 0.14)
	var boot := Color(0.16, 0.11, 0.06)
	_ball(st, Vector3(-0.15, 0.06, 0.03) * s, Vector3(0.15, 0.1, 0.22) * s, 3, 6, boot)
	_ball(st, Vector3(0.15, 0.06, 0.03) * s, Vector3(0.15, 0.1, 0.22) * s, 3, 6, boot)
	_ball(st, Vector3(-0.15, 0.46, 0) * s, Vector3(0.14, 0.42, 0.15) * s, 4, 6, trouser)
	_ball(st, Vector3(0.15, 0.46, 0) * s, Vector3(0.14, 0.42, 0.15) * s, 4, 6, trouser)
	_ball(st, Vector3(0, 1.12, 0) * s, Vector3(0.36, 0.42, 0.26) * s, 5, 8, tunic)      # torso
	_box(st, 0, 0.82 * s, 0, 0.68 * s, 0.12 * s, 0.46 * s, Color(0.3, 0.2, 0.1))         # belt
	_ball(st, Vector3(-0.36, 1.42, 0) * s, Vector3(0.19, 0.15, 0.2) * s, 4, 6, _METAL)   # L pauldron
	_ball(st, Vector3(0.36, 1.42, 0) * s, Vector3(0.19, 0.15, 0.2) * s, 4, 6, _METAL)    # R pauldron
	_ball(st, Vector3(-0.42, 1.05, 0) * s, Vector3(0.1, 0.34, 0.11) * s, 4, 6, tunic)    # arms
	_ball(st, Vector3(0.42, 1.05, 0) * s, Vector3(0.1, 0.34, 0.11) * s, 4, 6, tunic)
	_ball(st, Vector3(-0.44, 0.74, 0.02) * s, Vector3(0.1, 0.1, 0.1) * s, 3, 6, skin)    # hands
	_ball(st, Vector3(0.44, 0.74, 0.02) * s, Vector3(0.1, 0.1, 0.1) * s, 3, 6, skin)
	_ball(st, Vector3(0, 1.7, 0) * s, Vector3(0.22, 0.24, 0.22) * s, 5, 8, skin)         # head
	_ball(st, Vector3(0, 1.8, -0.03) * s, Vector3(0.25, 0.18, 0.26) * s, 4, 8, hair)     # hair
	if beard:
		_ball(st, Vector3(0, 1.56, 0.14) * s, Vector3(0.17, 0.16, 0.12) * s, 3, 6, hair)
	# eyes
	_ball(st, Vector3(-0.08, 1.72, 0.2) * s, Vector3(0.03, 0.04, 0.03) * s, 2, 4, Color(0.1, 0.1, 0.12))
	_ball(st, Vector3(0.08, 1.72, 0.2) * s, Vector3(0.03, 0.04, 0.03) * s, 2, 4, Color(0.1, 0.1, 0.12))
	if armed:   # a bearded axe in the right hand
		_cyl(st, 0.5 * s, 0.45 * s, 0.08 * s, 0.03 * s, 1.0 * s, 5, Color(0.4, 0.28, 0.14))
		_obox(st, Vector3(0.5, 1.35, 0.08) * s, Basis(), Vector3(0.13, 0.16, 0.03) * s, _METAL)

# ── rigged character (P-ANIM) — joint hierarchy that CharRig.gd animates ─────
## Same viking, but as a Node3D of pivoted PARTS (limbs hang from their joints) so
## legs/arms/torso can move. Part meshes are joint-at-origin + cached per colour.
func build_char_rig(appr: Dictionary) -> Node3D:
	var skin := _pick(_SKINS, int(appr.get("skin", 0)))
	var hair := _pick(_HAIRS, int(appr.get("hair_color", 0)))
	var tunic := _pick(_TUNICS, int(appr.get("tunic", 0)))
	var hstyle := int(appr.get("hair_style", 0))
	var beard_idx := int(appr.get("beard", 0))
	var trouser := Color(0.24, 0.20, 0.14)
	# Equipped armour overlays per slot (empty = show the bare tunic/skin part).
	var gear: Dictionary = appr.get("gear", {}) if appr.get("gear") is Dictionary else {}
	var g_head := str(gear.get("head", ""))
	var g_body := str(gear.get("body", ""))
	var g_legs := str(gear.get("legs", ""))
	var g_hands := str(gear.get("hands", ""))
	var g_boots := str(gear.get("boots", ""))
	var g_off := str(gear.get("offhand", ""))
	var root := Node3D.new()
	root.set_script(CharRigScript)
	var torso := Node3D.new(); torso.position = Vector3(0, 0.85, 0)
	root.add_child(torso); _mi(torso, _torso_mesh(tunic, skin, trouser))
	if g_body != "": _mi(torso, _armor_body_mesh(g_body))
	var head := Node3D.new(); head.position = Vector3(0, 0.85, 0)
	torso.add_child(head); _mi(head, _head_mesh(skin, hair, hstyle, beard_idx, g_head != ""))
	if g_head != "": _mi(head, _armor_helm_mesh(g_head))
	var larm := Node3D.new(); larm.position = Vector3(-0.4, 1.42, 0)
	root.add_child(larm); _mi(larm, _arm_mesh(tunic, skin))
	if g_hands != "": _mi(larm, _armor_gloves_mesh(g_hands))
	if g_off != "": _mi(larm, _armor_shield_mesh(g_off))   # off-hand shield
	var rarm := Node3D.new(); rarm.position = Vector3(0.4, 1.42, 0)
	root.add_child(rarm); _mi(rarm, _arm_mesh(tunic, skin))
	if g_hands != "": _mi(rarm, _armor_gloves_mesh(g_hands))
	var weapon := Node3D.new(); weapon.position = Vector3(0.0, -0.6, 0.06)   # in the fist
	# Blade points UP and slightly FORWARD (+X-rot = tips toward +Z / forward) with a
	# small outward roll — reads as gripped, not tilted back into the body.
	weapon.rotation = Vector3(0.4, 0.0, -0.12)
	# Distinct mesh per equipped weapon (type + tier); generic axe if unarmed.
	var wid := str(appr.get("weapon", ""))
	rarm.add_child(weapon); _mi(weapon, _weapon_mesh(wid) if wid != "" else _axe_mesh())
	var lleg := Node3D.new(); lleg.position = Vector3(-0.15, 0.85, 0)
	root.add_child(lleg); _mi(lleg, _leg_mesh(trouser))
	var rleg := Node3D.new(); rleg.position = Vector3(0.15, 0.85, 0)
	root.add_child(rleg); _mi(rleg, _leg_mesh(trouser))
	if g_legs != "":
		_mi(lleg, _armor_legs_mesh(g_legs)); _mi(rleg, _armor_legs_mesh(g_legs))
	if g_boots != "":
		_mi(lleg, _armor_boots_mesh(g_boots)); _mi(rleg, _armor_boots_mesh(g_boots))
	root.call("setup", {"torso": torso, "larm": larm, "rarm": rarm, "lleg": lleg, "rleg": rleg})
	return root

func _mi(parent: Node3D, m: Mesh) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	parent.add_child(mi)

func _torso_mesh(tunic: Color, skin: Color, trouser: Color) -> Mesh:
	var key := "torso:%s:%s:%s" % [tunic.to_html(false), skin.to_html(false), trouser.to_html(false)]
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leather := Color(0.34, 0.22, 0.12)
	var trim := _dk(tunic, 0.22)
	# Heroic torso — broad upper chest tapering to the waist. Shifted forward (+Z)
	# with a shallower back so the rear reads as a back, not a round marshmallow.
	_ball(st, Vector3(0, 0.44, 0.05), Vector3(0.4, 0.24, 0.23), 6, 10, tunic)     # chest (broad)
	_ball(st, Vector3(0, 0.14, 0.04), Vector3(0.31, 0.24, 0.19), 6, 10, tunic)    # waist (tapered)
	# Muscle/tone read under the tunic — pecs + lat taper + traps + centre groove.
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.14, 0.5, 0.19), Vector3(0.15, 0.11, 0.09), 4, 7, _lt(tunic, 0.05))   # pec
		_ball(st, Vector3(e * 0.28, 0.42, -0.04), Vector3(0.1, 0.18, 0.13), 4, 7, _dk(tunic, 0.06))  # lat / side
	_ball(st, Vector3(0, 0.57, -0.03), Vector3(0.24, 0.1, 0.12), 4, 7, _lt(tunic, 0.03))             # traps
	_obox(st, Vector3(0, 0.2, 0.24), Basis(), Vector3(0.012, 0.16, 0.02), _dk(tunic, 0.12))          # ab groove
	_obox(st, Vector3(0, 0.3, 0.25), Basis(), Vector3(0.02, 0.24, 0.02), trim)    # front lacing
	_ball(st, Vector3(0, 0.6, 0.05), Vector3(0.17, 0.08, 0.15), 4, 8, trim)       # collar
	_cyl(st, 0, 0.58, 0.01, 0.085, 0.16, 8, skin)                                 # neck
	# Rounded pelvis / seat (trouser-toned) so the rear reads as hips, not a boxy slab.
	_ball(st, Vector3(0, -0.14, 0.03), Vector3(0.29, 0.15, 0.2), 6, 10, trouser)
	# Belt — a rounded band + buckle (was a wide rectangular box).
	_ball(st, Vector3(0, -0.02, 0.0), Vector3(0.33, 0.06, 0.25), 4, 9, leather)
	_box(st, 0, -0.02, 0.24, 0.1, 0.11, 0.04, _METAL)                             # buckle
	# Cloth shoulder caps only — metal PAULDRONS come from equipped body armour
	# (so an unarmoured viking isn't wearing floating metal balls, and armour
	# doesn't double them up).
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.36, 0.53, 0), Vector3(0.16, 0.13, 0.18), 5, 8, tunic)
	var m: Mesh = st.commit(); _cache[key] = m; return m

## Head with hair SHAPE by hair_style + beard SHAPE by beard index, so vikings read
## as distinct like the 2D (which has 12 hairstyles / 10 beards). Face is +Z.
func _head_mesh(skin: Color, hair: Color, hstyle: int, beard_idx: int, helmed := false) -> Mesh:
	var key := "head:%s:%s:%d:%d:%s" % [skin.to_html(false), hair.to_html(false), hstyle, beard_idx, str(helmed)]
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Structured head: cranium + forward jaw/cheeks + nose + brow ridge + ears.
	_ball(st, Vector3(0, 0.04, -0.01), Vector3(0.21, 0.23, 0.21), 6, 10, skin)     # cranium
	_ball(st, Vector3(0, -0.1, 0.07), Vector3(0.17, 0.14, 0.16), 5, 9, skin)       # jaw / cheeks
	_ball(st, Vector3(0, -0.01, 0.19), Vector3(0.045, 0.05, 0.06), 3, 6, skin)     # nose
	_obox(st, Vector3(0, 0.09, 0.16), Basis(), Vector3(0.14, 0.025, 0.03), _dk(skin, 0.14))  # brow ridge
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.21, -0.01, 0.0), Vector3(0.03, 0.06, 0.045), 3, 6, skin)     # ears
	var hs := 4 if helmed else hstyle   # helm covers the hair (style 4 = bald → no hair clip)
	match ((hs % 6) + 6) % 6:
		0:   # short cap
			_ball(st, Vector3(0, 0.1, -0.03), Vector3(0.25, 0.17, 0.26), 4, 8, hair)
		1:   # long — cap + length down the back
			_ball(st, Vector3(0, 0.08, -0.05), Vector3(0.27, 0.2, 0.28), 4, 8, hair)
			_ball(st, Vector3(0, -0.08, -0.12), Vector3(0.2, 0.2, 0.14), 3, 6, hair)
		2:   # topknot
			_ball(st, Vector3(0, 0.11, -0.02), Vector3(0.24, 0.15, 0.25), 4, 7, hair)
			_ball(st, Vector3(0, 0.3, -0.05), Vector3(0.08, 0.12, 0.08), 3, 6, hair)
		3:   # mohawk / crest
			_ball(st, Vector3(0, 0.2, 0.0), Vector3(0.06, 0.18, 0.24), 3, 6, hair)
		4:   # bald / shaved — no hair
			pass
		_:   # wild + side braids
			_ball(st, Vector3(0, 0.12, -0.03), Vector3(0.26, 0.19, 0.27), 4, 8, hair)
			_ball(st, Vector3(-0.22, -0.06, 0.02), Vector3(0.05, 0.16, 0.05), 3, 5, hair)
			_ball(st, Vector3(0.22, -0.06, 0.02), Vector3(0.05, 0.16, 0.05), 3, 5, hair)
	if beard_idx > 0:
		match beard_idx % 4:
			1: _ball(st, Vector3(0, -0.13, 0.15), Vector3(0.14, 0.1, 0.1), 3, 6, hair)    # stubble
			2: _ball(st, Vector3(0, -0.15, 0.13), Vector3(0.18, 0.17, 0.13), 3, 6, hair)  # full
			3: _ball(st, Vector3(0, -0.22, 0.12), Vector3(0.13, 0.24, 0.12), 3, 6, hair)  # long braid
			_: _ball(st, Vector3(0, -0.12, 0.16), Vector3(0.16, 0.07, 0.09), 2, 6, hair)  # mustache
	# Eyes — a set white + a dark iris/pupil in a shallow socket, so the face reads.
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.085, 0.01, 0.175), Vector3(0.048, 0.045, 0.03), 3, 6, Color(0.92, 0.9, 0.85))
		_ball(st, Vector3(e * 0.092, 0.005, 0.2), Vector3(0.024, 0.03, 0.022), 2, 5, Color(0.14, 0.1, 0.16))
		_obox(st, Vector3(e * 0.09, 0.075, 0.17), Basis(Vector3.FORWARD, e * 0.2), Vector3(0.055, 0.014, 0.02), _dk(hair, 0.05))  # eyebrow
	_obox(st, Vector3(0, -0.11, 0.165), Basis(), Vector3(0.05, 0.012, 0.02), _dk(skin, 0.35))   # mouth
	var m: Mesh = st.commit(); _cache[key] = m; return m

func _arm_mesh(sleeve: Color, skin: Color) -> Mesh:
	var key := "arm:%s:%s" % [sleeve.to_html(false), skin.to_html(false)]
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bracer := Color(0.30, 0.20, 0.12)
	# Jointed arm (hangs from shoulder=0): deltoid → bicep → elbow → forearm → hand.
	_ball(st, Vector3(0, -0.15, 0), Vector3(0.11, 0.18, 0.12), 4, 8, sleeve)      # upper arm
	_ball(st, Vector3(0, -0.04, 0), Vector3(0.115, 0.08, 0.12), 4, 7, _lt(sleeve, 0.05))   # deltoid cap
	_ball(st, Vector3(0, -0.15, 0.06), Vector3(0.07, 0.1, 0.06), 4, 6, _lt(sleeve, 0.04))  # bicep bulge
	_ball(st, Vector3(0, -0.15, -0.05), Vector3(0.06, 0.11, 0.05), 3, 6, _dk(sleeve, 0.05))  # tricep (tone)
	_ball(st, Vector3(0, -0.33, 0.01), Vector3(0.085, 0.08, 0.09), 3, 7, sleeve)  # elbow
	_ball(st, Vector3(0.004, -0.49, 0.02), Vector3(0.088, 0.16, 0.095), 4, 8, skin)  # forearm
	_ball(st, Vector3(0.005, -0.44, 0.05), Vector3(0.06, 0.08, 0.05), 3, 6, _lt(skin, 0.04))  # forearm muscle
	_ball(st, Vector3(0, -0.43, 0.02), Vector3(0.096, 0.06, 0.1), 3, 7, bracer)   # bracer band
	_ball(st, Vector3(0, -0.65, 0.03), Vector3(0.1, 0.09, 0.11), 4, 7, skin)      # hand (fist)
	_ball(st, Vector3(0.07, -0.59, 0.06), Vector3(0.03, 0.055, 0.04), 3, 5, skin) # thumb
	var m: Mesh = st.commit(); _cache[key] = m; return m

func _leg_mesh(trouser: Color) -> Mesh:
	var key := "leg:" + trouser.to_html(false)
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Shaped leg (hangs from hip=0): thigh → knee → tapered shin → rounded boot with a
	# forward toe, so it reads as a leg instead of a boxy post.
	var boot := Color(0.18, 0.12, 0.07)
	_ball(st, Vector3(0, -0.19, 0), Vector3(0.145, 0.22, 0.155), 4, 8, trouser)   # thigh (fuller)
	_ball(st, Vector3(0, -0.16, 0.07), Vector3(0.1, 0.15, 0.06), 4, 6, _lt(trouser, 0.04))   # quad (front tone)
	_ball(st, Vector3(0, -0.52, -0.06), Vector3(0.08, 0.13, 0.06), 4, 6, _dk(trouser, 0.05)) # calf (back)
	_ball(st, Vector3(0, -0.36, 0), Vector3(0.115, 0.06, 0.125), 3, 7, _dk(trouser, 0.12))  # knee
	_ball(st, Vector3(0, -0.35, 0.08), Vector3(0.08, 0.06, 0.05), 3, 6, _METAL)   # knee guard (front)
	_ball(st, Vector3(0, -0.56, 0.01), Vector3(0.1, 0.22, 0.11), 4, 8, trouser)   # shin (tapered)
	_ball(st, Vector3(0, -0.72, 0.0), Vector3(0.125, 0.07, 0.12), 3, 7, _lt(boot, 0.06))  # boot cuff
	_ball(st, Vector3(0, -0.79, 0.02), Vector3(0.11, 0.08, 0.13), 3, 7, boot)     # boot
	_ball(st, Vector3(0, -0.82, 0.11), Vector3(0.1, 0.06, 0.15), 3, 7, _dk(boot, 0.12))  # toe forward
	var m: Mesh = st.commit(); _cache[key] = m; return m

func _axe_mesh() -> Mesh:
	var key := "axe"
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_cyl(st, 0, -0.2, 0, 0.028, 0.72, 5, Color(0.4, 0.28, 0.14))            # handle
	_obox(st, Vector3(0, 0.5, 0), Basis(), Vector3(0.13, 0.16, 0.03), _METAL)   # head
	var m: Mesh = st.commit(); _cache[key] = m; return m

## Metal tint for an equipped weapon/armor by TIER prefix in the item id.
func _gear_tier_col(id: String) -> Color:
	if "dragon" in id:   return Color(0.78, 0.22, 0.20)
	if "rune" in id:     return Color(0.66, 0.26, 0.86)
	if "adamant" in id:  return Color(0.22, 0.62, 0.34)
	if "mithril" in id:  return Color(0.42, 0.62, 0.9)
	if "steel" in id:    return Color(0.72, 0.74, 0.8)
	if "iron" in id:     return Color(0.55, 0.55, 0.6)
	if "gold" in id:     return Color(0.92, 0.78, 0.22)
	if "bronze" in id:   return Color(0.72, 0.5, 0.28)
	if "copper" in id:   return Color(0.82, 0.5, 0.24)
	if "obsidian" in id or "black" in id: return Color(0.22, 0.2, 0.26)
	return _METAL

## Equipped-weapon mesh by CATEGORY + TIER, so a rune sword ≠ a dragon axe. Authored
## around the grip (y≈0), blade/head up +Y. Falls back to a sword shape.
func _weapon_mesh(id: String) -> Mesh:
	var key := "wpn:" + id
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mc := _gear_tier_col(id)
	var wood := Color(0.4, 0.28, 0.14)
	var grip := Color(0.28, 0.18, 0.1)
	if "bow" in id:
		var w2 := _gear_tier_col(id) if ("rune" in id or "dragon" in id) else wood
		_obox(st, Vector3(0, 0.28, 0), Basis(Vector3.RIGHT, 0.5), Vector3(0.025, 0.34, 0.03), w2)   # upper limb
		_obox(st, Vector3(0, -0.28, 0), Basis(Vector3.RIGHT, -0.5), Vector3(0.025, 0.34, 0.03), w2) # lower limb
		_obox(st, Vector3(0, 0, -0.14), Basis(), Vector3(0.006, 0.5, 0.006), Color(0.85, 0.82, 0.7))  # string
	elif "staff" in id or "wand" in id:
		_cyl(st, 0, -0.35, 0, 0.03, 0.85, 6, wood)
		_ball(st, Vector3(0, 0.55, 0), Vector3(0.1, 0.11, 0.1), 4, 7, mc)          # orb
		_ball(st, Vector3(0, 0.55, 0), Vector3(0.05, 0.06, 0.05), 3, 6, _lt(mc, 0.4))
	elif "spear" in id or "halberd" in id or "pike" in id or "lance" in id:
		_cyl(st, 0, -0.45, 0, 0.024, 1.15, 6, wood)
		_cone(st, 0, 0.7, 0, 0.05, 0.22, 5, mc)                                    # point
		if "halberd" in id:
			_obox(st, Vector3(0.12, 0.62, 0), Basis(), Vector3(0.12, 0.08, 0.02), mc)  # axe blade
	elif "battleaxe" in id or "greataxe" in id:
		_cyl(st, 0, -0.15, 0, 0.03, 0.82, 6, wood)
		for sx: float in [-1.0, 1.0]:
			_obox(st, Vector3(sx * 0.14, 0.52, 0), Basis(), Vector3(0.14, 0.17, 0.028), mc)  # double head
	elif "axe" in id or "hatchet" in id:
		_cyl(st, 0, -0.2, 0, 0.028, 0.72, 5, wood)
		_obox(st, Vector3(0.06, 0.5, 0), Basis(), Vector3(0.15, 0.16, 0.03), mc)
	elif "warhammer" in id or "maul" in id or "mace" in id or "hammer" in id:
		_cyl(st, 0, -0.2, 0, 0.03, 0.72, 6, wood)
		if "mace" in id:
			_ball(st, Vector3(0, 0.52, 0), Vector3(0.13, 0.14, 0.13), 4, 7, mc)    # flanged ball
			for a in range(6):
				var an := TAU * float(a) / 6.0
				_cone(st, cos(an) * 0.13, 0.52, sin(an) * 0.13, 0.03, 0.08, 4, _dk(mc, 0.1))
		else:
			_box(st, 0, 0.52, 0, 0.26, 0.2, 0.2, mc)                               # hammer block
	elif "dagger" in id or "knife" in id:
		_cyl(st, 0, -0.1, 0, 0.022, 0.16, 5, grip)
		_box(st, 0, 0.02, 0, 0.14, 0.03, 0.04, mc)                                 # guard
		_obox(st, Vector3(0, 0.22, 0), Basis(), Vector3(0.028, 0.2, 0.01), mc)     # short blade
		_cone(st, 0, 0.42, 0, 0.028, 0.08, 4, mc)
	elif "scimitar" in id or "sabre" in id or "sab. " in id:
		_cyl(st, 0, -0.16, 0, 0.026, 0.24, 5, grip)
		_box(st, 0, 0.0, 0, 0.2, 0.035, 0.05, mc)                                  # guard
		_obox(st, Vector3(0.03, 0.3, 0), Basis(Vector3.FORWARD, 0.25), Vector3(0.032, 0.24, 0.012), mc)  # curved
		_obox(st, Vector3(0.12, 0.55, 0), Basis(Vector3.FORWARD, 0.6), Vector3(0.03, 0.18, 0.012), mc)
	else:   # sword / longsword / blade default
		_cyl(st, 0, -0.18, 0, 0.026, 0.24, 5, grip)                               # grip
		_ball(st, Vector3(0, -0.32, 0), Vector3(0.05, 0.05, 0.05), 3, 5, mc)      # pommel
		_box(st, 0, 0.0, 0, 0.22, 0.04, 0.05, mc)                                 # crossguard
		_obox(st, Vector3(0, 0.42, 0), Basis(), Vector3(0.035, 0.4, 0.012), mc)   # blade
		_cone(st, 0, 0.82, 0, 0.035, 0.12, 4, mc)                                 # tip
	var m: Mesh = st.commit(); _cache[key] = m; return m

# ── Equipped ARMOR overlays (v1.6.1) — tier-coloured plate over the rig parts ──
func _armor_body_mesh(id: String) -> Mesh:
	var key := "armb:" + id
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mc := _gear_tier_col(id)
	# ONE breastplate shell — three overlapping same-tone forms that flow into each
	# other (chest → abdomen → hips) so it reads as a single plate, not stacked balls.
	# Each is a hair larger than the torso beneath so no tunic/skin shows through.
	# Shifted forward (+Z) with shallower back so the rear reads as a BACK, not a
	# round marshmallow — front stays rounded (chest), back is flatter but not a plane.
	_ball(st, Vector3(0, 0.46, 0.06), Vector3(0.44, 0.28, 0.26), 6, 11, mc)        # chest (covers pecs/collar)
	_ball(st, Vector3(0, 0.16, 0.05), Vector3(0.37, 0.28, 0.23), 6, 11, mc)        # abdomen (covers waist)
	_ball(st, Vector3(0, -0.12, 0.04), Vector3(0.34, 0.15, 0.21), 5, 9, mc)        # hips (covers seat)
	# Pauldrons merged onto the shoulder tops (same tone → part of the shell).
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.34, 0.56, 0.03), Vector3(0.22, 0.18, 0.22), 5, 9, mc)
	var m: Mesh = st.commit(); _cache[key] = m; return m

func _armor_helm_mesh(id: String) -> Mesh:
	var key := "armh:" + id
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mc := _gear_tier_col(id); var dk := _dk(mc, 0.09)
	# ONE helm shell — dome + face-frame flow together (single tone), covering the hair.
	# No nasal/brow bars (they read as a "T" on the face).
	_ball(st, Vector3(0, 0.08, -0.02), Vector3(0.26, 0.25, 0.26), 6, 9, mc)        # dome (covers hair)
	_ball(st, Vector3(0, -0.05, 0.02), Vector3(0.255, 0.14, 0.25), 5, 8, mc)       # face frame / cheeks
	_obox(st, Vector3(0, 0.21, -0.02), Basis(), Vector3(0.02, 0.06, 0.24), dk)     # crown crest seam (on top)
	if "dragon" in id or "rune" in id or "adamant" in id:   # high-tier crest horns
		for e: float in [-1.0, 1.0]:
			_obox(st, Vector3(e * 0.18, 0.17, -0.02), Basis(Vector3.RIGHT, -0.5), Vector3(0.03, 0.16, 0.03), mc)
	var m: Mesh = st.commit(); _cache[key] = m; return m

func _armor_legs_mesh(id: String) -> Mesh:
	var key := "arml:" + id
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mc := _gear_tier_col(id); var dk := _dk(mc, 0.09)
	# ONE leg shell — thigh + shin flow (same tone), sized just over the leg beneath.
	_ball(st, Vector3(0, -0.2, 0.01), Vector3(0.17, 0.25, 0.17), 5, 8, mc)          # thigh
	_ball(st, Vector3(0, -0.55, 0.01), Vector3(0.135, 0.25, 0.14), 5, 8, mc)        # shin
	_obox(st, Vector3(0, -0.37, 0.09), Basis(), Vector3(0.1, 0.02, 0.02), dk)       # knee seam (dark, subtle)
	var m: Mesh = st.commit(); _cache[key] = m; return m

func _armor_boots_mesh(id: String) -> Mesh:
	var key := "armt:" + id
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mc := _gear_tier_col(id)
	_ball(st, Vector3(0, -0.79, 0.02), Vector3(0.12, 0.1, 0.14), 3, 7, mc)             # armored boot
	_ball(st, Vector3(0, -0.82, 0.11), Vector3(0.1, 0.06, 0.15), 3, 7, _dk(mc, 0.12))  # toe cap
	var m: Mesh = st.commit(); _cache[key] = m; return m

func _armor_gloves_mesh(id: String) -> Mesh:
	var key := "armg:" + id
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mc := _gear_tier_col(id)
	_ball(st, Vector3(0, -0.65, 0.03), Vector3(0.11, 0.1, 0.12), 4, 7, mc)             # gauntlet (over fist)
	_ball(st, Vector3(0, -0.55, 0.02), Vector3(0.1, 0.07, 0.1), 3, 6, _dk(mc, 0.1))    # wrist cuff
	var m: Mesh = st.commit(); _cache[key] = m; return m

## Round shield for the OFF-HAND (left arm), facing forward (+Z).
func _armor_shield_mesh(id: String) -> Mesh:
	var key := "arms:" + id
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mc := _gear_tier_col(id); var dk := _dk(mc, 0.15)
	_ball(st, Vector3(-0.02, -0.5, 0.09), Vector3(0.19, 0.23, 0.02), 4, 9, dk)         # rim (back)
	_ball(st, Vector3(-0.02, -0.5, 0.13), Vector3(0.18, 0.22, 0.03), 5, 10, mc)        # face
	_ball(st, Vector3(-0.02, -0.5, 0.16), Vector3(0.05, 0.05, 0.02), 3, 6, _lt(mc, 0.2))  # boss
	_obox(st, Vector3(-0.02, -0.5, 0.155), Basis(), Vector3(0.15, 0.018, 0.006), dk)   # cross
	_obox(st, Vector3(-0.02, -0.5, 0.155), Basis(), Vector3(0.018, 0.18, 0.006), dk)
	var m: Mesh = st.commit(); _cache[key] = m; return m

## Dungeon cave-mouth — a BIG rocky outcrop with a dark arched opening + flanking
## torches, so it reads as an entrance in the cliffs (not a pebble). Opening faces
## +Z; admin can rotate it to face out of the mountainside. Feet at y=0.
func cave_mouth(col: Color) -> Mesh:
	var key := "cave:" + col.to_html(false)
	if _cache.has(key): return _cache[key]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rc := Color(0.44, 0.43, 0.46)
	var dark := Color(0.04, 0.03, 0.05)
	# Rocky mass + boulders framing the mouth.
	_ball(st, Vector3(0, 1.5, -0.4), Vector3(1.9, 1.9, 1.5), 7, 11, rc)
	_ball(st, Vector3(-1.35, 0.95, 0.25), Vector3(0.75, 1.05, 0.8), 5, 9, _dk(rc, 0.1))     # left jamb
	_ball(st, Vector3(1.35, 0.95, 0.25), Vector3(0.75, 1.05, 0.8), 5, 9, _dk(rc, 0.1))      # right jamb
	_ball(st, Vector3(0, 2.55, 0.0), Vector3(1.15, 0.7, 1.0), 5, 9, _dk(rc, 0.04))          # lintel / overhang
	_ball(st, Vector3(-0.7, 0.25, 0.7), Vector3(0.5, 0.3, 0.4), 4, 7, rc)                   # base rubble
	_ball(st, Vector3(0.7, 0.25, 0.7), Vector3(0.5, 0.3, 0.4), 4, 7, rc)
	# Dark arched OPENING recessed into the front.
	_ball(st, Vector3(0, 1.0, 0.55), Vector3(0.9, 1.15, 0.7), 7, 11, dark)
	_ball(st, Vector3(0, 0.4, 0.7), Vector3(0.95, 0.45, 0.55), 4, 8, dark)                    # dark floor
	# Flanking torches (post + flame) to signal "enter here".
	for e: float in [-1.0, 1.0]:
		_cyl(st, e * 1.15, 0.0, 0.75, 0.05, 1.5, 5, Color(0.3, 0.2, 0.12))                    # post
		_ball(st, Vector3(e * 1.15, 1.62, 0.75), Vector3(0.11, 0.18, 0.11), 4, 7, Color(1.0, 0.55, 0.12))   # flame
		_ball(st, Vector3(e * 1.15, 1.7, 0.75), Vector3(0.05, 0.1, 0.05), 3, 6, Color(1.0, 0.9, 0.4))       # flame core
	var m2: Mesh = st.commit(); _cache[key] = m2; return m2

# ── ANIMATED monster RIGS (v1.6.1 P-ANIM) ────────────────────────────────────
## Public archetype lookup so World3D can decide rig (animated) vs single mesh.
func archetype_of(mtype: String) -> String:
	return _archetype(mtype)

func _pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n

## Commit a per-part SurfaceTool into a MeshInstance3D under `parent`.
func _rig_mi(parent: Node3D, st: SurfaceTool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	parent.add_child(mi)

func _st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

## Build a MonsterRig Node3D (self-animating part hierarchy) for the rigged
## archetypes; World3D falls back to the single `monster()` mesh for the rest.
## Geometry is authored facing +Z (forward); `scale` is applied to the root.
func build_monster_rig(mtype: String, col: Color, scale := 1.0) -> Node3D:
	var root := Node3D.new()
	root.set_script(MonsterRigScript)
	var parts: Dictionary
	match _archetype(mtype):
		"quad":      parts = _rig_quad(root, col, mtype)
		"dragon":    parts = _rig_serpent(root, mtype) if "wyrm" in mtype else _rig_dragon(root, col, mtype)
		"crawler":   parts = _rig_crawler(root, col, mtype)
		"bird":      parts = _rig_bird(root, col)
		"fish":      parts = _rig_fish(root)
		"elemental": parts = _rig_simple(root, col, mtype, "elemental")
		"spirit":    parts = _rig_simple(root, col, mtype, "spirit")
		_:           parts = _rig_humanoid(root, col, mtype)
	root.scale = Vector3.ONE * scale
	root.call("setup", parts)
	return root

## Quadruped (wolf / bear / rat) — body, head (now with EYES + snout + ears), 4
## swinging legs, a tail. Faces +Z.
func _rig_quad(root: Node3D, col: Color, t: String) -> Dictionary:
	var rat := "rat" in t
	var bear := "bear" in t
	var belly := _lt(col, 0.12)
	var body := _pivot(root, Vector3(0, 0.62, 0))
	var bst := _st()
	var blen: float = 0.72 if rat else (0.95 if bear else 0.85)
	_ball(bst, Vector3(0, 0, 0), Vector3(0.5 if bear else 0.42, 0.42 if bear else 0.34, blen), 6, 10, col)
	_ball(bst, Vector3(0, -0.14, 0), Vector3(0.36, 0.2, blen * 0.85), 4, 8, belly)   # underside
	if bear:
		_ball(bst, Vector3(0, 0.28, 0.25), Vector3(0.36, 0.28, 0.35), 5, 8, col)     # shoulder hump
	# Shoulder + haunch muscle definition so the body isn't one smooth blob.
	for zz: float in [0.46, -0.46]:
		_ball(bst, Vector3(0, 0.08, zz), Vector3(0.44 if bear else 0.38, 0.3, 0.22), 5, 8, _lt(col, 0.04))
	# Fur ruff (neck mane) + spine tufts for wolves + bears — reads as fur, not skin.
	if not rat:
		for fx: float in [-0.24, -0.08, 0.08, 0.24]:
			_ball(bst, Vector3(fx, 0.26, 0.46), Vector3(0.11, 0.14, 0.09), 3, 6, _lt(col, 0.05))    # neck ruff
		for sz: float in [0.15, -0.15, -0.42]:
			_ball(bst, Vector3(0, 0.34, sz), Vector3(0.1, 0.09, 0.11), 3, 6, _lt(col, 0.03))        # back fur tufts
	if "plague" in t:   # sickly boils
		for bp: Vector3 in [Vector3(0.2, 0.15, 0.2), Vector3(-0.18, 0.1, -0.15), Vector3(0.08, 0.22, -0.35)]:
			_ball(bst, bp, Vector3(0.07, 0.07, 0.07), 3, 6, Color(0.55, 0.62, 0.22))
	_rig_mi(body, bst)
	# HEAD (front +Z)
	var head := _pivot(root, Vector3(0, 0.74, 0.86))
	var hst := _st()
	_ball(hst, Vector3(0, 0, 0), Vector3(0.3, 0.3, 0.32), 6, 10, col)                 # skull
	_ball(hst, Vector3(0, -0.04, 0.14), Vector3(0.24, 0.22, 0.2), 5, 8, col)          # cheeks / brow mass
	_ball(hst, Vector3(0, -0.08, 0.26), Vector3(0.18, 0.16, 0.24), 5, 9, belly)       # muzzle
	_ball(hst, Vector3(0, -0.02, 0.44), Vector3(0.09, 0.08, 0.08), 4, 7, _dk(col, 0.2))  # nose pad
	for nn: float in [-0.04, 0.04]:                                                    # nostrils
		_ball(hst, Vector3(nn, -0.02, 0.5), Vector3(0.018, 0.02, 0.015), 2, 4, Color(0.05, 0.03, 0.03))
	_obox(hst, Vector3(0, -0.16, 0.42), Basis(), Vector3(0.09, 0.012, 0.06), _dk(col, 0.4))   # mouth line
	for fx: float in [-0.07, 0.07]:                                                    # fangs
		_cone(hst, fx, -0.2, 0.44, 0.018, 0.06, 4, Color(0.95, 0.93, 0.85))
	_obox(hst, Vector3(0, 0.12, 0.2), Basis(), Vector3(0.16, 0.02, 0.03), _dk(col, 0.18))    # brow ridge
	for e: float in [-1.0, 1.0]:                                                       # EYES
		_ball(hst, Vector3(e * 0.14, 0.08, 0.22), Vector3(0.05, 0.06, 0.04), 3, 6, Color(0.95, 0.85, 0.35))
		_ball(hst, Vector3(e * 0.145, 0.07, 0.255), Vector3(0.02, 0.03, 0.02), 2, 5, Color(0.05, 0.03, 0.02))
	if rat:
		for e2: float in [-1.0, 1.0]:
			_ball(hst, Vector3(e2 * 0.16, 0.28, -0.02), Vector3(0.11, 0.12, 0.05), 3, 6, _lt(col, 0.2))  # big ears
		_ball(hst, Vector3(0, -0.12, 0.44), Vector3(0.05, 0.05, 0.05), 2, 5, Color(0.9, 0.55, 0.6))       # pink nose
	elif bear:
		for e2: float in [-1.0, 1.0]:
			_ball(hst, Vector3(e2 * 0.18, 0.28, -0.02), Vector3(0.1, 0.09, 0.08), 3, 6, col)              # round ears
		_ball(hst, Vector3(0, -0.14, 0.42), Vector3(0.06, 0.05, 0.05), 2, 5, Color(0.1, 0.08, 0.07))      # nose
	else:
		for e2: float in [-1.0, 1.0]:
			_ball(hst, Vector3(e2 * 0.16, 0.3, -0.04), Vector3(0.08, 0.17, 0.05), 3, 5, col)              # pointed ears
	_rig_mi(head, hst)
	# LEGS — 4 hip pivots; diagonal gait phases.
	var legs: Array = []
	var hips := [
		{"p": Vector3(-0.28, 0.58, 0.55), "ph": 0.0},          # front-left
		{"p": Vector3(0.28, 0.58, 0.55),  "ph": PI},           # front-right
		{"p": Vector3(-0.28, 0.58, -0.55), "ph": PI},          # back-left
		{"p": Vector3(0.28, 0.58, -0.55),  "ph": 0.0}]         # back-right
	for hp: Dictionary in hips:
		var leg := _pivot(root, hp["p"] as Vector3)
		var lst := _st()
		# Jointed leg: haunch → hock → shank → paw with claws (was one blob).
		_ball(lst, Vector3(0, -0.16, 0), Vector3(0.115, 0.2, 0.13), 4, 7, col)          # upper (muscled)
		_ball(lst, Vector3(0, -0.33, 0.01), Vector3(0.072, 0.06, 0.08), 3, 6, _dk(col, 0.12))  # hock joint
		_ball(lst, Vector3(0, -0.47, 0.02), Vector3(0.078, 0.16, 0.088), 4, 7, _dk(col, 0.14))  # shank
		_ball(lst, Vector3(0, -0.57, 0.06), Vector3(0.088, 0.05, 0.13), 3, 7, _dk(col, 0.24))   # paw
		for cx: float in [-0.05, 0.0, 0.05]:
			_ball(lst, Vector3(cx, -0.58, 0.15), Vector3(0.02, 0.02, 0.05), 2, 4, Color(0.9, 0.88, 0.8))  # claws
		_rig_mi(leg, lst)
		legs.append({"node": leg, "phase": float(hp["ph"])})
	# TAIL (rear -Z)
	var tail := _pivot(root, Vector3(0, 0.66, -0.82))
	var tst := _st()
	if rat:
		_ball(tst, Vector3(0, -0.06, -0.34), Vector3(0.045, 0.05, 0.42), 3, 6, belly)
	elif bear:
		_ball(tst, Vector3(0, 0, -0.08), Vector3(0.09, 0.09, 0.1), 3, 6, col)
	else:
		_ball(tst, Vector3(0, 0.05, -0.28), Vector3(0.15, 0.17, 0.34), 4, 7, _lt(col, 0.06))   # bushy
	_rig_mi(tail, tst)
	return {"arche": "quad", "body": body, "head": head, "legs": legs, "tail": tail}

## Humanoid — distinct family proportions so giants/trolls DON'T read as big vikings:
## giants hunch with huge arms/fists + a small sunk head; trolls are bulky w/ long
## arms + a club; goblins/imps small. Body, head, 2 legs, 2 arms (R holds a weapon).
func _rig_humanoid(root: Node3D, col: Color, t: String) -> Dictionary:
	var giant := "giant" in t
	var troll := "troll" in t or "ogre" in t
	var small := "goblin" in t or "imp" in t
	var undead := "skeleton" in t or "draugr" in t or "spectral" in t or "death" in t
	var sk := _dk(col, 0.1)
	var arm_c := col
	# proportions
	var hip_y := 0.82
	var torso_y := 1.15
	var head_y := 1.75
	var shoulder_x := 0.42
	var shoulder_y := 1.5
	var arm_len := 0.34
	var arm_rad := 0.1
	var hand_r := 0.1
	var torso_w := 0.36
	var head_r := 0.22
	var hunch := 0.0
	if giant:
		hip_y = 1.0; torso_y = 1.5; head_y = 2.1; shoulder_x = 0.62; shoulder_y = 1.95
		arm_len = 0.5; arm_rad = 0.17; hand_r = 0.19; torso_w = 0.56; head_r = 0.2; hunch = 0.16
	elif troll:
		hip_y = 0.92; torso_y = 1.35; head_y = 1.95; shoulder_x = 0.5; shoulder_y = 1.78
		arm_len = 0.52; arm_rad = 0.14; hand_r = 0.16; torso_w = 0.46; head_r = 0.2; hunch = 0.12
	elif small:
		hip_y = 0.6; torso_y = 0.85; head_y = 1.3; shoulder_x = 0.3; shoulder_y = 1.1
		arm_len = 0.26; arm_rad = 0.08; hand_r = 0.08; torso_w = 0.26; head_r = 0.18
	# LEGS
	var legs: Array = []
	var i := 0
	for lx: float in [-0.16, 0.16]:
		var leg := _pivot(root, Vector3(lx * (torso_w / 0.36), hip_y, 0))
		var lst := _st()
		var lw := 0.14 * (torso_w / 0.36)
		var limb := Color(0.85, 0.82, 0.72) if undead else _dk(col, 0.22)   # undead = bone
		var lwf := (lw * 0.6) if undead else lw                              # bony = thin
		_ball(lst, Vector3(0, -hip_y * 0.35, 0), Vector3(lwf, hip_y * 0.34, lwf), 4, 7, limb)       # thigh
		_ball(lst, Vector3(0, -hip_y * 0.5, 0.0), Vector3(lwf * 0.85, 0.05, lwf * 0.85), 3, 6, _dk(limb, 0.12))  # knee knob
		_ball(lst, Vector3(0, -hip_y * 0.7, 0.02), Vector3(lwf * 0.82, hip_y * 0.32, lwf * 0.82), 4, 7, _dk(limb, 0.08))  # shin
		if not undead:
			_ball(lst, Vector3(0, -hip_y * 0.68, -0.055), Vector3(lw * 0.55, hip_y * 0.22, 0.05), 3, 6, _dk(col, 0.05))  # calf (back)
			_ball(lst, Vector3(0, -hip_y * 0.33, 0.06), Vector3(lw * 0.7, hip_y * 0.24, 0.05), 3, 6, _lt(col, 0.03))     # quad (front)
		_ball(lst, Vector3(0, -hip_y + 0.06, 0.02), Vector3(0.13, 0.09, 0.16), 3, 6, Color(0.16, 0.11, 0.06))   # boot
		_ball(lst, Vector3(0, -hip_y + 0.02, 0.16), Vector3(0.1, 0.06, 0.13), 3, 7, Color(0.13, 0.09, 0.05))    # toe forward
		_rig_mi(leg, lst)
		legs.append({"node": leg, "phase": 0.0 if i == 0 else PI})
		i += 1
	# BODY (torso) — hunched families lean forward (+Z).
	var body := _pivot(root, Vector3(0, torso_y, hunch * 0.4))
	if hunch > 0.0:
		body.rotation.x = -hunch
	var tst := _st()
	_ball(tst, Vector3(0, 0, 0), Vector3(torso_w, 0.42 if not giant else 0.5, 0.26 if not giant else 0.38), 6, 10, col)
	_box(tst, 0, -0.3, 0, torso_w * 1.9, 0.12, 0.46, Color(0.3, 0.2, 0.1))       # belt
	if not giant and not troll:
		_ball(tst, Vector3(-0.36, 0.3, 0), Vector3(0.19, 0.15, 0.2), 4, 6, _METAL)  # pauldrons
		_ball(tst, Vector3(0.36, 0.3, 0), Vector3(0.19, 0.15, 0.2), 4, 6, _METAL)
	# Anatomy: bare brutes get pecs, the undead get a ribcage.
	if undead:
		for ry: float in [0.16, 0.03, -0.1]:
			_obox(tst, Vector3(0, ry, 0.2), Basis(), Vector3(0.18, 0.014, 0.03), _dk(col, 0.32))   # ribs
		_ball(tst, Vector3(0, 0.04, 0.16), Vector3(0.1, 0.14, 0.06), 4, 7, _dk(col, 0.18))          # sternum hollow
	elif giant or troll:
		for e: float in [-1.0, 1.0]:
			_ball(tst, Vector3(e * 0.16, 0.22, 0.18), Vector3(0.15, 0.11, 0.09), 4, 7, _lt(col, 0.05))  # pecs
	# Per-variant surface accents (biome / element flavour).
	if "ice" in t or "frost" in t:
		for e: float in [-1.0, 1.0]:
			for ix in range(3):
				_ball(tst, Vector3(e * (0.2 + float(ix) * 0.11), 0.26 - float(ix) * 0.03, 0.0), Vector3(0.025, 0.09, 0.025), 3, 5, Color(0.85, 0.95, 1.0))  # shoulder icicles
	elif "swamp" in t:
		for rx: float in [-0.28, -0.09, 0.09, 0.28]:
			_obox(tst, Vector3(rx, -0.12, 0.02), Basis(), Vector3(0.012, 0.18, 0.012), Color(0.42, 0.48, 0.16))   # hanging reeds
		_ball(tst, Vector3(-0.1, 0.08, 0.24), Vector3(0.07, 0.05, 0.03), 3, 6, Color(0.3, 0.4, 0.12))             # slime patch
	elif "cave" in t or "ancient" in t:
		for cp: Vector3 in [Vector3(-0.2, 0.2, 0.18), Vector3(0.24, -0.05, 0.2), Vector3(0.05, 0.3, 0.16)]:
			_ball(tst, cp, Vector3(0.08, 0.08, 0.06), 3, 6, _lt(col, 0.12))                                       # rocky/mossy lumps
	elif "fire" in t or "lava" in t or "magma" in t:
		for fp: Vector3 in [Vector3(-0.15, 0.2, 0.2), Vector3(0.18, 0.05, 0.22), Vector3(0.0, 0.32, 0.18)]:
			_ball(tst, fp, Vector3(0.05, 0.06, 0.03), 2, 5, Color(1.0, 0.6, 0.15))                                # ember flecks
	_rig_mi(body, tst)
	# HEAD — giants sink a SMALL head into the shoulders; features per family.
	var head := _pivot(root, Vector3(0, head_y, hunch * 0.5))
	var hst := _st()
	if undead:
		var bone := Color(0.9, 0.85, 0.7)
		_ball(hst, Vector3(0, 0.02, 0.0), Vector3(head_r, head_r + 0.03, head_r), 5, 9, bone)          # cranium
		_ball(hst, Vector3(0, -0.1, head_r * 0.55), Vector3(head_r * 0.62, head_r * 0.4, head_r * 0.6), 4, 7, bone)  # protruding jaw
		for e: float in [-1.0, 1.0]:
			_ball(hst, Vector3(e * 0.085, 0.0, head_r * 0.82), Vector3(0.05, 0.06, 0.035), 3, 6, Color(0.05, 0.05, 0.06))  # deep socket
			_ball(hst, Vector3(e * 0.085, 0.0, head_r * 0.86), Vector3(0.03, 0.035, 0.02), 2, 5, Color(0.9, 0.25, 0.12))   # eye ember
		_ball(hst, Vector3(0, 0.02, head_r * 0.92), Vector3(0.03, 0.05, 0.04), 3, 5, _dk(bone, 0.5))    # nasal cavity
		for tx: float in [-0.06, 0.0, 0.06]:                                                            # teeth grin
			_box(hst, tx, -0.14, head_r * 0.82, 0.028, 0.05, 0.02, bone)
	else:
		_ball(hst, Vector3(0, 0, 0), Vector3(head_r, head_r + 0.02, head_r), 6, 9, sk)                  # cranium
		_ball(hst, Vector3(0, -0.09, head_r * 0.55), Vector3(head_r * 0.72, head_r * 0.55, head_r * 0.62), 5, 8, sk)  # jaw / muzzle
		_ball(hst, Vector3(0, -0.02, head_r * 0.95), Vector3(0.052, 0.05, 0.06), 3, 6, _dk(sk, 0.1))    # nose / snout
		_ball(hst, Vector3(0, 0.03, head_r), Vector3(0.02, 0.02, 0.02), 2, 4, _dk(sk, 0.35))            # nostril shade
		_obox(hst, Vector3(0, 0.09, head_r * 0.82), Basis(), Vector3(head_r * 0.55, 0.02, 0.03), _dk(sk, 0.22))  # brow ridge
		for e: float in [-1.0, 1.0]:
			_ball(hst, Vector3(e * 0.085, 0.02, head_r * 0.88), Vector3(0.042, 0.046, 0.03), 3, 6, Color(0.95, 0.87, 0.4))  # eye
			_ball(hst, Vector3(e * 0.092, 0.015, head_r * 0.92), Vector3(0.018, 0.024, 0.016), 2, 5, Color(0.1, 0.05, 0.05))  # pupil
		_obox(hst, Vector3(0, -0.12, head_r * 0.86), Basis(), Vector3(0.05, 0.013, 0.02), _dk(sk, 0.32))  # mouth
		if not small:
			for e: float in [-1.0, 1.0]:
				_ball(hst, Vector3(e * (head_r + 0.02), -0.02, 0.0), Vector3(0.03, 0.06, 0.045), 3, 5, sk)   # ears
	if giant:
		_ball(hst, Vector3(0, 0.14, 0.08), Vector3(0.22, 0.07, 0.1), 3, 6, _dk(col, 0.2))     # heavy brow
	elif troll:
		for e: float in [-0.08, 0.08]:
			_ball(hst, Vector3(e, -0.14, 0.16), Vector3(0.03, 0.11, 0.03), 3, 5, Color(0.9, 0.85, 0.7))  # tusks
	elif small:
		for e: float in [-1.0, 1.0]:
			_ball(hst, Vector3(e * 0.24, 0.02, 0.0), Vector3(0.14, 0.07, 0.05), 3, 5, col)     # big ears
	_rig_mi(head, hst)
	# ARMS (2 shoulder pivots); the right hand holds a weapon.
	var club := troll or giant
	var uarm := Color(0.85, 0.82, 0.72) if undead else arm_c   # undead limbs = bone
	var uskin := Color(0.85, 0.82, 0.72) if undead else sk
	var ar := (arm_rad * 0.62) if undead else arm_rad          # bony = thin
	for ex: float in [-1.0, 1.0]:
		var arm := _pivot(root, Vector3(ex * shoulder_x, shoulder_y, 0))
		var ast := _st()
		_ball(ast, Vector3(0, -arm_len * 0.7, 0), Vector3(ar, arm_len * 0.6, ar + 0.01), 4, 7, uarm)   # upper arm
		if not undead:
			_ball(ast, Vector3(0, -arm_len * 0.42, 0), Vector3(arm_rad * 1.08, arm_rad * 0.9, arm_rad * 1.1), 4, 6, _lt(arm_c, 0.05))  # deltoid
			_ball(ast, Vector3(0, -arm_len * 0.72, arm_rad * 0.55), Vector3(arm_rad * 0.7, arm_len * 0.4, arm_rad * 0.6), 3, 6, _lt(arm_c, 0.04))  # bicep
		else:
			_ball(ast, Vector3(0, -arm_len * 1.02, 0), Vector3(ar * 1.2, 0.03, ar * 1.2), 3, 6, _dk(uarm, 0.12))  # elbow bone knob
		_ball(ast, Vector3(0, -arm_len * 1.05, 0.01), Vector3(ar * 0.85, arm_len * 0.5, ar * 0.9), 4, 7, uskin)  # forearm
		_ball(ast, Vector3(0, -arm_len * 1.5, 0.02), Vector3(hand_r, hand_r * 1.05, hand_r), 4, 7, uskin)   # fist
		for kx: float in [-0.5, 0.0, 0.5]:   # knuckles
			_ball(ast, Vector3(kx * hand_r, -arm_len * 1.5 - hand_r * 0.4, 0.02 + hand_r * 0.7), Vector3(hand_r * 0.32, hand_r * 0.3, hand_r * 0.32), 2, 5, uskin)
		_ball(ast, Vector3(-hand_r * 0.85, -arm_len * 1.5 + hand_r * 0.3, 0.06), Vector3(hand_r * 0.3, hand_r * 0.45, hand_r * 0.3), 2, 5, uskin)  # thumb
		if ex > 0.0:   # right hand weapon
			if club:
				_cyl(ast, 0.0, -arm_len * 1.5, 0.12, 0.05, 0.7, 6, Color(0.34, 0.24, 0.13))
				_ball(ast, Vector3(0, -arm_len * 1.5 + 0.72, 0.12), Vector3(0.17, 0.19, 0.17), 4, 6, Color(0.3, 0.21, 0.11))
			elif not undead:
				_obox(ast, Vector3(0.02, -arm_len * 1.5 - 0.1, 0.16), Basis(Vector3.RIGHT, -0.9), Vector3(0.03, 0.34, 0.05), _METAL)  # blade
		_rig_mi(arm, ast)
	return {"arche": "humanoid", "body": body, "head": head, "legs": legs}

## Dragon — rigged: body, head (horns/jaw/eyes), 2 flapping membrane wings, 4 legs,
## a swaying spiked tail. Palette per type. Faces +Z. Simpler than the static boss
## mesh but ALIVE (was the "all 3 dragons move stiff" complaint).
func _rig_dragon(root: Node3D, _col: Color, t: String) -> Dictionary:
	var sd := Color(0.08, 0.32, 0.19); var sm := Color(0.14, 0.5, 0.29)
	var belly := Color(0.52, 0.6, 0.3); var horn := Color(0.86, 0.82, 0.58)
	var spike := Color(0.92, 0.8, 0.24); var mem := Color(0.3, 0.15, 0.14); var eye := Color(1.0, 0.85, 0.15)
	if "drake" in t:
		sd = Color(0.3, 0.2, 0.1); sm = Color(0.55, 0.4, 0.18); belly = Color(0.6, 0.5, 0.3); mem = Color(0.4, 0.28, 0.14)
	elif "wyvern" in t:
		sd = Color(0.2, 0.34, 0.24); sm = Color(0.42, 0.64, 0.46); belly = Color(0.6, 0.68, 0.42); mem = Color(0.3, 0.46, 0.32)
	elif "frost" in t or "wyrm" in t:
		sd = Color(0.4, 0.55, 0.68); sm = Color(0.62, 0.8, 0.92); belly = Color(0.82, 0.9, 0.95); mem = Color(0.52, 0.7, 0.84); eye = Color(0.55, 0.85, 1.0)
	# BODY
	var body := _pivot(root, Vector3(0, 1.0, 0))
	var bst := _st()
	_ball(bst, Vector3(0, 0, 0), Vector3(0.55, 0.5, 1.0), 6, 10, sm)
	_ball(bst, Vector3(0, -0.28, 0), Vector3(0.46, 0.3, 0.9), 4, 8, belly)
	for j in range(6):
		_cone(bst, 0, 0.45, (0.35 - float(j) * 0.28), 0.08, 0.2, 5, spike)   # dorsal spikes
	_rig_mi(body, bst)
	# HEAD (front +Z): neck + skull + snout + jaw + horns + eyes
	var head := _pivot(root, Vector3(0, 1.35, 0.7))
	var hst := _st()
	_ball(hst, Vector3(0, 0.05, 0.1), Vector3(0.26, 0.28, 0.4), 4, 8, sm)          # neck
	_ball(hst, Vector3(0, 0.2, 0.48), Vector3(0.27, 0.25, 0.34), 4, 8, sm)         # skull
	_ball(hst, Vector3(0, 0.14, 0.82), Vector3(0.17, 0.15, 0.22), 3, 7, sm)        # snout
	_ball(hst, Vector3(0, 0.02, 0.82), Vector3(0.14, 0.08, 0.17), 3, 6, sd)        # lower jaw
	_ball(hst, Vector3(0, 0.08, 0.9), Vector3(0.08, 0.06, 0.09), 3, 5, Color(1.0, 0.55, 0.08))  # maw glow
	for e: float in [-1.0, 1.0]:
		_obox(hst, Vector3(e * 0.18, 0.46, 0.3), Basis(Vector3.RIGHT, -0.7), Vector3(0.05, 0.28, 0.05), horn)  # horns
		_ball(hst, Vector3(e * 0.15, 0.24, 0.62), Vector3(0.06, 0.065, 0.05), 3, 6, eye)                       # eye
		_ball(hst, Vector3(e * 0.15, 0.24, 0.66), Vector3(0.015, 0.045, 0.015), 2, 4, Color(0.1, 0.03, 0.0))   # slit
	_rig_mi(head, hst)
	# WINGS — flapping membranes
	var wings: Array = []
	for side: float in [-1.0, 1.0]:
		var wing := _pivot(root, Vector3(side * 0.42, 1.35, 0.1))
		var wst := _st()
		var wrist := Vector3(side * 0.9, 0.6, -0.05)
		var f1 := Vector3(side * 1.35, 0.85, -0.4)
		var f2 := Vector3(side * 1.35, 0.2, 0.1)
		var f3 := Vector3(side * 1.0, -0.25, 0.5)
		var rootp := Vector3(0, 0, 0)
		_tri(wst, rootp, wrist, f1, mem)
		_tri(wst, rootp, f1, f2, _dk(mem, 0.06))
		_tri(wst, rootp, f2, f3, _dk(mem, 0.12))
		_strut(wst, rootp, wrist, 0.05, horn)
		for tip: Vector3 in [f1, f2, f3]:
			_strut(wst, wrist, tip, 0.03, horn)
		_rig_mi(wing, wst)
		wings.append({"node": wing, "side": side})
	# LEGS (4)
	var legs: Array = []
	var dhips := [
		{"p": Vector3(-0.34, 0.62, 0.4), "ph": 0.0},
		{"p": Vector3(0.34, 0.62, 0.4),  "ph": PI},
		{"p": Vector3(-0.34, 0.62, -0.4), "ph": PI},
		{"p": Vector3(0.34, 0.62, -0.4),  "ph": 0.0}]
	for hp: Dictionary in dhips:
		var leg := _pivot(root, hp["p"] as Vector3)
		var lst := _st()
		_ball(lst, Vector3(0, -0.3, 0), Vector3(0.13, 0.32, 0.15), 3, 7, sd)
		for cx: float in [-0.07, 0.0, 0.07]:
			_cone(lst, cx, -0.62, 0.1, 0.03, 0.12, 4, horn)    # toe claws
		_rig_mi(leg, lst)
		legs.append({"node": leg, "phase": float(hp["ph"])})
	# TAIL — tapering spiked, sways
	var tail := _pivot(root, Vector3(0, 1.0, -0.85))
	var tst := _st()
	var prev := Vector3(0, 0.05, 0)
	for k in range(6):
		var z := -float(k) * 0.32
		var ty := 0.02 - float(k) * 0.02
		var w := 0.24 - float(k) * 0.03
		_ball(tst, Vector3(0, ty, z), Vector3(w, w, 0.2), 3, 6, sm if k % 2 == 0 else sd)
		_cone(tst, 0, ty + w * 0.6, z, 0.04, 0.14, 4, spike)
		prev = Vector3(0, ty, z)
	_ball(tst, prev + Vector3(0, 0, -0.2), Vector3(0.16, 0.05, 0.2), 3, 6, spike)   # spade tip
	_rig_mi(tail, tst)
	return {"arche": "dragon", "body": body, "head": head, "legs": legs, "tail": tail, "wings": wings}

## Serpent (frost / venom WYRM) — a coiled, wingless, legless snake-dragon: a raised
## front coil + S-curve body, a horned head, a dorsal frill, and a long tapering tail
## that undulates (the rig's "tail" sway). Matches the 2D coiled wyrm. Faces +Z.
func _rig_serpent(root: Node3D, t: String) -> Dictionary:
	var sm := Color(0.62, 0.8, 0.92)
	var belly := Color(0.82, 0.9, 0.95); var horn := Color(0.86, 0.92, 0.98)
	var eye := Color(0.5, 0.85, 1.0); var frill := Color(0.5, 0.72, 0.9)
	if "venom" in t or "wyvern" in t:
		sm = Color(0.4, 0.66, 0.42); belly = Color(0.7, 0.78, 0.4)
		horn = Color(0.85, 0.9, 0.5); eye = Color(0.7, 1.0, 0.3); frill = Color(0.35, 0.6, 0.3)
	# BODY — a raised front coil rising into an S-curve trunk.
	var body := _pivot(root, Vector3(0, 0.7, 0))
	var bst := _st()
	_ball(bst, Vector3(0, 0.5, 0.35), Vector3(0.42, 0.5, 0.5), 7, 11, sm)          # reared front coil
	_ball(bst, Vector3(0, 0.5, 0.35), Vector3(0.3, 0.36, 0.4), 5, 9, belly)        # front belly
	_ball(bst, Vector3(0.28, 0.0, -0.15), Vector3(0.44, 0.4, 0.55), 6, 10, sm)     # mid coil (offset = S-curve)
	_ball(bst, Vector3(-0.24, -0.05, -0.55), Vector3(0.4, 0.34, 0.5), 6, 10, _dk(sm, 0.05))  # rear coil
	for i in range(4):                                                              # dorsal frill scutes
		_cone(bst, sin(float(i)) * 0.1, 0.75 - float(i) * 0.12, 0.4 - float(i) * 0.28, 0.06, 0.14, 4, frill)
	_rig_mi(body, bst)
	# HEAD — raised, horned, with a snout + fangs + glowing eyes.
	var head := _pivot(root, Vector3(0, 1.35, 0.55))
	var hst := _st()
	_ball(hst, Vector3(0, 0.05, 0.1), Vector3(0.24, 0.24, 0.34), 5, 9, sm)         # skull
	_ball(hst, Vector3(0, -0.02, 0.42), Vector3(0.15, 0.13, 0.2), 4, 8, sm)        # snout
	_ball(hst, Vector3(0, -0.1, 0.42), Vector3(0.12, 0.07, 0.16), 3, 7, belly)     # jaw
	for e: float in [-1.0, 1.0]:
		_obox(hst, Vector3(e * 0.16, 0.28, -0.05), Basis(Vector3.RIGHT, -0.5), Vector3(0.045, 0.24, 0.045), horn)  # horns swept back
		_ball(hst, Vector3(e * 0.14, 0.08, 0.28), Vector3(0.055, 0.06, 0.045), 3, 6, eye)                          # eye
		_ball(hst, Vector3(e * 0.16, 0.06, -0.02), Vector3(0.06, 0.12, 0.04), 3, 6, frill)                         # cheek frill
	_cone(hst, -0.05, -0.12, 0.5, 0.02, 0.08, 4, Color(0.95, 0.95, 0.9))           # fangs
	_cone(hst, 0.05, -0.12, 0.5, 0.02, 0.08, 4, Color(0.95, 0.95, 0.9))
	_rig_mi(head, hst)
	# TAIL — long tapering coil that undulates (rig sways this node).
	var tail := _pivot(root, Vector3(0, 0.55, -0.9))
	var tst := _st()
	for k in range(7):
		var z := -float(k) * 0.34
		var w := 0.32 - float(k) * 0.04
		_ball(tst, Vector3(sin(float(k) * 0.9) * 0.12, -float(k) * 0.02, z), Vector3(w, w * 0.9, 0.24), 4, 7, sm if k % 2 == 0 else _dk(sm, 0.06))
	_ball(tst, Vector3(0, -0.14, -2.3), Vector3(0.05, 0.12, 0.18), 3, 6, frill)    # tail fin
	_rig_mi(tail, tst)
	return {"arche": "serpent", "body": body, "head": head, "tail": tail}

## Crawler (spider / lava) — a body, head with clustered eyes, and 8 proper jointed
## legs (femur angled out + tibia down to a foot) that scuttle. Fixes the old flat
## obox legs. Faces +Z.
func _rig_crawler(root: Node3D, col: Color, t: String) -> Dictionary:
	var lava := "lava" in t
	var body_c: Color = col if not lava else Color(0.22, 0.1, 0.07)
	var leg_c := _dk(body_c, 0.15)
	var eye_c := Color(0.9, 0.1, 0.1) if not lava else Color(1.0, 0.75, 0.15)
	var body := _pivot(root, Vector3(0, 0.5, 0))
	var bst := _st()
	_ball(bst, Vector3(0, 0, -0.25), Vector3(0.45, 0.32, 0.5), 6, 10, body_c)     # abdomen (rear)
	_ball(bst, Vector3(0, 0.02, 0.35), Vector3(0.3, 0.26, 0.32), 5, 8, _dk(body_c, 0.1))  # cephalothorax (front)
	if lava:
		_ball(bst, Vector3(0, 0.2, -0.2), Vector3(0.22, 0.12, 0.26), 4, 7, Color(1.0, 0.5, 0.08))
		_ball(bst, Vector3(0, 0.28, -0.2), Vector3(0.1, 0.08, 0.12), 3, 6, Color(1.0, 0.9, 0.4))
	_rig_mi(body, bst)
	# HEAD — clustered eyes at the front.
	var head := _pivot(root, Vector3(0, 0.52, 0.62))
	var hst := _st()
	for ex: float in [-0.14, -0.05, 0.05, 0.14]:
		_ball(hst, Vector3(ex, 0.02, 0.06), Vector3(0.045, 0.045, 0.045), 3, 6, eye_c)
	for ex2: float in [-0.09, 0.09]:
		_ball(hst, Vector3(ex2, 0.1, 0.02), Vector3(0.035, 0.035, 0.035), 3, 6, eye_c)
	_rig_mi(head, hst)
	# 8 LEGS — femur out + tibia down to a foot; scuttle phases alternate.
	var legs: Array = []
	var n := 0
	for side: float in [-1.0, 1.0]:
		for row in range(4):
			var zz := 0.35 - float(row) * 0.26
			var leg := _pivot(root, Vector3(side * 0.32, 0.55, zz))
			var lst := _st()
			var knee := Vector3(side * 0.42, 0.06, 0.02)
			var foot := Vector3(side * 0.66, -0.5, 0.04)
			_strut(lst, Vector3(0, 0, 0), knee, 0.045, leg_c)     # femur out
			_strut(lst, knee, foot, 0.035, leg_c)                 # tibia down
			if lava:
				_ball(lst, knee, Vector3(0.05, 0.05, 0.05), 2, 5, Color(1.0, 0.55, 0.1))
			_rig_mi(leg, lst)
			legs.append({"node": leg, "phase": 0.0 if (n % 2 == 0) else PI})
			n += 1
	return {"arche": "crawler", "body": body, "head": head, "legs": legs}

## Bird (chicken) — body, pecking head w/ beak + comb + eyes, 2 walking legs, and
## tiny flapping wings. Faces +Z.
func _rig_bird(root: Node3D, col: Color) -> Dictionary:
	var body := _pivot(root, Vector3(0, 0.36, 0))
	var bst := _st()
	_ball(bst, Vector3(0, 0, 0), Vector3(0.26, 0.28, 0.3), 5, 9, col)
	_ball(bst, Vector3(0, -0.02, -0.28), Vector3(0.16, 0.2, 0.2), 4, 7, col)   # tail feathers (rear)
	_rig_mi(body, bst)
	var head := _pivot(root, Vector3(0, 0.7, 0.14))
	var hst := _st()
	_ball(hst, Vector3(0, 0, 0), Vector3(0.16, 0.17, 0.16), 4, 8, col)
	_cone(hst, 0, -0.02, 0.14, 0.06, 0.16, 5, Color(0.95, 0.7, 0.15))          # beak (+Z)
	_box(hst, 0, 0.14, -0.02, 0.16, 0.1, 0.02, Color(0.85, 0.15, 0.12))        # comb
	for e: float in [-1.0, 1.0]:
		_ball(hst, Vector3(e * 0.09, 0.03, 0.1), Vector3(0.025, 0.03, 0.02), 2, 5, Color(0.05, 0.05, 0.05))  # eyes
	_rig_mi(head, hst)
	var wings: Array = []
	for side: float in [-1.0, 1.0]:
		var wing := _pivot(root, Vector3(side * 0.22, 0.4, 0))
		var wst := _st()
		_ball(wst, Vector3(side * 0.14, -0.02, 0), Vector3(0.06, 0.16, 0.2), 3, 6, _dk(col, 0.08))
		_rig_mi(wing, wst)
		wings.append({"node": wing, "side": side})
	var legs: Array = []
	var i := 0
	for lx: float in [-0.1, 0.1]:
		var leg := _pivot(root, Vector3(lx, 0.2, 0))
		var lst := _st()
		_cyl(lst, 0, -0.2, 0, 0.028, 0.2, 5, Color(0.9, 0.7, 0.15))
		_box(lst, 0, -0.2, 0.04, 0.02, 0.02, 0.14, Color(0.9, 0.7, 0.15))      # foot
		_rig_mi(leg, lst)
		legs.append({"node": leg, "phase": 0.0 if i == 0 else PI})
		i += 1
	return {"arche": "bird", "body": body, "head": head, "legs": legs, "wings": wings}

## Fish (shark) — a finned body that swims: the tail fluke sways (the rig's tail on
## Y) and the body undulates via idle bob. No legs. Faces +Z.
func _rig_fish(root: Node3D) -> Dictionary:
	var back := Color(0.24, 0.3, 0.4); var side := Color(0.44, 0.52, 0.62); var belly := Color(0.78, 0.83, 0.88)
	var yb := 0.7
	var body := _pivot(root, Vector3(0, yb, 0))
	var bst := _st()
	_ball(bst, Vector3(0, 0, 0.05), Vector3(0.3, 0.28, 0.6), 6, 10, side)
	_ball(bst, Vector3(0, 0, -0.55), Vector3(0.16, 0.16, 0.4), 5, 8, side)      # tail stock (rear)
	_ball(bst, Vector3(0, 0, 0.62), Vector3(0.24, 0.24, 0.4), 5, 8, side)       # head (+Z)
	_ball(bst, Vector3(0, 0.14, 0.0), Vector3(0.24, 0.14, 0.55), 5, 9, back)
	_ball(bst, Vector3(0, -0.15, 0.0), Vector3(0.22, 0.12, 0.5), 5, 9, belly)
	_tri(bst, Vector3(0, 0.2, -0.05), Vector3(0, 0.62, 0.05), Vector3(0, 0.2, 0.35), back)   # dorsal fin
	for e: float in [-1.0, 1.0]:
		_tri(bst, Vector3(e * 0.2, -0.06, 0.2), Vector3(e * 0.62, -0.34, -0.1), Vector3(e * 0.24, -0.06, -0.15), _dk(side, 0.08))  # pectorals
		_ball(bst, Vector3(e * 0.16, 0.04, 0.82), Vector3(0.03, 0.04, 0.03), 2, 5, Color(0.05, 0.05, 0.06))   # eyes
	_rig_mi(body, bst)
	var tail := _pivot(root, Vector3(0, yb, -0.9))
	var tst := _st()
	_tri(tst, Vector3(0, 0, 0), Vector3(0, 0.42, -0.45), Vector3(0, 0.05, -0.25), back)
	_tri(tst, Vector3(0, 0, 0), Vector3(0, -0.42, -0.45), Vector3(0, -0.05, -0.25), back)
	_rig_mi(tail, tst)
	return {"arche": "fish", "body": body, "tail": tail}

## Simple hover rig — wraps the existing single mesh under a body pivot so it gently
## bobs (elementals + spirits float). No legs.
func _rig_simple(root: Node3D, col: Color, mtype: String, arche: String) -> Dictionary:
	var body := _pivot(root, Vector3(0, 0.15, 0))
	var st := _st()
	if arche == "elemental":
		_mon_elemental(st, col, 1.0, mtype)
	else:
		_mon_spirit(st, col, 1.0)
	_rig_mi(body, st)
	return {"arche": arche, "body": body}

# ── monsters (per-type body archetypes + per-type features) ──────────────────
func monster(mtype: String, col: Color, scale := 1.0) -> Mesh:
	var arche := _archetype(mtype)
	var key := "mon:%s:%s:%.2f" % [mtype, col.to_html(false), scale]   # per-TYPE mesh
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match arche:
		"quad":      _mon_quad(st, col, scale, mtype)
		"crawler":   _mon_crawler(st, col, scale, mtype)
		"dragon":    _mon_dragon(st, col, scale, mtype)
		"bird":      _mon_bird(st, col, scale)
		"fish":      _mon_fish(st, col, scale)
		"elemental": _mon_elemental(st, col, scale, mtype)
		"spirit":    _mon_spirit(st, col, scale)
		_:           _mon_humanoid(st, col, scale, mtype)
	var m: Mesh = st.commit()
	_cache[key] = m
	return m

func _archetype(t: String) -> String:
	if "shark" in t: return "fish"
	if "elemental" in t or "magma" in t: return "elemental"
	if "spirit" in t: return "spirit"
	if "wolf" in t or "bear" in t or "rat" in t: return "quad"
	if "spider" in t or "crawler" in t: return "crawler"
	if "dragon" in t or "wyvern" in t or "drake" in t or "wyrm" in t or "nidhogg" in t or "hogg" in t: return "dragon"
	if "chicken" in t: return "bird"
	return "humanoid"   # goblin/bandit/skeleton/draugr/troll/giant/imp/knight/…

const _BONE := Color(0.9, 0.85, 0.7)

func _mon_humanoid(st: SurfaceTool, col: Color, s: float, t: String) -> void:
	var sk := _dk(col, 0.1)
	# Family body-mass: giants tower, trolls/ogres are bulky, goblins/imps small.
	var bs := 1.15 * s
	if "giant" in t:                  bs = 1.55 * s
	elif "troll" in t or "ogre" in t: bs = 1.35 * s
	elif "goblin" in t or "imp" in t: bs = 0.92 * s
	var club := ("troll" in t or "ogre" in t or "giant" in t)
	var undead := ("skeleton" in t or "draugr" in t or "spectral" in t or "death" in t)
	# Trolls/giants swing a club (not the viking axe); undead go unarmed + skeletal.
	_body(st, sk, _dk(col, 0.3), col, false, not club and not undead, bs)
	var hy := 1.7 * bs      # head CENTRE height (matches _body's head)
	if "goblin" in t or "imp" in t:
		for e: float in [-1.0, 1.0]:   # big sideways pointed ears
			_ball(st, Vector3(e * 0.26 * bs, hy + 0.02 * bs, 0.0), Vector3(0.14, 0.07, 0.05) * s, 3, 5, col)
	elif "troll" in t or "ogre" in t:
		for e: float in [-0.08, 0.08]:   # upward tusks + heavy brow
			_ball(st, Vector3(e * bs, hy - 0.16 * bs, 0.16 * bs), Vector3(0.03, 0.11, 0.03) * s, 3, 5, _BONE)
		_ball(st, Vector3(0, hy + 0.1 * bs, 0.14 * bs), Vector3(0.2, 0.06, 0.08) * s, 3, 6, _dk(col, 0.2))
	elif "bandit" in t:            # dark hood over the head
		_ball(st, Vector3(0, hy + 0.06 * bs, -0.02 * bs), Vector3(0.2, 0.17, 0.22) * s, 4, 7, Color(0.18, 0.16, 0.14))
	elif undead:
		_ball(st, Vector3(0, hy, 0.03 * bs), Vector3(0.24, 0.24, 0.23) * s, 4, 7, _BONE)  # bare skull over face
		_ball(st, Vector3(-0.08 * bs, hy, 0.2 * bs), Vector3(0.045, 0.055, 0.03) * s, 2, 5, Color(0.9, 0.25, 0.12))  # eye sockets
		_ball(st, Vector3(0.08 * bs, hy, 0.2 * bs), Vector3(0.045, 0.055, 0.03) * s, 2, 5, Color(0.9, 0.25, 0.12))
		if "death" in t or "spectral" in t:   # dark warhelm + horns over the skull
			_ball(st, Vector3(0, hy + 0.1 * bs, -0.03 * bs), Vector3(0.26, 0.18, 0.26) * s, 4, 7, _dk(col, 0.4))
			for e2: float in [-0.14, 0.14]:
				_cone(st, e2 * bs, hy + 0.24 * bs, -0.02 * bs, 0.05 * s, 0.22 * s, 4, _dk(col, 0.45))
	else:                          # demonic horns (giants/default)
		for e: float in [-0.12, 0.12]:
			_ball(st, Vector3(e * bs, hy + 0.14 * bs, 0.02 * bs), Vector3(0.05, 0.16, 0.05) * s, 3, 5, _BONE)
	if club:   # a heavy knotted club in the right hand
		_cyl(st, 0.52 * bs, 0.5 * s, 0.1 * s, 0.05 * s, 1.15 * s, 6, Color(0.34, 0.24, 0.13))
		_ball(st, Vector3(0.52 * bs, 1.62 * s, 0.1 * s), Vector3(0.16, 0.18, 0.16) * s, 4, 6, Color(0.30, 0.21, 0.11))
	if "imp" in t:   # little bat wings + a pair of horns
		for e3: float in [-1.0, 1.0]:
			_tri(st, Vector3(e3 * 0.22 * bs, 1.35 * s, -0.08 * s), Vector3(e3 * 0.72 * bs, 1.75 * s, -0.06 * s), Vector3(e3 * 0.6 * bs, 1.0 * s, 0.02 * s), _dk(col, 0.28))
			_cone(st, e3 * 0.1 * bs, hy + 0.1 * bs, 0.02 * bs, 0.03 * s, 0.14 * s, 4, _dk(col, 0.3))

func _mon_quad(st: SurfaceTool, col: Color, s: float, t: String) -> void:
	var belly := _lt(col, 0.12)
	var rat := "rat" in t
	var bear := "bear" in t
	var blen: float = 0.72 if rat else (0.95 if bear else 0.85)
	_ball(st, Vector3(0, 0.62, 0) * s, Vector3(0.42 if not bear else 0.5, 0.34 if not bear else 0.42, blen) * s, 5, 8, col)
	_ball(st, Vector3(0, 0.72, -0.9) * s, Vector3(0.3, 0.3, 0.32) * s, 4, 7, col)     # head
	_ball(st, Vector3(0, 0.62, -1.15) * s, Vector3(0.18, 0.16, 0.22) * s, 3, 6, belly)  # snout
	for lp: Vector3 in [Vector3(-0.28, 0, -0.6), Vector3(0.28, 0, -0.6), Vector3(-0.28, 0, 0.6), Vector3(0.28, 0, 0.6)]:
		_ball(st, (lp + Vector3(0, 0.28, 0)) * s, Vector3(0.11, 0.3, 0.12) * s, 3, 6, _dk(col, 0.12))
	if rat:
		for e: float in [-0.16, 0.16]:   # big round ears + pink nose + long thin tail
			_ball(st, Vector3(e, 1.0, -0.86) * s, Vector3(0.11, 0.12, 0.05) * s, 3, 6, _lt(col, 0.2))
		_ball(st, Vector3(0, 0.6, -1.32) * s, Vector3(0.06, 0.05, 0.05) * s, 2, 5, Color(0.9, 0.55, 0.6))
		_ball(st, Vector3(0, 0.5, 1.35) * s, Vector3(0.045, 0.05, 0.55) * s, 3, 5, belly)
	elif bear:
		for e: float in [-0.17, 0.17]:   # small round ears + shoulder hump + stub tail
			_ball(st, Vector3(e, 1.02, -0.86) * s, Vector3(0.1, 0.09, 0.08) * s, 3, 6, col)
		_ball(st, Vector3(0, 0.9, -0.25) * s, Vector3(0.36, 0.28, 0.35) * s, 4, 7, col)
		_ball(st, Vector3(0, 0.62, 1.0) * s, Vector3(0.09, 0.09, 0.1) * s, 3, 5, col)
	else:                                # wolf: pointed ears + bushy tail
		for e: float in [-0.16, 0.16]:
			_ball(st, Vector3(e, 1.02, -0.88) * s, Vector3(0.08, 0.17, 0.05) * s, 3, 5, col)
		_ball(st, Vector3(0, 0.72, 1.08) * s, Vector3(0.15, 0.17, 0.36) * s, 3, 6, _lt(col, 0.06))

func _mon_crawler(st: SurfaceTool, col: Color, s: float, t := "") -> void:
	var lava := "lava" in t
	var body_c := col if not lava else Color(0.22, 0.10, 0.07)   # cooled-rock carapace
	var leg_c := _dk(body_c, 0.15)
	var eye_c := Color(0.9, 0.1, 0.1) if not lava else Color(1.0, 0.75, 0.15)
	_ball(st, Vector3(0, 0.4, 0.25) * s, Vector3(0.45, 0.3, 0.5) * s, 6, 10, body_c)     # abdomen
	_ball(st, Vector3(0, 0.36, -0.35) * s, Vector3(0.3, 0.26, 0.32) * s, 5, 8, _dk(body_c, 0.1))  # head
	for e: float in [-0.12, 0.12]:
		_ball(st, Vector3(e, 0.44, -0.6) * s, Vector3(0.06, 0.06, 0.06) * s, 3, 6, eye_c)
	if lava:   # molten cracks + glowing core on the back
		_ball(st, Vector3(0, 0.58, 0.2) * s, Vector3(0.22, 0.12, 0.26) * s, 4, 7, Color(1.0, 0.5, 0.08))
		_ball(st, Vector3(0, 0.66, 0.2) * s, Vector3(0.1, 0.08, 0.12) * s, 3, 6, Color(1.0, 0.9, 0.4))
		for cz: float in [-0.1, 0.35]:
			_ball(st, Vector3(0.18, 0.5, cz) * s, Vector3(0.05, 0.02, 0.12) * s, 2, 5, Color(1.0, 0.45, 0.05))
			_ball(st, Vector3(-0.18, 0.5, cz) * s, Vector3(0.05, 0.02, 0.12) * s, 2, 5, Color(1.0, 0.45, 0.05))
	var side := [-1.0, 1.0]
	for sd: float in side:
		for k: int in range(4):
			var zz := -0.25 + float(k) * 0.28
			var mid := Vector3(sd * 0.5, 0.5, zz) * s
			var foot := Vector3(sd * 0.85, 0.0, zz + 0.1) * s
			_obox(st, (Vector3(sd * 0.36, 0.42, zz) * s + mid) * 0.5,
				Basis(Vector3.FORWARD, sd * 0.6), Vector3(0.04, 0.04, 0.28) * s, leg_c)
			_obox(st, (mid + foot) * 0.5, Basis(Vector3.FORWARD, -sd * 0.8),
				Vector3(0.04, 0.04, 0.3) * s, leg_c)
			if lava:   # glowing knee joints
				_ball(st, mid, Vector3(0.05, 0.05, 0.05) * s, 2, 5, Color(1.0, 0.55, 0.1))

## FULL-DETAIL dragon — captures the 2D Níðhöggr art in 3D: scaled body + belly,
## dorsal spine spikes, back-swept horns (2 large + 2 small), cheek frills, a
## glowing fiery maw with teeth, slit eyes, membrane finger-wings, clawed legs, and
## a tapering spiked tail with a bladed tip. Faces -Z. (Fidelity test per the plan.)
func _mon_dragon(st: SurfaceTool, _col: Color, s: float, t: String) -> void:
	# ── palette by type ──
	var sd := Color(0.08, 0.32, 0.19); var sm := Color(0.14, 0.50, 0.29); var sl := Color(0.26, 0.68, 0.42)
	var belly := Color(0.52, 0.60, 0.30); var horn := Color(0.86, 0.82, 0.58); var spike := Color(0.92, 0.80, 0.24)
	var mem := Color(0.16, 0.34, 0.22); var ember := Color(1.0, 0.55, 0.08); var eye := Color(1.0, 0.85, 0.15)
	if "drake" in t:
		sd = Color(0.30, 0.20, 0.10); sm = Color(0.55, 0.40, 0.18); sl = Color(0.70, 0.52, 0.24)
		belly = Color(0.60, 0.50, 0.30); mem = Color(0.40, 0.28, 0.14)
	elif "wyvern" in t:
		sd = Color(0.20, 0.34, 0.24); sm = Color(0.42, 0.64, 0.46); sl = Color(0.56, 0.78, 0.58)
		belly = Color(0.60, 0.68, 0.42); mem = Color(0.30, 0.46, 0.32)
	elif "frost" in t or "wyrm" in t:
		sd = Color(0.40, 0.55, 0.68); sm = Color(0.62, 0.80, 0.92); sl = Color(0.80, 0.92, 0.98)
		belly = Color(0.82, 0.90, 0.95); mem = Color(0.52, 0.70, 0.84); ember = Color(0.55, 0.85, 1.0)
	# ── body + belly (elongated along z) ──
	_ball(st, Vector3(0, 1.0, 0.25) * s, Vector3(0.55, 0.5, 1.05) * s, 6, 9, sm)
	_ball(st, Vector3(0, 0.72, 0.25) * s, Vector3(0.46, 0.3, 0.92) * s, 4, 8, belly)   # underbelly
	# dorsal spine spikes (gold, along the back)
	for i in range(6):
		var z := (-0.35 + float(i) * 0.28) * s
		var h := (0.24 - absf(float(i) - 2.5) * 0.03) * s
		_cone(st, 0, (1.45 - float(i) * 0.02) * s, z, 0.08 * s, h + 0.14 * s, 5, spike)
	# ── 4 clawed legs ──
	for lp: Vector3 in [Vector3(-0.34, 0, -0.2), Vector3(0.34, 0, -0.2), Vector3(-0.34, 0, 0.6), Vector3(0.34, 0, 0.6)]:
		_ball(st, (lp + Vector3(0, 0.3, 0)) * s, Vector3(0.13, 0.32, 0.15) * s, 3, 6, sd)
		for cx: float in [-0.07, 0.0, 0.07]:   # toe claws
			_cone(st, (lp.x + cx) * s, 0.0, (lp.z - 0.12) * s, 0.03 * s, 0.12 * s, 4, horn)
	# ── neck → head (front, -z) ──
	_ball(st, Vector3(0, 1.32, -0.62) * s, Vector3(0.26, 0.28, 0.42) * s, 4, 7, sm)     # neck
	_ball(st, Vector3(0, 1.52, -1.08) * s, Vector3(0.27, 0.25, 0.34) * s, 4, 7, sm)     # skull
	_ball(st, Vector3(0, 1.46, -1.42) * s, Vector3(0.17, 0.15, 0.22) * s, 3, 6, sm)     # snout
	_ball(st, Vector3(0, 1.34, -1.42) * s, Vector3(0.14, 0.08, 0.17) * s, 3, 6, sd)     # lower jaw
	_ball(st, Vector3(0, 1.40, -1.5) * s, Vector3(0.08, 0.06, 0.09) * s, 3, 5, ember)   # fiery maw glow
	for tx: float in [-0.07, 0.0, 0.07]:   # upper teeth
		_cone(st, tx * s, 1.44 * s, -1.55 * s, 0.02 * s, 0.08 * s, 4, Color(0.95, 0.93, 0.82))
	# horns — 2 large back-swept + 2 small
	for e: float in [-1.0, 1.0]:
		_obox(st, Vector3(e * 0.18, 1.78, -0.9) * s, Basis(Vector3.RIGHT, 0.7), Vector3(0.05, 0.28, 0.05) * s, horn)
		_obox(st, Vector3(e * 0.1, 1.72, -1.02) * s, Basis(Vector3.RIGHT, 0.5), Vector3(0.035, 0.16, 0.035) * s, _dk(horn, 0.1))
		_ball(st, Vector3(e * 0.28, 1.5, -1.05) * s, Vector3(0.14, 0.05, 0.06) * s, 3, 5, spike)  # cheek frill
		# EYE — heavy brow + glowing eyeball + vertical slit pupil + a bright glint.
		_obox(st, Vector3(e * 0.14, 1.635, -1.31) * s, Basis(Vector3.FORWARD, e * 0.35), Vector3(0.09, 0.022, 0.05) * s, _dk(sm, 0.25))
		_ball(st, Vector3(e * 0.13, 1.575, -1.33) * s, Vector3(0.058, 0.062, 0.045) * s, 3, 6, eye)
		_obox(st, Vector3(e * 0.13, 1.575, -1.375) * s, Basis(), Vector3(0.008, 0.05, 0.012) * s, Color(0.12, 0.03, 0.0))  # slit pupil
		_ball(st, Vector3(e * 0.1, 1.6, -1.37) * s, Vector3(0.015, 0.015, 0.01) * s, 2, 4, Color(1, 1, 0.9))  # glint
		_ball(st, Vector3(e * 0.06, 1.46, -1.55) * s, Vector3(0.02, 0.02, 0.02) * s, 2, 4, ember) # nostril ember
	# ── membrane finger-wings (spread up + out) ──
	_dragon_wing3d(st, -1.0, s, mem, sl, horn)
	_dragon_wing3d(st, 1.0, s, mem, sl, horn)
	# ── tapering spiked tail (behind, +z) with a finned, two-bladed spade tip ──
	var prev_top := Vector3(0, 1.05 * s, 0.75 * s)
	for i in range(7):
		var z2 := (0.9 + float(i) * 0.32) * s
		var ty := (0.85 - float(i) * 0.055) * s
		var w := (0.25 - float(i) * 0.028) * s
		_ball(st, Vector3(0, ty, z2), Vector3(w, w, 0.2 * s), 3, 6, sm if i % 2 == 0 else sd)
		var spk := Vector3(0, ty + w + 0.14 * s, z2)
		_cone(st, 0, ty + w * 0.6, z2, 0.045 * s, 0.16 * s, 4, spike)                  # tail spike
		_tri(st, prev_top, spk, Vector3(0, ty + w * 0.5, z2 - 0.16 * s), _dk(mem, 0.05))  # fin webbing between spikes
		prev_top = spk
	var tip := Vector3(0, 0.5 * s, 3.05 * s)                                            # two-bladed spade
	_tri(st, prev_top, tip, Vector3(-0.28 * s, 0.5 * s, 2.75 * s), spike)
	_tri(st, prev_top, tip, Vector3(0.28 * s, 0.5 * s, 2.75 * s), spike)
	_obox(st, Vector3(0, 0.5 * s, 2.85 * s), Basis(), Vector3(0.03, 0.14, 0.24) * s, _dk(spike, 0.1))

## One membrane wing (side = ±1): a fan of triangles from the shoulder to 4 finger
## tips + a couple of darker veins + a bone leading edge.
func _dragon_wing3d(st: SurfaceTool, xd: float, s: float, mem: Color, vein: Color, bone: Color) -> void:
	var root := Vector3(0.42 * xd, 1.4, 0.15) * s
	var wrist := Vector3(1.25 * xd, 2.05, -0.05) * s
	var f1 := Vector3(1.75 * xd, 2.35, -0.4) * s
	var f2 := Vector3(1.75 * xd, 1.75, 0.05) * s
	var f3 := Vector3(1.45 * xd, 1.25, 0.5) * s
	var f4 := Vector3(1.0 * xd, 1.05, 0.75) * s
	var red := Color(0.30, 0.15, 0.14)               # reddish membrane, like the 2D webs
	_tri(st, root, wrist, f1, red.lerp(mem, 0.5))
	_tri(st, root, f1, f2, red.lerp(mem, 0.55))
	_tri(st, root, f2, f3, _dk(mem, 0.06))
	_tri(st, root, f3, f4, _dk(mem, 0.12))
	_tri(st, wrist, f1, f2, vein)                     # lit membrane panel near the wrist
	# arm bone + a strut out to EVERY finger tip + a claw at each fingertip
	_strut(st, root, wrist, 0.055 * s, bone)
	for tip: Vector3 in [f1, f2, f3, f4]:
		_strut(st, wrist, tip, 0.035 * s, bone)
	_cone(st, wrist.x, wrist.y, wrist.z, 0.045 * s, 0.18 * s, 4, bone)   # wrist claw
	# membrane veins radiating from the root
	_strut(st, root, f3, 0.015 * s, _lt(mem, 0.12))
	_strut(st, root, f4, 0.015 * s, _lt(mem, 0.1))

func _mon_bird(st: SurfaceTool, col: Color, s: float) -> void:
	_ball(st, Vector3(0, 0.35, 0) * s, Vector3(0.26, 0.28, 0.3) * s, 4, 7, col)
	_ball(st, Vector3(0, 0.68, -0.12) * s, Vector3(0.16, 0.17, 0.16) * s, 3, 6, col)
	_cone(st, 0, 0.66, -0.28 * s, 0.06 * s, 0.16 * s, 5, Color(0.95, 0.7, 0.15))     # beak
	_box(st, 0, 0.62, 0.02, 0.16 * s, 0.1 * s, 0.02, Color(0.85, 0.15, 0.12))        # comb
	for e: float in [-0.09, 0.09]:
		_cyl(st, e * s, 0, 0.02, 0.03 * s, 0.16 * s, 4, Color(0.9, 0.7, 0.15))

## Shark — sleek finned fish matching the 2D silhouette: tapered grey body with a
## dark dorsal back + pale belly, a triangular dorsal fin, swept pectoral fins, and
## a forked tail fluke. Swims a little above the seabed. Head faces -Z.
func _mon_fish(st: SurfaceTool, _col: Color, s: float) -> void:
	var back := Color(0.24, 0.30, 0.40)     # dark grey-blue back
	var side := Color(0.44, 0.52, 0.62)     # mid-grey flank
	var belly := Color(0.78, 0.83, 0.88)    # pale underbelly
	var yb := 0.7                            # float above the seabed
	# Tapered body — overlapping ellipsoids growing toward the head (-Z).
	_ball(st, Vector3(0, yb, 0.55) * s, Vector3(0.16, 0.16, 0.4) * s, 5, 8, side)   # tail stock
	_ball(st, Vector3(0, yb, 0.05) * s, Vector3(0.30, 0.28, 0.6) * s, 6, 10, side)  # trunk
	_ball(st, Vector3(0, yb, -0.62) * s, Vector3(0.24, 0.24, 0.4) * s, 5, 8, side)  # head
	_ball(st, Vector3(0, yb + 0.14, 0.0) * s, Vector3(0.24, 0.14, 0.55) * s, 5, 9, back)   # dark topline
	_ball(st, Vector3(0, yb - 0.15, 0.0) * s, Vector3(0.22, 0.12, 0.5) * s, 5, 9, belly)   # pale belly
	_ball(st, Vector3(0, yb - 0.03, -0.95) * s, Vector3(0.14, 0.12, 0.16) * s, 4, 7, side) # snout
	# Dorsal fin — triangle peak on the back.
	_tri(st, Vector3(0, yb + 0.2, 0.05) * s, Vector3(0, yb + 0.62, -0.05) * s, Vector3(0, yb + 0.2, -0.35) * s, back)
	# Pectoral fins — swept down/back on each side.
	for e: float in [-1.0, 1.0]:
		_tri(st, Vector3(e * 0.2, yb - 0.06, -0.2) * s, Vector3(e * 0.62, yb - 0.34, 0.1) * s, Vector3(e * 0.24, yb - 0.06, 0.15) * s, _dk(side, 0.08))
	# Forked tail fluke at +Z.
	_tri(st, Vector3(0, yb, 0.9) * s, Vector3(0, yb + 0.42, 1.35) * s, Vector3(0, yb + 0.05, 1.15) * s, back)
	_tri(st, Vector3(0, yb, 0.9) * s, Vector3(0, yb - 0.42, 1.35) * s, Vector3(0, yb - 0.05, 1.15) * s, back)
	# Eyes + gill slits.
	for e2: float in [-1.0, 1.0]:
		_ball(st, Vector3(e2 * 0.16, yb + 0.04, -0.82) * s, Vector3(0.03, 0.04, 0.03) * s, 2, 5, Color(0.05, 0.05, 0.06))
		for g: float in [-0.5, -0.65, -0.8]:
			_obox(st, Vector3(e2 * 0.2, yb, g) * s, Basis(), Vector3(0.012, 0.1, 0.012) * s, _dk(side, 0.18))

## Elemental (magma) — a molten body of clustered orbs with a blazing core, matching
## the 2D overlapping-circles read. `col` tints non-magma variants; magma is fixed
## to the fiery palette. Small blob feet, no limbs.
func _mon_elemental(st: SurfaceTool, col: Color, s: float, t: String) -> void:
	var cd := Color(0.50, 0.08, 0.02); var cm := Color(0.90, 0.30, 0.05)
	var cl := Color(1.00, 0.62, 0.10); var core := Color(1.0, 0.95, 0.5)
	if "magma" not in t:   # generic elemental — recolour from the type tint
		cd = _dk(col, 0.35); cm = col; cl = _lt(col, 0.25); core = _lt(col, 0.5)
	_ball(st, Vector3(0, 0.7, 0.05) * s, Vector3(0.5, 0.55, 0.48) * s, 6, 10, cd)     # base mass
	_ball(st, Vector3(-0.06, 0.92, 0.0) * s, Vector3(0.42, 0.44, 0.4) * s, 6, 9, cm)  # mid
	_ball(st, Vector3(0.1, 1.14, 0.02) * s, Vector3(0.3, 0.3, 0.28) * s, 5, 8, cl)    # upper
	_ball(st, Vector3(0, 0.98, 0.12) * s, Vector3(0.16, 0.2, 0.14) * s, 4, 7, core)   # blazing core
	# Molten drips / lumps around the mass.
	for lp: Vector3 in [Vector3(-0.42, 0.5, 0.0), Vector3(0.44, 0.42, 0.05), Vector3(-0.22, 1.24, 0.0), Vector3(0.26, 1.3, 0.0)]:
		_ball(st, lp * s, Vector3(0.13, 0.13, 0.12) * s, 3, 6, cm)
	# Stub feet.
	for e: float in [-0.24, 0.24]:
		_ball(st, Vector3(e, 0.14, 0.0) * s, Vector3(0.16, 0.13, 0.18) * s, 3, 6, cd)
	# A couple of bright eye embers.
	for e2: float in [-0.12, 0.12]:
		_ball(st, Vector3(e2, 1.0, 0.24) * s, Vector3(0.05, 0.06, 0.04) * s, 2, 5, core)

## Forest spirit — an ethereal wisp: a tapered smoky tail rising into a glowing body
## and head with bright eyes. No legs; floats. Greenish unless `col` says otherwise.
func _mon_spirit(st: SurfaceTool, col: Color, s: float) -> void:
	var glow := _lt(col, 0.35); var mist := _dk(col, 0.05); var eye := Color(0.85, 1.0, 0.6)
	# Wispy tail — stacked shrinking orbs tapering from the body down to a point.
	for i in range(5):
		var f := float(i) / 4.0                      # 0 at body, 1 at ground
		var wy := (1.15 - f * 1.0) * s
		var wr := (0.3 - f * 0.26) * s
		_ball(st, Vector3(sin(f * 3.0) * 0.06 * s, wy, 0.0), Vector3(wr, wr * 1.1, wr), 4, 7, mist.lerp(col, 1.0 - f))
	_ball(st, Vector3(0, 1.35, 0) * s, Vector3(0.34, 0.42, 0.3) * s, 6, 10, col)   # body
	_ball(st, Vector3(0, 1.82, 0) * s, Vector3(0.26, 0.28, 0.24) * s, 5, 8, glow)  # head
	# Trailing wisp curls at the sides.
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.34, 1.2, 0.0) * s, Vector3(0.1, 0.22, 0.1) * s, 4, 6, mist)
	# Glowing eyes.
	for e2: float in [-0.1, 0.1]:
		_ball(st, Vector3(e2, 1.85, 0.2) * s, Vector3(0.05, 0.07, 0.04) * s, 3, 5, eye)

# ── Dropped-item pickups (v1.6.1) ────────────────────────────────────────────
## Small floating 3D mesh for a ground drop, keyed by item CATEGORY so it reads
## like its 2D ItemArt icon (ore lump, ingot, log, gem, coin, fish, weapon…).
## One cached mesh per (category, colour). Centred at origin (~0.3 units); World3D
## floats + spins it. `col` is the item's tint (tier / species).
func item_mesh(item_id: String, col: Color) -> Mesh:
	var up := item_id.find("~u")           # strip token-upgrade suffix (e.g. "~u3")
	if up >= 0:
		item_id = item_id.substr(0, up)
	var cat := _item_cat(item_id)
	var key := "item:%s:%s" % [cat, col.to_html(false)]
	if _cache.has(key):
		return _cache[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match cat:
		"ore":    _it_ore(st, col)
		"bar":    _it_bar(st, col)
		"log":    _it_log(st, col)
		"plank":  _it_plank(st, col)
		"hide":   _it_hide(st, col)
		"bone":   _it_bone(st)
		"fish":   _it_fish(st, col)
		"gem":    _it_gem(st, col)
		"jewelry": _it_jewelry(st, col)
		"food":   _it_food(st, col)
		"coin":   _it_coin(st, col)
		"tooth":  _it_tooth(st)
		"crop":   _it_crop(st, item_id)
		"scroll": _it_scroll(st, col)
		"weapon": _it_weapon(st, col)
		"armor":  _it_armor(st, col)
		"potion": _it_potion(st, col)
		"rune":   _it_rune(st, col)
		_:        _it_pouch(st, col)
	var m: Mesh = st.commit()
	_cache[key] = m
	return m

func _item_cat(id: String) -> String:
	if id == "gold_coins" or id.ends_with("_token"):   return "coin"
	if id.ends_with("_ore"):                            return "ore"
	if id.ends_with("_bar"):                            return "bar"
	if id.ends_with("_log"):                            return "log"
	if id.ends_with("_plank"):                          return "plank"
	if id.ends_with("_pelt") or id.ends_with("_hide"): return "hide"
	if id == "bone" or id.ends_with("_bone"):           return "bone"
	if id in ["opal", "amethyst", "diamond", "abyssal_pearl", "leviathan_eye"]: return "gem"
	if id.ends_with("_ring") or id.ends_with("_amulet"): return "jewelry"
	if id.ends_with("_tooth"):                          return "tooth"
	if id in ["carrot", "potato", "moonwheat"]:         return "crop"
	if id.ends_with("_bread") or id.ends_with("_loaf") or id.ends_with("_stew") or id in ["ale_keg", "salt_sack", "fur_bundle", "wool_cloth", "troll_heart", "carrot_stew"]: return "food"
	for f: String in ["fish", "salmon", "shark", "trout", "lobster", "cod", "eel", "squid", "runefish"]:
		if f in id: return "fish"
	if id.begins_with("pledge") or id == "high_seat_warrant": return "scroll"
	for w: String in ["sword", "axe", "dagger", "mace", "spear", "bow", "staff", "scimitar", "blade", "hammer", "hatchet", "pick"]:
		if w in id: return "weapon"
	for a: String in ["body", "legs", "helm", "shield", "platebody", "chainbody", "boots", "gloves", "plate", "mail", "kite"]:
		if a in id: return "armor"
	if "potion" in id or "brew" in id or "elixir" in id: return "potion"
	if "rune" in id or id.ends_with("_essence"):         return "rune"
	return "pouch"

func _it_ore(st: SurfaceTool, col: Color) -> void:
	_ball(st, Vector3(0, 0, 0), Vector3(0.18, 0.15, 0.16), 4, 7, Color(0.40, 0.38, 0.37))
	_ball(st, Vector3(0.1, 0.05, 0.05), Vector3(0.1, 0.09, 0.1), 3, 6, Color(0.36, 0.34, 0.33))
	_ball(st, Vector3(-0.03, 0.02, 0.12), Vector3(0.05, 0.05, 0.03), 3, 6, col)          # vein
	_ball(st, Vector3(0.08, 0.06, 0.1), Vector3(0.035, 0.035, 0.02), 3, 5, _lt(col, 0.3))  # glint

func _it_bar(st: SurfaceTool, col: Color) -> void:
	_box(st, 0, 0, 0, 0.34, 0.14, 0.18, col)
	_box(st, 0, 0.075, 0, 0.3, 0.03, 0.15, _lt(col, 0.28))   # lit top face

func _it_log(st: SurfaceTool, col: Color) -> void:
	_ball(st, Vector3(0, 0, 0), Vector3(0.24, 0.085, 0.085), 5, 8, _dk(col, 0.22))   # bark
	_ball(st, Vector3(0.21, 0, 0), Vector3(0.04, 0.08, 0.08), 3, 6, _lt(col, 0.1))   # cut ends
	_ball(st, Vector3(-0.21, 0, 0), Vector3(0.04, 0.08, 0.08), 3, 6, _lt(col, 0.1))

func _it_plank(st: SurfaceTool, col: Color) -> void:
	_box(st, 0, 0, 0, 0.42, 0.05, 0.14, _dk(col, 0.1))
	_box(st, 0, 0.028, 0, 0.4, 0.012, 0.12, _lt(col, 0.12))

func _it_hide(st: SurfaceTool, col: Color) -> void:
	_box(st, 0, 0, 0, 0.3, 0.05, 0.24, col)
	_ball(st, Vector3(-0.04, 0.04, -0.02), Vector3(0.1, 0.03, 0.08), 3, 6, _lt(col, 0.15))

func _it_bone(st: SurfaceTool) -> void:
	var bone := Color(0.9, 0.88, 0.78)
	_obox(st, Vector3(0, 0, 0), Basis(Vector3.FORWARD, PI * 0.25), Vector3(0.03, 0.2, 0.03), bone)
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.12, e * 0.12, 0), Vector3(0.055, 0.055, 0.055), 3, 6, bone)
		_ball(st, Vector3(e * 0.16, e * 0.1, 0), Vector3(0.04, 0.04, 0.04), 3, 5, bone)

func _it_fish(st: SurfaceTool, col: Color) -> void:
	_ball(st, Vector3(0, 0, 0), Vector3(0.09, 0.08, 0.2), 5, 8, col)                       # spindle body
	_ball(st, Vector3(0, 0.03, 0), Vector3(0.08, 0.03, 0.16), 4, 8, _dk(col, 0.18))        # dorsal band
	_tri(st, Vector3(0, 0, 0.18), Vector3(0, 0.13, 0.34), Vector3(0, -0.13, 0.34), _dk(col, 0.15))  # tail
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.06, 0.03, -0.12), Vector3(0.02, 0.02, 0.02), 2, 5, Color(0.05, 0.05, 0.05))

func _it_gem(st: SurfaceTool, col: Color) -> void:
	_ball(st, Vector3(0, 0, 0), Vector3(0.11, 0.15, 0.11), 3, 4, col)                      # faceted (low seg)
	_ball(st, Vector3(-0.03, 0.05, 0.06), Vector3(0.03, 0.03, 0.02), 2, 4, _lt(col, 0.45))  # glint

func _it_jewelry(st: SurfaceTool, col: Color) -> void:
	var gold := Color(0.9, 0.75, 0.25)
	# Gold band — a ring of small spheres (a cheap torus) + a set gemstone.
	for i in range(10):
		var a := TAU * float(i) / 10.0
		_ball(st, Vector3(cos(a) * 0.11, sin(a) * 0.11, 0), Vector3(0.028, 0.028, 0.028), 2, 5, gold)
	_ball(st, Vector3(0, 0.12, 0.02), Vector3(0.055, 0.06, 0.05), 3, 5, col)   # gemstone
	_ball(st, Vector3(-0.02, 0.14, 0.05), Vector3(0.015, 0.015, 0.01), 2, 4, _lt(col, 0.5))  # glint

func _it_food(st: SurfaceTool, col: Color) -> void:
	# A rounded loaf/chunk — warm crust with a lit top. `col` tints exotic foods.
	var crust := col if col.v < 0.85 else Color(0.72, 0.5, 0.24)
	_ball(st, Vector3(0, 0, 0), Vector3(0.16, 0.11, 0.12), 5, 8, crust)
	_ball(st, Vector3(0, 0.05, 0), Vector3(0.13, 0.05, 0.09), 4, 7, _lt(crust, 0.18))   # lit top
	for sx: float in [-0.06, 0.0, 0.06]:
		_obox(st, Vector3(sx, 0.09, 0), Basis(), Vector3(0.008, 0.02, 0.05), _dk(crust, 0.25))   # score marks

func _it_coin(st: SurfaceTool, col: Color) -> void:
	_cyl(st, 0, -0.03, 0, 0.14, 0.05, 12, col)                # bottom coin
	_cyl(st, 0.05, 0.02, 0.03, 0.13, 0.05, 12, _lt(col, 0.08))  # stacked coin
	_cyl(st, -0.04, 0.06, -0.02, 0.12, 0.05, 12, _dk(col, 0.06))

func _it_tooth(st: SurfaceTool) -> void:
	_cone(st, 0, -0.1, 0, 0.06, 0.24, 5, Color(0.92, 0.9, 0.82))
	_cone(st, 0, -0.14, 0, 0.05, 0.06, 5, Color(0.7, 0.66, 0.55))   # darker root

func _it_crop(st: SurfaceTool, id: String) -> void:
	if id == "carrot":
		_ball(st, Vector3(0, -0.02, 0), Vector3(0.06, 0.14, 0.06), 4, 7, Color(0.95, 0.55, 0.2))
		for lx: float in [-0.04, 0.0, 0.04]:
			_obox(st, Vector3(lx, 0.14, 0), Basis(Vector3.FORWARD, lx * 4.0), Vector3(0.012, 0.08, 0.012), Color(0.3, 0.62, 0.28))
	elif id == "potato":
		_ball(st, Vector3(0, 0, 0), Vector3(0.13, 0.1, 0.11), 4, 7, Color(0.62, 0.45, 0.28))
		_ball(st, Vector3(0.06, 0.02, 0.05), Vector3(0.05, 0.05, 0.05), 3, 5, Color(0.55, 0.4, 0.25))
	else:   # moonwheat sheaf
		for i in range(3):
			var a := (float(i) - 1.0) * 0.28
			_obox(st, Vector3(a * 0.4, 0.02, 0), Basis(Vector3.FORWARD, -a), Vector3(0.014, 0.16, 0.014), Color(0.65, 0.75, 0.95))

func _it_scroll(st: SurfaceTool, col: Color) -> void:
	_ball(st, Vector3(0, 0, 0), Vector3(0.2, 0.07, 0.07), 5, 8, Color(0.92, 0.86, 0.68))   # rolled cloth
	_box(st, 0, 0, 0, 0.07, 0.15, 0.15, col)                                               # tint stripe
	for e: float in [-1.0, 1.0]:
		_ball(st, Vector3(e * 0.19, 0, 0), Vector3(0.035, 0.075, 0.075), 3, 6, Color(0.55, 0.4, 0.18))

func _it_weapon(st: SurfaceTool, col: Color) -> void:
	_obox(st, Vector3(0, 0.06, 0), Basis(), Vector3(0.02, 0.18, 0.045), _METAL)   # blade
	_box(st, 0, -0.14, 0, 0.13, 0.03, 0.03, Color(0.3, 0.2, 0.1))                 # cross-guard
	_cyl(st, 0, -0.26, 0, 0.022, 0.11, 6, Color(0.3, 0.2, 0.1))                   # grip
	_ball(st, Vector3(0, -0.27, 0), Vector3(0.035, 0.035, 0.035), 3, 5, col)      # tier pommel

func _it_armor(st: SurfaceTool, col: Color) -> void:
	_obox(st, Vector3(0, 0, 0), Basis(), Vector3(0.14, 0.17, 0.04), col)          # plate
	_ball(st, Vector3(0, 0, 0.05), Vector3(0.05, 0.06, 0.02), 3, 6, _lt(col, 0.22))  # boss
	_box(st, 0, 0.14, 0, 0.3, 0.03, 0.06, _dk(col, 0.15))                         # rim

func _it_potion(st: SurfaceTool, col: Color) -> void:
	_ball(st, Vector3(0, -0.02, 0), Vector3(0.08, 0.09, 0.08), 4, 7, col)         # liquid body
	_cyl(st, 0, 0.06, 0, 0.03, 0.08, 6, Color(0.7, 0.8, 0.85))                    # glass neck
	_cyl(st, 0, 0.13, 0, 0.035, 0.03, 6, Color(0.4, 0.28, 0.15))                  # cork

func _it_rune(st: SurfaceTool, col: Color) -> void:
	_obox(st, Vector3(0, 0, 0), Basis(), Vector3(0.12, 0.14, 0.03), _dk(col, 0.2))   # tablet
	_ball(st, Vector3(0, 0, 0.04), Vector3(0.05, 0.06, 0.02), 3, 6, _lt(col, 0.35))  # glowing sigil

func _it_pouch(st: SurfaceTool, col: Color) -> void:
	var leather := Color(0.55, 0.36, 0.18)
	_ball(st, Vector3(0, -0.02, 0), Vector3(0.14, 0.13, 0.14), 4, 7, leather)     # sack
	_cyl(st, 0, 0.08, 0, 0.06, 0.05, 6, _dk(leather, 0.25))                       # cinched neck
	_ball(st, Vector3(0, 0.03, 0), Vector3(0.04, 0.04, 0.04), 3, 5, col)          # peeking contents
