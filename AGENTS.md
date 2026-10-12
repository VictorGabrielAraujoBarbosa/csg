# AGENTS.md — working on Consumer Satisfaction (Guaranteed)

Guidance for AI agents (and humans) making changes to this repository. Read this file first
(it is the durable memory of the project), then `README.md` for the game itself.

## Status & history

| Milestone | Commit | What landed |
|---|---|---|
| Prototype 1 | `c5e0877` | 1 m grid + text map format, `Kitchen` builder, live map editor + colour tools, furniture placement, camera/look config, persistence, capture tool + self-tests |
| Prototype 2 | `0b05843` | Tick-based deterministic simulation (10/s), real-time presentation interpolation, order/recipe/job pipeline + finite tray cycle, visibility fixes (cartoon-big items, centred points, measured surface heights) |
| Prototype 3 | `14f22b6` | Real workers (toilet chibis: A*, operate, carry), workers as placed furniture with tinted posts + home return, central priority-ordered assignment, one-item-per-slot, placeholder executor deleted |
| **Prototype 4** | (this commit) | Build phase & day phase: buy catalog, seeded day schedules, order modifiers as recipe variants, order-card UI over a rounded kitchen viewport, day win/loss, money, drag-and-drop rearranging |

Current verification baseline: **142 self-tests green**; deterministic sim = first burger ~234
ticks, 4 orders incl. tray wash ~696 ticks, all workers back home when the board empties; one
full headless day (day 1: 725 ticks, 3/3 served, gate clean) plus the loss path.

## Current work: Prototype 5 (not started) — economy & stations polish

Prototype 4 is done. Next up, in rough order: selling appliances, day-start shop stock, async
stations (oven/pot) with progress bars and burning, modifier stations (fries need a fryer),
queue-pressure tuning, then the horror event (customers break in and eat you).

### Prototype 4 spec — what was built (reference)

**Phases.** `DayController` runs `BUILD → DAY → SUMMARY → BUILD`.
- Build: kitchen viewport fullscreen; the player rearranges appliances and buys new ones from a
  temporary catalog panel; a Start Day button begins the day.
- Day: viewport animates to the **left ~2/3 with rounded corners**; a dark **dot-matrix
  blueprint** background sits behind it; the right panel shows **order cards** sliding in from
  the top (dish photo from the food-kit previews + modifier lines like "- no cheese" / "+ fries").
- Summary: served/lost, money earned; then back to build.

**Day schedule (deterministic).** `DayPlan` is generated from **(day number, seed)** with a
seeded `RandomNumberGenerator`, producing `arrivals: [{tick, dish, adds, removes}]`.
- Day 1: **3 orders over 600 ticks** (60 s); **+1 order and +120 ticks per day** after.
- No new arrivals after the planned last slot; the day **extends only while orders are pending**.
- The day ends when every arrival has fired **and** no orders are pending → SUMMARY.

**Loss (simple, no horror visuals yet).** A day fails if pending orders exceed `max_pending`
(5) or any order's age passes `time_limit_ticks` (600). The summary reports the loss; the
customers-burst-in event is a later step.

**Money.** Starts at **$250**, carries across days; buying deducts `FurnitureDef.cost`; no
selling yet. Prices already exist on every def.

**Modifiers (3 adds + 3 removes).** Adds (base items from storage): `fries`, `sauce`,
`extra cheese slice`. Removes: `no meat` (patty_cooked), `no cheese` (cheese_slice),
`no salad` (salad).
- Implemented as **runtime recipe variants**: the dish recipe with removed inputs filtered out,
  cached by a variant id; the dish item carries `payload["variant"]`.
- Generalise the existing `needs_order` input spec into a small `payload_match` rule
  (`{"order": "$order"}` / `{"variant": "burger__no_cheese"}`), so trays match by order and
  dishes match by variant. Pre-making dishes ahead must keep working.

**Gate to start the day.** `Planner` gets a **dry-run mode** (no jobs/reservations) and the
controller checks every dish+variant the day can ask for, plus "at least one worker post".
Start Day is disabled with the reasons shown (reuse the existing warning strings).

**Build-phase feel.** LMB picks up an appliance: it lifts and **lags behind the mouse with
inertia** (exponential smoothing, same for purchase ghosts), green/red validity, LMB drops it
(new `Kitchen.move_furniture()`, undoable), RMB returns it home. Camera: build ≈ 15 m distance,
day start animates to ≈ 22 m so the whole restaurant is visible.

**UI assets available** (`assets/`): `kenney_ui-pack` (Grey `button_rectangle_line` outlined
buttons, checkboxes, sliders, arrows; `Double/` = 2×), `kenney_game-icons` (+ expansion) for
toolbar/catalog/warning icons, `kenney_interface-sounds` (100 ogg: `click_*`, `drop_*`,
`confirmation_*`, `bong_*`) for feedback, food-kit previews (64×64) as dish photos and modifier
chips, furniture isometric renders as catalog icons. **Font: Godot default** (user's call).
Panels/cards/dot background: `StyleBoxFlat` + a tiny shader (no assets needed).
Reference diagram: `docs/day-phase-reference.png` (kitchen fullscreen → left viewport with
rounded corners + order cards on the right).

### How it was built (for the next phase, which follows the same shape)

1. **Logic, headless-testable**: `DayPlan` + `DayController` + phases + loss checks; modifiers
   (variant recipes + `payload_match`); dry-run gate; tests: schedule determinism, arrivals fire
   on exact ticks, day end after last order, variant planning (no-cheese burger plans without
   cheese; fries get fetched; a stale variant cannot satisfy an order), gate reasons, purchase
   + money; and one **full headless day** (build → start → serve all → summary → build).
2. **UI pass**: `SubViewport` restructure (kitchen world inside; UI stays outside; input
   forwarding must keep the map editor and placement working), rounded-corner shader, blueprint
   background, order cards with slide-in/out tweens, catalog panel, Start Day button, camera
   transition, a few interface sounds. Verify with screenshots against the diagram.
3. **Build-phase polish**: pick-up/move with inertia + undo, purchase flow spending money.

### Deferred (documented in README)

The customers-burst-in horror event; selling appliances; modifier stations (fries needing a
fryer); async stations + burning; endless mode; save/load; real character art.

## Architecture at a glance

- **`KitchenLayout`** (`scripts/grid/kitchen_layout.gd`) — pure data: floor cells, wall edges,
  floor/wall tints, structural points, placed furniture, plus the text serialiser. No node code.
  Treat the text format as a public interface: it is the save format and people hand-edit it.
- **`Kitchen`** (`scripts/grid/kitchen.gd`) — the heart. Builds visuals from the layout, exposes
  the edit API (`paint_floor`, `paint_wall`, `paint_wall_tint`, `place_furniture`,
  `move_furniture` + `begin_grab`/`cancel_grab` for drag-and-drop, `tint_furniture`,
  `remove_furniture*`, `paint_point`, `undo`) and the queries gameplay uses (`has_floor`,
  `is_walkable`, `can_place`, `can_paint_wall`, `world_to_cell`, `surface_height`, …). Edits are
  incremental and push undo entries.
- **Furniture**: `FurnitureDef` (model, auto-measured footprint, cost, tags, stations zones,
  `solid`) → `FurnitureCatalog` → `FurnitureInstance` (placed/ghost piece, per-material tints).
  `worker_post` is a walkable mat that spawns a worker.
- **Service** (`scripts/service/service.gd`) — the simulation: owns `ItemManager`,
  `OrderManager`, `JobBoard`, `Planner` and the workers; rebuilds stations on layout changes,
  seeds the tray pool, advances the world in fixed **ticks** (`tick_once()`), and hands jobs out
  centrally (`_assign_jobs` + `assignment_cost`).
- **Workers** (`scripts/workers/worker.gd` + `pathfinder.gd`) — toilet chibis: claim assigned
  jobs, A* walk on the same rules as placement, operate stations, carry one item in front,
  return to their post when idle. Movement/bobs are real-time interpolation.
- **Items** — `ItemDef`/`ItemCatalog` (food + trays) and `WorldItem`: single-unit items on cells,
  one slot each. Trays carry `{order, recipe, dish}` payloads; dishes will carry `{variant}`.
- **Recipes** — `RecipeDef`/`RecipeCatalog`: inputs → output(s) at a station tag, optional
  `effect` (`complete_order`) and `stamp` (`order`, `order_dish`); base ingredients get a
  synthetic `take_<item>` source recipe; runtime **variants** are derived per modifier set
  (`variant_of`, cached by variant id) and dishes carry `payload["variant"]`.
- **Day/game**: `DayPlan` (seeded arrival schedule), `DayController` (phases, arrivals, win/loss,
  money, `can_start_day()` gate), `ModifierCatalog` (3 adds + 3 removes), `OrderManager` money.
- **Stations** — `StationInstance`: cells, capability tags, input/output/work zones (rotate with
  the piece) plus structural intake/delivery points.
- **Jobs/Planner** — `Job` (PRODUCE/TRANSFER), `JobBoard`, `JobAssignment` (priority-ordered
  cheapest-worker), `Planner` (recursive lazy resolution, reservations, dry-run mode for the gate).
- **World in a viewport**: `scenes/main.tscn` puts every 3D node under `Main/World`
  (a `SubViewport`); `Main/UI` (CanvasLayer, `scripts/ui/game_ui.gd`) draws the kitchen as a
  `TextureRect` (`KitchenFrame`) with the rounded-corner shader, the blueprint backdrop, order
  cards, catalog, Start Day button and summary, and forwards GUI input into the viewport.
  `Main/UI/DevHud` (`scripts/ui/hud.gd`, a `Control`) is the dev overlay (money, tick, jobs,
  warnings); `main.gd` wires the controllers and dev hotkeys.

## Invariants — do not break these

1. **Grid model.** 1 m cells; cell `(x, z)` is centred at world `(x, 0, z)`. Walls live on
   *edges*: `Vector3i(x, z, DIR_X)` is the edge between `(x, z)` and `(x+1, z)`; `DIR_Z` is the
   edge between `(x, z)` and `(x, z+1)`.
2. **Derived walls.** An edge with no explicit entry is solid when exactly one side has floor
   and open otherwise. `set_wall()` keeps the dict sparse — never write `walls` directly.
3. **Text format is the save file.** New persisted fields need a section in `to_text()`, parsing
   in `from_text()` and round-trip coverage in the capture self-test. Keep reading older files.
4. **Tunables are exported node properties** with doc comments (see `checker_*`, `ssao_*`,
   `tag_presets`, `walk_ticks_per_cell`, …).
5. **No assets are modified.** Visual changes are runtime tints / shared duplicated materials
   cached in `Kitchen._material_cache`. UI assets are used as-is.
6. **No physics.** Placement, walkability and pathfinding are grid lookups.
7. **Kenney kit facts.** Building kit: 1 unit = 1 m (2×2 m floor, 2.4 m walls). Furniture kit:
   ǀ unit = 0.5 m → `scale_mult = 2`. Food kit: ~3.3 units/m → food `scale_mult ≈ 0.7`
   (cartoon-big; the tomato needs ~1.2). Surfaces carry named materials (`wood`, `metal`,
   `glass`); the colour tools depend on those names surviving import.
8. **The tray pool is finite and closed.** Trays are items: intake packs a free tray into
   `tray_with_order`, plate merges it with the dish, delivery returns `tray_dirty`, the sink
   washes it back. Add tray states as items + recipes, not code special cases.
9. **Planning stays recursive and lazy.** `Planner._plan_item`: 1) reserve a free matching item,
   2) else plan a producer (source or craft), 3) else warn. One item per unit of amount; the
   cycle guard breaks the tray loop with a real warning.
10. **Jobs are the only interface to work.** Work is handed out centrally by
    `Service._assign_jobs()` via `JobAssignment.match()` + `assignment_cost()`; nothing claims
    jobs on its own and nothing teleports. Worker types/machines must plug into that seam.
11. **Ticks are the simulation clock; real time is the animation clock.** Everything timed in
    the sim counts ticks; visuals interpolate in `_process(delta)` over real seconds
    (`WorldItem`, `Worker` are the references). Never tie animation smoothness to the tick rate,
    and never read visual positions back into the simulation.
12. **Every item is one entity in one slot.** No stacks: yields spawn that many items,
    `ItemManager` lays them in a growing lattice, `MAX_SLOTS_PER_CELL` is the capacity hook.
13. **Workers exist only for placed posts.** `Service._sync_workers()` creates one worker per
    `worker_post` and despawns them when the post goes; the post's cell is the canonical home.
14. **Docs stay honest.** Move lines between "Not implemented yet" and features as they land.

## Verifying changes

The engine binary on this machine is `/home/victor/Godot_v4.7.2-stable_linux.x86_64`
(Godot 4.7, GL Compatibility).

```bash
# 1. must be silent apart from the known cosmetic at-exit reports (parse/runtime errors fail)
/home/victor/Godot_v4.7.2-stable_linux.x86_64 --headless --path . --quit-after 10

# 2. render + full self-test suite + deterministic sim + pixel checks
DISPLAY=:1 /home/victor/Godot_v4.7.2-stable_linux.x86_64 --path . \
  res://tools/capture.tscn -- --selftest --check --furniture --paint-demo --sim --pixeltest
```

The suite prints `[selftest] ok/FAIL …` and a `round-trip:` summary, and writes a screenshot to
`/tmp/opencode/kitchen.png`. **Every new feature needs assertions there**, and anything visual
needs a `--pixeltest` sample: rendered pixels are the only proof something is actually visible
(a checker was once invisible for days because the scene was overexposed to pure white).

Capture flags: `--pitch=`, `--yaw=`, `--dist=`, `--focus=x,z`, `--ambient=`,
`--ssao-intensity=`, `--ssao-radius=`, `--sun=`, `--exposure=`, `--item-showcase`, `--sim`,
`--sim-ticks=N`, `--pixeltest`. To debug a real game run use `-- --dump-events` (prints events,
orders, jobs, items, workers at shutdown).

## Gotchas

- After adding/renaming a `class_name` script, run `--import` once or other scripts fail with
  "Could not find type …" (stale global class cache). The user's editor may be staler still —
  tell them *Project → Reload Current Project* if the game renders gray after big changes.
- This project treats some GDScript warnings as errors: `:=` on a Variant ("type is being
  inferred from a Variant value") fails the build — annotate or cast explicitly.
- Typed arrays don't convert from untyped literals/ternaries; append element by element.
- `JobBoard.cleanup()` must keep ACTIVE jobs too — dropping them strands item reservations and
  station locks forever (looked like a deadlock).
- The demo map ships furnished, so tests must not assume an empty kitchen.
- Workers don't collide (two may share a cell) and carry exactly one item.
- Non-solid furniture (worker posts) is walkable and counts as floor for item heights, but still
  occupies its cell for placement. Worker "go home" paths target the post itself; job paths
  target a cell *next to* the station/item.
- Godot prints at-exit resource/leaked-instance warnings even on clean shutdowns; treat script
  and runtime errors as failures, the rest as noise.
- `Color.is_equal_approx` is too strict after the 8-bit hex round-trip; use ~0.01 tolerance
  (see `_color_close` in the capture tool).
- `@tool` scripts run in the editor: `Kitchen` previews the map there; generated nodes are never
  owned, so they don't get saved into the scene.
- `StationInstance.work_target()` is the cell a worker operates from; a 1×1 station's work
  target is its own cell (the worker stands adjacent).
- The capture's `_self_test()` is a coroutine: `_ready` **must** `await` it, or the flags that
  follow (`--furniture`, `--sim`, …) run in the middle of the suite and break its assumptions.
- The kitchen frame is a `TextureRect` over `SubViewport.get_texture()`, not a
  `SubViewportContainer`: a container's shader sees an empty `TEXTURE` (gray frame) and the
  container cannot mask its own viewport. Input is forwarded by hand (`_on_frame_input`).
- The rounded-corner shader needs the SDF's interior term
  (`+ min(max(q.x, q.y), 0.0) - corner_radius`); without it the whole frame renders at 50 % alpha
  (a wash over whatever is behind it) — that cost an afternoon.
- `Button` icon sizing is the theme constant `icon_max_width`, not a property.
- `hud.gd` extends `Control` (it sits inside the UI CanvasLayer as `DevHud`); `game_ui.gd` is the
  CanvasLayer that owns the player UI. Attaching the wrong script to either node is an editor error.

## Version control

Use **GitButler (`but`)**, never raw `git` writes.

```bash
but status -fv                       # always start here: file + branch CLI IDs
but branch new prototype-N           # then: but move prototype-N prototype-(N-1)  (stack it)
but commit prototype-N -m "prototype N" --changes <ids> --status-after
but push prototype-N
```

Read-only git (`git log`, `git show --stat`) is fine. Prototype branches are stacked on each
other and pushed; `origin/main` stays at the Kenney assets commit.
