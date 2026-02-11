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
	mwheel := app_mwheel()
	moving := app_is_mouse_down(.Middle)
	canvas_update(
		&the_canvas,
		app_mouse_pos(),
		app_mouse_dt(),
		app_is_mouse_down(.Left),
		moving,
		mwheel,
	)
	canvas_render(&the_canvas, vg, window_w, window_h)
	if im.Begin("Panel") {
		im.Text("Imm Fps: %f", 1.0 / im.GetIO().DeltaTime)
		im.Text("Avg Fps: %f", im.GetIO().Framerate)
	}
	im.End()

	app_set_hotstate(moving || mwheel!=0.0 || canvas_is_painting(&the_canvas))
}

main :: proc() {
	app_run(doinit = doinit, doframe = doframe, dofini = nil)
}
