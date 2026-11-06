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
	# v4.2 (06.11): kat — parent="Main" для дітей кореня: Godot чіпляє такі вузли прямо до кореня з іменем «Батько#Вузол»,
	# зміщення батьків губляться (камера в 0,0,0 впритул до гільзи — кадр суцільно жовтий, а сіток «у полі зору» 36)
	var lost: Array[String] = []
	_lost(get_tree().root, lost)
	if lost.size() > 0:
		_line("LOST PARENTS: %d nodes were re-attached to the root because their parent path in the .tscn does not exist (Godot renamed them Parent#Node and dropped the parent's position): %s. In .tscn a direct child of the root node has parent=\".\", a grandchild parent=\"Child\", deeper parent=\"Child/Grandchild\" — never the root's own name." % [lost.size(), ", ".join(lost.slice(0, 12))])
	if cam:
		_coverage(cam)
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


func _lost(n: Node, out: Array[String]) -> void:
	if n == self:
		return
	if "#" in String(n.name):
		out.append(String(n.name))
	for c in n.get_children():
		_lost(c, out)


func _meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and (n as MeshInstance3D).is_visible_in_tree():
		out.append(n)
	for c in n.get_children():
		_meshes(c, out)


# v4.2: що реально заповнює кадр — сітка 32×18 променів з камери, найближча AABB сітки на кожному промені.
# Сітки, всередині яких стоїть камера (небо-купол, великі кімнати), — тло. BLOCKED VIEW: одна сітка закриває >50 % кадру ближче 1 м.
func _coverage(cam: Camera3D) -> void:
	var size := get_viewport().get_visible_rect().size
	var ms: Array = []
	_meshes(get_tree().root, ms)
	var origin := cam.global_position
	var inside: Array[String] = []
	var boxes: Array = []
	for m in ms:
		var mi := m as MeshInstance3D
		var aabb := mi.global_transform * mi.mesh.get_aabb()
		if aabb.grow(0.01).has_point(origin):
			inside.append(String(mi.name))
		else:
			boxes.append([mi, aabb.grow(0.001)])
	var hits := {}
	var dist := {}
	var nx := 32
	var ny := 18
	for iy in ny:
		for ix in nx:
			var sp := Vector2((ix + 0.5) * size.x / nx, (iy + 0.5) * size.y / ny)
			var dir := cam.project_ray_normal(sp)
			var best := INF
			var who := ""
			for b in boxes:
				var hit = (b[1] as AABB).intersects_ray(origin, dir)
				if hit != null:
					var d := origin.distance_to(hit)
					if d < best:
						best = d
						who = String((b[0] as Node).name)
			if who == "":
				who = "(background/sky)"
			hits[who] = hits.get(who, 0) + 1
			dist[who] = min(dist.get(who, INF), best)
	var total := float(nx * ny)
	var names := hits.keys()
	names.sort_custom(func(a, b): return hits[a] > hits[b])
	var parts: Array[String] = []
	for k in names.slice(0, 6):
		parts.append("%s %d%%%s" % [k, round(100.0 * hits[k] / total), "" if dist[k] == INF else " (%.1f m)" % dist[k]])
	_line("FRAME COVERAGE (what fills the view, by share of screen): " + ", ".join(parts) + ("; camera is inside: " + ", ".join(inside.slice(0, 4)) if inside.size() > 0 else ""))
	var top = names[0] if names.size() > 0 else ""
	if top != "" and top != "(background/sky)" and hits[top] / total > 0.5 and dist[top] < 1.0:
		_line("BLOCKED VIEW: %s covers %d%% of the screen at %.1f m from the camera — the camera stands inside or right in front of it, the player sees nothing else. Check the camera position (and its parent) and this object's position." % [top, round(100.0 * hits[top] / total), dist[top]])
