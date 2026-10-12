class_name JobBoard
extends RefCounted
## The board every job is posted to. Workers (or the instant executor) pick the
## most important ready job from it: older jobs first, closer jobs first.

var jobs: Array[Job] = []
var next_id := 1


func add(job: Job) -> Job:
	job.id = next_id
	next_id += 1
	jobs.append(job)
	return job


func cancel(job: Job, reason := "cancelled") -> void:
	if job == null:
		return
	if job.state != Job.State.PENDING and job.state != Job.State.ACTIVE:
		return
	job.state = Job.State.FAILED
	job.fail_reason = reason
	_release(job)
	for other in jobs:
		if other.parent == job:
			cancel(other, reason)


func cancel_for_order(order: Order, reason := "replanned") -> void:
	for job in jobs:
		if job.order == order:
			cancel(job, reason)


## The best ready job for someone standing at [param from_cell]. Readiness is
## decided by the caller (it needs item/station state). Older jobs win over
## distance; both weights are tunable on the service.
func best_ready(from_cell: Vector2i, is_ready: Callable, now: float,
		age_weight: float, distance_weight: float) -> Job:
	var best: Job = null
	var best_score := -INF
	for job in jobs:
		if job.state != Job.State.PENDING:
			continue
		if not is_ready.call(job):
			continue
		var distance := absi(job.location.x - from_cell.x) + absi(job.location.y - from_cell.y)
		var score := age_weight * (now - job.created_at) - distance_weight * float(distance)
		if score > best_score:
			best_score = score
			best = job
	return best


func pending_count() -> int:
	var count := 0
	for job in jobs:
		if job.state == Job.State.PENDING:
			count += 1
	return count


func cleanup() -> void:
	jobs = jobs.filter(func(job: Job) -> bool:
		return job.state == Job.State.PENDING or job.state == Job.State.ACTIVE)


func _release(job: Job) -> void:
	if job.item != null and job.item.reserved_by == job:
		job.item.reserved_by = null
	for held in job.reserved_items:
		if held != null and held.reserved_by == job:
			held.reserved_by = null
	job.reserved_items.clear()
	if job.station != null and job.station.busy_by == job:
		job.station.busy_by = null
