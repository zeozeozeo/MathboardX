#+build !js
package mathboardx

import im "imgui"
import "imgui/imgui_impl_glfw"
import "imgui/imgui_impl_opengl3"
import nvg "nanovg"
import nvg_gl "nanovg/gl"

import gl "vendor:OpenGL"
import "vendor:glfw"

import win32 "core:sys/windows"
import "core:time"

DISABLE_DOCKING :: #config(DISABLE_DOCKING, false)

g_hotstate: bool
app_set_hotstate :: proc(in_hotstate:bool) {
	g_hotstate=in_hotstate
}


g_allow_request_update: bool
app_request_update :: proc() {
    if g_allow_request_update {
        g_allow_request_update = false
        glfw.PostEmptyEvent()
    }
}

@(private="file")
find_window_monitor :: proc(window: glfw.WindowHandle) -> glfw.MonitorHandle {
    wx, wy := glfw.GetWindowPos(window)
    ww, wh := glfw.GetWindowSize(window)

    monitors := glfw.GetMonitors()
    best_monitor: glfw.MonitorHandle
    max_overlap := -1

    for m in monitors {
        mx, my := glfw.GetMonitorPos(m)
        mode := glfw.GetVideoMode(m)
        if mode == nil do continue

        overlap_x0 := max(wx, mx)
        overlap_y0 := max(wy, my)
        overlap_x1 := min(wx + ww, mx + i32(mode.width))
        overlap_y1 := min(wy + wh, my + i32(mode.height))

        if overlap_x1 > overlap_x0 && overlap_y1 > overlap_y0 {
            area := (overlap_x1 - overlap_x0) * (overlap_y1 - overlap_y0)
            if area > i32(max_overlap) {
                max_overlap = int(area)
                best_monitor = m
            }
        }
    }
    return best_monitor
}

@(private="file")
get_current_refresh_rate :: proc(window: glfw.WindowHandle) -> i32 {
    default_rate : i32 = 60
    monitor := glfw.GetWindowMonitor(window)
    if monitor == nil do monitor = find_window_monitor(window)

    if monitor != nil {
        mode := glfw.GetVideoMode(monitor)
        if mode != nil do return mode.refresh_rate
    }
    return default_rate
}

app_run :: proc(doinit: Mainloop_Proc, doframe: Frame_Proc, dofini: Mainloop_Proc) {
    defer if dofini != nil do dofini()
    assert(cast(bool)glfw.Init())

    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 2)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
    glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)

    window := glfw.CreateWindow(1280, 720, "MathboardX", nil, nil)
    assert(window != nil)
    defer glfw.DestroyWindow(window)

    glfw.MakeContextCurrent(window)
    glfw.SwapInterval(0)

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

    when ODIN_OS == .Windows {
        win32.timeBeginPeriod(1)
        defer win32.timeEndPeriod(1)
    }

    last_swap_time := time.now()

    NS_PER_SECOND   :: 1_000_000_000
    SLEEP_THRESHOLD :: 2 * 1_000_000

    for !glfw.WindowShouldClose(window) {
    	real_refresh_rate := get_current_refresh_rate(window)
        refresh_rate := g_hotstate?real_refresh_rate*3/2:real_refresh_rate/2 // overshoot by 1.5 to reduce latency
        frame_duration_ns := i64(NS_PER_SECOND) / i64(refresh_rate)

        // update every 1s without events
        glfw.WaitEventsTimeout(1.0)

        // on 240hz this theoretically should sleep once and busyloop the rest
        for {
            elapsed_ns := time.duration_nanoseconds(time.since(last_swap_time))
            remaining_ns := frame_duration_ns - elapsed_ns

            if remaining_ns <= 0 do break

            if remaining_ns > SLEEP_THRESHOLD {
                sleep_time := (remaining_ns * 8) / 10 // undershoot 80%
                time.sleep(time.Duration(sleep_time))
            }
        }

        last_swap_time = time.now()
        g_allow_request_update = true

        // render
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
