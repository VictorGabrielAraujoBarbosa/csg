class_name Order
extends RefCounted
## One customer order: a dish to make and hand over. Timers count in ticks.

enum State { WAITING, IN_PROGRESS, COMPLETED, FAILED, UNPLANNABLE }

var id := 0
var recipe_id: StringName = &""
var dish_name := ""
## Simulation tick the order arrived.
var created_tick := 0
## Absolute tick the order must be completed by (0 = no limit).
var deadline_tick := 0
var state := State.WAITING
var reward := 0


func age_ticks(now_tick: int) -> int:
	return now_tick - created_tick


func is_active() -> bool:
	return state == State.WAITING or state == State.IN_PROGRESS or state == State.UNPLANNABLE
