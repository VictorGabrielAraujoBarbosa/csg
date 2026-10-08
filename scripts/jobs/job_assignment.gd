class_name JobAssignment
extends RefCounted
## Priority-ordered greedy matching of free workers to ready jobs.
##
## Jobs are taken in priority order (oldest first) and each one gets the free
## worker with the lowest assignment cost — the coupling with the best margin,
## not just whoever asked first. The cost callable is the seam where worker
## types will add their own terms later ("only a cook can use the stove",
## "a runner is cheaper for long carries").


## Returns an array of {worker, job} pairs (each used at most once).
static func match(workers: Array, jobs: Array, cost: Callable) -> Array:
	var taken := {}
	var out: Array = []
	for job in jobs:
		var best: Variant = null
		var best_cost := INF
		for worker in workers:
			if taken.has(worker):
				continue
			var value: float = cost.call(worker, job)
			if value < best_cost:
				best_cost = value
				best = worker
		if best != null:
			taken[best] = true
			out.append({"worker": best, "job": job})
	return out
