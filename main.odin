package mathboardx

import im "imgui"
import nvg "nanovg"

the_canvas: Canvas

doinit :: proc() {
	the_canvas = canvas_new()
}

doframe :: proc(vg: ^nvg.Context, window_w, window_h: f32) {
	if app_shortcut(.ImGuiMod_Ctrl | .Z) do canvas_undo(&the_canvas)
	if app_shortcut(.ImGuiMod_Ctrl | .ImGuiMod_Shift | .Z) || app_shortcut(.ImGuiMod_Ctrl | .Y) do canvas_redo(&the_canvas)
	canvas_update(
		&the_canvas,
		app_mouse_pos(),
		app_mouse_dt(),
		app_is_mouse_down(.Left),
		app_is_mouse_down(.Middle),
		app_mwheel(),
	)
	canvas_render(&the_canvas, vg, window_w, window_h)
}

main :: proc() {
	app_run(doinit = doinit, doframe = doframe, dofini = nil)
}
