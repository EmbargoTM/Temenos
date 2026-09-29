// A small CPU canvas (milk's tx canvas, for GDI): a premultiplied ARGB DIB
// shown through a layered window, so every shape gets anti-aliased edges and
// real transparency at any corner radius. Text is drawn by GDI in grayscale
// on a separate mask (GDI cannot write alpha) and blended in with its colour.
package temenos

import "core:math"
import "core:slice"
import win "core:sys/windows"

foreign import gdi32 "system:Gdi32.lib"
@(default_calling_convention = "system")
foreign gdi32 {
	GetTextFaceW :: proc(hdc: win.HDC, c: i32, name: win.LPWSTR) -> i32 ---
	GdiFlush     :: proc() -> win.BOOL ---
}

DT_CENTER       :: 0x0001
DT_VCENTER      :: 0x0004
DT_SINGLELINE   :: 0x0020
DT_NOPREFIX     :: 0x0800
DT_END_ELLIPSIS :: 0x8000

foreign import user32 "system:User32.lib"
@(default_calling_convention = "system")
foreign user32 {
	UpdateLayeredWindow :: proc(hwnd: win.HWND, hdcDst: win.HDC, pptDst: ^win.POINT, psize: ^win.SIZE, hdcSrc: win.HDC,
	                            pptSrc: ^win.POINT, crKey: win.COLORREF, pblend: ^win.BLENDFUNCTION, dwFlags: win.DWORD) -> win.BOOL ---
}

ULW_ALPHA    :: 0x02
AC_SRC_ALPHA :: 0x01

Canvas :: struct {
	dc, mask_dc:   win.HDC,
	bmp, mask_bmp: win.HBITMAP,
	px, mask:      []u32, // top-down rows; px is premultiplied BGRA
	w, h:          i32,
}

@(private = "file")
make_dib :: proc(w, h: i32) -> (dc: win.HDC, bmp: win.HBITMAP, px: []u32) {
	bi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	bits: rawptr
	dc = win.CreateCompatibleDC(nil)
	bmp = win.CreateDIBSection(dc, &bi, win.DIB_RGB_COLORS, &bits, nil, 0)
	win.SelectObject(dc, win.HGDIOBJ(bmp))
	return dc, bmp, ([^]u32)(bits)[:w * h]
}

canvas_resize :: proc(cv: ^Canvas, w, h: i32) {
	if cv.dc != nil && cv.w == w && cv.h == h { return }
	canvas_free(cv)
	cv.w, cv.h = max(w, 1), max(h, 1)
	cv.dc, cv.bmp, cv.px = make_dib(cv.w, cv.h)
	cv.mask_dc, cv.mask_bmp, cv.mask = make_dib(cv.w, cv.h)
	win.SetBkMode(cv.mask_dc, .TRANSPARENT)
	win.SetTextColor(cv.mask_dc, 0xFFFFFF)
}

canvas_free :: proc(cv: ^Canvas) {
	if cv.dc == nil { return }
	win.DeleteDC(cv.dc); win.DeleteObject(win.HGDIOBJ(cv.bmp))
	win.DeleteDC(cv.mask_dc); win.DeleteObject(win.HGDIOBJ(cv.mask_bmp))
	cv^ = {}
}

canvas_clear :: proc(cv: ^Canvas) { slice.zero(cv.px) }

// Show the canvas as the layered window's content at (x, y).
present :: proc(cv: ^Canvas, hwnd: win.HWND, x, y: i32, alpha: u8 = 255) {
	pt, src := win.POINT{x, y}, win.POINT{}
	size := win.SIZE{cv.w, cv.h}
	bf := win.BLENDFUNCTION{BlendOp = win.AC_SRC_OVER, SourceConstantAlpha = win.BYTE(alpha), AlphaFormat = AC_SRC_ALPHA}
	UpdateLayeredWindow(hwnd, nil, &pt, &size, cv.dc, &src, 0, &bf, ULW_ALPHA)
}

// Move / fade a layered window without re-sending its content.
present_move :: proc(hwnd: win.HWND, x, y: i32, alpha: u8) {
	pt := win.POINT{x, y}
	bf := win.BLENDFUNCTION{BlendOp = win.AC_SRC_OVER, SourceConstantAlpha = win.BYTE(alpha), AlphaFormat = AC_SRC_ALPHA}
	UpdateLayeredWindow(hwnd, nil, &pt, nil, nil, nil, 0, &bf, ULW_ALPHA)
}

// Source-over of colour `rgb` (0xRRGGBB) with opacity `a` onto a premultiplied pixel.
@(private = "file")
blend :: #force_inline proc(dst: ^u32, rgb: u32, a: f32) {
	if a <= 0 { return }
	d, ia := dst^, 1 - a
	ch :: #force_inline proc(s, d: u32, a, ia: f32) -> u32 { return u32(f32(s) * a + f32(d) * ia + 0.5) }
	dst^ = ch(255, d >> 24, a, ia) << 24 | ch(rgb >> 16 & 0xFF, d >> 16 & 0xFF, a, ia) << 16 |
	       ch(rgb >> 8 & 0xFF, d >> 8 & 0xFF, a, ia) << 8 | ch(rgb & 0xFF, d & 0xFF, a, ia)
}

// Anti-aliased rounded rectangle (signed distance field). `soft` > 1 blurs
// the edge over that many pixels: soft shadows.
fill_round :: proc(cv: ^Canvas, x, y, w, h, radius: f32, rgb: u32, alpha: f32 = 1, soft: f32 = 1) {
	if w <= 0 || h <= 0 { return }
	r := clamp(radius, 0, min(w, h) / 2)
	cx, cy := x + w / 2, y + h / 2
	hx, hy := w / 2 - r, h / 2 - r
	x0, x1 := max(i32(x - soft), 0), min(i32(math.ceil(x + w + soft)), cv.w)
	y0, y1 := max(i32(y - soft), 0), min(i32(math.ceil(y + h + soft)), cv.h)
	solid := 0xFF00_0000 | rgb
	for py in y0 ..< y1 {
		qy := abs(f32(py) + 0.5 - cy) - hy
		row := cv.px[py * cv.w:]
		for px in x0 ..< x1 {
			qx := abs(f32(px) + 0.5 - cx) - hx
			// Distance to the edge; only the corner arcs need a square root.
			d := (qx > 0 && qy > 0 ? math.sqrt(qx * qx + qy * qy) : max(qx, qy)) - r
			a := alpha * clamp(0.5 - d / soft, 0, 1)
			if a >= 1 { row[px] = solid } else if a > 0 { blend(&row[px], rgb, a) }
		}
	}
}

// The first installed face: GDI silently substitutes an unrelated font for a missing one.
@(private = "file")
first_font :: proc(px, weight: i32, faces: ..string) -> win.HFONT {
	dc := win.CreateCompatibleDC(nil)
	defer win.DeleteDC(dc)
	for face, i in faces {
		f := win.CreateFontW(-px, 0, 0, 0, weight, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS,
		                     win.ANTIALIASED_QUALITY, win.DEFAULT_PITCH, win.utf8_to_wstring(face, context.temp_allocator))
		win.SelectObject(dc, win.HGDIOBJ(f))
		name: [64]u16
		GetTextFaceW(dc, len(name), &name[0])
		if got, _ := win.wstring_to_utf8(cstring16(&name[0]), -1, context.temp_allocator); got == face || i == len(faces) - 1 { return f }
		win.DeleteObject(win.HGDIOBJ(f))
	}
	return nil
}

// A configured face, else Windows 11's UI font, else Windows 10's.
make_font :: proc(px: i32, weight: i32 = 400, face := "") -> win.HFONT {
	return face != "" ? first_font(px, weight, face) : first_font(px, weight, "Segoe UI Variable Text", "Segoe UI")
}

icon_font :: proc(px: i32) -> win.HFONT { return first_font(px, 400, "Segoe Fluent Icons", "Segoe MDL2 Assets") }

text_width :: proc(cv: ^Canvas, font: win.HFONT, s: string) -> i32 {
	ws := win.utf8_to_utf16(s, context.temp_allocator)
	win.SelectObject(cv.mask_dc, win.HGDIOBJ(font))
	size: win.SIZE
	win.GetTextExtentPoint32W(cv.mask_dc, cstring16(raw_data(ws)), i32(len(ws)), &size)
	return size.cx
}

TEXT_CENTER :: DT_CENTER

// GDI text into the mask (cleared first), vertically centred in (x, y, w, h);
// returns that box clipped to the canvas.
@(private = "file")
mask_text :: proc(cv: ^Canvas, font: win.HFONT, s: string, x, y, w, h: i32, flags: win.UINT) -> (rc: win.RECT, ok: bool) {
	rc = {max(x, 0), max(y, 0), min(x + w, cv.w), min(y + h, cv.h)}
	if rc.left >= rc.right || rc.top >= rc.bottom { return rc, false }
	for py in rc.top ..< rc.bottom { slice.zero(cv.mask[py * cv.w + rc.left:py * cv.w + rc.right]) }
	ws := win.utf8_to_utf16(s, context.temp_allocator)
	win.SelectObject(cv.mask_dc, win.HGDIOBJ(font))
	area := win.RECT{x, y, x + w, y + h}
	win.DrawTextW(cv.mask_dc, cstring16(raw_data(ws)), i32(len(ws)), &area,
	              win.DrawTextFormat(DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX | flags))
	GdiFlush()
	return rc, true
}

// The inked part of `rc` in the mask.
@(private = "file")
mask_ink :: proc(cv: ^Canvas, rc: win.RECT) -> (ink: win.RECT, ok: bool) {
	ink = {rc.right, rc.bottom, rc.left, rc.top}
	for py in rc.top ..< rc.bottom {
		for px in rc.left ..< rc.right {
			if cv.mask[py * cv.w + px] & 0xFF00 == 0 { continue }
			ink = {min(ink.left, px), min(ink.top, py), max(ink.right, px + 1), max(ink.bottom, py + 1)}
		}
	}
	return ink, ink.left < ink.right
}

// Blend the mask inside `rc` onto the canvas in colour `rgb`, moved by (dx, dy).
@(private = "file")
mask_blend :: proc(cv: ^Canvas, rc: win.RECT, dx, dy: i32, rgb: u32, alpha: f32) {
	for py in max(rc.top, -dy) ..< min(rc.bottom, cv.h - dy) {
		for px in max(rc.left, -dx) ..< min(rc.right, cv.w - dx) {
			if m := cv.mask[py * cv.w + px] >> 8 & 0xFF; m != 0 { blend(&cv.px[(py + dy) * cv.w + px + dx], rgb, alpha * f32(m) / 255) }
		}
	}
}

// Text vertically centred in (x, y, w, h), cut with an ellipsis when too wide.
draw_text :: proc(cv: ^Canvas, font: win.HFONT, s: string, x, y, w, h: i32, rgb: u32, alpha: f32 = 1, flags: win.UINT = 0) {
	if rc, ok := mask_text(cv, font, s, x, y, w, h, flags); ok { mask_blend(cv, rc, 0, 0, rgb, alpha) }
}

// One icon glyph centred by its ink on (cx, cy): icon fonts place each glyph
// differently in the line box, and differently from text.
draw_icon :: proc(cv: ^Canvas, font: win.HFONT, glyph: string, cx, cy: f32, size: i32, rgb: u32, alpha: f32 = 1) {
	rc, drawn := mask_text(cv, font, glyph, i32(cx) - size, i32(cy) - size, 2 * size, 2 * size, DT_CENTER)
	if !drawn { return }
	ink, inked := mask_ink(cv, rc)
	if !inked { return }
	mask_blend(cv, ink, i32(math.round(cx - f32(ink.left + ink.right) / 2)), i32(math.round(cy - f32(ink.top + ink.bottom) / 2)), rgb, alpha)
}

// How far to move text drawn centred in a box `h` high so its digits sit on
// the box's centre line: GDI centres the whole line box, descenders included.
text_center_offset :: proc(cv: ^Canvas, font: win.HFONT, h: i32) -> i32 {
	rc, ok := mask_text(cv, font, "0123456789", 0, 0, cv.w, h, 0)
	if !ok { return 0 }
	ink, inked := mask_ink(cv, rc)
	return inked ? i32(math.round(f32(h) / 2 - f32(ink.top + ink.bottom) / 2)) : 0
}

// A premultiplied image (an app icon) centred on (cx, cy).
draw_bitmap :: proc(cv: ^Canvas, icon: Icon, cx, cy: f32) {
	x0, y0 := i32(cx - f32(icon.w) / 2 + 0.5), i32(cy - f32(icon.h) / 2 + 0.5)
	for j in max(0, -y0) ..< min(icon.h, cv.h - y0) {
		for i in max(0, -x0) ..< min(icon.w, cv.w - x0) {
			s := icon.px[j * icon.w + i]
			a := s >> 24
			if a == 0 { continue }
			d := &cv.px[(y0 + j) * cv.w + x0 + i]
			if a == 255 { d^ = s; continue }
			ia := 255 - a
			ch :: #force_inline proc(s, d, ia: u32, shift: u32) -> u32 { return min((s >> shift & 0xFF) + (d >> shift & 0xFF) * ia / 255, 255) << shift }
			d^ = ch(s, d^, ia, 24) | ch(s, d^, ia, 16) | ch(s, d^, ia, 8) | ch(s, d^, ia, 0)
		}
	}
}

// Opaque BGRA pixels (w x h) copied into the canvas at (x, y), clipped to a rounded rectangle.
blit_rounded :: proc(cv: ^Canvas, px: []u32, w, h, x, y: i32, radius: f32) {
	r := min(radius, f32(min(w, h)) / 2)
	for j in 0 ..< h {
		for i in 0 ..< w {
			dx, dy := x + i, y + j
			if dx < 0 || dy < 0 || dx >= cv.w || dy >= cv.h { continue }
			qx := abs(f32(i) + 0.5 - f32(w) / 2) - (f32(w) / 2 - r)
			qy := abs(f32(j) + 0.5 - f32(h) / 2) - (f32(h) / 2 - r)
			ox, oy := max(qx, 0), max(qy, 0)
			d := math.sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - r
			blend(&cv.px[dy * cv.w + dx], px[j * w + i] & 0xFFFFFF, clamp(0.5 - d, 0, 1))
		}
	}
}

// ---------------------------------------------------------------------------
// Area dots (milk's workspace dots): the active area is a pill.
// ---------------------------------------------------------------------------
@(private = "file") DOT_PILL :: 22
@(private = "file") DOT_SIZE :: 6
@(private = "file") DOT_GAP  :: 7

// Offset and width of dot `i` (0-based) from the start of the row.
dot_x :: proc(i, active: int, s: f32) -> (x, w: f32) {
	x = f32(i) * (DOT_SIZE + DOT_GAP) * s
	if active < i { x += (DOT_PILL - DOT_SIZE) * s }
	return x, (i == active ? DOT_PILL : DOT_SIZE) * s
}

dots_width :: proc(count: int, s: f32) -> f32 {
	if count <= 0 { return 0 }
	return (DOT_PILL + f32(count - 1) * (DOT_SIZE + DOT_GAP)) * s
}

// A row of `count` dots starting at x, centred on cy; `active` is 0-based.
draw_dots :: proc(cv: ^Canvas, x, cy: f32, count, active: int, s: f32, on, off: u32, off_alpha: f32 = 1) {
	d := DOT_SIZE * s
	for i in 0 ..< count {
		dx, dw := dot_x(i, active, s)
		fill_round(cv, x + dx, cy - d / 2, dw, d, d / 2, i == active ? on : off, i == active ? 1 : off_alpha)
	}
}

// DPI scale of a monitor (1 at 100%).
monitor_scale :: proc(mon: win.HMONITOR) -> f32 {
	dx, dy: win.UINT
	if win.GetDpiForMonitor(mon, .MDT_EFFECTIVE_DPI, &dx, &dy) != 0 { return 1 }
	return f32(dx) / 96
}

primary_monitor :: proc() -> win.HMONITOR {
	return win.MonitorFromPoint({0, 0}, .MONITOR_DEFAULTTOPRIMARY)
}

monitor_rects :: proc(mon: win.HMONITOR) -> (full, work: win.RECT) {
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	win.GetMonitorInfoW(mon, &mi)
	return mi.rcMonitor, mi.rcWork
}
