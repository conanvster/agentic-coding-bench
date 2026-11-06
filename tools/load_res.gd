# Stand v4: godot --headless --path <project> -s load_res.gd -- res://file.tscn  → prints LOAD_OK or errors
extends SceneTree
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var ok := true
	for path in args:
		var r = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if r == null:
			ok = false
			printerr("ERROR: cannot load ", path)
		elif r is PackedScene:
			var inst = (r as PackedScene).instantiate()
			if inst == null:
				ok = false
				printerr("ERROR: scene does not instantiate: ", path)
			else:
				inst.free()
	if ok:
		print("LOAD_OK")
	quit(0 if ok else 1)
