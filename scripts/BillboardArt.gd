extends Node

## v1.6 P2 — SHARED billboard art (the perf foundation for the 3D client).
##
## The prototype rendered a live SubViewport PER ENTITY — fine for a dozen, fatal
## for a real crowd. This shares ONE SubViewport per art KEY (a monster type, a
## resource type, or a character appearance-hash); its ViewportTexture is reused
## by EVERY instance of that key. So the number of viewports scales with the
## number of art TYPES on screen, not the number of entities.
##
## Animated keys keep re-rendering (UPDATE_ALWAYS) so all same-type mobs animate
## in sync (classic-MMO look). Static keys (trees/rocks/structures) render ONCE
## then hold the frame (UPDATE_ONCE) — effectively free after the first frame.
##
## Add this as a child of the 3D world; it parents all the shared viewports.

var _tex: Dictionary = {}   # key(String) → ViewportTexture

## Shared texture for `key`. `make_drawer` is a Callable returning a fresh Node2D
## drawer (Monster / Interactable / CharPreview …) — only CALLED on a cache miss.
## `art_bottom` = px below the drawer origin where the art's feet/base sit, so the
## drawer is placed feet-near-viewport-bottom.
func texture_for(key: String, make_drawer: Callable, size: Vector2i,
		animated: bool, art_bottom := 20.0) -> Texture2D:
	if _tex.has(key):
		return _tex[key]
	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if animated else SubViewport.UPDATE_ONCE
	vp.disable_3d = true
	var drawer := make_drawer.call() as Node2D
	drawer.position = Vector2(size.x * 0.5, float(size.y) - 4.0 - art_bottom)
	vp.add_child(drawer)
	add_child(vp)
	var t: Texture2D = vp.get_texture()
	_tex[key] = t
	return t

## Build a billboard Sprite3D backed by the shared texture for `key`. The caller
## positions it (feet on the ground = center at ground + size.y*pixel*0.5).
func make_sprite(key: String, make_drawer: Callable, size: Vector2i,
		animated: bool, pixel := 0.05, art_bottom := 20.0) -> Sprite3D:
	var spr := Sprite3D.new()
	spr.texture = texture_for(key, make_drawer, size, animated, art_bottom)
	spr.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	spr.shaded = false
	spr.transparent = true
	spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	spr.pixel_size = pixel
	return spr

## Stable cache key for a character appearance (so identical looks share a viewport).
static func char_key(appr: Dictionary) -> String:
	return "char:" + str(hash(JSON.stringify(appr)))

## How many distinct viewports are live (types on screen, not entities).
func viewport_count() -> int:
	return _tex.size()
