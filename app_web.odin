#+build js
package mathboardx

import "base:runtime"
import "core:fmt"
import gl "vendor:wasm/WebGL"

import im "imgui"
import "imgui/imgui_impl_js"
import "imgui/imgui_impl_webgl"

import nvg "nanovg"
//import nvg_gl "nanovg/gl"

DISABLE_DOCKING :: #config(DISABLE_DOCKING, false)

App_State :: struct {
	ctx:     runtime.Context,
	vg:      ^nvg.Context,
	doframe: Frame_Proc,
	dofini:  Mainloop_Proc,
	window:  struct {
		w, h: i32,
	},
	inited:  bool,
}

g_app: App_State

app_run :: proc(doinit: Mainloop_Proc, doframe: Frame_Proc, dofini: Mainloop_Proc) {
	g_app.ctx = context
	g_app.doframe = doframe
	g_app.dofini = dofini

	if !gl.CreateCurrentContextById("webgl-canvas", gl.DEFAULT_CONTEXT_ATTRIBUTES) {
		fmt.println("Error: Failed to create WebGL context!")
		return
	}

	gl.SetCurrentContextById("webgl-canvas")

	im.CHECKVERSION()
	im.CreateContext()
	io := im.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .NavEnableGamepad}
	io.IniFilename = nil

	when !DISABLE_DOCKING {
		io.ConfigFlags += {.DockingEnable}
		style := im.GetStyle()
		style.WindowRounding = 0
		style.Colors[im.Col.WindowBg].w = 1
	}

	im.StyleColorsLight()

	imgui_impl_js.Init("canvas")
	imgui_impl_webgl.Init()

	//g_app.vg = nvg_gl.Create({.ANTI_ALIAS, .STENCIL_STROKES})
	//assert(g_app.vg != nil, "Failed to create NanoVG context!")

	if doinit != nil do doinit()
	g_app.inited = true
}

// called by requestAnimationFrame
@(export)
step :: proc(dt: f64) -> (keep_going: bool) {
	if !g_app.inited do return true
	context = g_app.ctx

	defer free_all(context.temp_allocator)

	fw := gl.DrawingBufferWidth()
	fh := gl.DrawingBufferHeight()

	px_ratio: f32 = 1.0
	if io := im.GetIO(); io.DisplaySize.x > 0 {
		px_ratio = f32(fw) / io.DisplaySize.x
	}

	imgui_impl_js.NewFrame(f32(dt))
	imgui_impl_webgl.NewFrame()
	im.NewFrame()

	nvg.BeginFrame(g_app.vg, f32(fw) / px_ratio, f32(fh) / px_ratio, px_ratio)

	if g_app.doframe != nil {
		g_app.doframe(g_app.vg, f32(fw), f32(fh))
	}

	im.Render()
	gl.Viewport(0, 0, fw, fh)
	gl.ClearColor(1, 1, 1, 1)
	gl.Clear(cast(u32)gl.COLOR_BUFFER_BIT | cast(u32)gl.STENCIL_BUFFER_BIT)

	nvg.EndFrame(g_app.vg)
	imgui_impl_webgl.RenderDrawData(im.GetDrawData())

	return true
}

@(fini)
fini :: proc "contextless" () {
	context = g_app.ctx

	if g_app.dofini != nil do g_app.dofini()

	//nvg_gl.Destroy(g_app.vg)
	imgui_impl_webgl.Shutdown()
	imgui_impl_js.Shutdown()
	im.DestroyContext()
}
