# AGENTS.md — working on Consumer Satisfaction (Guaranteed)

Guidance for AI agents (and humans) making changes to this repository.

## What this is

A Godot 4.7 kitchen-management horror jam game. Read `README.md` first for the game itself,
controls and the map text format. This file covers the architecture, the conventions you must
keep, and how to verify your work.

## Architecture at a glance

- **`KitchenLayout`** (`scripts/grid/kitchen_layout.gd`) — pure data: floor cells, wall edges,
  floor/wall tints, placed furniture, plus the text serialiser. No node code. Treat the text
  format as a public interface: it is the save format and people hand-edit it.
- **`Kitchen`** (`scripts/grid/kitchen.gd`) — the heart. Builds visuals from the layout,
  exposes the edit API (`paint_floor`, `paint_wall`, `paint_wall_tint`, `place_furniture`,
  `tint_furniture`, `remove_furniture*`, `undo`) and the queries the gameplay will use
  (`has_floor`, `is_walkable`, `can_place`, `can_paint_wall`, `world_to_cell`, …). Edits do
  incremental rebuilds and push undo entries.
- **Furniture**: `FurnitureDef` (model, auto-measured footprint, cost, tags) →
  `FurnitureCatalog` (the list) → `FurnitureInstance` (a placed or ghost piece with per-material
  tints).
- **Controllers**: `PlaceController` (furniture), `MapPaintController` (map + colour tools),
  `CameraRig`, `LookConfig` (environment), all wired in `scenes/main.tscn` by `scripts/main.gd`.

## Invariants — do not break these

1. **Grid model.** 1 m cells; cell `(x, z)` is centred at world `(x, 0, z)`. Walls live on
   *edges*: `Vector3i(x, z, DIR_X)` is the edge between `(x, z)` and `(x+1, z)` (its line runs
   along Z at `x+0.5`); `DIR_Z` is the edge between `(x, z)` and `(x, z+1)`.
2. **Derived walls.** An edge with no explicit entry is solid when exactly one side has floor
   and open otherwise. The engine stores only deviations, so `set_wall()` must go through
   `KitchenLayout.set_wall` (which keeps the dict sparse) — never write `walls` directly.
3. **Text format is the save file.** Any new persisted field needs: a section in `to_text()`,
   parsing in `from_text()`, and round-trip coverage in the capture self-test. Keep reading
   older files (see the bare-colour fallback in `_parse_furniture`).
4. **Tunables are exported node properties.** If you add a magic number someone would want to
   tune (speeds, colours, sizes, timings), put it in an `@export` with a sensible default and a
   doc comment. Follow the existing naming (`checker_*`, `ssao_*`, `tag_presets`, …).
5. **No assets are modified.** Everything visual is a runtime tint / shared material duplicate
   cached in `Kitchen._material_cache` keyed by source material + colour. Do not edit files
   under `assets/`.
6. **No physics.** Placement, walkability and (later) pathfinding are grid lookups. Don't add
   colliders for gameplay logic.
7. **Kenney kit facts.** Building kit: 1 unit = 1 m (2×2 m floor tile, 2.4 m tall 0.1 m thick
   walls, 2 m windows/doorways/low walls). Furniture kit: 1 unit = 0.5 m, hence `scale_mult = 2`
   on defs. Furniture surfaces carry named materials (`wood`, `metal`, `glass`, …); the colour
   tools rely on those names surviving import.

## Verifying changes

The engine binary on this machine is `/home/victor/Godot_v4.7.2-stable_linux.x86_64`.
The project targets 4.7 (GL Compatibility).

```bash
# 1. must be completely silent (parse errors, runtime errors)
/home/victor/Godot_v4.7.2-stable_linux.x86_64 --headless --path . --quit-after 10

# 2. render + full self-test suite (adds --paint-demo for visual colour samples)
DISPLAY=:1 /home/victor/Godot_v4.7.2-stable_linux.x86_64 --path . \
  res://tools/capture.tscn -- --selftest --check --furniture --paint-demo --pixeltest
```

The suite prints `[selftest] ok/FAIL …` lines and a `round-trip:` summary, and writes a
screenshot to `/tmp/opencode/kitchen.png`. **Every new feature needs assertions there**, and
anything visual needs a `--pixeltest` sample: rendered pixels are the only proof a tint or
checker is actually visible (a previous checker was invisible for days because the scene was
overexposed to pure white — the pixel test exists because of that).

Useful capture flags: `--pitch=`, `--yaw=`, `--dist=`, `--focus=x,z` for framing,
`--ambient=`, `--ssao-intensity=`, `--ssao-radius=`, `--sun=`, `--exposure=` for look tests.

## Gotchas

- After adding/renaming a `class_name` script, run `--import` once, otherwise other scripts
  fail with "Could not find type …" (the global class cache is stale).
- The user's Godot editor may hold an even staler cache; if the game renders gray after big
  script changes, tell them to *Project → Reload Current Project*.
- Typed arrays: `var edges: Array[Vector3i] = []` — ternaries and `Array` literals do not
  convert implicitly. Assign element by element when in doubt.
- Integer division (`c / 2`) is legal but noisy; keep it intentional in index math.
- `Color.is_equal_approx` is too strict after the 8-bit hex round-trip; compare with ~0.01
  tolerance (see `_color_close` in the capture tool).
- `@tool` scripts run in the editor too. `Kitchen` previews the map there; generated nodes are
  never owned so they don't get saved into the scene.

## Version control

Use **GitButler (`but`)**, never raw `git` writes (no `git add/commit/push/checkout/…`).

```bash
but status -fv                       # always start here: file + branch CLI IDs
but branch new <name>                # if the work needs a new branch
but commit <branch> -m "msg" --changes <id>,<id> --status-after
but push
```

Read-only git (`git log`, `git show --stat`) is fine.
