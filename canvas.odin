package mathboardx

import "core:math/linalg"
import "core:slice"
import nvg "nanovg"

Point :: [2]f64
Vec2 :: [2]f64

AABB :: struct {
	min, max: Point,
}

@(private = "file")
aabb_contains_point :: proc(rect: AABB, p: Point) -> bool {
	return p.x >= rect.min.x && p.x <= rect.max.x && p.y >= rect.min.y && p.y <= rect.max.y
}

@(private = "file")
aabb_contains_rect :: proc(outer, inner: AABB) -> bool {
	return(
		inner.min.x >= outer.min.x &&
		inner.max.x <= outer.max.x &&
		inner.min.y >= outer.min.y &&
		inner.max.y <= outer.max.y \
	)
}

@(private = "file")
aabb_intersects :: proc(a, b: AABB) -> bool {
	return !(b.min.x > a.max.x || b.max.x < a.min.x || b.min.y > a.max.y || b.max.y < a.min.y)
}

QT_MAX_ELEMENTS :: 8 // max strokes in quadnode
QT_MIN_SIZE :: 0.05

Quadtree_Node :: struct {
	bounds:   AABB,
	strokes:  [dynamic]^Stroke,
	children: ^[4]Quadtree_Node,
	is_leaf:  bool,
}

quadtree_init :: proc(bounds: AABB) -> Quadtree_Node {
	return {bounds = bounds, is_leaf = true}
}

quadtree_split :: proc(node: ^Quadtree_Node) {
	half_size := (node.bounds.max - node.bounds.min) * 0.5
	center := node.bounds.min + half_size

	node.children = new([4]Quadtree_Node)
	// TL, TR, BL, BR
	node.children[0] = quadtree_init({node.bounds.min, center})
	node.children[1] = quadtree_init(
		{{center.x, node.bounds.min.y}, {node.bounds.max.x, center.y}},
	)
	node.children[2] = quadtree_init(
		{{node.bounds.min.x, center.y}, {center.x, node.bounds.max.y}},
	)
	node.children[3] = quadtree_init({center, node.bounds.max})

	node.is_leaf = false

	kept_strokes := make([dynamic]^Stroke)

	for s in node.strokes {
		moved := false
		for i in 0 ..< 4 {
			if aabb_contains_rect(node.children[i].bounds, s.bounds) {
				quadtree_insert(&node.children[i], s)
				moved = true
				break
			}
		}
		if !moved {
			append(&kept_strokes, s)
		}
	}

	delete(node.strokes)
	node.strokes = kept_strokes
}

quadtree_insert :: proc(node: ^Quadtree_Node, s: ^Stroke) {
	if !aabb_intersects(node.bounds, s.bounds) do return

	if node.is_leaf {
		append(&node.strokes, s)

		node_size := node.bounds.max.x - node.bounds.min.x
		should_split := len(node.strokes) >= QT_MAX_ELEMENTS && node_size > QT_MIN_SIZE

		if should_split {
			quadtree_split(node)
		}
	} else {
		// try to push down
		inserted_into_child := false
		for i in 0 ..< 4 {
			if aabb_contains_rect(node.children[i].bounds, s.bounds) {
				quadtree_insert(&node.children[i], s)
				inserted_into_child = true
				break
			}
		}

		// stroke is too big to fit in one child, stays in parent
		if !inserted_into_child {
			append(&node.strokes, s)
		}
	}
}

// Returns true if the node is now empty and can be considered for merging
quadtree_remove :: proc(node: ^Quadtree_Node, s: ^Stroke) -> bool {
	if !aabb_intersects(node.bounds, s.bounds) do return false

	// try to remove from this node
	for i in 0 ..< len(node.strokes) {
		if node.strokes[i] == s {
			unordered_remove(&node.strokes, i)
			return len(node.strokes) == 0 && node.is_leaf
		}
	}

	if !node.is_leaf {
		can_merge := true

		// try to remove from children
		for i in 0 ..< 4 {
			quadtree_remove(&node.children[i], s)

			// child prevents merging?
			if !node.children[i].is_leaf || len(node.children[i].strokes) > 0 {
				can_merge = false
			}
		}

		if can_merge {
			quadtree_consolidate(node)
		}
	}

	return false
}

// Merge children back into parent
quadtree_consolidate :: proc(node: ^Quadtree_Node) {
	if node.is_leaf do return

	// safety: children will likely be empty if we get to here, but move them here anyway
	for i in 0 ..< 4 {
		for s in node.children[i].strokes {
			append(&node.strokes, s)
		}
		delete(node.children[i].strokes)
	}

	free(node.children)
	node.children = nil
	node.is_leaf = true
}

quadtree_query :: proc(node: ^Quadtree_Node, view_bounds: AABB, results: ^[dynamic]^Stroke) {
	if !aabb_intersects(node.bounds, view_bounds) do return

	for s in node.strokes {
		if aabb_intersects(s.bounds, view_bounds) {
			append(results, s)
		}
	}
	if !node.is_leaf {
		for i in 0 ..< 4 {
			quadtree_query(&node.children[i], view_bounds, results)
		}
	}
}


Stroke :: struct {
	points:     [dynamic]Point,
	color:      nvg.Color, // RGBA f32
	size:       f32,
	bounds:     AABB,
	baked:      nvg.BakedStroke,
	is_baked:   bool,
	baked_zoom: f32,
}

stroke_update_bounds :: proc(s: ^Stroke) {
	if len(s.points) == 0 do return

	min_p := s.points[0]
	max_p := s.points[0]

	for p in s.points {
		min_p.x = min(min_p.x, p.x)
		min_p.y = min(min_p.y, p.y)
		max_p.x = max(max_p.x, p.x)
		max_p.y = max(max_p.y, p.y)
	}

	padding := f64(s.size * 0.5)
	s.bounds = {
		min = min_p - padding,
		max = max_p + padding,
	}
}


Undo_Action :: struct {
	stroke: ^Stroke,
}

Layer :: struct {
	name:       string,
	strokes:    [dynamic]^Stroke,
	tree:       Quadtree_Node,
	undo_stack: [dynamic]Undo_Action,
	redo_stack: [dynamic]Undo_Action,
}

// Expand the quadtree upwards if stroke is outside current bounds
layer_ensure_bounds :: proc(l: ^Layer, s: ^Stroke) {
	mid := (s.bounds.min + s.bounds.max) * 0.5

	for !aabb_contains_point(l.tree.bounds, mid) {
		old_root := l.tree
		old_size := old_root.bounds.max - old_root.bounds.min

		expand_left := mid.x < old_root.bounds.min.x
		expand_up := mid.y < old_root.bounds.min.y

		new_min := old_root.bounds.min
		new_max := old_root.bounds.max

		child_index := 0

		if expand_left {
			new_min.x -= old_size.x
			child_index += 1
		} else {
			new_max.x += old_size.x
		}

		if expand_up {
			new_min.y -= old_size.y
			child_index += 2
		} else {
			new_max.y += old_size.y
		}

		// need new root and siblings
		l.tree = quadtree_init({new_min, new_max})
		l.tree.is_leaf = false
		l.tree.children = new([4]Quadtree_Node)

		half_size := (new_max - new_min) * 0.5
		center := new_min + half_size

		l.tree.children[0] = quadtree_init({new_min, center})
		l.tree.children[1] = quadtree_init({{center.x, new_min.y}, {new_max.x, center.y}})
		l.tree.children[2] = quadtree_init({{new_min.x, center.y}, {center.x, new_max.y}})
		l.tree.children[3] = quadtree_init({center, new_max})

		strokes := &l.tree.children[child_index].strokes
		if strokes^ != nil do delete(strokes^)
		l.tree.children[child_index] = old_root
	}
}

Canvas :: struct {
	layers:      [dynamic]Layer,
	layer:       ^Layer, // active layer
	pan:         Vec2,
	zoom:        f32,
	was_drawing: bool, // last frame
}

canvas_new :: proc() -> Canvas {
	c := Canvas {
		zoom = 1.0,
	}

	canvas_add_layer(&c, "default")
	c.layer = &c.layers[0]

	return c
}

canvas_add_layer :: proc(c: ^Canvas, name: string) {
	ROOT_SIZE :: 1_000
	initial_bounds := AABB {
		min = {-ROOT_SIZE, -ROOT_SIZE},
		max = {ROOT_SIZE, ROOT_SIZE},
	}

	append(&c.layers, Layer{name = name, tree = quadtree_init(initial_bounds)})
}

@(private = "file")
screen_to_world :: proc(c: ^Canvas, screen_pos: Point) -> Point {
	return (screen_pos - c.pan) / f64(c.zoom)
}

@(private = "file")
world_to_screen :: proc(c: ^Canvas, world_pos: Point) -> Point {
	return (world_pos * f64(c.zoom)) + c.pan
}

canvas_undo :: proc(c: ^Canvas) {
	l := c.layer
	if len(l.undo_stack) == 0 do return

	action := pop(&l.undo_stack)

	if len(l.strokes) > 0 {
		pop(&l.strokes)
		quadtree_remove(&l.tree, action.stroke)
		append(&l.redo_stack, action)
	}
}

canvas_redo :: proc(c: ^Canvas) {
	l := c.layer
	if len(l.redo_stack) == 0 do return

	action := pop(&l.redo_stack)
	append(&l.undo_stack, action)
	append(&l.strokes, action.stroke)
}

canvas_update :: proc(
	c: ^Canvas,
	mouse_pos: Point,
	mouse_dt: Vec2,
	is_held, is_panning: bool,
	mwheel: f32,
) {
	if is_panning do c.pan += mouse_dt

	if mwheel != 0.0 {
		before_zoom := screen_to_world(c, mouse_pos)
		ZOOM_SPEED :: 0.1
		if mwheel > 0 do c.zoom *= (1.0 + ZOOM_SPEED)
		else do c.zoom /= (1.0 + ZOOM_SPEED)

		c.zoom = clamp(c.zoom, 0.001, 100.0)

		after_zoom := screen_to_world(c, mouse_pos)
		c.pan += (after_zoom - before_zoom) * f64(c.zoom)
	}

	if is_held {
		raw_world_pos := screen_to_world(c, mouse_pos)

		if !c.was_drawing {
			new_stroke := new(Stroke)
			new_stroke^ = Stroke {
				points = make([dynamic]Point, 0, 16),
				color  = nvg.RGB(0, 0, 0),
				size   = 8.0 / c.zoom,
			}
			append(&new_stroke.points, raw_world_pos)
			append(&c.layer.strokes, new_stroke)
			c.was_drawing = true
		} else {
			cur_stroke := c.layer.strokes[len(c.layer.strokes) - 1]
			last_p := cur_stroke.points[len(cur_stroke.points) - 1]

			SMOOTHING :: 0.5
			world_pos := linalg.lerp(last_p, raw_world_pos, SMOOTHING)

			epsilon := 0.5 / f64(c.zoom)
			if linalg.distance(last_p, world_pos) > epsilon {
				append(&cur_stroke.points, world_pos)
				stroke_update_bounds(cur_stroke)
			}
		}
	} else if c.was_drawing {
		idx := len(c.layer.strokes) - 1
		l := c.layer
		if idx >= 0 {
			s := l.strokes[idx]

			if len(s.points) == 1 {
				dot_offset := f64(s.size * 0.001)
				append(&s.points, s.points[0] + {dot_offset, 0})
			} else {
				old_points := s.points
				s.points = rdp_simplify(old_points[:], 0.1 / c.zoom)
				delete(old_points)

				if len(s.points) < 2 {
					if len(s.points) == 1 {
						append(&s.points, s.points[0] + {0.01, 0})
					} else {
						free(s)
						pop(&l.strokes)
						c.was_drawing = false
						return
					}
				}
			}

			stroke_update_bounds(s)
			layer_ensure_bounds(l, s)
			quadtree_insert(&l.tree, s)

			append(&l.undo_stack, Undo_Action{stroke = s})

			for &action in l.redo_stack {
				if action.stroke.is_baked do nvg.DeleteBakedStroke(&action.stroke.baked)
				delete(action.stroke.points)
				free(action.stroke)
			}
			clear(&l.redo_stack)
		}
		c.was_drawing = false
	}
}

canvas_render :: proc(c: ^Canvas, vg: ^nvg.Context, window_w, window_h: f32, debug: bool = false) {
	world_origin := screen_to_world(c, {0, 0})

	view_min := world_origin
	view_max := screen_to_world(c, {f64(window_w), f64(window_h)})
	view_aabb := AABB{view_min, view_max}

	nvg.Save(vg)
	// translation will be handled per-stroke
	nvg.Scale(vg, c.zoom, c.zoom)

	for &layer in c.layers {
		visible_strokes: [dynamic]^Stroke
		visible_strokes.allocator = context.temp_allocator
		quadtree_query(&layer.tree, view_aabb, &visible_strokes)

		for s in visible_strokes {
			draw_stroke(vg, c, s, c.zoom, false, world_origin)
		}

		if c.layer == &layer && c.was_drawing && len(layer.strokes) > 0 {
			active_stroke := layer.strokes[len(layer.strokes) - 1]
			draw_stroke(vg, c, active_stroke, c.zoom, true, world_origin)
		}
	}
	nvg.Restore(vg)

	if debug {
		for &layer in c.layers {
			render_debug_quadtree(vg, c, &layer.tree, view_aabb)
		}
	}
}

draw_stroke :: proc(
	vg: ^nvg.Context,
	c: ^Canvas,
	stroke: ^Stroke,
	current_zoom: f32,
	is_active: bool,
	world_origin: Point,
) {
	pts := stroke.points
	n := len(pts)
	if n < 2 do return

	// feathering LOD
	if !is_active && stroke.is_baked {
		if abs(current_zoom - stroke.baked_zoom) / stroke.baked_zoom > 0.1 {
			nvg.DeleteBakedStroke(&stroke.baked)
			stroke.is_baked = false
		}
	}

	// fastpath: stroke is baked
	if !is_active && stroke.is_baked {
		nvg.StrokeColor(vg, stroke.color)
		nvg.StrokeWidth(vg, stroke.size)

		draw_pos := stroke.bounds.min - world_origin

		nvg.Save(vg)
		nvg.Translate(vg, f32(draw_pos.x), f32(draw_pos.y))
		nvg.StrokeBaked(vg, &stroke.baked)
		nvg.Restore(vg)
		return
	}

	// tessellate
	nvg.BeginPath(vg)
	nvg.StrokeColor(vg, stroke.color)
	nvg.StrokeWidth(vg, stroke.size)
	nvg.LineCap(vg, .ROUND)
	nvg.LineJoin(vg, .ROUND)

	p0 := pts[0] - world_origin
	nvg.MoveTo(vg, f32(p0.x), f32(p0.y))

	if n == 2 {
		p1 := pts[1] - world_origin
		nvg.LineTo(vg, f32(p1.x), f32(p1.y))
	} else {
		// Catmull-Rom
		for i in 0 ..< n - 1 {
			// offset all control points
			p0 := pts[max(0, i - 1)] - world_origin
			p1 := pts[i] - world_origin
			p2 := pts[i + 1] - world_origin
			p3 := pts[min(n - 1, i + 2)] - world_origin

			cp1 := p1 + (p2 - p0) * (1.0 / 6.0)
			cp2 := p2 - (p3 - p1) * (1.0 / 6.0)
			nvg.BezierTo(vg, f32(cp1.x), f32(cp1.y), f32(cp2.x), f32(cp2.y), f32(p2.x), f32(p2.y))
		}
	}

	// bake/render
	if !is_active {
		nvg.Stroke(vg)
		bake_offset := world_origin - stroke.bounds.min
		stroke.baked = nvg.BakeStroke(vg, bake_offset)
		stroke.is_baked = true
		stroke.baked_zoom = current_zoom
	} else {
		nvg.Stroke(vg)
	}
}


render_debug_quadtree :: proc(vg: ^nvg.Context, c: ^Canvas, node: ^Quadtree_Node, view: AABB) {
	if !aabb_intersects(node.bounds, view) do return

	min_screen := world_to_screen(c, node.bounds.min)
	max_screen := world_to_screen(c, node.bounds.max)

	nvg.BeginPath(vg)
	nvg.Rect(
		vg,
		f32(min_screen.x),
		f32(min_screen.y),
		f32(max_screen.x - min_screen.x),
		f32(max_screen.y - min_screen.y),
	)

	color := node.is_leaf ? nvg.RGBA(0, 255, 0, 50) : nvg.RGBA(0, 100, 255, 30)
	color_faint := color
	color_faint.a /= 2
	nvg.StrokeColor(vg, color)
	nvg.StrokeWidth(vg, 4.0)
	nvg.FillColor(vg, color_faint)
	nvg.Fill(vg)
	nvg.Stroke(vg)

	if !node.is_leaf {
		for i in 0 ..< 4 {
			render_debug_quadtree(vg, c, &node.children[i], view)
		}
	}
}

@(private = "file")
rdp_simplify :: proc(points: []Point, epsilon: f32) -> [dynamic]Point {
	if len(points) < 3 do return slice.to_dynamic(points)

	max_dist: f64 = 0.0
	index := 0

	epsilon_f64 := f64(epsilon)

	for i in 1 ..< len(points) - 1 {
		dist := perpendicular_distance(points[i], points[0], points[len(points) - 1])
		if dist > max_dist {
			index = i
			max_dist = dist
		}
	}

	res := make([dynamic]Point)
	if max_dist > epsilon_f64 {
		left := rdp_simplify(points[:index + 1], epsilon)
		right := rdp_simplify(points[index:], epsilon)

		append(&res, ..left[:len(left) - 1])
		append(&res, ..right[:])
		delete(left)
		delete(right)
	} else {
		append(&res, points[0])
		append(&res, points[len(points) - 1])
	}
	return res
}

@(private = "file")
perpendicular_distance :: proc(p, line_start, line_end: Point) -> f64 {
	dx := line_end.x - line_start.x
	dy := line_end.y - line_start.y
	mag := dx * dx + dy * dy
	if mag == 0 do return linalg.distance(p, line_start)

	u := ((p.x - line_start.x) * dx + (p.y - line_start.y) * dy) / mag
	intersection := Point{line_start.x + u * dx, line_start.y + u * dy}
	return linalg.distance(p, intersection)
}
