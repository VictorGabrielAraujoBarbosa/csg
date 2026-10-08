# Consumer Satisfaction (Guaranteed)

A kitchen-management horror game for a game jam. You design a kitchen, your hard-working
chibis cook and serve orders, and every day more customers arrive. Fall too far behind and
the customers stop waiting and come for you.

Built with **Godot 4.7** (GL Compatibility renderer) using the Kenney CC0 3D kits.

> **Status: Prototype 3 — the chibis run the kitchen.** Grid, map authoring, furniture,
> colouring, look & feel and the full order pipeline are in: recipes, recursive job planning,
> a finite tray pool that cycles through the kitchen, money and warnings. The simulation is
> deterministic (fixed ticks), presentation interpolates in real time, and three toilet-shaped
> chibi workers walk the grid, operate stations and carry items (placeholder mesh).
> See [Roadmap](#roadmap) and [Not implemented yet](#not-implemented-yet).

---

## Running

Open `project.godot` in Godot 4.7+ and press **F5**, or from a terminal:

```bash
godot --path .
```

Controls (also shown in-game):

**Furniture mode** (default)

| Input | Action |
|---|---|
| `1`–`9` / `Tab` | pick a furniture item |
| `R` | rotate 90° |
| LMB / RMB | place / remove |
| `M` | switch to map edit mode |

**Map edit mode**

| Input | Action |
|---|---|
| `M` | back to furniture mode |
| `1`–`9`, `0` | tools: tile, plating, wall, window, doorway, low wall, erase, paint material, paint wall, tag preset |
| `Y` / `U` | order intake / order delivery point |
| `[` `]` | cycle tools |
| `C` | cycle palette colour |
| `V` | cycle paint target (whole piece → wood / metal / glass / …) |
| `Shift+P` | apply tag presets to every placed piece (one undo step) |
| LMB / RMB | paint / erase |
| `Ctrl+Z` | undo |

**Both modes:** `WASD` pan, `Q`/`E` turn the camera 90°, mouse wheel zoom, `G` toggle the
grid overlay, `F5` export the whole kitchen (map + furniture + colours) as text.

---

## Project layout

```
scenes/main.tscn                  the game scene (kitchen, camera rig, controllers, lights)
scripts/main.gd                   wires everything, UI hints, F5 export
scripts/grid/kitchen_layout.gd    map data model + the text format (to_text/from_text)
scripts/grid/kitchen.gd           builds the visuals, edit API, undo, grid queries
scripts/furniture/furniture_def.gd      what an item is (model, footprint, cost, tags, zones)
scripts/furniture/furniture_instance.gd a placed/ghost piece (tints, material names)
scripts/furniture/furniture_catalog.gd  the buyable list
scripts/items/                    item definitions + catalog + world items + ItemManager
scripts/recipes/                  recipe definitions + catalog (the burger line & tray cycle)
scripts/stations/station.gd       a station instance: cells, zones, capability tags
scripts/jobs/                     Job, JobBoard (age/distance priority), Planner (recursive)
scripts/orders/                   Order + OrderManager (queue, money, rules)
scripts/service/service.gd        runs it all: items, stations, jobs, orders, workers
scripts/workers/                  worker.gd (toilet chibi, walk/work/carry) + pathfinder.gd (A*)
scripts/ui/hud.gd                 money / orders / warnings HUD
scripts/build/place_controller.gd       furniture placement
scripts/build/map_paint_controller.gd   live map editor + colour tools
scripts/camera_rig.gd                   rotatable grid-aligned 3/4 camera
scripts/render/look_config.gd           SSAO / glow / grading / ambient panel
resources/layouts/demo_kitchen.txt      the demo map (source of truth for the level)
tools/capture.tscn, capture.gd          dev tool: screenshot + self-test suite + --sim
tools/inspect_materials.gd              dev tool: prints furniture material names
assets/                                 Kenney kits (CC0), untouched
```

## Tuning

Everything that matters is an exported node property — open `scenes/main.tscn` and select:

- **CameraRig** — pitch (50°), start yaw (grid-aligned), turn step, distance limits, FOV,
  pan speed, focus margin.
- **WorldEnvironment** (`LookConfig`) — sky colours, ambient, SSAO, glow, grading, tonemap.
  This node *owns* the Environment it builds, so these values are the source of truth.
- **Kitchen** — checkerboard (`checker_light` / `checker_dark` / `checker_amount`), floor and
  plating tints, grid overlay colour/width, structural point colours and scale.
- **ItemCatalog** — `FOOD_SCALE` / `TRAY_SCALE` (how big food and trays look; the kit is
  modelled at ~3.3 units/m).
- **MapPaintController** — tint palette, `tag_presets` (tag → colour), feedback colours.
- **Sun** / **Fill** — the two shadowless directional lights (cloudy-day look).
- **Service** — job priority (`age_weight`, `distance_weight`), tick rate
  (`ticks_per_second`), `sim_speed`, `max_ticks_per_frame`, `starting_trays`.
- **Service/Workers** — `worker_scale`, `worker_tint` (default for posts without paint) and
  `walk_ticks_per_cell`. Job priority is `age_weight`; `assignment_cost` uses `distance_weight`.
- **Service/Orders** (`OrderManager`) — `reward_per_order`, `max_pending`, `time_limit_ticks`,
  `start_orders`, `arrive_on_turn_in`, target `dish_id`.

---

## The map format

Maps are plain text: rooms are dots, walls are the lines between them. Edge cases (pun
intended) are handled automatically — any floor/void border becomes a solid wall unless you
say otherwise, so you only draw what is special.

```
 +-+-w-+        cells:  '.' floor     ':' plating floor     ' ' void
 |. . .|        edges:  - | solid     w window   d doorway   l low wall   ' ' open
 + +-d +        vertices: '+' is cosmetic (readability), ignored by the parser
 |. . :|
 +-----+
```

Then optional sections, written by the tools or by hand:

```
[colors]          x z rrggbb              per-cell floor tints
[wallcolors]      x z dir rrggbb          per-edge wall tints (dir 0 = along Z, 1 = along X)
[points]          pickup|delivery x z     structural order intake / delivery points
[furniture]       id x z steps [material=rrggbb ...]
```

In `[furniture]`, `*=rrggbb` colours the whole piece and `wood=rrggbb` colours one material
group only (`*` is also what a bare colour token means in older files).

The demo level lives in `resources/layouts/demo_kitchen.txt` and ships with a working kitchen
(stations + intake/delivery points), so `F5` shows the whole order loop immediately. The same
`F5` writes the current kitchen back out to `user://kitchen_export.txt` and prints the path, so
anything you build or paint can be pasted straight back into the layout file.

## The service loop (orders, recipes, jobs)

An order is a dish to produce and hand over. A **recipe** is a recursive requirement tree: it
lists inputs, the **station tag** that can run it, a duration and its output (with arbitrary
yields — one cheese becomes six slices, two tomatoes and a lettuce become two salads).
**Jobs** are posted to a board and picked by whoever is free, oldest first and nearest first,
so the whole chain runs itself.

The trays make a closed loop, which is the backbone of the whole system:

```
tray ──[intake: pack order]──▶ tray_with_order ─┐
                                                 ├─[assembly: plate]──▶ tray_with_finished_order
                        burger ──────────────────┘                              │
                                                                                ▼
                                        [delivery: hand over] ──▶ tray_dirty + 💰 + order complete
                                                                                │
                                        [sink: wash] ◀───────────────────────────┘
                                             └──▶ tray (back in the pool)
```

- **Lazy resolution**: for every requirement the planner first looks for a finished, free item
  and reserves it (so two orders can't grab the same burger); only if there is none does it
  plan a production step — recursively.
- **The tray pool is finite.** If every tray is dirty or in use, the intake cannot pack the
  next order; the recursion reaches the sink (wash a dirty tray back into the pool) or warns
  the player that no tray can be had.
- **Warnings**: if a station is missing (no assembly table, no sink…) or an ingredient cannot
  be sourced, the planner says so on screen instead of silently stalling.
- Base ingredients are pulled from any storage station (`storage` tag: fridge, shelf, drawer
  counter) and are **infinite** for now.
- **Workers** (currently toilet-shaped) are **placed as furniture**: a 1×1 walkable mat
  (`worker_post`) spawns a chibi whose home is that cell, and they walk back there when idle.
  The mat's painted colour tints its worker.
- **Job assignment** is central: once per tick the Service takes the ready jobs in priority
  order (oldest first) and gives each one the **cheapest free worker** (distance now, worker
  types later) — so the best worker/task coupling wins instead of whoever asked first.
- **Every item is a single entity in its own slot.** Yields spawn that many items (six cheese
  slices are six items, two salads are two) and a cell arranges items in a growing lattice, so
  nothing ever overlaps or hides behind something else. `ItemManager.MAX_SLOTS_PER_CELL` is the
  hook for limiting capacity later.

## Simulation & presentation

The simulation is **tick-based and deterministic**: everything timed (recipes, walking, order
limits) counts ticks, `Service.tick_once()` advances exactly one tick, and headless tests run
thousands of ticks instantly via `run_ticks()` / `run_until_idle()` (`sim_speed = 0`).

Rendering is **decoupled from ticks**: item and worker views interpolate between their old and
new position in *real time* (`WorldItem`, `Worker`), so a lower or higher tick rate never makes
movement choppier — the arrival pop, slot settling and the worker walk/work bobs are pure
presentation. Animations must stay in real time; never tie smoothness to the tick rate.

### Adding a recipe

1. Add the item to `ItemCatalog` (model + scale; food kit models need ~0.3).
2. Add the recipe in `RecipeCatalog._build()`: inputs, output (+ amount), `station_tag`,
   duration. That's it — the planner picks it up automatically.

## Not implemented yet

- Order arrivals by day timestamps, per-second chance rolls, periodic top-ups (only "one at
  start" and "one on every turn-in" exist).
- Losing the run: queue overflow past `max_pending`, and the per-order `time_limit` (the data
  exists and orders fail on timeout, but there is no game-over flow yet).
- Async stations (oven, deep pot) that work without a worker, progress bars, and burning food
  left too long.
- Finite food stock and purchasing (base ingredients are infinite), buying more trays.
- Worker limitations: workers can share a cell (no collision between them) and carry exactly
  one item at a time. Worker types/skills are not implemented — `Service.assignment_cost()` is
  the seam where they will change who takes which job.
- The "customers break in and eat you" horror event, day cycle, synergies, audio.

## Development tools

```bash
# the project must run clean (catches script errors)
godot --headless --path . --quit-after 10

# render the main scene and run the self-test suite
godot --path . res://tools/capture.tscn -- --selftest --check --furniture --paint-demo --sim --pixeltest
```

`tools/capture.gd` loads `scenes/main.tscn` into an offscreen viewport, places demo furniture,
runs 77 assertions (placement rules, painting, tints, undo, tag presets, recipes/stations,
presentation interpolation, text round-trip, and pixel-level checks that rendered results
actually differ), runs the order pipeline headlessly (`--sim`: a full burger order plus the
tray-recycling loop through the sink, deterministically in ticks) and saves a screenshot to
`/tmp/opencode/kitchen.png`. Extra flags: `--pitch=`, `--yaw=`, `--dist=`, `--focus=x,z`,
`--item-showcase` (spawns one of every item to check sizes/heights), `--sim` (tick-deterministic
order simulation), `--sim-ticks=N` (run exactly N ticks, to catch workers mid-action) and
`--pixeltest` (rendered-pixel checks).

For diagnosing a *real* game run, start the game with `-- --dump-events`: the service prints its
whole state (events, orders, jobs, items) when it shuts down.
`--ambient=`, `--ssao-intensity=`, `--sun=`.

`tools/inspect_materials.gd` prints the surface material names of every furniture model —
useful when adding per-material colour support for a new piece.

## Assets

Kenney 3D kits, all CC0: [Building Kit](https://kenney.nl/assets/building-kit),
[Furniture Kit](https://kenney.nl/assets/furniture-kit),
[Food Kit](https://kenney.nl/assets/food-kit),
[Retro Urban Kit](https://kenney.nl/assets/retro-urban-kit). Assets are used as-is; all
colouring and the checkerboard are runtime material tints.

## Roadmap

1. ~~Grid, authored maps, furniture placement, live map editor, colouring~~ ✅
2. ~~Orders, recipes, recursive job planning, the tray cycle, tick simulation~~ ✅
3. ~~Chibi workers: grid pathfinding, work loop, carrying, placed as furniture with spawn
   posts~~ ✅ (mesh is still a toilet)
4. Build phase & economy: money UI, buy/sell, day cycle, end-of-day summary
5. Stations & orders polish: async stations (oven/pot) with progress and burning, order queue
   rules (timed/chance arrivals, losing on overflow or timeout)
6. The horror: customers break in and eat you, day cycle pressure, synergies, audio, polish
