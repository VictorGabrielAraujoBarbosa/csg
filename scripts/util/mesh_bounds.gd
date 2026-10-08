class_name MeshBounds
## Neutral helper for measuring instanced models, shared by furniture, items and
## the kitchen. Kept in its own class so no two gameplay classes need to
## reference each other just to measure meshes (script cycles make the engine
## report leaked script objects at exit).


## Combined AABB of every mesh below [param root], in the parent space of root
## (i.e. root's own transform is included).
static func combined_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var found := false
	var stack: Array = [[root, root.transform]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Node = item[0]
		var xf: Transform3D = item[1]
		if node is MeshInstance3D:
			var a: AABB = (node as MeshInstance3D).get_aabb()
			a = xf * a
			result = a if not found else result.merge(a)
			found = true
		for child in node.get_children():
			var child_xf := xf
			if child is Node3D:
				child_xf = xf * (child as Node3D).transform
			stack.append([child, child_xf])
	return result
