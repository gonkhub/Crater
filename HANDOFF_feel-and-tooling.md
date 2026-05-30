# Crater — Session Handoff
*Generated after merging `feel-and-tooling` into `main`. Last commit: `9faf553`.*

---

## Project Snapshot

Crater is a Godot 4 multiplayer sandbox — a crater environment with a moving alien star,
holdable physics objects, and NPCs. The codebase is GDScript throughout.

**Repo:** `C:\Users\EV-02\Documents\GitHub\Crater`
**Current branch:** `main` (clean, up to date with origin except for the
`feel-and-tooling` remote which is 1 commit behind — ignore it)
**Active branches to be aware of:** `shaders-and-lights` (already merged into main content-wise)

---

## Architecture — Key Files

| File | Purpose |
|---|---|
| `player.gd` | Local player: movement, hold/carry, punch/lunge, tab-mode HUD interaction, RPC sync |
| `hud.gd` | CanvasLayer overlay: action menu, info popup, Dev sidebar + all floating windows |
| `holdable.gd` | Component (child Node) marking an object as carryable; weight buckets, tune schema, persistent settings |
| `interactable.gd` | Component (child Node) tagging any object for raycast/action-menu discovery |
| `world.gd` | Scene root: player instantiation, object spawn/despawn, physics broadcast, sky bootstrapping |
| `npc.gd` | CharacterBody3D NPC: host-authoritative nav, rate-limited RPC position sync |
| `audio_manager.gd` | Autoload: ambient crossfade driven by `TimeSystem.phase_changed`, one-shot SFX |
| `time_system.gd` | Autoload: star phase (ABOVE/RISING/SETTING/BELOW), signals, spatial light helpers |
| `sky_manager.gd` | Child of world root: drives star azimuth/elevation cycle, colour, shader params |

### Component pattern
Every interactive world object has two sibling children:
- **`Interactable`** — display name, description, action list (`actions: Array[String]`).
  `"Info"` is auto-appended in `_ready()`. `"Take"` is auto-prepended by `Holdable`.
- **`Holdable`** *(optional)* — weight bucket, carry/punch/throw overrides, orientation.
  Must be a direct child of the physics body (same parent as Interactable).

---

## Hold / Feel System (fully merged)

### Weight buckets
`Holdable._WEIGHT_PHYSICS` is a static table (shared across all instances) with three
rows — LIGHT / MEDIUM / HEAVY. Each row contains:

```
sway_mouse_scale, sway_damping, sway_spring_k, sway_max_speed, sway_sensitivity,
roll_damping, max_roll_speed,
punch_pull, punch_accel, punch_peak_hold, punch_settle_spd, punch_pushback, punch_cooldown
```

- Edited live via **Dev → Hold** floating window (tab-accessible slider + spinbox per row).
- Persisted to `user://object_tunes.cfg` under sections `weight_0 / weight_1 / weight_2`.
- Reset with the per-weight "↺ Reset to Defaults" button.
- `get_default_physics()` holds the factory values the reset button restores from.

### Punch / Lunge phases (in `player.gd _update_held_object`)
1. **Extend** — accelerated by `punch_accel` up to `eff_punch_dist`
2. **Peak hold** — dwells at max for `punch_peak_hold` seconds; lunge fires here
3. **Settle** — retracts to `PUNCH_SETTLE_FRAC * eff_punch_dist` at `punch_settle_spd`
4. **Return** (M1 released) — retracts to 0 at `PUNCH_RETURN_SPEED`

### Lunge lock (`_lunge_locked`)
- Set `true` when `_lunge_active` fires (Phase 1→2 transition).
- Clears only when `_punch_offset <= 0.001` in Phase 4 (object at neutral carry position).
- Punch animation always runs on cooldown — only the velocity pull impulse is gated.

### Cooldown resolution in `_start_punch()`
Per-object `punch_cooldown` export → weight-bucket `dyn.get("punch_cooldown")` → player constant `PUNCH_COOLDOWN`.

---

## Dev Sidebar System (fully merged)

Tab key toggles **tab mode**. In tab mode:

- **Dev sidebar** — narrow persistent strip (top-right by default, draggable, position
  remembered across Tab cycles).
- **Section windows** — each sidebar button lazily creates its own independent floating
  window (Player, World, Settings, Hold, Spawn, Weather). Each window is draggable,
  closeable, and its open/closed state is snapshotted when Tab closes and restored
  when Tab reopens.
- **Direct-action buttons** (no window): **Tune**, **Despawn** — activate a mode with a
  banner label, Esc to cancel.

### Tune mode (new)
- Press **Tune** in sidebar → cyan banner appears at top of screen.
- Click any holdable object → a draggable floating window opens for that object.
- Window is keyed by `scene_file_path` — clicking another instance of the same scene
  brings the existing window to front rather than opening a duplicate.
- Changes propagate **live to all instances** of the same scene via
  `get_tree().get_nodes_in_group("holdables")` in `save_tune_value()`.
- Changes also persist to `user://object_tunes.cfg` and are loaded by `_apply_saved_tune()`
  in each Holdable's `_ready()`.

### Tune schema (defined in `Holdable.tune_schema()`)
Supports four entry types:
- `"group"` — section header (label only, no prop)
- `"dropdown"` — OptionButton (stores int index)
- `"number"` — SpinBox (stores float)
- `"vector3"` — three labelled X/Y/Z SpinBoxes (stores Vector3; used for `hold_rotation`)

Current schema: Weight Bucket → **Hold** group (Rotation°, Pivot Length, Carry Distance,
Max Tether) → **Combat** group (Punch Distance, Punch Force, Throw Speed).

### Focus / Tab traversal
`_disable_focus_recursive(node)` sets `FOCUS_NONE` on the root node and all descendants.
Called twice for section windows: once before `add_child` (static tree) and once after
(catches SpinBox's runtime-created internal LineEdit).

---

## Sky & Time System (merged from `shaders-and-lights`)

`TimeSystem` is an **Autoload singleton** — use it everywhere, not `SkyManager` directly.

```gdscript
TimeSystem.phase              # TimeSystem.Phase enum: ABOVE / RISING / SETTING / BELOW
TimeSystem.is_above_horizon   # bool
TimeSystem.elevation_deg      # float
TimeSystem.star_direction     # Vector3 (world-space toward star)
TimeSystem.get_light_at(pos)  # float 0–1, accounts for shade
TimeSystem.phase_changed      # signal(new_phase: int, old_phase: int)
```

`SkyManager` is found via group: `get_tree().get_first_node_in_group("sky_manager")`.
It exposes `dev_set_paused / speed / rotation_time / orbital_time / elevation_override`
for live tuning — these are already wired to the **Dev → Weather** window.

**Mushrooms** (`Objects/mushroom.gd`) gate movement on `TimeSystem.get_light_at(pos) >= 0.45`.

---

## What Is NOT Done Yet

### High priority
- **Tune schema needs scene-level cleanup** — any scenes (stick.tscn, mushroom.tscn, etc.)
  that still have `"Tune"` listed in their Interactable `actions` export array should
  have it removed. `interactable.gd` no longer auto-registers it; it won't crash if
  left in (falls through to `action_performed` with no listener) but clutters the menu.

### Medium priority
- **Hold window sliders in the Dev sidebar** — the Hold window exists and works, but its
  sliders do not yet live-update already-held objects. Changes take effect on next pickup.
- **Nocturnal NPC behaviour** — `TimeSystem.Phase.BELOW` / `is_blood_moon` signals are
  wired but nothing reacts to them yet. Mushrooms only check light level, not phase.
- **Cloud art direction** — FogVolumes work but coverage / density / drift / altitude
  have not been tuned in-game.

### Low priority / future
- **More spawnable objects** — `_SPAWNABLE` in `hud.gd` lists only Stick and Mushroom.
  Extend to add more world objects.
- **Audio cycle** — `AudioManager` crossfades blood-moon / starlight ambient layers, but
  no world events trigger sounds beyond player interaction SFX.
- **NPC dialogue / Follow behaviour** — `npc.gd` has `set_follow_target()` but no
  Interactable action wires it up. The `action_performed` signal is ready to use.

---

## Patterns & Conventions

- **Never hardcode node paths** — use groups (`get_first_node_in_group`) or signals.
- **Multiplayer guard** — every `_physics_process` / `_process` that does authoritative
  work starts with `if not is_multiplayer_authority(): return`.
- **RPC naming** — `_rpc_<verb>_<noun>` pattern. Unreliable for position, reliable for
  state changes.
- **Per-object physics** — always resolve as: per-object export override (if > 0) →
  weight-bucket value → player constant fallback.
- **No match-case growth in player.gd** — new interactable actions connect to
  `interactable.action_performed` on the object side; `player.gd` does not grow new
  match arms for content actions.
- **ConfigFile sections** — `user://object_tunes.cfg` uses scene path as section key for
  per-object tunes, and `weight_0 / weight_1 / weight_2` for bucket overrides.
