extends SceneTree
var n := 0
func box(size: Vector3, pos: Vector3, col: Color, parent: Node = null) -> void:
	var m := MeshInstance3D.new(); var b := BoxMesh.new(); b.size = size; m.mesh = b
	var mat := StandardMaterial3D.new(); mat.albedo_color = col; m.material_override = mat
	m.position = pos; (parent if parent else root).add_child(m)
func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var env := WorldEnvironment.new(); var e := Environment.new(); e.background_mode = Environment.BG_SKY
	var sky := Sky.new(); sky.sky_material = ProceduralSkyMaterial.new(); e.sky = sky; env.environment = e; root.add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); root.add_child(sun)
	box(Vector3(400, 0.1, 400), Vector3(0, -0.05, 0), Color("b29c7e"))
	box(Vector3(3.8, 0.08, 1.3), Vector3(0, 0.86, -2.35), Color("6f665b"))
	box(Vector3(3.8, 0.86, 0.1), Vector3(0, 0.43, -1.75), Color("3a332c"))
	for c in [[Vector3(-0.8, 6.9, -10), Color("d81e1e")], [Vector3(2.8, 7.0, -10), Color("22b322")], [Vector3(2.3, 3.4, -10), Color("f2d21a")], [Vector3(0.5, 1.1, -10), Color("22b322")]]:
		box(Vector3.ONE, c[0], c[1])
	var cam := Camera3D.new(); cam.position = Vector3(0, 1.6, 0); cam.fov = 60; root.add_child(cam)
	var muz := Vector3(0.14, -0.09, -1.05); var butt := Vector3(0.32, -0.38, 0.0)
	var r := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = Vector3(0.05, 0.07, muz.distance_to(butt)); r.mesh = bm
	var rm := StandardMaterial3D.new(); rm.albedo_color = Color("6b3a22"); r.material_override = rm; cam.add_child(r)
	r.position = (muz + butt) / 2; r.look_at_from_position((muz + butt) / 2, muz, Vector3.UP)
	cam.make_current()
	var ui := CanvasLayer.new(); root.add_child(ui)
	var panel := ColorRect.new(); panel.color = Color(55 / 255.0, 60 / 255.0, 65 / 255.0, 0.75); panel.position = Vector2(8, 6); panel.size = Vector2(430, 132); ui.add_child(panel)
	for cr in [Rect2(660, 383, 30, 2), Rect2(718, 383, 30, 2), Rect2(703, 340, 2, 30), Rect2(703, 398, 2, 30)]:
		var l := ColorRect.new(); l.color = Color("202020"); l.position = cr.position; l.size = cr.size; ui.add_child(l)
func _process(_d: float) -> bool:
	n += 1
	if n == 20:
		root.get_texture().get_image().save_png(OS.get_environment("OUT")); quit()
	return false
