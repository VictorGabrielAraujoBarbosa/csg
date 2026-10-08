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
  `OrderManager`, the `JobBoard`, the `Planner` and the workers. It listens to kitchen layout
  changes to rebuild stations, seeds the tray pool on the intake, and advances the world in
  fixed **ticks** (`tick_once()`).
- **Workers** (`scripts/workers/worker.gd` + `pathfinder.gd`) — toilet-shaped chibis that walk
  with A* on the same grid rules as placement, operate stations for the recipe's ticks and
  carry one item in front. **Workers are placed as furniture**: a `worker_post` mat spawns one
  worker whose home is that cell; idle workers walk back there. The mat's tint colours its
  worker. The mesh is a placeholder; movement and walk/work bobs are real-time interpolation.
- **JobAssignment** (`scripts/jobs/job_assignment.gd`) — the pure matcher: jobs in priority
  order, each taking the cheapest free worker (see `Service.assignment_cost`).
- **Items** — `ItemDef`/`ItemCatalog` (food + trays) and `WorldItem`: single-unit items that
  live on cells, each in its own slot. Trays are items with a payload
  `{order, recipe, dish}`.
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
   matching item, 2) else plan a producer (source or craft), 3) else warn. Amounts are satisfied
   with one item each (2 tomatoes = two source jobs), recipes are gated by their
   `station_tag`, and the cycle guard exists to break the tray loop with a real warning.
10. **Jobs are the only interface to work.** All work goes through
    `Service.claim/assign` → `finish_produce`/`finish_transfer`, which only need the job to be
    *ready* (inputs present at the station, station not busy). Work is handed out centrally:
    `Service._assign_jobs()` runs `JobAssignment.match()` with `assignment_cost()` — priority
    (age) decides who is served first, the cost function decides which worker (distance now,
    worker types later). Nothing teleports and nothing claims jobs on its own; new worker types
    or machines must plug into that same seam.
11. **Ticks are the simulation clock; real time is the animation clock.** Everything timed in
    the sim counts ticks (`RecipeDef.duration_ticks`, `walk_ticks_per_cell`, order limits) so
    runs are deterministic and testable via `run_ticks()`. Visuals (movement, pops, settles,
    worker bobs) interpolate in `_process(delta)` over real seconds (`WorldItem` and `Worker`
    are the reference implementations). Never tie animation smoothness to the tick rate, and
    never read visual positions back into the simulation.
12. **Every item is one entity in one slot.** No stacks anywhere: yields spawn that many items,
    `ItemManager` places them in a growing lattice of slots per cell, and
    `MAX_SLOTS_PER_CELL` is the future capacity hook. Recipes consume items individually.
13. **Workers exist only for placed posts.** `Service._sync_workers()` creates one worker per
    `worker_post` furniture instance and despawns them when the post goes away. Never spawn
    workers another way; the post's cell is the worker's canonical home.
14. **Docs stay honest.** When you finish something from the "Not implemented yet" list in
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
`--item-showcase` for item size/height checks, `--sim` for the tick simulation and
`--sim-ticks=N` to run an exact number of ticks (catch workers mid-action). To debug a
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
- Items never stack: one item = one slot (see `ItemManager.slot_offset`). If you need to
  "combine" items, model it as a recipe with multiple inputs, not by merging entities.
- `JobBoard.cleanup()` must keep **ACTIVE** jobs as well as PENDING ones — dropping active jobs
  strands their item reservations and station locks forever (a bug that looked like a deadlock).
- The demo map ships **furnished** (stations + points), so tests must not assume an empty
  kitchen: e.g. the planner probe clears `planner.stations` to test the refusal path.
- Workers do not collide with each other (two may share a cell) and carry exactly one item.
- Non-solid furniture (`FurnitureDef.solid = false`, e.g. worker posts) is walkable and counts
  as floor for item heights, but still occupies its cell for placement.
- Worker "go home" paths target the post cell itself (mats are walkable), unlike job paths
  which target a cell *next to* the station/item.
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
