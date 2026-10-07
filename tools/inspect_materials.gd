extends SceneTree
## Dev utility: prints the surface material names of every furniture model, so
## we know what can be tinted per material. Run with:
##   godot --headless --path . -s res://tools/inspect_materials.gd


func _initialize() -> void:
	for def in FurnitureCatalog.all():
		var node: Node = def.scene.instantiate()
		var parts: PackedStringArray = []
		_collect(node, parts)
		print("%s: %s" % [def.id, ", ".join(parts)])
		node.free()
	quit()


func _collect(node: Node, out: PackedStringArray) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			for i in mi.mesh.get_surface_count():
				var mat := mi.mesh.surface_get_material(i)
				var name := "(unnamed)"
				if mat != null:
					name = mat.resource_name if not mat.resource_name.is_empty() else "(empty-name)"
				out.append("%s#%d=%s" % [mi.name, i, name])
	for child in node.get_children():
		_collect(child, out)
