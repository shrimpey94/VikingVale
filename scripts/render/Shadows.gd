extends RefCounted
## One switch for every shadow in the game (owner call 2026-11-22): NO shadows,
## real or fake, in 2D or 3D, until the day/night cycle exists. Then one
## simulated sun drives all of them (one direction, one length, one softness),
## so 2D ground shadows and 3D sun shadows always agree.
##
## Every shadow draw site asks `Shadows.ground_enabled()` first; the 3D sun
## takes `Shadows.sun_enabled()`. Not built yet: `sun_offset()` is where the
## day/night cycle will feed the shared direction.

## Covers every 2D fake shadow: the blobs under players, NPCs, monsters/animals
## and resource nodes, the building/wall/tower drop shadows and the boat's water
## shadow.
const GROUND_SHADOWS := false   # all 2D ground/drop/water shadows
const SUN_SHADOWS := false      # 3D DirectionalLight3D shadows

static func ground_enabled() -> bool:
	return GROUND_SHADOWS

static func sun_enabled() -> bool:
	return SUN_SHADOWS

## Future (day/night): shadow offset per unit of object height, from the one sun.
## Placeholder: straight down (no offset) so nothing points a different way.
static func sun_offset() -> Vector2:
	return Vector2.ZERO
