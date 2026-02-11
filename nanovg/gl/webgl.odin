// An Odin-native source port of [[ nanovg ; https://github.com/memononen/nanovg ]]'s GL backend.
#+build js
package nanovg_gl

import "core:log"
import "core:strings"
import "core:mem"
import "core:math"
import "core:fmt"
import gl "vendor:wasm/WebGL"
import nvg "../../nanovg"

Color :: nvg.Color
Vertex :: nvg.Vertex
ImageFlags :: nvg.ImageFlags
TextureType :: nvg.Texture
Paint :: nvg.Paint
ScissorT :: nvg.ScissorT

CreateFlag :: enum {
	// Flag indicating if geometry based anti-aliasing is used (may not be needed when using MSAA).
	ANTI_ALIAS,
	// Flag indicating if strokes should be drawn using stencil buffer. The rendering will be a little
	// slower, but path overlaps (i.e. self-intersecting or sharp turns) will be drawn just once.
	STENCIL_STROKES,
	// additional debug checks
	DEBUG,
}
CreateFlags :: bit_set[CreateFlag]

USE_STATE_FILTER :: #config(USE_STATE_FILTER, true)

UniformLoc :: enum {
	VIEW_SIZE,
	TEX,
	FRAG,
}

ShaderType :: enum i32 {
	FILL_GRAD,
	FILL_IMG,
	SIMPLE,
	IMG,
}

Shader :: struct {
	prog: gl.Program,
	frag: gl.Shader,
	vert: gl.Shader,
	loc: [UniformLoc]i32,
}

Texture :: struct {
	id: int,
	tex: gl.Texture,
	width, height: int,
	type: TextureType,
	flags: ImageFlags,
}

Blend :: struct {
	src_RGB: gl.Enum,
	dst_RGB: gl.Enum,
	src_alpha: gl.Enum,
	dst_alpha: gl.Enum,
}

CallType :: enum {
	NONE,
	FILL,
	CONVEX_FILL,
	STROKE,
	TRIANGLES,
}

Call :: struct {
	type: CallType,
	image: int,
	pathOffset: int,
	pathCount: int,
	triangleOffset: int,
	triangleCount: int,
	uniformOffset: int,
	blendFunc: Blend,
}

Path :: struct {
	fillOffset: int,
	fillCount: int,
	strokeOffset: int,
	strokeCount: int,
}

GL_UNIFORMARRAY_SIZE :: 11

when GL2_IMPLEMENTATION {
	FragUniforms :: struct #raw_union {
		using _: struct {
			scissorMat: [12]f32, // matrices are actually 3 vec4s
			paintMat: [12]f32,
			innerColor: Color,
			outerColor: Color,
			scissorExt: [2]f32,
			scissorScale: [2]f32,
			extent: [2]f32,
			radius: f32,
			feather: f32,
			strokeMult: f32,
			strokeThr: f32,
			texType: i32,
			type: ShaderType,
		},
		uniform_array: [GL_UNIFORMARRAY_SIZE][4]f32,
	}
} else {
	FragUniforms :: struct #packed {
		scissorMat: [12]f32, // matrices are actually 3 vec4s
		paintMat: [12]f32,
		innerColor: Color,
		outerColor: Color,
		scissorExt: [2]f32,
		scissorScale: [2]f32,
		extent: [2]f32,
		radius: f32,
		feather: f32,
		strokeMult: f32,
		strokeThr: f32,
		texType: i32,
		type: ShaderType,
	}
}

DEFAULT_IMPLEMENTATION_STRING :: #config(NANOVG_GL_IMPL, "GL3")
GL2_IMPLEMENTATION   :: false
GL3_IMPLEMENTATION   :: true // webgl
GLES2_IMPLEMENTATION :: false
GLES3_IMPLEMENTATION :: false

when GL2_IMPLEMENTATION {
	GL2 :: true
	GL3 :: false
	GLES2 :: false
	GLES3 :: false
	GL_IMPLEMENTATION :: true
	GL_USE_UNIFORMBUFFER :: false
} else when GL3_IMPLEMENTATION {
	GL2 :: false
	GL3 :: true
	GLES2 :: false
	GLES3 :: false
	GL_IMPLEMENTATION :: true
	GL_USE_UNIFORMBUFFER :: true
} else when GLES2_IMPLEMENTATION {
	GL2 :: false
	GL3 :: false
	GLES2 :: true
	GLES3 :: false
	GL_IMPLEMENTATION :: true
	GL_USE_UNIFORMBUFFER :: false
} else when GLES3_IMPLEMENTATION {
	GL2 :: false
	GL3 :: false
	GLES2 :: false
	GLES3 :: true
	GL_IMPLEMENTATION :: true
	GL_USE_UNIFORMBUFFER :: false
}

Context :: struct {
	shader: Shader,
	textures: [dynamic]Texture,
	view: [2]f32,
	textureId: int,

	vertBuf: gl.Buffer,
	vertArr: gl.VertexArrayObject, // GL3
	fragBuf: gl.Buffer, // USE_UNIFORMBUFFER
	fragSize: int,
	flags: CreateFlags,
	frag_binding: u32,

	// Per frame buffers
	calls: [dynamic]Call,
	paths: [dynamic]Path,
	verts: [dynamic]Vertex,
	uniforms: [dynamic]byte,

	// cached state used for state filter
	boundTexture: gl.Texture,
	stencilMask: u32,
	stencilFunc: gl.Enum,
	stencilFuncRef: i32,
	stencilFuncMask: u32,
	blendFunc: Blend,

	dummyTex: int,
}

__nearestPow2 :: proc(num: uint) -> uint {
	n := num > 0 ? num - 1 : 0
	n |= n >> 1
	n |= n >> 2
	n |= n >> 4
	n |= n >> 8
	n |= n >> 16
	n += 1
	return n
}

__bindTexture :: proc(ctx: ^Context, tex: gl.Texture) {
	when USE_STATE_FILTER {
		if ctx.boundTexture != tex {
			ctx.boundTexture = tex
			gl.BindTexture(gl.TEXTURE_2D, tex)
		}
	} else {
		gl.BindTexture(gl.TEXTURE_2D, tex)
	}
}

__stencilMask :: proc(ctx: ^Context, mask: u32) {
	when USE_STATE_FILTER {
		if ctx.stencilMask != mask {
			ctx.stencilMask = mask
			gl.StencilMask(mask)
		}
	} else {
		gl.StencilMask(mask)
	}
}

__stencilFunc :: proc(ctx: ^Context, func: gl.Enum, ref: i32, mask: u32) {
	when USE_STATE_FILTER {
		if ctx.stencilFunc != func ||
			ctx.stencilFuncRef != ref ||
			ctx.stencilFuncMask != mask {
			ctx.stencilFunc = func
			ctx.stencilFuncRef = ref
			ctx.stencilFuncMask = mask
			gl.StencilFunc(func, ref, mask)
		}
	} else {
		gl.StencilFunc(func, ref, mask)
	}
}

__blendFuncSeparate :: proc(ctx: ^Context, blend: ^Blend) {
	when USE_STATE_FILTER {
		if ctx.blendFunc != blend^ {
			ctx.blendFunc = blend^
			gl.BlendFuncSeparate(blend.src_RGB, blend.dst_RGB, blend.src_alpha, blend.dst_alpha)
		}
	} else {
		gl.BlendFuncSeparate(blend.src_RGB, blend.dst_RGB, blend.src_alpha, blend.dst_alpha)
	}
}

__allocTexture :: proc(ctx: ^Context) -> (tex: ^Texture) {
	for &texture in ctx.textures {
		if texture.id == 0 {
			tex = &texture
			break
		}
	}

	if tex == nil {
		append(&ctx.textures, Texture {})
		tex = &ctx.textures[len(ctx.textures) - 1]
	}

	tex^ = {}
	ctx.textureId += 1
	tex.id = ctx.textureId

	return
}

__findTexture :: proc(ctx: ^Context, id: int) -> ^Texture {
	for &texture in ctx.textures {
		if texture.id == id {
			return &texture
		}
	}

	return nil
}

__deleteTexture :: proc(ctx: ^Context, id: int) -> bool {
	for &texture, i in ctx.textures {
		if texture.id == id {
			if texture.tex != 0 && (.NO_DELETE not_in texture.flags) {
				gl.DeleteTexture(texture.tex)
			}

			ctx.textures[i] = {}
			return true
		}
	}

	return false
}

__deleteShader :: proc(shader: ^Shader) {
	if shader.prog != 0 {
		gl.DeleteProgram(shader.prog)
	}

	if shader.vert != 0 {
		gl.DeleteShader(shader.vert)
	}

	if shader.frag != 0 {
		gl.DeleteShader(shader.frag)
	}
}

__getUniforms :: proc(shader: ^Shader) {
	shader.loc[.VIEW_SIZE] = gl.GetUniformLocation(shader.prog, "viewSize")
	shader.loc[.TEX] = gl.GetUniformLocation(shader.prog, "tex")

	when GL_USE_UNIFORMBUFFER {
		shader.loc[.FRAG] = gl.GetUniformBlockIndex(shader.prog, "frag")
	} else {
		shader.loc[.FRAG] = gl.GetUniformLocation(shader.prog, "frag")
	}
}

vert_shader := #load("vert.glsl")
frag_shader := #load("frag.glsl")

__renderCreate :: proc(uptr: rawptr) -> bool {
	ctx := cast(^Context) uptr

	// just build the string at runtime
	builder := strings.builder_make(0, 512, context.temp_allocator)

	when GL2 {
		strings.write_string(&builder, "#version 300 es\n#define NANOVG_GL2 1\n")
	} else when GL3 {
		strings.write_string(&builder, "#version 300 es\n#define NANOVG_GL3 1\n")
	} else when GLES2 {
		strings.write_string(&builder, "#version 300 es\n#define NANOVG_GL2 1\n")
	} else when GLES3 {
		strings.write_string(&builder, "#version 300 es\n#define NANOVG_GL3 1\n")
	}

	when GL_USE_UNIFORMBUFFER {
		strings.write_string(&builder, "#define USE_UNIFORMBUFFER 1\n")
	} else {
		strings.write_string(&builder, "#define UNIFORMARRAY_SIZE 11\n")
	}

	__checkError(ctx, "init")

	shader_header := strings.to_string(builder)
	anti: string = .ANTI_ALIAS in ctx.flags ? "#define EDGE_AA 1\n" : " "
	if !__createShader(
		&ctx.shader,
		shader_header,
		anti,
		string(vert_shader),
		string(frag_shader),
	) {
		return false
	}

	__checkError(ctx, "uniform locations")
	__getUniforms(&ctx.shader)

	ctx.vertArr = gl.CreateVertexArray()

	ctx.vertBuf = gl.CreateBuffer()
	align := i32(4)

	when GL_USE_UNIFORMBUFFER {
		// Create UBOs
		gl.UniformBlockBinding(ctx.shader.prog, ctx.shader.loc[.FRAG], i32(ctx.frag_binding))
		ctx.fragBuf = gl.CreateBuffer()
		// WebGL uniform buffer alignment query is complex, 256 is the spec minimum.
		align = 256
	}

	ctx.fragSize = int(size_of(FragUniforms) + align - size_of(FragUniforms) % align)
	// ctx.fragSize = size_of(FragUniforms)
	ctx.dummyTex = __renderCreateTexture(ctx, .Alpha, 1, 1, {}, nil)

	__checkError(ctx, "create done")

	gl.Finish()

	return true
}

__renderCreateTexture :: proc(
	uptr: rawptr,
	type: TextureType,
	w, h: int,
	imageFlags: ImageFlags,
	data: []byte,
) -> int {
	ctx := cast(^Context) uptr
	tex := __allocTexture(ctx)
	imageFlags := imageFlags

	if tex == nil {
		return 0
	}

	tex.tex = gl.CreateTexture()
	tex.width = w
	tex.height = h
	tex.type = type
	tex.flags = imageFlags
	__bindTexture(ctx, tex.tex)

	gl.PixelStorei(gl.UNPACK_ALIGNMENT,1)

	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, i32(tex.width))
	gl.PixelStorei(gl.UNPACK_SKIP_PIXELS, 0)
	gl.PixelStorei(gl.UNPACK_SKIP_ROWS, 0)

	if type == .RGBA {
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(w), i32(h), 0, gl.RGBA, gl.UNSIGNED_BYTE, len(data), raw_data(data))
	} else {
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, i32(w), i32(h), 0, gl.RED, gl.UNSIGNED_BYTE, len(data), raw_data(data))
	}

	if .GENERATE_MIPMAPS in imageFlags {
		if .NEAREST in imageFlags {
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.NEAREST_MIPMAP_NEAREST))
		} else {
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.LINEAR_MIPMAP_LINEAR))
		}
	} else {
		if .NEAREST in imageFlags {
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.NEAREST))
		} else {
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.LINEAR))
		}
	}

	if .NEAREST in imageFlags {
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.NEAREST))
	} else {
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.LINEAR))
	}

	if .REPEAT_X in imageFlags {
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.REPEAT))
	}	else {
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
	}

	if .REPEAT_Y in imageFlags {
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.REPEAT))
	}	else {
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))
	}

	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)

	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	gl.PixelStorei(gl.UNPACK_SKIP_PIXELS, 0)
	gl.PixelStorei(gl.UNPACK_SKIP_ROWS, 0)

	if .GENERATE_MIPMAPS in imageFlags {
		gl.GenerateMipmap(gl.TEXTURE_2D)
	}

	__checkError(ctx, "create tex")
	__bindTexture(ctx, 0)

	return tex.id
}

__checkError :: proc(ctx: ^Context, str: string) {
	if .DEBUG in ctx.flags {
		err := gl.GetError()

		if err != gl.NO_ERROR {
			log.errorf("FOUND ERROR %v:\n\t%s\n", err, str)
		}
	}
}

__checkProgramError :: proc(prog: gl.Program) {
	status := gl.GetProgramParameter(prog, gl.LINK_STATUS)

	if status == 0 {
		buf: [1024]byte
		log_str := gl.GetProgramInfoLog(prog, buf[:])
		log.errorf("Program Error:\n%s\n", log_str)
	}
}

__checkShaderError :: proc(shader: gl.Shader, type: string) {
	status := gl.GetShaderiv(shader, gl.COMPILE_STATUS)

	if status == 0 {
		buf: [1024]byte
		log_str := gl.GetShaderInfoLog(shader, buf[:])
		log.errorf("Shader error:\n%s\n", log_str)
	}
}

// TODO good case for or_return
__createShader :: proc(
	shader: ^Shader,
	header: string,
	opts: string,
	vshader: string,
	fshader: string,
) -> bool {
	shader^ = {}

	prog := gl.CreateProgram()
	vert := gl.CreateShader(gl.VERTEX_SHADER)
	frag := gl.CreateShader(gl.FRAGMENT_SHADER)

	// WebGL ShaderSource takes a slice of strings
	vsrc := strings.concatenate({header, opts, vshader}, context.temp_allocator)
	gl.ShaderSource(vert, {vsrc})
	gl.CompileShader(vert)
	__checkShaderError(vert, "vert")

	// fragment shader
	fsrc := strings.concatenate({header, opts, fshader}, context.temp_allocator)
	gl.ShaderSource(frag, {fsrc})
	gl.CompileShader(frag)
	__checkShaderError(frag, "frag")

	gl.AttachShader(prog, vert)
	gl.AttachShader(prog, frag)

	gl.BindAttribLocation(prog, 0, "vertex")
	gl.BindAttribLocation(prog, 1, "tcoord")

	gl.LinkProgram(prog)
	__checkProgramError(prog)

	shader.prog = prog
	shader.vert = vert
	shader.frag = frag
	return true
}

__renderDeleteTexture :: proc(uptr: rawptr, image: int) -> bool {
	ctx := cast(^Context) uptr
	return __deleteTexture(ctx, image)
}

__renderUpdateTexture :: proc(
	uptr: rawptr,
	image: int,
	x, y: int,
	w, h: int,
	data: []byte,
) -> bool {
	ctx := cast(^Context) uptr
	tex := __findTexture(ctx, image)

	if tex == nil {
		return false
	}

	__bindTexture(ctx, tex.tex)

	gl.PixelStorei(gl.UNPACK_ALIGNMENT,1)

	x := x
	w := w
	data := data

	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, i32(tex.width))
	gl.PixelStorei(gl.UNPACK_SKIP_PIXELS, i32(x))
	gl.PixelStorei(gl.UNPACK_SKIP_ROWS, i32(y))

	if tex.type == .RGBA {
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, i32(x), i32(y), i32(w), i32(h), gl.RGBA, gl.UNSIGNED_BYTE, len(data), raw_data(data))
	} else {
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, i32(x), i32(y), i32(w), i32(h), gl.RED, gl.UNSIGNED_BYTE, len(data), raw_data(data))
	}

	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)

	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	gl.PixelStorei(gl.UNPACK_SKIP_PIXELS, 0)
	gl.PixelStorei(gl.UNPACK_SKIP_ROWS, 0)

	__bindTexture(ctx, 0)

	return true
}

__renderGetTextureSize :: proc(uptr: rawptr, image: int, w, h: ^int) -> bool {
	ctx := cast(^Context) uptr
	tex := __findTexture(ctx, image)

	if tex == nil {
		return false
	}

	w^ = tex.width
	h^ = tex.height
	return true
}

__xformToMat3x4 :: proc(m3: ^[12]f32, t: [6]f32) {
	m3[0] = t[0]
	m3[1] = t[1]
	m3[2] = 0
	m3[3] = 0
	m3[4] = t[2]
	m3[5] = t[3]
	m3[6] = 0
	m3[7] = 0
	m3[8] = t[4]
	m3[9] = t[5]
	m3[10] = 1
	m3[11] = 0
}

__premulColor :: proc(c: Color) -> (res: Color) {
	res = c
	res.r *= c.a
	res.g *= c.a
	res.b *= c.a
	return
}

__convertPaint :: proc(
	ctx: ^Context,
	frag: ^FragUniforms,
	paint: ^Paint,
	scissor: ^ScissorT,
	width: f32,
	fringe: f32,
	strokeThr: f32,
) -> bool {
	invxform: [6]f32
	frag^ = {}
	frag.innerColor = __premulColor(paint.innerColor)
	frag.outerColor = __premulColor(paint.outerColor)

	if scissor.extent[0] < -0.5 || scissor.extent[1] < -0.5 {
		frag.scissorMat = {}
		frag.scissorExt[0] = 1.0
		frag.scissorExt[1] = 1.0
		frag.scissorScale[0] = 1.0
		frag.scissorScale[1] = 1.0
	} else {
		nvg.TransformInverse(&invxform, scissor.xform)
		__xformToMat3x4(&frag.scissorMat, invxform)
		frag.scissorExt[0] = scissor.extent[0]
		frag.scissorExt[1] = scissor.extent[1]
		frag.scissorScale[0] = math.sqrt(scissor.xform[0]*scissor.xform[0] + scissor.xform[2]*scissor.xform[2]) / fringe
		frag.scissorScale[1] = math.sqrt(scissor.xform[1]*scissor.xform[1] + scissor.xform[3]*scissor.xform[3]) / fringe
	}

	frag.extent = paint.extent
	frag.strokeMult = (width * 0.5 + fringe * 0.5) / fringe
	frag.strokeThr = strokeThr

	if paint.image != 0 {
		tex := __findTexture(ctx, paint.image)

		if tex == nil {
			return false
		}

		// TODO maybe inversed?
		if .FLIP_Y in tex.flags {
			m1: [6]f32
			m2: [6]f32
			nvg.TransformTranslate(&m1, 0.0, frag.extent[1] * 0.5)
			nvg.TransformMultiply(&m1, paint.xform)
			nvg.TransformScale(&m2, 1.0, -1.0)
			nvg.TransformMultiply(&m2, m1)
			nvg.TransformTranslate(&m1, 0.0, -frag.extent[1] * 0.5)
			nvg.TransformMultiply(&m1, m2)
			nvg.TransformInverse(&invxform, m1)
		} else {
			nvg.TransformInverse(&invxform, paint.xform)
		}

		frag.type = .FILL_IMG

		if tex.type == .RGBA {
			frag.texType = (.PREMULTIPLIED in tex.flags) ? 0 : 1
		}	else {
			frag.texType = 2
		}
	} else {
		frag.type = .FILL_GRAD
		frag.radius = paint.radius
		frag.feather = paint.feather
		nvg.TransformInverse(&invxform, paint.xform)
	}

	__xformToMat3x4(&frag.paintMat, invxform)

	return true
}

__setUniforms :: proc(ctx: ^Context, uniformOffset: int, image: int) {
	when GL_USE_UNIFORMBUFFER {
		gl.BindBufferRange(gl.UNIFORM_BUFFER, i32(ctx.frag_binding), ctx.fragBuf, uniformOffset, size_of(FragUniforms))
	} else {
		frag := __fragUniformPtr(ctx, uniformOffset)
		gl.Uniform4fv(ctx.shader.loc[.FRAG], frag.uniform_array[:])
	}

	__checkError(ctx, "uniform4")

	tex: ^Texture
	if image != 0 {
		tex = __findTexture(ctx, image)
	}

	// If no image is set, use empty texture
	if tex == nil {
		tex = __findTexture(ctx, ctx.dummyTex)
	}

	__bindTexture(ctx, tex != nil ? tex.tex : 0)
	__checkError(ctx, "tex paint tex")
}

__renderViewport :: proc(uptr: rawptr, width, height, devicePixelRatio: f32) {
	ctx := cast(^Context) uptr
	ctx.view[0] = width
	ctx.view[1] = height
}

__fill :: proc(ctx: ^Context, call: ^Call) {
	paths := ctx.paths[call.pathOffset:]

	// Draw shapes
	gl.Enable(gl.STENCIL_TEST)
	__stencilMask(ctx, 0xff)
	__stencilFunc(ctx, gl.ALWAYS, 0, 0xff)
	gl.ColorMask(false, false, false, false)

	// set bindpoint for solid loc
	__setUniforms(ctx, call.uniformOffset, 0)
	__checkError(ctx, "fill simple")

	gl.StencilOpSeparate(gl.FRONT, gl.KEEP, gl.KEEP, gl.INCR_WRAP)
	gl.StencilOpSeparate(gl.BACK, gl.KEEP, gl.KEEP, gl.DECR_WRAP)
	gl.Disable(gl.CULL_FACE)
	for i in 0..<call.pathCount {
		gl.DrawArrays(gl.TRIANGLE_FAN, paths[i].fillOffset, paths[i].fillCount)
	}
	gl.Enable(gl.CULL_FACE)

	// Draw anti-aliased pixels
	gl.ColorMask(true, true, true, true)

	__setUniforms(ctx, call.uniformOffset + ctx.fragSize, call.image)
	__checkError(ctx, "fill fill")

	if .ANTI_ALIAS in ctx.flags {
		__stencilFunc(ctx, gl.EQUAL, 0x00, 0xff)
		gl.StencilOp(gl.KEEP, gl.KEEP, gl.KEEP)
		// Draw fringes
		for i in 0..<call.pathCount {
			gl.DrawArrays(gl.TRIANGLE_STRIP, paths[i].strokeOffset, paths[i].strokeCount)
		}
	}

	// Draw fill
	__stencilFunc(ctx, gl.NOTEQUAL, 0x0, 0xff)
	gl.StencilOp(gl.ZERO, gl.ZERO, gl.ZERO)
	gl.DrawArrays(gl.TRIANGLE_STRIP, call.triangleOffset, call.triangleCount)

	gl.Disable(gl.STENCIL_TEST)
}

__convexFill :: proc(ctx: ^Context, call: ^Call) {
	paths := ctx.paths[call.pathOffset:]

	__setUniforms(ctx, call.uniformOffset, call.image)
	__checkError(ctx, "convex fill")

	for i in 0..<call.pathCount {
		gl.DrawArrays(gl.TRIANGLE_FAN, paths[i].fillOffset, paths[i].fillCount)

		// draw fringes
		if paths[i].strokeCount > 0 {
			gl.DrawArrays(gl.TRIANGLE_STRIP, paths[i].strokeOffset, paths[i].strokeCount)
		}
	}
}

__stroke :: proc(ctx: ^Context, call: ^Call) {
	paths := ctx.paths[call.pathOffset:]

	if .STENCIL_STROKES in ctx.flags {
		gl.Enable(gl.STENCIL_TEST)
		__stencilMask(ctx, 0xff)

		// Fill the stroke base without overlap
		__stencilFunc(ctx, gl.EQUAL, 0x0, 0xff)
		gl.StencilOp(gl.KEEP, gl.KEEP, gl.INCR)
		__setUniforms(ctx, call.uniformOffset + ctx.fragSize, call.image)
		__checkError(ctx, "stroke fill 0")

		for i in 0..<call.pathCount {
			gl.DrawArrays(gl.TRIANGLE_STRIP, paths[i].strokeOffset, paths[i].strokeCount)
		}

		// Draw anti-aliased pixels.
		__setUniforms(ctx, call.uniformOffset, call.image)
		__stencilFunc(ctx, gl.EQUAL, 0x00, 0xff)
		gl.StencilOp(gl.KEEP, gl.KEEP, gl.KEEP)
		for i in 0..<call.pathCount {
			gl.DrawArrays(gl.TRIANGLE_STRIP, paths[i].strokeOffset, paths[i].strokeCount)
		}

		// Clear stencil buffer.
		gl.ColorMask(false, false, false, false)
		__stencilFunc(ctx, gl.ALWAYS, 0x0, 0xff)
		gl.StencilOp(gl.ZERO, gl.ZERO, gl.ZERO)
		__checkError(ctx, "stroke fill 1")
		for i in 0..<call.pathCount {
			gl.DrawArrays(gl.TRIANGLE_STRIP, paths[i].strokeOffset, paths[i].strokeCount)
		}
		gl.ColorMask(true, true, true, true)

		gl.Disable(gl.STENCIL_TEST)
	} else {
		__setUniforms(ctx, call.uniformOffset, call.image)
		__checkError(ctx, "stroke fill")

		// Draw Strokes
		for i in 0..<call.pathCount {
			gl.DrawArrays(gl.TRIANGLE_STRIP, paths[i].strokeOffset, paths[i].strokeCount)
		}
	}
}

__triangles :: proc(ctx: ^Context, call: ^Call) {
	__setUniforms(ctx, call.uniformOffset, call.image)
	__checkError(ctx, "triangles fill")
	gl.DrawArrays(gl.TRIANGLES, call.triangleOffset, call.triangleCount)
}

__renderCancel :: proc(uptr: rawptr) {
	ctx := cast(^Context) uptr
	clear(&ctx.verts)
	clear(&ctx.paths)
	clear(&ctx.calls)
	clear(&ctx.uniforms)
}

__blendFactorToGL :: proc(factor: nvg.BlendFactor) -> gl.Enum {
	switch factor {
	case .ZERO: return gl.ZERO
	case .ONE: return gl.ONE
	case .SRC_COLOR: return gl.SRC_COLOR
	case .ONE_MINUS_SRC_COLOR: return gl.ONE_MINUS_SRC_COLOR
	case .DST_COLOR: return gl.DST_COLOR
	case .ONE_MINUS_DST_COLOR: return gl.ONE_MINUS_DST_COLOR
	case .SRC_ALPHA: return gl.SRC_ALPHA
	case .ONE_MINUS_SRC_ALPHA: return gl.ONE_MINUS_SRC_ALPHA
	case .DST_ALPHA: return gl.DST_ALPHA
	case .ONE_MINUS_DST_ALPHA: return gl.ONE_MINUS_DST_ALPHA
	case .SRC_ALPHA_SATURATE: return gl.SRC_ALPHA_SATURATE
	}
	return gl.ZERO
}

__blendCompositeOperation :: proc(op: nvg.CompositeOperationState) -> Blend {
	blend := Blend {
		__blendFactorToGL(op.srcRGB),
		__blendFactorToGL(op.dstRGB),
		__blendFactorToGL(op.srcAlpha),
		__blendFactorToGL(op.dstAlpha),
	}
	return blend
}

__renderFlush :: proc(uptr: rawptr) {
	ctx := cast(^Context) uptr

	if len(ctx.calls) > 0 {
		// Setup require GL state.
		gl.UseProgram(ctx.shader.prog)

		gl.Enable(gl.CULL_FACE)
		gl.CullFace(gl.BACK)
		gl.FrontFace(gl.CCW)
		gl.Enable(gl.BLEND)
		gl.Disable(gl.DEPTH_TEST)
		gl.Disable(gl.SCISSOR_TEST)
		gl.ColorMask(true, true, true, true)
		gl.StencilMask(0xffffffff)
		gl.StencilOp(gl.KEEP, gl.KEEP, gl.KEEP)
		gl.StencilFunc(gl.ALWAYS, 0, 0xffffffff)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, 0)

		when USE_STATE_FILTER {
			ctx.boundTexture = 0
			ctx.stencilMask = 0xffffffff
			ctx.stencilFunc = gl.ALWAYS
			ctx.stencilFuncRef = 0
			ctx.stencilFuncMask = 0xffffffff
			ctx.blendFunc.src_RGB = gl.NONE
			ctx.blendFunc.src_alpha = gl.NONE
			ctx.blendFunc.dst_RGB = gl.NONE
			ctx.blendFunc.dst_alpha = gl.NONE
		}

		when GL_USE_UNIFORMBUFFER {
			// Upload ubo for frag shaders
			gl.BindBuffer(gl.UNIFORM_BUFFER, ctx.fragBuf)
			gl.BufferData(gl.UNIFORM_BUFFER, len(ctx.uniforms), raw_data(ctx.uniforms), gl.STREAM_DRAW)
		}

		// Upload vertex data
		gl.BindVertexArray(ctx.vertArr)

		gl.BindBuffer(gl.ARRAY_BUFFER, ctx.vertBuf)
		gl.BufferData(gl.ARRAY_BUFFER, len(ctx.verts) * size_of(Vertex), raw_data(ctx.verts), gl.STREAM_DRAW)
		gl.EnableVertexAttribArray(0)
		gl.EnableVertexAttribArray(1)
		gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(Vertex), 0)
		gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Vertex), 2 * size_of(f32))

		// Set view and texture just once per frame.
		gl.Uniform1i(ctx.shader.loc[.TEX], 0)
		gl.Uniform2fv(ctx.shader.loc[.VIEW_SIZE], {ctx.view})

		when GL_USE_UNIFORMBUFFER {
			gl.BindBuffer(gl.UNIFORM_BUFFER, ctx.fragBuf)
		}

		for i in 0..<len(ctx.calls) {
			call := &ctx.calls[i]
			__blendFuncSeparate(ctx, &call.blendFunc)

			switch call.type {
			case .NONE: {}
			case .FILL: __fill(ctx, call)
			case .CONVEX_FILL: __convexFill(ctx, call)
			case .STROKE: __stroke(ctx, call)
			case .TRIANGLES: __triangles(ctx, call)
			}
		}

		gl.DisableVertexAttribArray(0)
		gl.DisableVertexAttribArray(1)

		gl.BindVertexArray(0)

		gl.Disable(gl.CULL_FACE)
		gl.BindBuffer(gl.ARRAY_BUFFER, 0)
		gl.UseProgram(0)
		__bindTexture(ctx, 0)
	}

	// Reset calls
	clear(&ctx.verts)
	clear(&ctx.paths)
	clear(&ctx.calls)
	clear(&ctx.uniforms)
}

__maxVertCount :: proc(paths: []nvg.Path) -> (count: int) {
	for i in 0..<len(paths) {
		count += len(paths[i].fill)
		count += len(paths[i].stroke)
	}
	return
}

__allocCall :: #force_inline proc(ctx: ^Context) -> ^Call {
	append(&ctx.calls, Call {})
	return &ctx.calls[len(ctx.calls) - 1]
}

// alloc paths and return the original start position
__allocPaths :: proc(ctx: ^Context, count: int) -> int {
	old := len(ctx.paths)
	resize(&ctx.paths, len(ctx.paths) + count)
	return old
}

// alloc verts and return the original start position
__allocVerts :: proc(ctx: ^Context, count: int) -> int {
	old := len(ctx.verts)
	resize(&ctx.verts, len(ctx.verts) + count)
	return old
}

// alloc uniforms and return the original start position
__allocFragUniforms :: proc(ctx: ^Context, count: int) -> int {
	ret := len(ctx.uniforms)
	resize(&ctx.uniforms, len(ctx.uniforms) + count * ctx.fragSize)
	return ret
}

// get frag uniforms from byte slice offset
__fragUniformPtr :: proc(ctx: ^Context, offset: int) -> ^FragUniforms {
	return cast(^FragUniforms) &ctx.uniforms[offset]
}

///////////////////////////////////////////////////////////
// CALLBACKS
///////////////////////////////////////////////////////////

__renderFill :: proc(
	uptr: rawptr,
	paint: ^nvg.Paint,
	compositeOperation: nvg.CompositeOperationState,
	scissor: ^ScissorT,
	fringe: f32,
	bounds: [4]f32,
	paths: []nvg.Path,
) {
	ctx := cast(^Context) uptr
	call := __allocCall(ctx)

	call.type = .FILL
	call.triangleCount = 4
	call.pathOffset = __allocPaths(ctx, len(paths))
	call.pathCount = len(paths)
	call.image = paint.image
	call.blendFunc = __blendCompositeOperation(compositeOperation)

	if len(paths) == 1 && paths[0].convex {
		call.type = .CONVEX_FILL
		call.triangleCount = 0
	}

	// allocate vertices for all the paths
	maxverts := __maxVertCount(paths) + call.triangleCount
	offset := __allocVerts(ctx, maxverts)

	for i in 0..<len(paths) {
		copy := &ctx.paths[call.pathOffset + i]
		copy^ = {}
		path := &paths[i]

		if len(path.fill) > 0 {
			copy.fillOffset = offset
			copy.fillCount = len(path.fill)
			mem.copy(&ctx.verts[offset], &path.fill[0], size_of(Vertex) * len(path.fill))
			offset += len(path.fill)
		}

		if len(path.stroke) > 0 {
			copy.strokeOffset = offset
			copy.strokeCount = len(path.stroke)
			mem.copy(&ctx.verts[offset], &path.stroke[0], size_of(Vertex) * len(path.stroke))
			offset += len(path.stroke)
		}
	}

	// setup uniforms for draw calls
	if call.type == .FILL {
		// quad
		call.triangleOffset = offset
		quad := ctx.verts[call.triangleOffset:call.triangleOffset+4]
		quad[0] = { bounds[2], bounds[3], 0.5, 1 }
		quad[1] = { bounds[2], bounds[1], 0.5, 1 }
		quad[2] = { bounds[0], bounds[3], 0.5, 1 }
		quad[3] = { bounds[0], bounds[1], 0.5, 1 }

		// simple shader for stencil
		call.uniformOffset = __allocFragUniforms(ctx, 2)
		frag := __fragUniformPtr(ctx, call.uniformOffset)
		frag^ = {}
		frag.strokeThr = -1
		frag.type = .SIMPLE

		// fill shader
		__convertPaint(
			ctx,
			__fragUniformPtr(ctx, call.uniformOffset + ctx.fragSize),
			paint,
			scissor,
			fringe,
			fringe,
			-1,
		)
	} else {
		call.uniformOffset = __allocFragUniforms(ctx, 1)
		// fill shader
		__convertPaint(
			ctx,
			__fragUniformPtr(ctx, call.uniformOffset),
			paint,
			scissor,
			fringe,
			fringe,
			-1,
		)
	}
}

__renderStroke :: proc(
	uptr: rawptr,
	paint: ^Paint,
	compositeOperation: nvg.CompositeOperationState,
	scissor: ^ScissorT,
	fringe: f32,
	strokeWidth: f32,
	paths: []nvg.Path,
) {
	ctx := cast(^Context) uptr
	call := __allocCall(ctx)

	call.type = .STROKE
	call.pathOffset = __allocPaths(ctx, len(paths))
	call.pathCount = len(paths)
	call.image = paint.image
	call.blendFunc = __blendCompositeOperation(compositeOperation)

	// allocate vertices for all the paths
	maxverts := __maxVertCount(paths)
	offset := __allocVerts(ctx, maxverts)

	for i in 0..<len(paths) {
		copy := &ctx.paths[call.pathOffset + i]
		copy^ = {}
		path := &paths[i]

		if len(path.stroke) != 0 {
			copy.strokeOffset = offset
			copy.strokeCount = len(path.stroke)
			mem.copy(&ctx.verts[offset], &path.stroke[0], size_of(Vertex) * len(path.stroke))
			offset += len(path.stroke)
		}
	}

	if .STENCIL_STROKES in ctx.flags {
		// fill shader
		call.uniformOffset = __allocFragUniforms(ctx, 2)

		__convertPaint(
			ctx,
			__fragUniformPtr(ctx, call.uniformOffset),
			paint,
			scissor,
			strokeWidth,
			fringe,
			-1,
		)

		__convertPaint(
			ctx,
			__fragUniformPtr(ctx, call.uniformOffset + ctx.fragSize),
			paint,
			scissor,
			strokeWidth,
			fringe,
			1 - 0.5 / 255,
		)
	} else {
		// fill shader
		call.uniformOffset = __allocFragUniforms(ctx, 1)
		__convertPaint(
			ctx,
			__fragUniformPtr(ctx, call.uniformOffset),
			paint,
			scissor,
			strokeWidth,
			fringe,
			-1,
		)
	}
}

__renderTriangles :: proc(
	uptr: rawptr,
	paint: ^Paint,
	compositeOperation: nvg.CompositeOperationState,
	scissor: ^ScissorT,
	verts: []Vertex,
	fringe: f32,
) {
	ctx := cast(^Context) uptr
	call := __allocCall(ctx)

	call.type = .TRIANGLES
	call.image = paint.image
	call.blendFunc = __blendCompositeOperation(compositeOperation)

	// allocate the vertices for all the paths
	call.triangleOffset = __allocVerts(ctx, len(verts))
	call.triangleCount = len(verts)
	mem.copy(&ctx.verts[call.triangleOffset], raw_data(verts), size_of(Vertex) * len(verts))

	// fill shader
	call.uniformOffset = __allocFragUniforms(ctx, 1)
	frag := __fragUniformPtr(ctx, call.uniformOffset)
	__convertPaint(ctx, frag, paint, scissor, 1, fringe, -1)
	frag.type = .IMG
}

__renderDelete :: proc(uptr: rawptr) {
	ctx := cast(^Context) uptr
	__deleteShader(&ctx.shader)

	if ctx.fragBuf != 0 {
		gl.DeleteBuffer(ctx.fragBuf)
	}

	if ctx.vertArr != 0 {
		gl.DeleteVertexArray(ctx.vertArr)
	}

	if ctx.vertBuf != 0 {
		gl.DeleteBuffer(ctx.vertBuf)
	}

	for &texture in ctx.textures {
		if texture.tex != 0 && (.NO_DELETE not_in texture.flags) {
			gl.DeleteTexture(texture.tex)
		}
	}

	delete(ctx.textures)
	delete(ctx.paths)
	delete(ctx.verts)
	delete(ctx.uniforms)
	delete(ctx.calls)
	free(ctx)
}

///////////////////////////////////////////////////////////
// CREATION?
///////////////////////////////////////////////////////////

Create :: proc(flags: CreateFlags) -> ^nvg.Context {
	ctx := new(Context)
	params: nvg.Params
	params.renderCreate = __renderCreate
	params.renderCreateTexture = __renderCreateTexture
	params.renderDeleteTexture = __renderDeleteTexture
	params.renderUpdateTexture = __renderUpdateTexture
	params.renderGetTextureSize = __renderGetTextureSize
	params.renderViewport = __renderViewport
	params.renderCancel = __renderCancel
	params.renderFlush = __renderFlush
	params.renderFill = __renderFill
	params.renderStroke = __renderStroke
	params.renderTriangles = __renderTriangles
	params.renderDelete = __renderDelete
	params.userPtr = ctx
	params.edgeAntiAlias = (.ANTI_ALIAS in flags)
	ctx.flags = flags
	return nvg.CreateInternal(params)
}

Destroy :: proc(ctx: ^nvg.Context) {
	nvg.DeleteInternal(ctx)
}

CreateImageFromHandle :: proc(ctx: ^nvg.Context, textureId: gl.Texture, w, h: int, imageFlags: ImageFlags) -> int {
	gctx := cast(^Context) ctx.params.userPtr
	tex := __allocTexture(gctx)
	tex.type = .RGBA
	tex.tex = textureId
	tex.flags = imageFlags
	tex.width = w
	tex.height = h
	return tex.id
}

ImageHandle :: proc(ctx: ^nvg.Context, textureId: int) -> gl.Texture {
	gctx := cast(^Context) ctx.params.userPtr
	tex := __findTexture(gctx, textureId)
	return tex.tex
}

// framebuffer additional

framebuffer :: struct {
	ctx: ^nvg.Context,
	fbo: gl.Framebuffer,
	rbo: gl.Renderbuffer,
	texture: gl.Texture,
	image: int,
}

BindFramebuffer :: proc(fb: ^framebuffer) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, fb != nil ? fb.fbo : gl.Framebuffer(0))
}

CreateFramebuffer :: proc(ctx: ^nvg.Context, w, h: int, imageFlags: ImageFlags) -> (fb: framebuffer) {
	imageFlags := imageFlags
	imageFlags += {.FLIP_Y, .PREMULTIPLIED}
	fb.image = nvg.CreateImageRGBA(ctx, w, h, imageFlags, nil)
	fb.texture = ImageHandle(ctx, fb.image)
	fb.ctx = ctx

	// frame buffer object
	fb.fbo = gl.CreateFramebuffer()
	gl.BindFramebuffer(gl.FRAMEBUFFER, fb.fbo)

	// render buffer object
	fb.rbo = gl.CreateRenderbuffer()
	gl.BindRenderbuffer(gl.RENDERBUFFER, fb.rbo)
	gl.RenderbufferStorage(gl.RENDERBUFFER, gl.STENCIL_INDEX8, i32(w), i32(h))

	// combine all
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, fb.texture, 0)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.STENCIL_ATTACHMENT, gl.RENDERBUFFER, fb.rbo)

	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
// #ifdef gl.DEPTH24_STENCIL8
		// If gl.STENCIL_INDEX8 is not supported, try gl.DEPTH24_STENCIL8 as a fallback.
		// Some graphics cards require a depth buffer along with a stencil.
		gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, i32(w), i32(h))
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, fb.texture, 0)
		gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.STENCIL_ATTACHMENT, gl.RENDERBUFFER, fb.rbo)

		if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
			fmt.eprintln("ERROR: Framebuffer incomplete")
		}
// #endif // gl.DEPTH24_STENCIL8
// 			goto error
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, gl.Framebuffer(0))
	gl.BindRenderbuffer(gl.RENDERBUFFER, gl.Renderbuffer(0))
	return
}

DeleteFramebuffer :: proc(fb: ^framebuffer) {
	if fb == nil {
		return
	}

	if fb.fbo != 0 {
		gl.DeleteFramebuffer(fb.fbo)
	}

	if fb.rbo != 0 {
		gl.DeleteRenderbuffer(fb.rbo)
	}

	if fb.image >= 0 {
		nvg.DeleteImage(fb.ctx, fb.image)
	}

	fb.ctx = nil
	fb.fbo = 0
	fb.rbo = 0
	fb.texture = 0
	fb.image = -1
}
