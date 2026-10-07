# Consumer Satisfaction (Guaranteed)

A kitchen-management horror game for a game jam. You design a kitchen, your hard-working
chibis cook and serve orders, and every day more customers arrive. Fall too far behind and
the customers stop waiting and come for you.

Built with **Godot 4.7** (GL Compatibility renderer) using the Kenney CC0 3D kits.

> **Status: Prototype 1.** The grid, the kitchen map authoring tools, furniture placement,
> colouring and the look & feel are in. Workers, stations, orders, the day cycle and the
> horror fail state are not implemented yet — see [Roadmap](#roadmap).

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
scripts/furniture/furniture_def.gd      what an item is (model, footprint, cost, tags)
scripts/furniture/furniture_instance.gd a placed/ghost piece (tints, material names)
scripts/furniture/furniture_catalog.gd  the buyable list
scripts/build/place_controller.gd       furniture placement
scripts/build/map_paint_controller.gd   live map editor + colour tools
scripts/camera_rig.gd                   rotatable grid-aligned 3/4 camera
scripts/render/look_config.gd           SSAO / glow / grading / ambient panel
resources/layouts/demo_kitchen.txt      the demo map (source of truth for the level)
tools/capture.tscn, capture.gd          dev tool: screenshot + self-test suite
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
  plating tints, grid overlay colour/width.
- **MapPaintController** — tint palette, `tag_presets` (tag → colour), feedback colours.
- **Sun** / **Fill** — the two shadowless directional lights (cloudy-day look).

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
[furniture]       id x z steps [material=rrggbb ...]
```

In `[furniture]`, `*=rrggbb` colours the whole piece and `wood=rrggbb` colours one material
group only (`*` is also what a bare colour token means in older files).

The demo level lives in `resources/layouts/demo_kitchen.txt`. `F5` in-game writes the current
kitchen back out to `user://kitchen_export.txt` and prints the path, so anything you build or
paint can be pasted straight back into the layout file.

## Development tools

```bash
# the project must run clean (catches script errors)
godot --headless --path . --quit-after 10

# render the main scene and run the self-test suite
godot --path . res://tools/capture.tscn -- --selftest --check --furniture --paint-demo --pixeltest
```

`tools/capture.gd` loads `scenes/main.tscn` into an offscreen viewport, places demo furniture,
runs ~54 assertions (placement rules, painting, tints, undo, tag presets, text round-trip,
and pixel-level checks that rendered results actually differ) and saves a screenshot to
`/tmp/opencode/kitchen.png`. Extra flags: `--pitch=`, `--yaw=`, `--dist=`, `--focus=x,z`,
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
2. Build phase & economy: money, buy/sell, palette UI, day-start phase, end-of-day summary
3. Chibi workers: character models, grid pathfinding, work loop
4. Stations & orders: recipes, tickets, customer queue, and the "10 pending orders" horror event
5. Day cycle & escalating difficulty
6. Synergies (adjacency rules) and horror polish
