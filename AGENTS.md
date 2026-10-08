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
- **Furniture**: `FurnitureDef` (model, auto-measured footprint, cost, tags, station zones) →
  `FurnitureCatalog` (the list) → `FurnitureInstance` (a placed or ghost piece with per-material
  tints).
- **Service** (`scripts/service/service.gd`) — the simulation: owns `ItemManager`,
  `OrderManager`, the `JobBoard`, the `Planner` and the executor. It listens to kitchen layout
  changes to rebuild stations, seeds the tray pool on the intake, and advances the world in
  fixed **ticks** (`tick_once()`).
- **PlaceholderExecutor** (`scripts/service/placeholder_executor.gd`) — ⚠ a stand-in for real
  chibi workers, loudly marked. It claims ready jobs and finishes them after the recipe's tick
  duration, up to `parallel_jobs` at once. Delete it (and `Service.executor`) when workers land.
- **Items** — `ItemDef`/`ItemCatalog` (food + trays) and `WorldItem` stacks that live on cells.
  Trays are items with a payload: `{order, recipe, dish}`.
- **Recipes** — `RecipeDef`/`RecipeCatalog`: inputs → output(s) at a station tag, with optional
  `effect` (`complete_order`) and `stamp` (`order`, `order_dish`) for payloads. Base ingredients
  get a synthetic `take_<item>` source recipe.
- **Stations** — `StationInstance`: cells, capability tags, input/output/work zones (multi-cell
  zones rotate with the piece) plus structural intake/delivery points.
- **Jobs/Planner** — `Job` (PRODUCE/TRANSFER), `JobBoard` (age+distance priority),
  `Planner` (recursive lazy resolution, reservations, warnings).
- **Controllers**: `PlaceController` (furniture), `MapPaintController` (map + colour tools),
  `CameraRig`, `LookConfig` (environment), `HUD`, all wired in `scenes/main.tscn` by
  `scripts/main.gd`.

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
   on defs. Food kit: ~3.3 units/m, hence food item `scale_mult ≈ 0.3`. Furniture surfaces carry
   named materials (`wood`, `metal`, `glass`, …); the colour tools rely on those names surviving
   import.
8. **The tray pool is finite and closed.** Trays are items, never spawned out of thin air:
   intake packs a free tray into `tray_with_order`, plate merges it with the dish, delivery
   returns `tray_dirty`, the sink washes it back. Add new tray states as items + recipes, not
   as special cases in code.
9. **Planning stays recursive and lazy.** `Planner._plan_item` must always: 1) reserve a free
   matching item, 2) else plan a producer (source or craft), 3) else warn. Amounts must be
   satisfied across jobs/stacks (2 tomatoes = two source jobs), recipes are gated by their
   `station_tag`, and the cycle guard exists to break the tray loop with a real warning.
10. **The executor is a seam for workers.** All work goes through
    `PlaceholderExecutor.tick()` → `_finish_produce`/`_finish_transfer`, which only need the job
    to be *ready* (inputs present at the station, station not busy). Real chibi workers replace
    the executor by claiming the same ready jobs and walking there — do not bake teleporting
    into game logic, and keep `PlaceholderExecutor` loudly temporary.
11. **Ticks are the simulation clock; real time is the animation clock.** Everything timed in
    the sim counts ticks (`RecipeDef.duration_ticks`, `carry_ticks`, order limits) so runs are
    deterministic and testable via `run_ticks()`. Visuals (movement, pops, settles, worker
    bobs) interpolate in `_process(delta)` over real seconds (`WorldItem` is the reference
    implementation). Never tie animation smoothness to the tick rate, and never read visual
    positions back into the simulation.
12. **Docs stay honest.** When you finish something from the "Not implemented yet" list in
    README.md (or add a new deferral), move the line so the list keeps matching reality.

## Verifying changes

The engine binary on this machine is `/home/victor/Godot_v4.7.2-stable_linux.x86_64`.
The project targets 4.7 (GL Compatibility).

```bash
# 1. must be completely silent (parse errors, runtime errors)
/home/victor/Godot_v4.7.2-stable_linux.x86_64 --headless --path . --quit-after 10

# 2. render + full self-test suite (adds --paint-demo for visual colour samples and
#    --sim for the headless order/tray-cycle simulation)
DISPLAY=:1 /home/victor/Godot_v4.7.2-stable_linux.x86_64 --path . \
  res://tools/capture.tscn -- --selftest --check --furniture --paint-demo --sim --pixeltest
```

The suite prints `[selftest] ok/FAIL …` lines and a `round-trip:` summary, and writes a
screenshot to `/tmp/opencode/kitchen.png`. **Every new feature needs assertions there**, and
anything visual needs a `--pixeltest` sample: rendered pixels are the only proof a tint or
checker is actually visible (a previous checker was invisible for days because the scene was
overexposed to pure white — the pixel test exists because of that).

Useful capture flags: `--pitch=`, `--yaw=`, `--dist=`, `--focus=x,z` for framing,
`--ambient=`, `--ssao-intensity=`, `--ssao-radius=`, `--sun=`, `--exposure=` for look tests,
`--item-showcase` for item size/height checks and `--sim` for the tick simulation. To debug a
real game run (not the capture harness), run the game with `-- --dump-events`: the service
prints its events, orders, jobs and items at shutdown.

## Gotchas

- After adding/renaming a `class_name` script, run `--import` once, otherwise other scripts
  fail with "Could not find type …" (the global class cache is stale).
- The user's Godot editor may hold an even staler cache; if the game renders gray after big
  script changes, tell them to *Project → Reload Current Project*.
- Typed arrays: `var edges: Array[Vector3i] = []` — ternaries and `Array` literals do not
  convert implicitly. Assign element by element when in doubt.
- This project treats some GDScript warnings as errors. In particular `:=` on a Variant
  ("type is being inferred from a Variant value") fails the build — annotate the type
  (`var inputs: Variant = ...`) or cast explicitly.
- Items merge into stacks per cell (same def + payload + unreserved), and station inputs are
  gathered across stacks, so "2 tomatoes" works whether they arrived as one stack or two.
- `JobBoard.cleanup()` must keep **ACTIVE** jobs as well as PENDING ones — dropping active jobs
  strands their item reservations and station locks forever (a bug that looked like a deadlock).
- Godot reports at-exit resource/leaked-instance warnings in headless runs even when the game
  shuts down cleanly; treat *script errors and runtime errors* as failures, and these cosmetic
  reports as noise (a couple come from engine internals).
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
