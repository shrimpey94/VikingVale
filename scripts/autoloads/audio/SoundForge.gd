class_name SoundForge
extends RefCounted

## ── SoundForge ──────────────────────────────────────────────────────────────
##
## Procedural audio generation. Every sound is synthesized into an
## AudioStreamWAV (PCM16, 22050 Hz mono) at startup — no external assets.
##
## Each gen_*() function returns one finished AudioStreamWAV. Loops set
## LOOP_FORWARD so AudioStreamPlayer keeps cycling without pop.
##
## Synthesis primitives are deliberately minimal (sine, noise, exp envelope,
## first-order lowpass). The goal is *distinct character* per sound, not
## audiophile quality.

const SR := 22050  # sample rate (Hz)

# ── Core helpers ────────────────────────────────────────────────────────────
static func _buf(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	return a

static func _n(sec: float) -> int:
	return int(sec * float(SR))

static func _to_pcm16(samples: PackedFloat32Array) -> PackedByteArray:
	var n: int = samples.size()
	var data := PackedByteArray()
	data.resize(n * 2)
	for i: int in range(n):
		var v: float = clampf(samples[i], -1.0, 1.0)
		var s: int = int(v * 32767.0)
		data[i * 2]     = s & 0xFF
		data[i * 2 + 1] = (s >> 8) & 0xFF
	return data

static func _wav(samples: PackedFloat32Array, looped: bool = false) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = _to_pcm16(samples)
	if looped:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w

static func _midi_hz(midi: int) -> float:
	return 440.0 * pow(2.0, float(midi - 69) / 12.0)

# Apply a first-order lowpass in place. cutoff Hz.
static func _lowpass(buf: PackedFloat32Array, cutoff: float) -> void:
	var dt: float = 1.0 / float(SR)
	var rc: float = 1.0 / (TAU * cutoff)
	var alpha: float = dt / (rc + dt)
	var y: float = 0.0
	for i: int in range(buf.size()):
		y += alpha * (buf[i] - y)
		buf[i] = y

# Apply a first-order highpass in place.
static func _highpass(buf: PackedFloat32Array, cutoff: float) -> void:
	var dt: float = 1.0 / float(SR)
	var rc: float = 1.0 / (TAU * cutoff)
	var alpha: float = rc / (rc + dt)
	var y: float = 0.0
	var prev: float = 0.0
	for i: int in range(buf.size()):
		var x: float = buf[i]
		y = alpha * (y + x - prev)
		prev = x
		buf[i] = y

# Normalize buffer to a peak of `target`.
static func _normalize(buf: PackedFloat32Array, target: float = 0.9) -> void:
	var peak: float = 0.0
	for i: int in range(buf.size()):
		var v: float = absf(buf[i])
		if v > peak:
			peak = v
	if peak <= 0.0001:
		return
	var g: float = target / peak
	for i: int in range(buf.size()):
		buf[i] *= g

# Mix buffer `src` into `dst` at `gain`. Buffers must be same length.
static func _mix_into(dst: PackedFloat32Array, src: PackedFloat32Array,
		gain: float) -> void:
	var n: int = mini(dst.size(), src.size())
	for i: int in range(n):
		dst[i] += src[i] * gain

# Apply a small fade-in / fade-out so loop seams don't click (only for
# one-shots; looped tracks keep the full waveform).
static func _envelope_edges(buf: PackedFloat32Array, fade_samples: int) -> void:
	var n: int = buf.size()
	@warning_ignore("integer_division") var f: int = mini(fade_samples, n / 2)
	for i: int in range(f):
		var k: float = float(i) / float(f)
		buf[i] *= k
		buf[n - 1 - i] *= k

# ── Combat SFX ──────────────────────────────────────────────────────────────

## Sharp whoosh: bandpass-ish noise + sine sweep, fast attack, exp decay.
static func gen_sword_swing() -> AudioStreamWAV:
	var dur: float = 0.32
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var phase: float = 0.0
	var f_lo: float = 220.0
	var f_hi: float = 2200.0
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var freq: float = f_hi * pow(f_lo / f_hi, tn)
		phase += TAU * freq / float(SR)
		var env: float = exp(-4.0 * tn)
		var noise: float = rng.randf_range(-1.0, 1.0)
		buf[i] = (sin(phase) * 0.35 + noise * 0.65) * env
	_lowpass(buf, 3000.0)
	_normalize(buf, 0.85)
	_envelope_edges(buf, 64)
	return _wav(buf)

## Bow release: short twang. Plucked-tone (sine + decaying harmonic) with
## a tiny string-noise burst at attack.
static func gen_bow_release() -> AudioStreamWAV:
	var dur: float = 0.28
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 22
	var f: float = 320.0
	var inv_n: float = 1.0 / float(n)
	for i: int in range(n):
		var tn: float = float(i) * inv_n
		var env: float = exp(-7.0 * tn)
		var fund: float = sin(TAU * f * float(i) / float(SR))
		var h2: float   = sin(TAU * f * 2.0 * float(i) / float(SR)) * 0.4
		var twang: float = (fund + h2) * env
		var burst: float = 0.0
		if i < 200:
			burst = rng.randf_range(-1.0, 1.0) * (1.0 - float(i) / 200.0) * 0.6
		buf[i] = twang * 0.7 + burst
	_normalize(buf, 0.85)
	_envelope_edges(buf, 32)
	return _wav(buf)

## Spell cast: rising harmonic shimmer. Two sines an octave apart sweep up,
## ringing tail via long exponential decay and subtle detune.
static func gen_spell_cast() -> AudioStreamWAV:
	var dur: float = 0.85
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var f_start: float = 220.0
	var f_end: float = 880.0
	var phase1: float = 0.0
	var phase2: float = 0.0
	var phase3: float = 0.0
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var freq: float = f_start + (f_end - f_start) * tn
		phase1 += TAU * freq / float(SR)
		phase2 += TAU * freq * 2.0 / float(SR)
		phase3 += TAU * freq * 3.01 / float(SR)  # detuned harmonic for shimmer
		var env: float
		if tn < 0.6:
			env = tn / 0.6
		else:
			env = 1.0 - (tn - 0.6) / 0.4
		env = clampf(env, 0.0, 1.0)
		buf[i] = (sin(phase1) * 0.45 + sin(phase2) * 0.30 + sin(phase3) * 0.25) * env
	_normalize(buf, 0.8)
	_envelope_edges(buf, 64)
	return _wav(buf)

## Melee hit: blunt thud. Low-frequency sine kick + lowpassed noise body.
static func gen_melee_hit() -> AudioStreamWAV:
	var dur: float = 0.22
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 33
	var phase: float = 0.0
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var freq: float = 110.0 * exp(-3.0 * tn)  # drop from 110 → ~5Hz
		phase += TAU * freq / float(SR)
		var env: float = exp(-9.0 * tn)
		var body: float = sin(phase) * 0.8
		var crack: float = rng.randf_range(-1.0, 1.0) * 0.5
		buf[i] = (body + crack) * env
	_lowpass(buf, 800.0)
	_normalize(buf, 0.95)
	_envelope_edges(buf, 32)
	return _wav(buf)

## Magic hit: crystalline ping with echo tail. Bell-like harmonics, sharp
## attack, long decay.
static func gen_magic_hit() -> AudioStreamWAV:
	var dur: float = 0.6
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var f: float = 660.0
	var harmonics: Array[float] = [1.0, 2.76, 5.40, 8.93]  # inharmonic bell ratios
	var amps: Array[float]      = [0.5, 0.3, 0.18, 0.10]
	var decays: Array[float]    = [3.0, 5.0, 8.0, 12.0]
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var t: float = float(i) / float(SR)
		var s: float = 0.0
		for k: int in range(harmonics.size()):
			s += amps[k] * sin(TAU * f * harmonics[k] * t) * exp(-decays[k] * tn)
		buf[i] = s
	_normalize(buf, 0.85)
	_envelope_edges(buf, 16)
	return _wav(buf)

## Arrow impact: short sharp thud. Noise burst lowpassed with very fast decay.
static func gen_arrow_impact() -> AudioStreamWAV:
	var dur: float = 0.18
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 44
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var env: float = exp(-12.0 * tn)
		var click: float = 0.0
		if i < 60:
			click = sin(TAU * 220.0 * float(i) / float(SR)) * 0.5
		buf[i] = (rng.randf_range(-1.0, 1.0) * 0.7 + click) * env
	_lowpass(buf, 1500.0)
	_normalize(buf, 0.9)
	_envelope_edges(buf, 24)
	return _wav(buf)

# ── Gathering SFX ───────────────────────────────────────────────────────────

## Mining hit: metallic clang. Sine + dissonant harmonic with bell-ish decay,
## bright tonality (high cutoff lowpass preserves clang).
static func gen_mining_hit() -> AudioStreamWAV:
	var dur: float = 0.35
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var f: float = 880.0
	var ratios: Array[float] = [1.0, 1.41, 2.13, 3.27]
	var amps: Array[float]   = [0.4, 0.35, 0.2, 0.15]
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var t: float = float(i) / float(SR)
		var env: float = exp(-6.0 * tn)
		var s: float = 0.0
		for k: int in range(ratios.size()):
			s += amps[k] * sin(TAU * f * ratios[k] * t)
		buf[i] = s * env
	_highpass(buf, 200.0)
	_normalize(buf, 0.9)
	_envelope_edges(buf, 32)
	return _wav(buf)

## Wood chop: dull thwack with woody resonance. Lowpassed noise burst with
## a damped low-mid sine for the wood "knock".
static func gen_wood_chop() -> AudioStreamWAV:
	var dur: float = 0.28
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 55
	var f: float = 180.0
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var t: float = float(i) / float(SR)
		var env: float = exp(-10.0 * tn)
		var crack: float = rng.randf_range(-1.0, 1.0) * 0.6
		var knock: float = sin(TAU * f * t) * 0.5
		buf[i] = (crack + knock) * env
	_lowpass(buf, 1200.0)
	_normalize(buf, 0.9)
	_envelope_edges(buf, 32)
	return _wav(buf)

## Fishing cast: whoosh into plop. Two-segment: first half is a swooshing
## frequency sweep, second half is a low water-plop.
static func gen_fishing_cast() -> AudioStreamWAV:
	var dur: float = 0.55
	var n: int = _n(dur)
	var split: int = int(0.35 * float(n))
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 66
	# Segment 1: whoosh (filtered noise sweep)
	var phase: float = 0.0
	for i: int in range(split):
		var tn: float = float(i) / float(split)
		var freq: float = 800.0 * pow(0.25, tn)  # sweep down 800→200
		phase += TAU * freq / float(SR)
		var env: float = 1.0 - tn
		buf[i] = (sin(phase) * 0.3 + rng.randf_range(-1.0, 1.0) * 0.5) * env
	# Segment 2: plop (low sine with quick decay)
	var plop_phase: float = 0.0
	for i: int in range(split, n):
		var tn: float = float(i - split) / float(n - split)
		var freq: float = 80.0 * exp(-4.0 * tn) + 30.0
		plop_phase += TAU * freq / float(SR)
		var env: float = exp(-8.0 * tn)
		buf[i] = sin(plop_phase) * env * 0.9
	_normalize(buf, 0.85)
	_envelope_edges(buf, 32)
	return _wav(buf)

## Fishing catch: water splash + brief reel-click pattern at start.
static func gen_fishing_catch() -> AudioStreamWAV:
	var dur: float = 0.7
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	# Splash: lowpassed noise with bumpy envelope (water foam)
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var env: float = exp(-3.5 * tn) * (1.0 + 0.3 * sin(TAU * 12.0 * tn))
		buf[i] = rng.randf_range(-1.0, 1.0) * env * 0.7
	_lowpass(buf, 2200.0)
	# Reel clicks: 5 short bursts at the start (every ~30ms)
	for k: int in range(5):
		var pos: int = int(float(k) * 0.04 * float(SR))
		if pos >= n - 80:
			break
		for j: int in range(80):
			var fade: float = 1.0 - float(j) / 80.0
			buf[pos + j] += sin(TAU * 1800.0 * float(j) / float(SR)) * fade * 0.35
	_normalize(buf, 0.9)
	_envelope_edges(buf, 32)
	return _wav(buf)

# ── Footsteps ───────────────────────────────────────────────────────────────

## Grass: soft rustle — lowpassed noise burst, very short.
static func gen_footstep_grass() -> AudioStreamWAV:
	var dur: float = 0.12
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 81
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var env: float = exp(-15.0 * tn) * (1.0 - tn)
		buf[i] = rng.randf_range(-1.0, 1.0) * env
	_lowpass(buf, 1600.0)
	_normalize(buf, 0.7)
	_envelope_edges(buf, 16)
	return _wav(buf)

## Stone: hard tap — narrow click with mid-range body.
static func gen_footstep_stone() -> AudioStreamWAV:
	var dur: float = 0.10
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 82
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var env: float = exp(-25.0 * tn)
		var body: float = sin(TAU * 320.0 * float(i) / float(SR)) * 0.4
		var crack: float = rng.randf_range(-1.0, 1.0) * 0.6
		buf[i] = (body + crack) * env
	_highpass(buf, 200.0)
	_normalize(buf, 0.75)
	_envelope_edges(buf, 16)
	return _wav(buf)

## Wood: hollow knock — short with a resonant mid sine.
static func gen_footstep_wood() -> AudioStreamWAV:
	var dur: float = 0.13
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var t: float = float(i) / float(SR)
		var env: float = exp(-18.0 * tn)
		var body: float = sin(TAU * 220.0 * t) * 0.6 + sin(TAU * 330.0 * t) * 0.3
		buf[i] = body * env
	_normalize(buf, 0.7)
	_envelope_edges(buf, 16)
	return _wav(buf)

## Dirt: soft thud — lowpassed noise with subtle low body.
static func gen_footstep_dirt() -> AudioStreamWAV:
	var dur: float = 0.14
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 84
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var env: float = exp(-14.0 * tn)
		var body: float = sin(TAU * 90.0 * float(i) / float(SR)) * 0.3
		var noise: float = rng.randf_range(-1.0, 1.0) * 0.6
		buf[i] = (body + noise) * env
	_lowpass(buf, 900.0)
	_normalize(buf, 0.7)
	_envelope_edges(buf, 16)
	return _wav(buf)

# ── UI sounds ───────────────────────────────────────────────────────────────

## Click: short clean tick — single short sine pulse at a clicky frequency.
static func gen_ui_click() -> AudioStreamWAV:
	var dur: float = 0.05
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var env: float = exp(-45.0 * tn)
		buf[i] = sin(TAU * 1600.0 * float(i) / float(SR)) * env
	_normalize(buf, 0.6)
	_envelope_edges(buf, 8)
	return _wav(buf)

## Tab switch: soft swoosh — quick frequency sweep with filtered noise.
static func gen_ui_tab_switch() -> AudioStreamWAV:
	var dur: float = 0.14
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	var phase: float = 0.0
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var freq: float = 600.0 + 1200.0 * tn  # sweep up
		phase += TAU * freq / float(SR)
		var env: float = sin(PI * tn)  # bump envelope
		buf[i] = (sin(phase) * 0.3 + rng.randf_range(-1.0, 1.0) * 0.4) * env
	_lowpass(buf, 2400.0)
	_normalize(buf, 0.55)
	_envelope_edges(buf, 16)
	return _wav(buf)

## Quest complete: ascending 3-note chime (C-E-G) over ~0.9s.
static func gen_quest_complete() -> AudioStreamWAV:
	return _chime_chord([_midi_hz(72), _midi_hz(76), _midi_hz(79)],
		[0.0, 0.18, 0.36], 0.45, 1.1)

## Level up: ascending 4-note fanfare (C-G-C-E octave) over ~1.4s,
## brighter and longer than quest complete.
static func gen_level_up() -> AudioStreamWAV:
	return _chime_chord(
		[_midi_hz(72), _midi_hz(79), _midi_hz(84), _midi_hz(88)],
		[0.0, 0.15, 0.30, 0.55], 0.70, 1.5)

## Item pickup: short soft chime — single note with sparkle.
static func gen_item_pickup() -> AudioStreamWAV:
	return _chime_chord([_midi_hz(84), _midi_hz(91)], [0.0, 0.04], 0.20, 0.35)

## Craft success: click + chime combo. Short tick then a 2-note chime.
static func gen_craft_success() -> AudioStreamWAV:
	var dur: float = 0.6
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	# Tick first 0.03s
	var tick_n: int = _n(0.03)
	for i: int in range(tick_n):
		var tn: float = float(i) / float(tick_n)
		var env: float = exp(-40.0 * tn)
		buf[i] = sin(TAU * 1400.0 * float(i) / float(SR)) * env * 0.7
	# 2-note chime starts at 0.06s
	var notes: Array[float] = [_midi_hz(76), _midi_hz(83)]  # E, B
	var starts: Array[float] = [0.06, 0.18]
	var note_len: float = 0.45
	for k: int in range(notes.size()):
		var start_i: int = _n(starts[k])
		var dur_n: int = _n(note_len)
		var f: float = notes[k]
		for i: int in range(dur_n):
			var idx: int = start_i + i
			if idx >= n:
				break
			var tn: float = float(i) / float(dur_n)
			var env: float = exp(-4.0 * tn)
			var t: float = float(i) / float(SR)
			var s: float = sin(TAU * f * t) * 0.45 + sin(TAU * f * 2.0 * t) * 0.20
			buf[idx] += s * env
	_normalize(buf, 0.85)
	_envelope_edges(buf, 32)
	return _wav(buf)

# Helper: build an N-note chime chord with given start-times (sec), each
# note's decay duration, and total length. Each note is a fundamental +
# 2nd harmonic with exponential decay.
static func _chime_chord(freqs: Array, starts: Array,
		note_decay: float, total_dur: float) -> AudioStreamWAV:
	var n: int = _n(total_dur)
	var buf: PackedFloat32Array = _buf(n)
	for k: int in range(freqs.size()):
		var f: float = freqs[k]
		var start_i: int = _n(starts[k])
		var note_n: int = _n(note_decay)
		for i: int in range(note_n):
			var idx: int = start_i + i
			if idx >= n:
				break
			var tn: float = float(i) / float(note_n)
			var env: float = exp(-4.5 * tn)
			var t: float = float(i) / float(SR)
			var s: float = sin(TAU * f * t) * 0.5 \
				+ sin(TAU * f * 2.0 * t) * 0.25 \
				+ sin(TAU * f * 3.0 * t) * 0.12
			buf[idx] += s * env
	_normalize(buf, 0.85)
	_envelope_edges(buf, 32)
	return _wav(buf)

# ── Ambience loops ──────────────────────────────────────────────────────────

## Ocean: layered low sine waves (different frequencies) with slow amplitude
## modulation to suggest swelling waves. Loop seamless — picked frequencies
## that complete integer cycles in the loop window.
static func gen_amb_ocean() -> AudioStreamWAV:
	var dur: float = 12.0
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	# Pick AM frequencies that complete integer cycles in `dur` (so the loop
	# is seamless). For dur=12: AM at 1/12, 1/6, 1/4 Hz → 1, 2, 3 cycles.
	for i: int in range(n):
		var t: float = float(i) / float(SR)
		var am1: float = 0.5 + 0.5 * sin(TAU * (1.0 / dur) * t)
		var am2: float = 0.5 + 0.5 * sin(TAU * (2.0 / dur) * t + 1.3)
		# Layered low-freq sines (also picked to complete in dur)
		var s: float = sin(TAU * 40.0 * t) * 0.4 * am1 \
			+ sin(TAU * 67.0 * t) * 0.3 * am2 \
			+ sin(TAU * 95.0 * t) * 0.2 * am1
		buf[i] = s
	# Add white-foam noise that's lowpass filtered + AM modulated
	var rng := RandomNumberGenerator.new()
	rng.seed = 101
	var foam: PackedFloat32Array = _buf(n)
	for i: int in range(n):
		foam[i] = rng.randf_range(-1.0, 1.0)
	_lowpass(foam, 800.0)
	for i: int in range(n):
		var t: float = float(i) / float(SR)
		var am: float = 0.4 + 0.5 * sin(TAU * (3.0 / dur) * t)
		buf[i] += foam[i] * 0.25 * am
	_normalize(buf, 0.7)
	return _wav(buf, true)

## Wind: bandpassed noise with slow frequency drift (achieved by sweeping
## the lowpass cutoff via re-filter passes — approximated here as
## modulated noise + slow AM).
static func gen_amb_wind() -> AudioStreamWAV:
	var dur: float = 14.0
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 102
	for i: int in range(n):
		buf[i] = rng.randf_range(-1.0, 1.0)
	# Two lowpass passes for steeper rolloff
	_lowpass(buf, 1200.0)
	_lowpass(buf, 1200.0)
	# Slow AM gives a "gusting" feel — uses integer cycles for loop seam
	for i: int in range(n):
		var t: float = float(i) / float(SR)
		var am: float = 0.4 + 0.4 * sin(TAU * (1.0 / dur) * t) \
			+ 0.2 * sin(TAU * (3.0 / dur) * t + 0.7)
		buf[i] *= am
	_normalize(buf, 0.55)
	return _wav(buf, true)

## Forest: random bird chirp events at deterministic times (so the loop
## point is seamless — chirps don't straddle the end).
static func gen_amb_forest() -> AudioStreamWAV:
	var dur: float = 15.0
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	# Faint wind bed underneath
	var rng := RandomNumberGenerator.new()
	rng.seed = 103
	for i: int in range(n):
		buf[i] = rng.randf_range(-1.0, 1.0)
	_lowpass(buf, 600.0)
	_lowpass(buf, 600.0)
	for i: int in range(n):
		buf[i] *= 0.15
	# Chirps — placed at fixed offsets with varied pitch & length
	var chirps: Array = [
		[1.2,  2200.0, 0.08, false],
		[2.8,  1900.0, 0.06, true],
		[4.5,  2600.0, 0.07, false],
		[6.1,  2100.0, 0.10, true],
		[8.0,  2400.0, 0.05, false],
		[9.7,  1800.0, 0.09, true],
		[11.5, 2300.0, 0.07, false],
		[13.4, 2000.0, 0.08, true],
	]
	for c: Variant in chirps:
		var ca: Array = c
		var start_s: float = float(ca[0])
		var f0: float = float(ca[1])
		var clen: float = float(ca[2])
		var ascend: bool = bool(ca[3])
		var start_i: int = _n(start_s)
		var clen_n: int = _n(clen)
		var phase: float = 0.0
		for i: int in range(clen_n):
			var idx: int = start_i + i
			if idx >= n - 1:
				break
			var tn: float = float(i) / float(clen_n)
			var freq: float
			if ascend:
				freq = f0 * (1.0 + 0.4 * tn)
			else:
				freq = f0 * (1.0 - 0.3 * tn)
			phase += TAU * freq / float(SR)
			var env: float = sin(PI * tn)  # bump envelope
			buf[idx] += sin(phase) * env * 0.35
	_normalize(buf, 0.6)
	return _wav(buf, true)

## Cave: sparse random drips. Each drip is a damped sine "plok" at varied
## pitch with subtle reverb-like delay tail.
static func gen_amb_cave() -> AudioStreamWAV:
	var dur: float = 16.0
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	# Very quiet rumble bed
	var rng := RandomNumberGenerator.new()
	rng.seed = 104
	for i: int in range(n):
		buf[i] = rng.randf_range(-1.0, 1.0)
	_lowpass(buf, 120.0)
	_lowpass(buf, 120.0)
	for i: int in range(n):
		buf[i] *= 0.4
	# Drips at fixed seeds — varied frequency
	var drips: Array = [
		[1.6,  640.0],
		[4.2,  520.0],
		[5.9,  720.0],
		[7.8,  580.0],
		[10.1, 690.0],
		[12.0, 550.0],
		[14.3, 660.0],
	]
	for d: Variant in drips:
		var da: Array = d
		var start_s: float = float(da[0])
		var freq: float = float(da[1])
		var start_i: int = _n(start_s)
		var drip_n: int = _n(0.4)
		for i: int in range(drip_n):
			var idx: int = start_i + i
			if idx >= n - 1:
				break
			var tn: float = float(i) / float(drip_n)
			var env: float = exp(-6.0 * tn)
			var t: float = float(i) / float(SR)
			# Drop pitch quickly for "plop" character
			var f_inst: float = freq * (1.0 - 0.4 * tn)
			var s: float = sin(TAU * f_inst * t) * env * 0.5
			buf[idx] += s
			# Tail echo (single delayed copy)
			var echo_i: int = idx + _n(0.18)
			if echo_i < n - 1:
				buf[echo_i] += s * 0.35
	_normalize(buf, 0.6)
	return _wav(buf, true)

# ── Music loops ─────────────────────────────────────────────────────────────

## Town: a Norse mead-hall piece in D Dorian. Slow deliberate 90 BPM,
## drone-rooted (D + A power-fifth low end), modal melody emphasizing
## the major-6th (B) that gives Dorian its hopeful-but-medieval character.
## Replaces the old C-major-pentatonic version which read as East Asian.
## Structure (72 beats, 48 s):
##   A   0-16s  slow modal verse — D Dorian melody over D/A drone
##   B   16-32s parallel-fifth passages, the "hall lifts" — adds open chord
##   C   32-40s brief shift to G drone (subtonic warmth)
##   A'  40-48s return to D, resolves on the open fifth
##
## Timbre uses _paint_warm_notes — slower decay than the original pluck
## and a touch of vibrato so notes sustain like a horn/lyre, not a music
## box. Open fifths (root + 5th simultaneously) replace single-line
## melodies in the B section, the "Skyrim hall" sound.
static func gen_music_town() -> AudioStreamWAV:
	var bpm: float = 90.0                  # mead-hall pace
	var beat: float = 60.0 / bpm           # ≈0.667 s — clean integer s at 72 beats
	var dur: float = beat * 72.0           # 48.0 s exactly
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	# Drone bass per section. Power fifth (root + 5th) gives the open
	# Nordic "horn" sound. No 3rd in the bass — fifths only, never thirds.
	var bass_sections: Array = [
		[0.0,  24.0, [38, 45]],   # A: D2 + A2 (tonic open fifth)
		[24.0, 48.0, [38, 45]],   # B: stay on D — parallel motion above
		[48.0, 60.0, [43, 50]],   # C: G2 + D3 (subtonic shift, "warm hall")
		[60.0, 72.0, [38, 45]],   # A': back to D
	]
	for sec: Variant in bass_sections:
		var sa: Array = sec
		var s_beat: float = float(sa[0])
		var e_beat: float = float(sa[1])
		var notes: Array = sa[2]
		var s_i: int = int(s_beat * beat * float(SR))
		var e_i: int = int(e_beat * beat * float(SR))
		var fade: int = int(0.4 * float(SR))
		for nm: Variant in notes:
			var f: float = _midi_hz(int(nm))
			for i: int in range(s_i, mini(e_i, n)):
				var t: float = float(i) / float(SR)
				var w: float = 1.0
				if i - s_i < fade:
					w = float(i - s_i) / float(fade)
				elif e_i - i < fade:
					w = float(e_i - i) / float(fade)
				# Slow tremolo (1Hz) — gives the drone a "living" pulse
				# like a slowly bowed string instead of a flat sine.
				var trem: float = 1.0 + 0.10 * sin(TAU * 1.0 * t)
				buf[i] += sin(TAU * f * t) * 0.08 * w * trem
	# D Dorian scale: D E F G A B C D — natural minor with raised 6th.
	# That major-6th (B in D Dorian) is the modal signature.
	# Midi: 50 52 53 55 57 59 60 62  (D3 E3 F3 G3 A3 B3 C4 D4)
	# Higher octave for melody phrases: 62 64 65 67 69 71 72 74
	var d_dor:  Array = [62, 64, 65, 67, 69, 71, 72, 74]
	var d_low:  Array = [50, 52, 53, 55, 57, 59, 60, 62]
	# Section A (0-24 beats, 16s): slow modal verse. Notes drawn mostly
	# from D Dorian, settling on D and A.
	var pattern_a: Array = [
		# Bar 1-2: tonic motif D-F-A-D
		[0,  d_dor[0], 2.0, 0.42],   # D
		[2,  d_dor[2], 2.0, 0.42],   # F
		[4,  d_dor[4], 2.0, 0.42],   # A
		[6,  d_dor[0], 2.0, 0.42],   # D
		# Bar 3-4: lift to the Dorian color note (B), then descend
		[8,  d_dor[5], 1.0, 0.40],   # B  (the Dorian color)
		[9,  d_dor[4], 1.0, 0.40],   # A
		[10, d_dor[3], 2.0, 0.42],   # G
		[12, d_dor[2], 2.0, 0.42],   # F
		# Bar 5-6: resolve back to D, hold
		[14, d_dor[1], 1.0, 0.40],   # E
		[15, d_dor[0], 3.0, 0.45],   # D
		[18, d_dor[4], 2.0, 0.42],   # A
		[20, d_dor[0], 4.0, 0.46],   # D — held for next section entry
	]
	# Section B (24-48 beats, 16s): the "hall lifts" — parallel fifths
	# (paint both root + 5th at once) make this read as power-chord folk.
	# We achieve this by painting two notes 7 semitones apart at the same
	# start beat with the same length.
	var pattern_b: Array = [
		# Open fifth pulse: D + A, F + C, G + D, A + E — Mixolydian/Dorian flavor
		[24, d_dor[0], 1.5, 0.36], [24, d_dor[4], 1.5, 0.32],   # D + A
		[26, d_dor[2], 1.5, 0.36], [26, d_dor[6], 1.5, 0.32],   # F + C
		[28, d_dor[3], 1.5, 0.36], [28, d_dor[7], 1.5, 0.32],   # G + D
		[30, d_dor[4], 2.0, 0.38], [30, d_dor[7]+2, 2.0, 0.32], # A + E
		[32, d_dor[5], 1.5, 0.36], [32, d_dor[7]+2, 1.5, 0.32], # B + E (color)
		[34, d_dor[4], 1.5, 0.36], [34, d_dor[7]+2, 1.5, 0.32], # A + E
		[36, d_dor[2], 2.0, 0.38], [36, d_dor[6], 2.0, 0.32],   # F + C
		[38, d_dor[0], 2.0, 0.40], [38, d_dor[4], 2.0, 0.36],   # D + A (resolve)
		# Second half of B — single-line answer
		[40, d_dor[4], 1.5, 0.42],   # A
		[41.5, d_dor[5], 0.5, 0.40], # B
		[42, d_dor[4], 1.5, 0.42],   # A
		[43.5, d_dor[3], 0.5, 0.40], # G
		[44, d_dor[2], 2.0, 0.42],   # F
		[46, d_dor[0], 2.0, 0.44],   # D
	]
	# Section C (48-60 beats, 8s): warm hall — shift drone to G. Melody
	# stays in scale but emphasizes G and C (4th + b7) for modal warmth.
	var pattern_c: Array = [
		[48, d_dor[3], 3.0, 0.40],   # G — sustained
		[51, d_dor[6], 1.0, 0.40],   # C
		[52, d_dor[5], 3.0, 0.40],   # B held
		[55, d_dor[3], 1.0, 0.40],   # G
		[56, d_dor[4], 2.0, 0.42],   # A
		[58, d_dor[3], 2.0, 0.42],   # G
	]
	# Section A' (60-72 beats, 8s): condensed return, ends on open fifth.
	var pattern_a_prime: Array = [
		[60, d_dor[0], 2.0, 0.46],   # D
		[62, d_dor[2], 2.0, 0.44],   # F
		[64, d_dor[4], 2.0, 0.46],   # A
		[66, d_dor[2], 1.0, 0.42],   # F
		[67, d_dor[0], 1.0, 0.44],   # D
		# Final open-fifth resolution: D + A together held to the loop point
		[68, d_dor[0], 4.0, 0.50],
		[68, d_dor[4], 4.0, 0.42],
	]
	# Low-octave shadow: paint the A-section melody one octave down (using
	# d_low scale notes) at lower gain so the upper voice has support.
	# Skipped during B/C to keep the contrast.
	var pattern_a_shadow: Array = []
	for ev: Variant in pattern_a:
		var arr: Array = ev
		var midi_lo: int = int(arr[1]) - 12
		pattern_a_shadow.append([float(arr[0]), midi_lo, float(arr[2]), float(arr[3]) * 0.5])
	# Sanity-check that d_low covers the expected low-octave register —
	# any pattern_a note - 12 should land inside d_low's range. (Compile-
	# time documentation only; no runtime cost.)
	var _lo_root: int = d_low[0]
	for pat: Variant in [pattern_a, pattern_b, pattern_c, pattern_a_prime, pattern_a_shadow]:
		_paint_warm_notes(buf, pat, beat, n)
	_normalize(buf, 0.76)
	return _wav(buf, true)

# Paint a sequence of WARM, sustained notes — slower decay than the
# plucked variant, with light vibrato that simulates a bowed/horn timbre.
# Used by the town theme for its mead-hall warmth.
# Pattern shape: [start_beat: float, midi: int, length_beats: float, gain: float]
static func _paint_warm_notes(buf: PackedFloat32Array, pattern: Array,
		beat: float, n: int) -> void:
	for ev: Variant in pattern:
		var arr: Array = ev
		var when_b: float = float(arr[0])
		var midi: int = int(arr[1])
		var len_b: float = float(arr[2])
		var gain: float = float(arr[3])
		var f: float = _midi_hz(midi)
		var start_i: int = int(when_b * beat * float(SR))
		var note_dur: float = len_b * beat * 0.95
		var note_n: int = int(note_dur * float(SR))
		for i: int in range(note_n):
			var idx: int = start_i + i
			if idx >= n:
				break
			var tn: float = float(i) / float(note_n)
			# Soft attack (50ms) + sustained body + gentle decay tail.
			var atk_n: int = int(0.05 * float(SR))
			var env: float
			if i < atk_n:
				env = float(i) / float(atk_n)
			else:
				env = exp(-1.2 * (tn - float(atk_n) / float(note_n)))
			var t: float = float(i) / float(SR)
			# 4.5 Hz vibrato — barely audible, gives the horn shimmer.
			var vib: float = 1.0 + 0.005 * sin(TAU * 4.5 * t)
			var s: float = sin(TAU * f * vib * t) * 0.55 \
				+ sin(TAU * f * 2.0 * vib * t) * 0.22 \
				+ sin(TAU * f * 3.0 * vib * t) * 0.08
			buf[idx] += s * env * gain

# Paint BRASS-LIKE notes — saw-style harmonic stack (1f, 2f, 3f, 4f, 5f
# with 1/k amplitude). Slower attack than warm, heavier bottom end.
# Used by the combat track for the low-brass tonal layer.
static func _paint_brass_notes(buf: PackedFloat32Array, pattern: Array,
		beat: float, n: int) -> void:
	for ev: Variant in pattern:
		var arr: Array = ev
		var when_b: float = float(arr[0])
		var midi: int = int(arr[1])
		var len_b: float = float(arr[2])
		var gain: float = float(arr[3])
		var f: float = _midi_hz(midi)
		var start_i: int = int(when_b * beat * float(SR))
		var note_dur: float = len_b * beat * 0.92
		var note_n: int = int(note_dur * float(SR))
		for i: int in range(note_n):
			var idx: int = start_i + i
			if idx >= n:
				break
			var tn: float = float(i) / float(note_n)
			# 80ms attack ramp, then slow exponential decay.
			var atk_n: int = int(0.08 * float(SR))
			var env: float
			if i < atk_n:
				env = float(i) / float(atk_n)
			else:
				env = exp(-1.8 * tn)
			var t: float = float(i) / float(SR)
			# Saw-style summed harmonics.
			var s: float = sin(TAU * f * t) * 0.50 \
				+ sin(TAU * f * 2.0 * t) * 0.30 \
				+ sin(TAU * f * 3.0 * t) * 0.18 \
				+ sin(TAU * f * 4.0 * t) * 0.10 \
				+ sin(TAU * f * 5.0 * t) * 0.05
			buf[idx] += s * env * gain

# Punchy war-drum kick. ~80Hz sine with rapid pitch-drop + lowpassed
# noise burst. Returns a small float buffer the caller adds in at the
# right offsets — cheaper than re-generating per beat.
static func _war_drum_buf(strength: float = 1.0) -> PackedFloat32Array:
	var dur: float = 0.18
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 901
	var phase: float = 0.0
	for i: int in range(n):
		var tn: float = float(i) / float(n)
		var freq: float = 90.0 * exp(-6.0 * tn) + 35.0
		phase += TAU * freq / float(SR)
		var env: float = exp(-7.0 * tn)
		var body: float = sin(phase) * 0.8
		var crack: float = rng.randf_range(-1.0, 1.0) * 0.35
		buf[i] = (body + crack) * env * strength
	_lowpass(buf, 700.0)
	return buf

# Paint a sequence of plucked-tone notes (fundamental + 2nd + 3rd harmonic
# with exponential decay) into a buffer. Pattern entry shape:
#   [start_beat: float, midi: int, length_beats: float, gain: float]
static func _paint_melody_notes(buf: PackedFloat32Array, pattern: Array,
		beat: float, n: int) -> void:
	for ev: Variant in pattern:
		var arr: Array = ev
		var when_b: float = float(arr[0])
		var midi: int = int(arr[1])
		var len_b: float = float(arr[2])
		var gain: float = float(arr[3])
		var f: float = _midi_hz(midi)
		var start_i: int = int(when_b * beat * float(SR))
		var note_dur: float = len_b * beat * 0.92
		var note_n: int = int(note_dur * float(SR))
		# Shorter notes decay faster so they "pluck" rather than ring
		var decay_rate: float = 2.4 if len_b >= 1.5 else 3.5
		for i: int in range(note_n):
			var idx: int = start_i + i
			if idx >= n:
				break
			var tn: float = float(i) / float(note_n)
			var env: float = exp(-decay_rate * tn)
			var t: float = float(i) / float(SR)
			var s: float = sin(TAU * f * t) * 0.5 \
				+ sin(TAU * f * 2.0 * t) * 0.18 \
				+ sin(TAU * f * 3.0 * t) * 0.08
			buf[idx] += s * env * gain

## Wilderness: A natural-minor / minor-pentatonic Nordic folk feel. Open
## fjord atmosphere — sustained low drone, sparse plaintive notes with
## long decay tails, like a distant horn over water. Strictly A minor
## pentatonic (A C D E G) — no major pentatonic which read as East Asian.
## 18s seamless loop.
static func gen_music_wilderness() -> AudioStreamWAV:
	var dur: float = 18.0
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	# Power-fifth drone in A: A1 (33) + E2 (40). Very low so it reads as
	# distant wind / earth rather than a chord.
	var drones: Array = [33, 40]
	for dm: Variant in drones:
		var f: float = _midi_hz(int(dm))
		for i: int in range(n):
			var t: float = float(i) / float(SR)
			# Slow swell (integer cycles in dur for clean loop).
			var swell: float = 0.55 + 0.30 * sin(TAU * (1.0 / dur) * t) \
				+ 0.15 * sin(TAU * (3.0 / dur) * t + 1.2)
			buf[i] += sin(TAU * f * t) * 0.10 * swell
	# A minor pentatonic: A C D E G = midi 57 60 62 64 67
	# Plus higher octave for melody: 69 72 74 76 79
	# Plaintive horn-style notes — long decay, soft attack.
	var pent_a: Array[int] = [57, 60, 62, 64, 67, 69, 72, 74, 76, 79]
	# Sparse phrase placement — designed so phrases never straddle the
	# loop seam. Each entry: [start_s, pent_idx, length_s, gain]
	var phrases: Array = [
		[1.0,  5, 2.5, 0.30],   # A4 — opening call
		[3.5,  7, 1.5, 0.28],   # D5
		[5.5,  6, 3.0, 0.30],   # C5 — held
		[8.5,  4, 1.5, 0.25],   # G4 — pulled-back answer
		[10.2, 5, 2.0, 0.28],   # A4
		[12.5, 6, 1.5, 0.26],   # C5
		[14.2, 5, 3.0, 0.30],   # A4 — long resolution toward loop
	]
	for ph: Variant in phrases:
		var pa: Array = ph
		var start_s: float = float(pa[0])
		var midi: int = pent_a[int(pa[1])]
		var len_s: float = float(pa[2])
		var gain: float = float(pa[3])
		var f: float = _midi_hz(midi)
		var start_i: int = _n(start_s)
		var note_n: int = _n(len_s)
		for i: int in range(note_n):
			var idx: int = start_i + i
			if idx >= n:
				break
			var tn: float = float(i) / float(note_n)
			# 80ms attack, exp decay tail — like a wooden horn.
			var atk_n: int = int(0.08 * float(SR))
			var env: float
			if i < atk_n:
				env = float(i) / float(atk_n)
			else:
				env = exp(-1.4 * tn)
			var t: float = float(i) / float(SR)
			# Light vibrato for the open-fjord sustain feel.
			var vib: float = 1.0 + 0.004 * sin(TAU * 5.0 * t)
			var s: float = sin(TAU * f * vib * t) * 0.55 \
				+ sin(TAU * f * 2.0 * vib * t) * 0.20 \
				+ sin(TAU * f * 3.0 * vib * t) * 0.07
			buf[idx] += s * env * gain
	_normalize(buf, 0.62)
	return _wav(buf, true)

## Combat: 35-second dynamic 3-section track in D Phrygian — the darkest
## Western mode, classic for war / dread / Norse battle scenes. Heavy
## percussive war drums + low-brass pad over a D power-fifth drone (NO
## thirds; thirds soften the dread). Replaces the prior C-minor pluck
## arpeggio which was too melodic for combat.
##
## Structure:
##   Section 1 (0-10s)  — BUILD:  drum on beats 1+3 only, brass swells in
##   Section 2 (10-25s) — FULL:   drums every beat, brass motif, snare hits
##   Section 3 (25-35s) — RELEASE: drum thins, brass holds, final stinger
## 140 BPM. Loops at 35.0 s.
static func gen_music_combat() -> AudioStreamWAV:
	var bpm: float = 140.0
	var beat: float = 60.0 / bpm
	var dur: float = 35.0
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var sec1_end: float = 10.0
	var sec2_end: float = 25.0
	var total_beats: int = int(dur / beat)
	# Drone: D1 + D2 + A2 (power-fifth, doubled root for depth)
	var drone_notes: Array[int] = [26, 38, 45]   # D1, D2, A2
	for dm: int in drone_notes:
		var f: float = _midi_hz(dm)
		var gain: float = 0.06 if dm == 26 else 0.05
		for i: int in range(n):
			var t: float = float(i) / float(SR)
			# Section envelope so drone breathes with the form.
			var section_gain: float
			if t < sec1_end:
				section_gain = 0.50 + 0.40 * (t / sec1_end)
			elif t < sec2_end:
				section_gain = 0.95
			else:
				section_gain = 0.95 - 0.40 * ((t - sec2_end) / (dur - sec2_end))
			buf[i] += sin(TAU * f * t) * gain * section_gain
	# ── War drums — pre-rendered 180ms kick mixed in at beat times ──
	var drum: PackedFloat32Array = _war_drum_buf(1.0)
	var drum_soft: PackedFloat32Array = _war_drum_buf(0.65)
	for k: int in range(total_beats):
		var beat_t: float = float(k) * beat
		var hit: PackedFloat32Array
		var play_it: bool = false
		if beat_t < sec1_end:
			# Build — beats 1 + 3 (k % 2 == 0), soft hits
			play_it = (k % 2 == 0)
			hit = drum_soft
		elif beat_t < sec2_end:
			# Full intensity — every beat
			play_it = true
			hit = drum
		else:
			# Release — beats 1, 2, 3 of each bar; skip the "and of 4"
			play_it = (k % 4 != 3)
			hit = drum_soft
		if not play_it:
			continue
		var start_i: int = int(beat_t * float(SR))
		var hit_len: int = mini(hit.size(), n - start_i)
		for i: int in range(hit_len):
			buf[start_i + i] += hit[i]
	# ── Snare-like noise hits on offbeats (section 2 + part of 3) ──
	var rng := RandomNumberGenerator.new()
	rng.seed = 313
	for k: int in range(total_beats):
		var off_t: float = (float(k) + 0.5) * beat
		if off_t >= dur:
			break
		var play_hit: bool = false
		var gain: float = 0.22
		if off_t < sec1_end:
			play_hit = (k % 8 == 3)   # very sparse — one accent per 2 bars
			gain = 0.14
		elif off_t < sec2_end:
			play_hit = true
			gain = 0.24
		else:
			play_hit = (k % 4 == 1)
			gain = 0.18
		if not play_hit:
			continue
		var start_i: int = int(off_t * float(SR))
		var hit_n: int = int(0.07 * float(SR))
		for i: int in range(hit_n):
			var idx: int = start_i + i
			if idx >= n:
				break
			var tn: float = float(i) / float(hit_n)
			var env: float = exp(-28.0 * tn)
			buf[idx] += rng.randf_range(-1.0, 1.0) * env * gain
	# ── Brass motif (section 2) — D Phrygian. The signature interval is
	# D → Eb (b2), the Phrygian half-step that delivers the "darkness".
	# Pattern over 4 bars at 140 BPM = 6.86s, repeats ~2.2 times in
	# sec2_end - sec1_end = 15s. Each "note" is a low-brass stab.
	# Notes (midi): 38 D2 / 39 Eb2 / 41 F2 / 43 G2 / 45 A2
	var motif_seq: Array = [
		# beat_offset_from_sec2_start, midi, len_beats, gain
		[0.0,  38, 1.0, 0.34],
		[1.0,  39, 0.5, 0.32],    # the Phrygian half-step
		[1.5,  38, 0.5, 0.32],
		[2.0,  41, 1.0, 0.34],
		[3.0,  38, 1.0, 0.34],
		[4.0,  43, 1.0, 0.36],
		[5.0,  39, 0.5, 0.32],
		[5.5,  41, 0.5, 0.32],
		[6.0,  38, 2.0, 0.36],
	]
	var motif_bars: float = 8.0   # 8 beats per motif cycle
	var motif_dur_s: float = motif_bars * beat
	var motif_start: float = sec1_end + 0.2
	var cycles: int = int(((sec2_end - motif_start) / motif_dur_s) + 0.5)
	var brass_pattern: Array = []
	for c: int in range(cycles):
		var cycle_start_s: float = motif_start + float(c) * motif_dur_s
		for ev: Variant in motif_seq:
			var arr: Array = ev
			var note_t: float = cycle_start_s + float(arr[0]) * beat
			if note_t >= sec2_end:
				break
			var note_beat_index: float = note_t / beat
			brass_pattern.append([note_beat_index, int(arr[1]),
				float(arr[2]), float(arr[3])])
	_paint_brass_notes(buf, brass_pattern, beat, n)
	# ── Final stinger in section 3 — single low D blast that resolves
	# the cycle. Loops cleanly because the stinger ends before the loop
	# point.
	var stinger: Array = [
		[(sec2_end + 0.5) / beat, 38, 2.0, 0.42],   # D2
		[(sec2_end + 3.0) / beat, 26, 4.0, 0.30],   # D1 — long fade-out
	]
	_paint_brass_notes(buf, stinger, beat, n)
	_highpass(buf, 30.0)
	_normalize(buf, 0.80)
	return _wav(buf, true)

# ── Norse instrument timbres (paint helpers) ────────────────────────────────
#
# Each paints ONE note into `buf` starting at `start_i`. Caller owns the
# buffer + the loop/phrase scheduling. Timbres are deliberately simple
# additive-synthesis approximations of the real instruments, not
# audiophile models — goal is "this reads as a bowed lyre" or "this reads
# as a bone flute", not historical accuracy.

# Tagelharpa — bowed Estonian/Swedish lyre. Saw-style harmonic stack with
# slow ~200ms bow attack, light bow noise, 5 Hz tremolo. Sustains for the
# duration requested.
static func _paint_tagelharpa(buf: PackedFloat32Array, start_i: int,
		freq: float, note_n: int, gain: float, rng_seed: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed if rng_seed != 0 else int(freq * 100.0)
	var atk_n: int = int(0.20 * float(SR))
	var rel_n: int = int(0.30 * float(SR))
	var n_max: int = buf.size()
	for i: int in range(note_n):
		var idx: int = start_i + i
		if idx >= n_max:
			break
		var t: float = float(i) / float(SR)
		var env: float
		if i < atk_n:
			env = float(i) / float(atk_n)
		elif i > note_n - rel_n:
			env = float(note_n - i) / float(rel_n)
		else:
			env = 1.0
		var trem: float = 1.0 + 0.06 * sin(TAU * 5.0 * t)
		var s: float = sin(TAU * freq * t) * 0.55 \
			+ sin(TAU * freq * 2.0 * t) * 0.30 \
			+ sin(TAU * freq * 3.0 * t) * 0.20 \
			+ sin(TAU * freq * 4.0 * t) * 0.12
		var bow_noise: float = rng.randf_range(-1.0, 1.0) * 0.03
		buf[idx] += (s + bow_noise) * env * trem * gain

# Throat-style hum — overtone singing approximation. Fundamental plus
# strongly emphasized 4th + 5th partials, slow 0.3 Hz swell, gentle
# tremor. Used for the deep ritual drone.
static func _paint_throat_hum(buf: PackedFloat32Array, start_i: int,
		freq: float, note_n: int, gain: float) -> void:
	var atk_n: int = int(0.30 * float(SR))
	var rel_n: int = int(0.40 * float(SR))
	var n_max: int = buf.size()
	for i: int in range(note_n):
		var idx: int = start_i + i
		if idx >= n_max:
			break
		var t: float = float(i) / float(SR)
		var env: float
		if i < atk_n:
			env = float(i) / float(atk_n)
		elif i > note_n - rel_n:
			env = float(note_n - i) / float(rel_n)
		else:
			env = 1.0
		var s: float = sin(TAU * freq * t) * 0.45 \
			+ sin(TAU * freq * 2.0 * t) * 0.15 \
			+ sin(TAU * freq * 4.0 * t) * 0.30 \
			+ sin(TAU * freq * 5.0 * t) * 0.22
		var swell: float = 0.70 + 0.30 * sin(TAU * 0.3 * t)
		var tremor: float = 1.0 + 0.04 * sin(TAU * 6.5 * t)
		buf[idx] += s * env * swell * tremor * gain

# Bone flute — pure sine fundamental + soft 2nd harmonic, breath noise
# floor, 50ms attack, gentle vibrato.
static func _paint_bone_flute(buf: PackedFloat32Array, start_i: int,
		freq: float, note_n: int, gain: float, rng_seed: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed if rng_seed != 0 else int(freq * 73.0)
	var atk_n: int = int(0.05 * float(SR))
	var rel_n: int = int(0.15 * float(SR))
	var n_max: int = buf.size()
	for i: int in range(note_n):
		var idx: int = start_i + i
		if idx >= n_max:
			break
		var t: float = float(i) / float(SR)
		var env: float
		if i < atk_n:
			env = float(i) / float(atk_n)
		elif i > note_n - rel_n:
			env = float(note_n - i) / float(rel_n)
		else:
			env = 1.0
		var vib: float = 1.0 + 0.006 * sin(TAU * 5.0 * t)
		var s: float = sin(TAU * freq * vib * t) * 0.65 \
			+ sin(TAU * freq * 2.0 * vib * t) * 0.10
		var breath: float = rng.randf_range(-1.0, 1.0) * 0.06
		buf[idx] += (s + breath) * env * gain

# Lyre pluck — fast attack, exponential decay. Sutton Hoo style.
static func _paint_lyre_pluck(buf: PackedFloat32Array, start_i: int,
		freq: float, note_n: int, gain: float) -> void:
	var atk_n: int = int(0.004 * float(SR))
	var n_max: int = buf.size()
	for i: int in range(note_n):
		var idx: int = start_i + i
		if idx >= n_max:
			break
		var tn: float = float(i) / float(note_n)
		var t: float = float(i) / float(SR)
		var env: float
		if i < atk_n:
			env = float(i) / float(atk_n)
		else:
			env = exp(-3.2 * tn)
		var s: float = sin(TAU * freq * t) * 0.55 \
			+ sin(TAU * freq * 2.0 * t) * 0.22 \
			+ sin(TAU * freq * 3.0 * t) * 0.10
		buf[idx] += s * env * gain

# Distant horn call — mellow brass swell with long release.
static func _paint_horn_call(buf: PackedFloat32Array, start_i: int,
		freq: float, note_n: int, gain: float) -> void:
	var atk_n: int = int(0.25 * float(SR))
	var rel_n: int = int(0.55 * float(SR))
	var n_max: int = buf.size()
	for i: int in range(note_n):
		var idx: int = start_i + i
		if idx >= n_max:
			break
		var t: float = float(i) / float(SR)
		var env: float
		if i < atk_n:
			env = float(i) / float(atk_n)
		elif i > note_n - rel_n:
			env = float(note_n - i) / float(rel_n)
		else:
			env = 1.0
		var s: float = sin(TAU * freq * t) * 0.42 \
			+ sin(TAU * freq * 2.0 * t) * 0.25 \
			+ sin(TAU * freq * 3.0 * t) * 0.15 \
			+ sin(TAU * freq * 4.0 * t) * 0.08
		buf[idx] += s * env * gain

# Wooden clack — short percussive strike, mid-range wood body.
static func _paint_wooden_clack(buf: PackedFloat32Array, start_i: int,
		gain: float, rng_seed: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed if rng_seed != 0 else start_i
	var clack_n: int = int(0.06 * float(SR))
	var n_max: int = buf.size()
	for i: int in range(clack_n):
		var idx: int = start_i + i
		if idx >= n_max:
			break
		var tn: float = float(i) / float(clack_n)
		var t: float = float(i) / float(SR)
		var env: float = exp(-40.0 * tn)
		var body: float = sin(TAU * 850.0 * t) * 0.40 \
			+ sin(TAU * 1280.0 * t) * 0.18
		var crack: float = rng.randf_range(-1.0, 1.0) * 0.55
		buf[idx] += (body + crack) * env * gain

# Rattle — repeated tiny noise clicks over dur_s seconds.
static func _paint_rattle(buf: PackedFloat32Array, start_i: int,
		dur_s: float, gain: float, rng_seed: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed if rng_seed != 0 else (start_i + 1000)
	var n_max: int = buf.size()
	var t_off: float = 0.0
	while t_off < dur_s:
		var click_i: int = start_i + int(t_off * float(SR))
		var click_n: int = int(0.014 * float(SR))
		for j: int in range(click_n):
			var idx: int = click_i + j
			if idx >= n_max:
				break
			var tn: float = float(j) / float(click_n)
			var env: float = exp(-55.0 * tn)
			buf[idx] += rng.randf_range(-1.0, 1.0) * env * 0.35 * gain
		t_off += rng.randf_range(0.024, 0.044)

# ── High-level Norse renderers (called by NorseMusic.gd) ────────────────────

# Build a sustained drone of `dur` seconds. `notes` is an array of dicts:
#   {"midi": int, "instrument": "tagelharpa"|"throat_hum", "gain": float}
# All notes start at t=0 and run for the full duration. Drone frequencies
# are nudged to integer cycles in `dur` so the loop seam is click-free.
static func render_drone(notes: Array, dur: float) -> AudioStreamWAV:
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	for nd: Variant in notes:
		if not (nd is Dictionary):
			continue
		var d: Dictionary = nd as Dictionary
		var midi: int = int(d.get("midi", 50))
		var instrument: String = str(d.get("instrument", "tagelharpa"))
		var gain: float = float(d.get("gain", 0.20))
		var raw_f: float = _midi_hz(midi)
		var cycles: float = round(raw_f * dur)
		var f: float = cycles / dur if cycles > 0.0 else raw_f
		match instrument:
			"throat_hum":
				_paint_throat_hum(buf, 0, f, n, gain)
			_:
				_paint_tagelharpa(buf, 0, f, n, gain, midi * 17)
	_highpass(buf, 25.0)
	_normalize(buf, 0.55)
	return _wav(buf, true)

# Render one melodic phrase. `notes` is array of [midi, beats]. midi=-1
# is a rest. Returns a one-shot WAV (no loop).
static func render_phrase(notes: Array, instrument: String,
		bpm: float) -> AudioStreamWAV:
	var beat: float = 60.0 / bpm
	var total_beats: float = 0.0
	for ev: Variant in notes:
		var arr: Array = ev as Array
		total_beats += float(arr[1])
	var dur: float = total_beats * beat + 0.5  # tail for last release
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var t_beats: float = 0.0
	for ev2: Variant in notes:
		var arr2: Array = ev2 as Array
		var midi: int = int(arr2[0])
		var note_b: float = float(arr2[1])
		if midi < 0:
			t_beats += note_b
			continue
		var freq: float = _midi_hz(midi)
		var start_i: int = int(t_beats * beat * float(SR))
		var note_n: int = int(note_b * beat * 0.95 * float(SR))
		match instrument:
			"lyre":
				_paint_lyre_pluck(buf, start_i, freq, note_n, 0.55)
			"flute":
				_paint_bone_flute(buf, start_i, freq, note_n, 0.50, midi * 13)
			"horn":
				_paint_horn_call(buf, start_i, freq, note_n, 0.45)
			_:
				_paint_lyre_pluck(buf, start_i, freq, note_n, 0.55)
		t_beats += note_b
	_normalize(buf, 0.78)
	_envelope_edges(buf, int(0.01 * float(SR)))
	return _wav(buf, false)

# Render a percussion loop. `pattern` is array of [beat_offset, kind, gain]
# where kind is "drum" / "clack" / "rattle". `dur_beats` must be integer
# so the loop matches meter exactly.
static func render_percussion(pattern: Array, bpm: float,
		dur_beats: int) -> AudioStreamWAV:
	var beat: float = 60.0 / bpm
	var dur: float = beat * float(dur_beats)
	var n: int = _n(dur)
	var buf: PackedFloat32Array = _buf(n)
	var drum_buf: PackedFloat32Array = _war_drum_buf(0.9)
	for ev: Variant in pattern:
		var arr: Array = ev as Array
		var beat_off: float = float(arr[0])
		var kind: String = str(arr[1])
		var gain: float = float(arr[2]) if arr.size() > 2 else 1.0
		var start_i: int = int(beat_off * beat * float(SR))
		if start_i >= n:
			continue
		match kind:
			"drum":
				var drum_n: int = mini(drum_buf.size(), n - start_i)
				for i: int in range(drum_n):
					buf[start_i + i] += drum_buf[i] * gain
			"clack":
				_paint_wooden_clack(buf, start_i, gain, start_i * 7)
			"rattle":
				_paint_rattle(buf, start_i, 0.30, gain, start_i * 11)
	_normalize(buf, 0.72)
	return _wav(buf, true)
