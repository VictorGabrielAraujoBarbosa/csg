extends Control
## Minimal developer overlay: order queue, job/item counts and the last warning.
## (Player-facing UI lives in game_ui.gd on the parent CanvasLayer.)

@export var service_path: NodePath
@export var day_path: NodePath

var service: Service
var day_controller: DayController
var _warning_until := 0.0

@onready var orders_label: Label = $Orders
@onready var warnings_label: Label = $Warnings


func _ready() -> void:
	service = get_node_or_null(service_path) as Service
	if service == null:
		service = get_node_or_null("../../World/Service") as Service
	day_controller = get_node_or_null(day_path) as DayController
	if day_controller == null:
		day_controller = get_node_or_null("../../World/DayController") as DayController
	if service != null:
		service.warning.connect(_on_warning)
	_refresh()


func _process(_delta: float) -> void:
	_refresh()
	if _warning_until > 0.0 and service != null and float(service.tick) > _warning_until:
		_warning_until = 0.0
		warnings_label.text = ""


func _refresh() -> void:
	if service == null or service.orders == null:
		return
	var tps := maxf(float(service.ticks_per_second), 1.0)
	var lines: PackedStringArray = []
	lines.append("MONEY  $%d" % service.orders.money)
	if day_controller != null:
		match day_controller.phase:
			DayController.Phase.BUILD:
				lines.append("BUILD  —  press N for day %d" % (day_controller.day + 1))
			DayController.Phase.DAY:
				var total := day_controller.plan.arrivals.size() if day_controller.plan != null else 0
				lines.append("DAY %d  —  served %d / %d" % [day_controller.day, day_controller.served, total])
			DayController.Phase.SUMMARY:
				lines.append("DAY %d %s  —  served %d, $%d  (press N)" % [
					day_controller.day, "LOST" if day_controller.lost else "complete",
					day_controller.served, service.orders.money])
	lines.append("TICK  %d  (%.0fs)" % [service.tick, float(service.tick) / tps])
	lines.append("ORDERS  %d / %d" % [service.orders.active_orders().size(), service.orders.max_pending])
	for order in service.orders.active_orders():
		var suffix := "  (? can't plan)" if order.state == Order.State.UNPLANNABLE else ""
		var age := float(service.tick - order.created_tick) / tps
		lines.append("  #%d %s  %.0fs%s" % [order.id, order.dish_name, age, suffix])
	var running := 0
	for job in service.board.jobs:
		if job.state == Job.State.ACTIVE:
			running += 1
	lines.append("jobs %d +%d   items %d" % [service.board.pending_count(), running, service.items.items.size()])
	orders_label.text = "\n".join(lines)


func _on_warning(text: String) -> void:
	warnings_label.text = "! " + text
	_warning_until = (float(service.tick) if service != null else 0.0) + 6.0 * (service.ticks_per_second if service != null else 10)
	print("[warning] ", text)
