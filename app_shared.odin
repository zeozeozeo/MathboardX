package mathboardx

import im "imgui"
import nvg "nanovg"

Mainloop_Proc :: #type proc()
Frame_Proc :: #type proc(vg: ^nvg.Context, window_w, window_h: f32)

app_is_mouse_down :: proc(mb: im.MouseButton) -> bool {
	return im.GetIO().MouseDown[mb]
}

app_mouse_pos :: proc() -> Point {
	pos := im.GetMousePos() - im.GetMainViewport().Pos
	return Point{f64(pos.x), f64(pos.y)}
}

app_mwheel :: proc() -> f32 {
	return im.GetIO().MouseWheel
}

app_mouse_dt :: proc() -> Vec2 {
	dt := im.GetIO().MouseDelta
	return Vec2{f64(dt.x), f64(dt.y)}
}

app_shortcut :: proc(chord: im.Key, flags: im.InputFlags = {.Repeat, .RouteGlobal}) -> bool {
	return im.Shortcut(cast(im.KeyChord)chord, flags)
}
