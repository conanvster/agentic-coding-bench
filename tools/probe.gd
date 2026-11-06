# Stand v4 probe: added as autoload to a COPY of the model's project by stand_tools.py (godot_run play).
# Waits, injects scripted input, saves screenshots and dumps a text report of what the camera can see.
# Env: PROBE_OUT (dir), PROBE_FRAMES (total frames), PROBE_SHOTS ("60,150"), PROBE_INPUT ("click 704 384 @60;key SPACE @90")
extends Node

var frame := 0
var total := 180
var shots: Array[int] = []
var inputs: Array = []
var out_dir := ""
var report: Array[String] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	out_dir = OS.get_environment("PROBE_OUT")
	total = int(OS.get_environment("PROBE_FRAMES")) if OS.get_environment("PROBE_FRAMES") != "" else 180
	for s in OS.get_environment("PROBE_SHOTS").split(",", false):
		shots.append(int(s))
	for item in OS.get_environment("PROBE_INPUT").split(";", false):
		var parts := item.strip_edges().split("@")
		if parts.size() == 2:
			inputs.append([int(parts[1]), parts[0].strip_edges()])


func _send(cmd: String) -> void:
	var w := cmd.split(" ", false)
	if w.is_empty():
		return
	if w[0] == "click" and w.size() >= 3:
		for pressed in [true, false]:
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_LEFT
			e.pressed = pressed
			e.position = Vector2(float(w[1]), float(w[2]))
			e.global_position = e.position
			Input.parse_input_event(e)
	elif w[0] == "move" and w.size() >= 3:
		var m := InputEventMouseMotion.new()
		m.position = Vector2(float(w[1]), float(w[2]))
		m.global_position = m.position
		Input.parse_input_event(m)
	elif w[0] == "key" and w.size() >= 2:
		for pressed in [true, false]:
			var k := InputEventKey.new()
			k.keycode = OS.find_keycode_from_string(w[1])
			k.physical_keycode = k.keycode
			k.pressed = pressed
			Input.parse_input_event(k)
	elif w[0] == "action" and w.size() >= 2:
		Input.action_press(w[1])
		Input.action_release(w[1])


func _process(_d: float) -> void:
	frame += 1
	for it in inputs:
		if it[0] == frame:
			_send(it[1])
	if frame in shots:
		var img := get_viewport().get_texture().get_image()
		img.save_png(out_dir + "/frame-%d.png" % frame)
	if frame >= total:
		_dump()
		get_tree().quit()


func _line(s: String) -> void:
	report.append(s)


func _dump() -> void:
	var root := get_tree().current_scene
	var vp := get_viewport()
	var cam := vp.get_camera_3d()
	var size := vp.get_visible_rect().size
	_line("viewport %dx%d" % [size.x, size.y])
	if root == null:
		_line("current_scene: NONE (main scene not loaded)")
	else:
		_line("current_scene: %s (%s)" % [root.name, root.get_class()])
	if cam:
		_line("camera3d: %s pos=%s looking=%s fov=%.0f" % [cam.get_path(), _v(cam.global_position), _v(-cam.global_transform.basis.z), cam.fov])
	else:
		_line("camera3d: NONE (3D content is not rendered without a current Camera3D)")
	var counts := {"meshes": 0, "in_view": 0, "hidden": 0, "no_mesh": 0}
	var tree_lines: Array[String] = []
	_walk(get_tree().root, 0, cam, counts, tree_lines)
	_line("mesh instances: %d, visible in camera view: %d, hidden: %d, without mesh resource: %d" % [counts.meshes, counts.in_view, counts.hidden, counts.no_mesh])
	_line("tree (max 120 nodes):")
	for l in tree_lines.slice(0, 120):
		_line(l)
	var f := FileAccess.open(out_dir + "/report.txt", FileAccess.WRITE)
	f.store_string("\n".join(report) + "\n")


func _v(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


func _walk(n: Node, depth: int, cam: Camera3D, counts: Dictionary, lines: Array[String]) -> void:
	if n == self:
		return
	var info := "%s%s [%s]" % ["  ".repeat(depth), n.name, n.get_class()]
	if n is Node3D:
		var n3 := n as Node3D
		info += " pos=" + _v(n3.global_position)
		if not n3.is_visible_in_tree():
			info += " HIDDEN"
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		counts.meshes += 1
		if mi.mesh == null:
			counts.no_mesh += 1
			info += " mesh=NONE"
		else:
			var aabb := mi.global_transform * mi.mesh.get_aabb()
			info += " mesh=%s size=%s" % [mi.mesh.get_class(), _v(aabb.size)]
			if not mi.is_visible_in_tree():
				counts.hidden += 1
			elif cam and _in_view(cam, aabb):
				counts.in_view += 1
				info += " IN_VIEW"
	elif n is Camera3D and (n as Camera3D).current:
		info += " CURRENT"
	elif n is CanvasItem and not (n as CanvasItem).is_visible_in_tree():
		info += " HIDDEN"
	elif n is Label:
		info += " text=\"%s\"" % (n as Label).text.left(40)
	lines.append(info)
	for c in n.get_children():
		_walk(c, depth + 1, cam, counts, lines)


func _in_view(cam: Camera3D, aabb: AABB) -> bool:
	var size := get_viewport().get_visible_rect().size
	for i in 8:
		var p := aabb.get_endpoint(i)
		if cam.is_position_behind(p):
			continue
		var s := cam.unproject_position(p)
		if s.x >= 0 and s.y >= 0 and s.x <= size.x and s.y <= size.y:
			return true
	var c := aabb.get_center()
	return not cam.is_position_behind(c) and Rect2(Vector2.ZERO, size).has_point(cam.unproject_position(c))
