class_name Job
extends RefCounted
## One unit of work on the job board. PRODUCE runs a recipe at a station,
## TRANSFER carries an existing item to a cell.

enum Kind { PRODUCE, TRANSFER }
enum State { PENDING, ACTIVE, DONE, FAILED }

var id := 0
var kind := Kind.PRODUCE
var state := State.PENDING
var created_at := 0.0
## Simulation ticks: when an ACTIVE job started and when it finishes.
var started_tick := 0
var finish_tick := 0

# PRODUCE
var recipe: RecipeDef
var station: StationInstance
## Where the produced item should be carried to (NO_CELL = leave it on the
## station's output cell).
var deliver_to := NO_CELL
var order: Order

# TRANSFER
var item: WorldItem
var target_cell := Vector2i.ZERO

var parent: Job
var location := Vector2i.ZERO
var fail_reason := ""

const NO_CELL := Vector2i(-2147483647, -2147483647)


func step_label() -> String:
	if kind == Kind.TRANSFER:
		return "Carry %s -> %s" % [item.describe() if item != null else "?", target_cell]
	return "%s @ %s" % [recipe.display_name if recipe != null else "?", location]


func describe() -> String:
	var who := ""
	if order != null:
		who = " (order %d)" % order.id
	return "%s%s" % [step_label(), who]
