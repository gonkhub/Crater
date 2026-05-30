# Handoff — `hold-dynamics` Branch

**Branch:** `hold-dynamics` (merged into `shaders-and-lights`, which is the current HEAD)  
**Final commit on this work:** `dd70969` — "Rename pass: clarify structure across all branch features"  
**Primary files:** `holdable.gd`, `interactable.gd`, `player.gd`, `hud.gd`, `world.gd`

---

## What This Branch Is

`hold-dynamics` built the physical feel of picking up, holding, and using objects. Before it: objects were simply frozen RigidBodies that snapped to a carry position. After it: held objects have full angular sway driven by mouse input, axial spin as an independent DOF, a four-phase punch state machine, per-weight-class dynamics, per-object tuning saved to disk, and a full multiplayer sync layer for held objects.

The work also added the foundational interaction architecture (`Interactable`, `Holdable` as reusable node components), the HUD action menu / info popup / tune popup, and the server-authoritative world physics broadcast.

---

## Architecture Overview

Objects that can be interacted with have two optional child Node components:

```
RigidBody3D (the object)
├── Interactable    ← identity, action list, info popup data
└── Holdable        ← weight class, dynamics, per-object overrides
```

`Interactable` alone = can be examined or triggered but not picked up.  
`Interactable` + `Holdable` = can be picked up and physically manipulated.

This component pattern means new interactable objects only need these two script nodes — no subclassing, no copying physics values between scenes. The player never cares about the object's scene structure beyond finding these components.

---

## Files

### `interactable.gd` (`class_name Interactable`)
Defines identity and actions for any interactive object.

**Key exports:**
- `display_name` — shown in hover labels and action menus
- `description` — BBCode body shown in the Info popup
- `actions: Array[String]` — custom actions beyond the auto-registered ones

**Auto-registration (in `_ready`):**
- `"Tune"` is appended automatically (before Info)
- `"Info"` is always appended last

`"Take"` is prepended by `Holdable._ready()` if a Holdable component is present — designers don't list it manually.

**Runtime state:**
- `is_held: bool` — set by player.gd on take/drop; prevents other players from taking a held object (the Take action is stripped from the menu if `interactable.is_held` is true).

---

### `holdable.gd` (`class_name Holdable`)
Defines physical behaviour for a held object. Three weight classes, per-object overrides, and the full save/load system.

#### Weight Buckets (`_WEIGHT_PHYSICS`)
A `static var` — one shared table for all live Holdable instances. Editing it at runtime (via the Weight Class settings panel in the HUD) immediately affects every held object without reload.

Three buckets: `LIGHT (0)`, `MEDIUM (1)`, `HEAVY (2)`.

| Key | Description |
|---|---|
| `sway_mouse_scale` | Mouse pixels → angular velocity (rad/s/px) |
| `sway_damping` | Position damping per second (higher = snappier return) |
| `sway_spring_k` | Spring stiffness pulling sway toward target edge |
| `sway_max_speed` | Hard cap on sway angular velocity (rad/s) |
| `sway_sensitivity` | Mouse pixels/frame to reach full-amplitude deflection |
| `roll_damping` | Axial spin decay per second (lower = spins longer) |
| `max_roll_speed` | Hard cap on axial spin (rad/s) |
| `punch_pull` | Player velocity impulse (m/s) fired once at punch peak |
| `punch_accel` | Extend-phase acceleration (m/s²) |
| `punch_peak_hold` | Dwell time at max extension before settling (s) |
| `punch_settle_spd` | Retraction speed from peak to M1-held position (m/s) |
| `punch_pushback` | Acceleration (m/s²) pushed back on player when punch is blocked by geometry |

**Defaults (do not blindly reset — these were tuned over many iterations):**

| | Light | Medium | Heavy |
|---|---|---|---|
| sway_mouse_scale | 0.010 | 0.006 | 0.003 |
| sway_damping | 0.30 | 0.40 | 0.60 |
| sway_spring_k | 14.0 | 10.0 | 6.0 |
| sway_max_speed | 8.0 | 5.5 | 3.5 |
| sway_sensitivity | 18.0 | 32.0 | 52.0 |
| roll_damping | 0.08 | 0.05 | 0.02 |
| max_roll_speed | 15.0 | 8.0 | 4.0 |
| punch_pull | 2.0 | 5.0 | 10.0 |
| punch_accel | 220.0 | 120.0 | 55.0 |
| punch_peak_hold | 0.06 | 0.12 | 0.20 |
| punch_settle_spd | 1.2 | 0.9 | 0.6 |
| punch_pushback | 6.0 | 14.0 | 28.0 |

#### Editor Exports

**Hold group:**
- `hold_rotation: Vector3` — local Euler offset to align the mesh's "forward" axis with the carry pivot direction. Example: `(-90, 0, 0)` rotates a Y-axis capsule to point toward the anchor.
- `hold_pivot: float` — half-length of the object along the hold axis (metres). Defines sway circle radius. `0` = compact carry with no pivot sway.
- `weight: Weight` — weight bucket enum.

**Actions group:**
- `m1_action` — what left-click does while holding. Built-ins: `"punch"`, `"throw"`. Default: `"punch"`.
- `m2_action` — right-click action. Default: empty.
- `scroll_up_action` — scroll-up action. Default: `"throw"`.

**Physics Overrides group:**
Per-object overrides for weight-bucket values. Leave at `0.0` to inherit from the bucket. Non-zero replaces that specific parameter for this object only.

**Carry / Punch Overrides groups:**
Per-object overrides for player-global carry and punch values (`carry_distance`, `max_carry_dist`, `throw_speed`, `punch_distance`, `punch_impulse`, `punch_cooldown`). `0.0` = use player default.

#### `get_dynamics() -> Dictionary`
Returns the effective physics dict: bucket values with any non-zero per-object overrides applied. This is called once per frame by `player.gd` to get all dynamic parameters.

#### Save / Load System
Save path: `user://object_tunes.cfg` (ConfigFile).

Two layers of persistence in the same file:
1. **Per-object tuning** — keyed by `scene_file_path`. All instances of the same scene share one saved config. Example section: `[res://Objects/stick.tscn]`
2. **Weight-class physics** — keyed by `weight_0`, `weight_1`, `weight_2`. Overrides the defaults in `_WEIGHT_PHYSICS` for all objects of that class.

Load order in `_ready()`:
1. `load_weight_physics()` — runs once (guarded by `static var _physics_loaded`); loads global weight-class overrides into the live table.
2. `_apply_saved_tune()` — loads per-object field values for this specific scene.

---

### `player.gd` — Hold System

The player owns all hold state. The held object is a frozen RigidBody3D (or CharacterBody3D for NPCs) that the player repositions every `_process` frame.

#### Hold State Variables (all reset by `_clear_hold_state()`)

```gdscript
_held_object:       PhysicsBody3D   # the frozen body
_held_interactable: Interactable    # component cache
_held_holdable:     Holdable        # component cache

# Sway (position on circle, 2D polar)
_sway_angle:    float   # current angle of the close end on the sway circle
_sway_ang_vel:  float   # angular velocity (rad/s)
_sway_target:   float   # spring target angle
_sway_amplitude:float   # 0–1 deflection magnitude
_sway_direction:float   # angle of last significant mouse input

# Roll (axial spin, independent DOF)
_roll_angle:    float
_roll_ang_vel:  float

# Punch state machine
_punch_offset:    float   # current extension depth beyond carry distance
_punch_vel:       float   # extension velocity (m/s)
_punch_held:      bool    # M1 currently down
_punch_peaked:    bool    # has reached max extension this punch
_punch_hold_timer:float   # countdown at peak before settling
_punch_returning: bool    # sway spring driving to opposite side
_punch_start_angle:float  # sway angle when punch began (for opposite-side target)
_lunge_active:    bool    # player pull impulse is firing (peak dwell only)

_mouse_delta: Vector2     # accumulated mouse movement since last _update_held_object
```

#### Sway Model

Sway is a **spring-to-target** system on a circle. The object's close end orbits a 2D circle centered on the carry anchor. Mouse input doesn't directly push the angle — it sets a **target angle** on the opposite side of the circle from the mouse direction.

```
Mouse moved RIGHT → target angle = LEFT edge of circle
```

This is intentional: it creates the feel of the object lagging behind and being dragged, rather than mirroring the mouse.

**Amplitude persistence:** `_sway_amplitude` tracks the deflection magnitude (0 = rest, 1 = full opposite edge). It only decays on a direction reversal of >108° — otherwise, it holds or grows. This prevents the object from retreating mid-gesture as the mouse decelerates.

**Spring parameters:** `sway_spring_k` stiffness, damping ratio `0.85` (slightly underdamped) — produces a gentle wobble at the edge that reads as natural weight, not dead-stop.

#### Punch State Machine

Four phases, controlled by `_punch_held` (M1 down) and `_punch_peaked`:

```
Phase 1 — Extend:
  _punch_held = true, _punch_peaked = false
  _punch_vel += w_punch_accel * delta
  _punch_offset approaches eff_punch_dist

Phase 2 — Peak hold:
  _punch_peaked = true, _punch_hold_timer > 0
  Dwells at max extension for w_peak_hold seconds.
  Fires player velocity pull impulse (w_pull / w_peak_hold * delta) if lunge granted.
  Lunge is only granted if the object actually reached 85% of intended extension
  (prevents a lunge trigger on a blocked punch).

Phase 3 — Settle (M1 still held):
  _punch_hold_timer <= 0, _punch_peaked = true
  Object retracts to PUNCH_SETTLE_FRAC (0.65) of max distance.
  Sway spring pre-aimed at _punch_start_angle + PI (opposite side).

Phase 4 — Return (M1 released):
  _punch_held = false
  _punch_offset returns to 0 at PUNCH_RETURN_SPEED.
  If punch had peaked: sway springs to opposite side (_punch_returning = true).
  _punch_returning clears when offset ≤ 0.001, angle error < 0.08 rad, ang_vel < 0.1.
```

**Opposite-side spring** (during `_punch_returning`): critically-damped (`spring_d = 2 * sqrt(spring_k)`), stiffer than normal sway. Ensures the object swings to the far side of the player's view after a punch instead of snapping back to center.

#### Endpoint Collision Protection

For objects with `hold_pivot > 0`, two raycasts run every frame:

1. **Ray 1 (tip/anchor):** Camera → intended tip position. If blocked, depth is shortened so the tip can't clip into geometry.
2. **Ray 2 (butt/close end):** Tip → intended butt position. If blocked, the butt is clamped and `_sway_ang_vel` is zeroed — prevents the object from continuing to push into a surface.

Additionally, `PhysicsServer3D.body_test_motion()` sweeps the object's collision shape through the frame's displacement, clamping the center if blocked. When the object is blocked during a punch, `w_pushback * delta` is subtracted from the player's velocity in the punch direction (weight-scaled pushback).

#### Player Global Defaults (player.gd top-level vars)

These are the fallbacks used when a Holdable has no per-object override:

```gdscript
CARRY_DISTANCE   = 2.0 m      # distance in front of camera
CARRY_OFFSET_Y   = -0.35 m    # downward offset from camera center
MAX_CARRY_DIST   = 7.0 m      # tether limit before auto-drop
PUNCH_DISTANCE   = 1.5 m      # max extension
PUNCH_ACCEL      = 120.0 m/s² # (overridden by weight bucket)
PUNCH_IMPULSE    = 10.0 N·s   # applied to hit RigidBodies
THROW_SPEED      = 15.0 m/s   # added to player velocity
PUNCH_COOLDOWN   = 0.5 s
PUNCH_SETTLE_FRAC= 0.65       # settle at 65% of extension while M1 held
ENDPOINT_MARGIN  = 0.06 m     # minimum clearance between endpoints and surfaces
```

#### Tab Mode + Interaction Flow

**Tab** toggles `_tab_mode`. When active:
- Mouse is freed from capture
- Hover label shows object names under cursor
- Left-click raycast → shows action menu if an Interactable is hit
- Right-click opens action menu context / cancels pending spawn

Action menu choices flow through `_on_action_chosen()`:
- `"Take"` — freezes object, sets collision exceptions, caches components, switches to captured mouse
- `"Info"` — opens info popup via HUD
- `"Tune"` — opens tune popup via HUD
- anything else — emits `interactable.action_performed` for custom handling

---

### `hud.gd` — Action Menu, Info Popup, Tune Popup, Dev Panel

#### Action Menu
Floating button list shown at the mouse position when Tab-clicking an interactable. Emits `action_chosen(action, target)` to `player.gd`. Strips `"Take"` from the list if the object is currently held by anyone (`interactable.is_held == true`).

#### Info Popup
Floating panel with `display_name` header and `description` body (RichTextLabel, BBCode supported). Opened via the "Info" action.

#### Tune Popup
Opened via the "Tune" action on any holdable object. Dynamically built from `holdable.tune_schema()`:
- `"dropdown"` entries → `OptionButton` (used for weight bucket)
- `"number"` entries → `SpinBox` with min/max/step

Changes call `holdable.save_tune_value(prop, value)` which writes to `user://object_tunes.cfg` immediately. Changes to `weight` take effect on the live object immediately (the bucket lookup in `get_dynamics()` is per-frame).

#### Weight Class Settings (Pause Menu)
Three sections (Light / Medium / Heavy), each with 12 `HSlider` widgets covering all dynamic parameters. Sliders call `Holdable.save_weight_physics(weight_idx, key, value)` which updates the live `_WEIGHT_PHYSICS` static table and persists to disk. Because `_WEIGHT_PHYSICS` is static, changes apply to all live Holdable instances immediately — no scene reload needed.

#### Dev Panel
Separate floating window (not the pause overlay). Accessed via a different keybind. Contains:
- **Settings** — player move/jump/interaction tuning sliders
- **Spawn** — object spawn picker
- **Weather** — sky telemetry readout (added in `shaders-and-lights` branch)

---

### `world.gd` — Multiplayer Physics Sync

#### Server → All Clients: World Physics Broadcast
Server scans all nodes in the `"world_objects"` group every `_BCAST_INTERVAL` physics ticks (3 ticks = ~20 hz at 60 hz physics). Only sends objects that are moving (or had one trailing frame of movement — ensures final rest position syncs). Clients receive position, rotation (as Quaternion), linear_vel, and angular_vel; store in `_net_targets`; lerp in `_process`.

**Snap threshold:** If the received position is >1.5 m from current, the object snaps instantly (desync recovery).

#### Server ← Client: Held Object Transform
Holding players broadcast their held object's transform every physics tick via `_rpc_held_xform` (unreliable_ordered). This routes through `world.queue_net_target()` so the same lerp system handles smoothing — held objects don't teleport for other clients.

#### Punch Impulse Forwarding
Non-host clients apply punch impulses locally for immediate feel, then forward via `_rpc_punch_impulse` to the host. The host applies the impulse to the authoritative physics simulation, which then propagates to all clients through the normal broadcast.

#### Late-Join World Sync
When a new peer connects, the server sends a full snapshot of all world objects (position, transform, velocity, held state) via `_rpc_recv_object_state`. This ensures late-joining clients don't see objects at their spawn origins.

#### Dynamic Spawning
`world.spawn_object(scene_path, pos)` — client calls this, routes to server, server spawns + broadcasts. Late-joiners receive a list of all dynamically spawned objects on connect.

---

## Issues Encountered & Workarounds

### Sway Model Evolution (Multiple Rewrites)

The sway system went through several complete rewrites:

1. **Angular velocity impulse model:** Mouse input added directly to `_sway_ang_vel`. Problem: fast mouse input caused the object to orbit wildly with no settling; slow mouse did nothing. Abandoned.

2. **Polar angular model with impulses:** Switched to a polar coordinate model (object moves on a circle). Still impulse-driven. Problem: even with damping, the feel was "slippery" — the object kept orbiting past the target point.

3. **Spring-to-target model (current):** Mouse direction computes a target angle on the *opposite* side of the circle; a damped spring pulls toward it. The key insight: the target is persistent and holds its position, so the object naturally rests at the edge after a flick rather than orbiting past it.

4. **Amplitude persistence bug (fixed in `cf0c038`):** The sway target was resetting to the rest angle when the mouse slowed, causing the object to retreat mid-gesture. Fixed by separating `_sway_amplitude` (persists until direction reversal) from `_sway_direction` (updates continuously from mouse).

### Punch "Propfly" Bug (Fixed in `967c6dc`)

Early punch implementation granted the player pull impulse every frame during peak hold rather than distributing it over the dwell time. At low `punch_peak_hold` values this fired the player across the map in one frame. Fix: `velocity += punch_dir * (w_pull / w_peak_hold) * delta` — distributes the total pull over the dwell duration regardless of framerate.

### Opposite-Side Spring Not Holding (Fixed in `967c6dc`)

After punch retraction, the sway spring would spring to the opposite side but then drift back to the mouse-driven target on the next input frame. Fix: when `_punch_returning` completes, both `_sway_target` and `_sway_direction` are set to the return angle — the next mouse input starts from that position rather than overwriting it from stale direction state.

### Held-Object Tunnelling Through Thin Geometry

Released/thrown objects at high velocity would pass through thin floors and walls (one-frame physics step larger than geometry thickness). Fix: `continuous_cd = true` set on the RigidBody immediately before unfreezing (`_drop_object`, `_throw_object`, `_rpc_drop_object`). Applied on all peers so CCD is active everywhere.

### Floor Tunnelling on Lerp Snap

Non-authority players receiving large position deltas (e.g. on late join) would momentarily appear underground, then snap up. Fix: snap threshold at 1.5 m — above that, position is set directly; below that, lerp is used. This prevents the lerp from overshooting and clipping through floors.

### Cave Collision (GLB Import Limitation)

The cave mesh (GLB file) had no collision because the Godot 4 GLB importer ignores the `_subresources` physics flags in project settings for static geometry. Fix: `_build_mesh_colliders()` in `world.gd` recursively walks the imported scene and calls `create_trimesh_collision()` on every `MeshInstance3D` at runtime. This is called once in `_ready()` after the scene loads.

### Held-Object Host Sync Gap

When a non-host player held an object, the host would continue broadcasting the object's last *unfrozen* position from the world physics broadcast (because frozen objects are skipped in the broadcast scan). Other clients saw the object frozen at its pre-take position. Fix: held object transforms are routed through `world.queue_net_target()` — the same lerp table used by the physics broadcast — so the system handles smoothing uniformly regardless of whether the object is frozen or live.

### Collision Exceptions for Held Objects

Without collision exceptions, the player would collide with their own held object when extending a punch or when the carry position overlapped the player capsule. Fix: `add_collision_exception_with()` called on both the player and the held object on Take; `remove_collision_exception_with()` on both on drop/throw (in `_clear_hold_state()`). The exceptions are bidirectional — both sides must be cleared.

---

## Component Setup for New Objects

To make a new object interactable:

1. Create a `RigidBody3D` scene (or use an existing one)
2. Add an `Interactable` node (script: `interactable.gd`)
   - Set `display_name`
   - Set `description` (BBCode supported)
   - Leave `actions` empty unless you need custom actions beyond Take/Tune/Info
3. Add a `Holdable` node (script: `holdable.gd`)
   - Set `weight` (LIGHT / MEDIUM / HEAVY)
   - Set `hold_pivot` — half-length along the hold axis. `0.15` for compact objects, `0.5–0.7` for weapons/sticks.
   - Set `hold_rotation` if the mesh's "forward" doesn't naturally point away from the player
   - Leave all overrides at `0` to inherit weight-bucket defaults
4. Add the object to the `"world_objects"` group so the multiplayer broadcast includes it

The player finds `Interactable` and `Holdable` by scanning the object's children — no specific child order required.

---

## What's Not Yet Done

- **M2 action wiring:** `m2_action` is exported and dispatched but no built-in handler exists for it beyond emitting `action_performed`. Right-click while holding currently does nothing for most objects.
- **NPC hold (CharacterBody3D path):** The player can technically pick up CharacterBody3D nodes (the mushroom NPC for example) — it freezes their physics process. This is rough and untested in multiplayer. Physics hand-off on release is not properly synced.
- **Tune popup weight-class physics sliders:** The pause-menu Weight Class sliders exist and save correctly, but there's no "reset to defaults" button. If a user dials in a bad value, they must either know the default or delete `user://object_tunes.cfg`.
- **Network authority for Tune changes:** Tune popup changes are applied locally only — they are not broadcast to other clients. Each client has its own `object_tunes.cfg`. In multiplayer, different clients may have different tuning for the same object.
- **Throw angular velocity for CharacterBody3D:** When throwing a CharacterBody3D, `_roll_ang_vel` is not transferred (CharacterBody3D doesn't have `angular_velocity`). The NPC tumbles with no spin.
