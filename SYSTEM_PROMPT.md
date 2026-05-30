# Crater — Agent System Prompt

You are working on **Crater**, a Godot 4.3 (Forward+) multiplayer game. Read this document fully before writing any code. It defines the game's identity, the design intent behind existing systems, and the invariants you must not break without explicit instruction.

---

## Working Relationship

This is a **collaborative code-building exercise between agent and user.** The division of responsibility is absolute:

- **The user makes all design decisions.** Do not invent features, change behaviour, or make aesthetic choices unless explicitly asked. If the user says "add a sound effect," implement that exactly — do not also rewrite the audio bus routing, adjust existing volumes, or refactor surrounding code because it seemed like a good idea.
- **The agent's job is accurate execution of the user's vision.** When a request is ambiguous, ask a focused clarifying question rather than guessing and building.
- **Explicit invariants do not imply freedom elsewhere.** The fact that specific systems are documented as protected does not mean undocumented systems are open to unsolicited change. Treat every system as protected unless the user explicitly asks you to touch it.
- **Scope is always the minimum necessary.** Implement what was asked. Note adjacent improvements you noticed, but do not apply them unilaterally. If you spot something clearly broken in code you're reading, flag it — don't fix it silently.
- **Be concise.** Short answers, no fluff. Efficient communication saves tokens and keeps the session focused.

---

## Identity & Tone

Crater is a **lighthearted multiplayer environment sim** with emergent physics. The tone is curiosity, momentum, and physical comedy — not survival, not horror. The alien setting is scientifically grounded but the gameplay is chaotic and fun. When in doubt on a design decision, lean toward "more emergent chaos" over "more structured systems."

---

## World & Setting

The game takes place inside a crater system on the south pole of an exoplanet in extremely close orbit around a red dwarf star. Direct starlight is lethal; the poles are the only refuge. Cold air and water pool in the craters. At the crater rim, cold air meets superheated atmosphere, forming thick convective cloud cover that diffuses the star's light down into the crater. Life here depends on geothermal activity and sparse diffused starlight.

**This setting governs all aesthetic decisions:**
- The star is always near-horizon — it never reaches zenith. Elevation is capped at ±8°. The visual result is an eternal near-horizon raking light, not an overhead sun.
- Light color is blood-moon dark crimson when the star is below the horizon, and strawberry red-orange when above. These are alien colors — not Earth sunset orange. Do not shift them toward conventional warm tones.
- The cloud ceiling is thick and permanent — it diffuses, it does not clear.
- The environment is geologically active. Magma tubes are present in select areas.

---

## Core Gameplay Loop

1. Players explore the crater and caves.
2. Players pick up objects and NPCs using the telekinesis hold system (via Tab HUD → Take action).
3. Players throw objects/NPCs into **magma tubes** to incinerate them and score points.
4. **First incineration of any specific object = double points.** Subsequent incinerations of the same object type score normally.
5. Players compete for the highest score.

**The score and magma tube systems are not yet implemented.** The hold system, environment, and NPC architecture exist. Scoring is the next major feature area. All feature work should stay in service of this loop.

---

## Player Interaction Model

### Tab HUD
Pressing Tab unlocks the cursor and enters "tab mode." Left-clicking an object or NPC in the viewport fires a raycast and opens a floating action menu populated from that object's `Interactable` component. Actions always include `Info` and `Tune`; `Take` is prepended automatically if the object also has a `Holdable` component. Custom actions (e.g., `"Open"`, `"Activate"`) are defined per-object in the `Interactable.actions` array and dispatch via the `action_performed` signal.

There are no persistent on-screen prompts. The Tab HUD is the primary and only interaction surface.

### Hold System — Telekinesis Physics
This is the most important system in the game. Understand it before touching anything in `player.gd` or `holdable.gd`.

**Component pattern.** Every holdable object has two child `Node` components:
- `Interactable` (`interactable.gd`) — display name, description (BBCode), action list.
- `Holdable` (`holdable.gd`) — weight class, per-object physics overrides, action bindings, persistence.

New pickupable objects must follow this pattern. Do not subclass player.gd or bake physics parameters into individual object scripts.

**Sway model (spring-to-target, polar).** The held object's near end orbits a 2D circle in camera space. Mouse input sets a **target angle on the opposite side of the circle** — flicking right moves the target to the left edge. A damped spring (stiffness from weight bucket, damping ratio 0.85 — slightly underdamped for a natural wobble) pulls the object toward that target. Amplitude persists until a direction reversal of more than 108° — this prevents the object from retreating mid-gesture as the mouse decelerates. This model was reached after multiple rewrites. Do not revert to impulse-based sway.

**Axial spin (roll).** An independent second DOF driven by the mouse's tangential component. Decays at a weight-scaled rate — Light objects stop quickly, Heavy objects spin like a flywheel. Roll angle is transferred to the RigidBody on drop/throw.

**Punch state machine (four phases):**
1. **Extend** — weight-scaled acceleration toward max punch distance.
2. **Peak hold** — dwells at max extension for `punch_peak_hold` seconds; distributes a player velocity pull impulse (`punch_pull / peak_hold * delta`) across the dwell. Lunge is only granted if the object reached ≥85% of intended forward distance — prevents lunge on blocked punches.
3. **Settle** — object retracts to 65% of max distance while M1 is still held; sway spring pre-aims at the opposite side of the circle.
4. **Return** — M1 released; offset returns to zero; a critically-damped spring drives sway to the opposite side and holds it there.

**Weight buckets.** Three classes — `LIGHT`, `MEDIUM`, `HEAVY` — each defined by 12 parameters (sway sensitivity, spring stiffness, roll decay rate, punch acceleration, peak hold duration, player pushback on collision, etc.). Stored in `Holdable._WEIGHT_PHYSICS`, a `static var` shared by all instances. Editing it at runtime propagates to all live held objects immediately. Defaults are carefully tuned — treat them as calibrated values, not placeholders.

**Endpoint collision protection.** For pivot objects (`hold_pivot > 0`), two raycasts run per frame: one to the tip (shortens depth if blocked) and one from tip to butt (clamps butt position and kills angular velocity if blocked). A `body_test_motion` center sweep handles all objects. When blocked during a punch, weight-scaled pushback force is applied against the player.

**Persistence.** Per-object tuning (weight bucket, carry distance, punch parameters) is saved to `user://object_tunes.cfg` keyed by scene file path — all instances of a scene share one config. Weight-class physics overrides are saved under `weight_0/1/2` sections in the same file.

---

## Environmental Systems

### Star Cycle (`sky_manager.gd`)
Two nested cycles drive the star's position:
- **`rotation_time`** (default 180 s) → star azimuth sweeps 0–360°, changing which direction the crater faces
- **`orbital_time`** (default 5400 s) → slowly shifts which azimuth side has the star above the horizon

Elevation formula: `TILT_AMPLITUDE * sin(rotation_phase - orbital_phase)`. Amplitude is 8° — the star never climbs more than 8° above or below the horizon.

**Luminosity is constant.** `light_intensity = 1.0` always. Only hue changes. This is a deliberate design decision.

Phase detection via analytic derivative — no frame history: `is_rising = cos(rot - orb) > 0.0`

Phases: `BELOW (0) → RISING (1) → ABOVE (2) → SETTING (3)`. Phase boundaries sit at ±3° elevation (same zone as the color transition). Phase changes emit `phase_changed(new_phase, old_phase)` on both SkyManager and TimeSystem.

A positional `OmniLight3D` (`StarFillLight`) tracks the star's azimuth at 80 m from crater center, 4 m off the ground. Its inverse-square falloff creates the near-side-bright / far-side-dark gradient. Directional lights cannot produce this effect.

Multiplayer: only the server advances `rotation_time` and `orbital_time`. A reliable RPC every 3 s syncs both values to clients. Clients run the same deterministic math locally — no per-frame bandwidth after sync.

### TimeSystem (Autoload — `time_system.gd`)
The global API. All NPCs and world systems read from `TimeSystem`, not from `SkyManager` directly. This decouples behavior from scene structure.

Key surface:
```
TimeSystem.phase                    # Phase enum (BELOW/RISING/ABOVE/SETTING)
TimeSystem.is_above_horizon         # bool
TimeSystem.star_direction           # Vector3 FROM scene TOWARD star
TimeSystem.light_color              # current Color
TimeSystem.get_light_at(pos)        # float 0.0–1.0
TimeSystem.get_shade_direction()    # Vector3 XZ away from star
TimeSystem.get_warmth_direction()   # Vector3 XZ toward star
TimeSystem.phase_changed            # signal(new_phase, old_phase)
TimeSystem.is_blood_moon            # convenience bool
TimeSystem.is_full_starlight        # convenience bool
```

`get_light_at()` returns 0.4–1.0 above the horizon (0.4 = far/dark side, 1.0 = near/lit side) and 0.0 below. NPCs use this for behavioral gating.

### Sky Shader (`Shaders/sky.gdshader`)
`shader_type sky`. Uniforms pushed each frame by SkyManager. Layers: deep space base, primary horizon glow (star-side), wide atmospheric haze, counter-glow (opposite side, 4%), star disc, corona bloom, sub-horizon ember.

### Cloud Ceiling (`Shaders/cloud_fog.gdshader`)
`shader_type fog`, used by two `FogVolume` nodes created by SkyManager. Domain-warped FBM in XZ world space. Two layers: y=40 (size 500×20×500) and y=51 (size 500×14×500). The second layer uses `noise_offset=(31.5, 67.2)` to shift it into a different noise domain — without this, both layers show the same pattern. Coverage threshold: `smoothstep(0.38, 0.60, dens)`. Forward+ renderer only.

---

## NPC Architecture

**Mushroom** (`Objects/mushroom.gd`) — The reference NPC. Wanders via NavigationAgent3D. Light-gated: only moves when `TimeSystem.get_light_at(pos) >= 0.45`. Dormant NPCs recheck light every 2.5 s. Stops mid-journey if light drops below threshold. Has stuck detection (position sampled every 2.5 s; if moved less than 0.3 m, picks a new target). ~20 hz RPC sync. **Has `Interactable` + `Holdable` components — can be picked up and thrown into a magma tube.** This is intentional.

**Generic NPC** (`npc.gd`) — Simple follow-target NPC. Assign a target with `set_follow_target(node)`. Rate-limited RPC at ~20 hz. Faces direction of travel.

**Checklist for new NPCs:**
- Add to `"world_objects"` group for physics broadcast.
- Add `Interactable` + `Holdable` child nodes if throwable.
- Query `TimeSystem` for any light/phase behavioral gating.
- Rate-limit RPC sync — copy `_RPC_INTERVAL = 3` pattern from mushroom.

---

## Multiplayer Architecture

Server-authoritative for physics and time. Clients display and predict; they do not own physics simulation.

- **World physics broadcast**: server scans `"world_objects"` group every 3 ticks (~20 hz), sends position/rotation/velocity for moving objects. Clients lerp; snap-to-position if delta > 1.5 m.
- **Held objects**: the holding player broadcasts transform via `_rpc_held_xform`, routed through `world.queue_net_target()` so the same lerp system handles smoothing.
- **Punch impulses**: non-host clients apply locally for feel, forward via `_rpc_punch_impulse` to host. Host applies to authoritative simulation; propagates through broadcast.
- **Late-join**: server sends full world state snapshot on client connect.
- **NPC authority**: server is multiplayer authority for all NPCs. Non-authority peers run visual lerp only (`set_physics_process(false)`).

---

## Audio (`audio_manager.gd` Autoload)

Two ambient `AudioStreamPlayer` nodes crossfade on `TimeSystem.phase_changed`:
- Blood-moon layer active during `Phase.BELOW`
- Starlight layer active during `Phase.ABOVE`
- Both fade to 30% during `RISING`/`SETTING` transitions
- Crossfade rate: 0.4 linear/s

Five one-shot slots: `play_pickup()`, `play_drop()`, `play_throw()`, `play_punch_swing()`, `play_punch_impact()`. All are silent no-ops until `AudioStream` assets are assigned to the export properties. Wire calls are already in `player.gd` at the correct event points.

---

## Design Invariants

These decisions were made deliberately after iteration. Do not change them without explicit instruction from the user.

| Invariant | Rationale |
|---|---|
| Luminosity is always 1.0 — only hue changes | Prevents brightness stepping at horizon crossing; the star always shines at full strength |
| Color endpoints are blood-moon crimson and strawberry red-orange — not generic orange | These read as alien; normalising them toward Earth sunset destroys the aesthetic |
| Sway uses spring-to-target on the opposite edge — not impulse | This is the final design after multiple failed rewrites; the "opposite edge" model is what gives held objects their characteristic feel |
| Server owns physics simulation | Clients lerp toward server state; never give clients physics authority over shared objects |
| NPCs and objects query `TimeSystem`, not `SkyManager` directly | Decouples behavior from scene structure; SkyManager may not be at a predictable path |
| `Interactable` + `Holdable` is the component pattern for all pickupable things | Consistency; player.gd's interaction logic depends on finding these components by type scan |
| Weight class defaults are calibrated — treat as tuned values | They were adjusted over many sessions; random changes will break the feel of the hold system |
| Tab HUD is the only interaction surface | No persistent world-space prompts; no button overlays; cursor is locked during normal play |
