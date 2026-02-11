#+build !js
package mathboardx

import im "imgui"
import "imgui/imgui_impl_glfw"
import "imgui/imgui_impl_opengl3"
import nvg "nanovg"
import nvg_gl "nanovg/gl"

import gl "vendor:OpenGL"
import "vendor:glfw"

DISABLE_DOCKING :: #config(DISABLE_DOCKING, false)

app_run :: proc(doinit: Mainloop_Proc, doframe: Frame_Proc, dofini: Mainloop_Proc) {
	defer if dofini != nil do dofini()
	assert(cast(bool)glfw.Init())

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 2)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1) // i32(true)

	window := glfw.CreateWindow(1280, 720, "MathboardX", nil, nil)
	assert(window != nil)
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	glfw.SwapInterval(1) // vsync

	gl.load_up_to(3, 2, proc(p: rawptr, name: cstring) {
		(cast(^rawptr)p)^ = glfw.GetProcAddress(name)
	})

	im.CHECKVERSION()
	im.CreateContext()
	defer im.DestroyContext()
	io := im.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .NavEnableGamepad}
	io.IniFilename = nil

	when !DISABLE_DOCKING {
		io.ConfigFlags += {.DockingEnable}
		io.ConfigFlags += {.ViewportsEnable}

		style := im.GetStyle()
		style.WindowRounding = 0
		style.Colors[im.Col.WindowBg].w = 1
	}

	im.StyleColorsLight()

	imgui_impl_glfw.InitForOpenGL(window, true)
	defer imgui_impl_glfw.Shutdown()
	imgui_impl_opengl3.Init("#version 150")
	defer imgui_impl_opengl3.Shutdown()

	vg := nvg_gl.Create({.ANTI_ALIAS, .STENCIL_STROKES})
	assert(vg != nil)
	defer nvg_gl.Destroy(vg)

	if doinit != nil do doinit()

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
		ww, wh := glfw.GetWindowSize(window)
		fw, fh := glfw.GetFramebufferSize(window)
		px_ratio := f32(fw) / f32(ww)

		imgui_impl_opengl3.NewFrame()
		imgui_impl_glfw.NewFrame()
		im.NewFrame()
		nvg.BeginFrame(vg, f32(ww), f32(wh), px_ratio)

		if doframe != nil do doframe(vg, f32(fw), f32(fh))

		im.Render()
		gl.Viewport(0, 0, fw, fh)
		gl.ClearColor(1, 1, 1, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		nvg.EndFrame(vg)
		imgui_impl_opengl3.RenderDrawData(im.GetDrawData())

		when !DISABLE_DOCKING {
			backup_current_window := glfw.GetCurrentContext()
			im.UpdatePlatformWindows()
			im.RenderPlatformWindowsDefault()
			glfw.MakeContextCurrent(backup_current_window)
		}

		glfw.SwapBuffers(window)
		free_all(context.temp_allocator)
	}
}
