# Custom sounds — drop your recordings here

The game synthesizes every sound in code (`SoundForge.gd`). To replace any of them
with your **own recorded sound**, just drop an audio file in this folder named after
the sound's **id** below. The game uses it automatically — no code changes.

## How to add a sound
1. Record + trim the sound in **Audacity** (free): https://www.audacityteam.org
2. **Export** it as **`<id>.ogg`** (File → Export → Export as OGG). `.wav` also works,
   but `.ogg` is much smaller.
3. Drop it in this folder: `assets/audio/<id>.ogg`
4. Open the Godot editor once (it auto-imports the file), then re-export the game.
   Done — that sound now plays instead of the synthetic one.

Tips: record mono, keep one-shots SHORT and trimmed tight (no leading silence).
You don't have to do all of them — any file you add overrides just that one sound;
anything you skip keeps its current synthetic sound.

---

## Sound ids to record

### Combat (one-shots, ~0.2–0.6s)
- `sword_swing`   — a melee weapon whoosh through the air
- `bow_release`   — bowstring twang / arrow loose
- `spell_cast`    — a magic cast (whoosh + shimmer)
- `melee_hit`     — a solid blunt impact / thud on flesh
- `magic_hit`     — a magical impact / zap
- `arrow_impact`  — an arrow striking (thwack)

### Gathering (one-shots, ~0.3–0.7s)
- `mining_hit`     — pickaxe striking rock (clink/crack)
- `wood_chop`      — axe chopping wood (thock)
- `fishing_cast`   — a fishing line cast / whoosh + light splash
- `fishing_catch`  — a fish caught (splash / reel)

### Footsteps (very short one-shots, ~0.1–0.2s — record 1 clean step each)
- `footstep_grass` — a step on grass
- `footstep_stone` — a step on stone
- `footstep_wood`  — a step on a wooden floor
- `footstep_dirt`  — a step on dirt

### UI (short one-shots, ~0.1–0.5s)
- `click`          — a menu/button click
- `tab_switch`     — switching a UI tab (softer click)
- `quest_complete` — a small success flourish
- `level_up`       — a bigger, triumphant flourish
- `item_pickup`    — a light pickup blip
- `craft_success`  — a satisfying "made it" ding

### Ambience (LOOPS — record 5–15s that can repeat seamlessly)
- `ocean`  — waves / coastal ambience
- `wind`   — open wind (plains / snow)
- `forest` — forest ambience (birds / rustle)
- `cave`   — cave / mountain ambience (drips / low rumble)

### Music (LOOPS — longer, 30s–2min musical beds)
- `town`       — calm town/settlement music
- `wilderness` — exploring the wilds
- `combat`     — tense battle music

> Ambience + music are set to loop automatically when you drop them in.
> These are the perfect place to use your own voice/instruments/noises.
