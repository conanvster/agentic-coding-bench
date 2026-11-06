# Скриншоти гри для порівняння моделей: головний екран і після пострілу (лівий клік у центр).
# Додається автозавантаженням у КОПІЮ проєкту моделі (qa/shot-gra.sh), гра йде як звичайно.
extends Node
var n := 0
func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	process_mode = Node.PROCESS_MODE_ALWAYS
func _click(pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT; e.pressed = pressed
	e.position = get_viewport().get_visible_rect().size / 2; e.global_position = e.position
	Input.parse_input_event(e)
func _save(name: String) -> void:
	get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/" + name)
func _process(_d: float) -> void:
	n += 1
	match n:
		120: _save("1-main.png"); _click(true)
		122: _click(false)
		126: _save("2-shot-4f.png")
		150: _save("3-shot-30f.png"); get_tree().quit()
