// Optional window tiling (wm.enabled): milk's dwm layouts (master/stack
// "[]=", monocle "[M]", floating "><>") applied to the normal windows of the
// current virtual desktop, per monitor, inside each monitor's work area.
// Windows on other desktops are cloaked by DWM and skipped; minimized,
// maximized, owned, fixed-size and tool windows float, as do windows matched
// by wm.rules or toggled with Mod+Shift+Space. Keys (Mod = wm.modKey):
//   J/K focus next/previous   Enter  zoom (swap with the master)
//   H/L master width -/+      I/D    more/fewer masters
//   T/M/F tile/monocle/float  Shift+Space  float/tile the focused window
package temenos

import "core:slice"
import "core:strings"
import win "core:sys/windows"

Layout :: enum { Tile, Monocle, Float }
@(rodata) LAYOUT_SYMBOLS := [Layout]string{.Tile = "[]=", .Monocle = "[M]", .Float = "><>"}

@(private = "file")
Tiler :: struct {
	layout:   Layout,
	mfact:    f64,
	nmaster:  int,
	order:    [dynamic]win.HWND, // master first
	floating: map[win.HWND]bool, // toggled by the user
	focused:  win.HWND,          // wears the focus border
}
@(private = "file") tiler: Tiler

TIMER_ARRANGE :: 3
DWMWA_COLOR_DEFAULT :: 0xFFFFFFFF

@(private = "file") HOTKEY_BASE :: 200

@(private = "file")
Key :: struct { shift: bool, vk: win.UINT, action: proc(arg: int), arg: int }

@(private = "file", rodata)
KEYS := [?]Key{
	{false, 'J', focus_step, +1}, {false, 'K', focus_step, -1}, {false, win.VK_RETURN, zoom, 0},
	{false, 'H', mfact_step, -1}, {false, 'L', mfact_step, +1},
	{false, 'I', nmaster_step, +1}, {false, 'D', nmaster_step, -1},
	{false, 'T', set_layout, int(Layout.Tile)}, {false, 'M', set_layout, int(Layout.Monocle)}, {false, 'F', set_layout, int(Layout.Float)},
	{true, win.VK_SPACE, toggle_floating, 0},
}

tiler_layout :: proc() -> Layout { return tiler.layout }

tiler_start :: proc() {
	tiler.mfact = cfg.wm.master_factor
	tiler.nmaster = cfg.wm.master_count
	mod: win.UINT = cfg.wm.mod_key == "super" ? MOD_WIN : MOD_ALT
	for k, i in KEYS {
		win.RegisterHotKey(main_hwnd, i32(HOTKEY_BASE + i), mod | MOD_NOREPEAT | (k.shift ? MOD_SHIFT : 0), k.vk)
	}
	tiler_arrange()
	tiler_focus_changed(win.GetForegroundWindow())
}

tiler_stop :: proc() {
	if tiler.focused != nil { set_border(tiler.focused, DWMWA_COLOR_DEFAULT) }
}

// A WM_HOTKEY id of ours: run it.
tiler_hotkey :: proc(id: int) -> bool {
	i := id - HOTKEY_BASE
	if i < 0 || i >= len(KEYS) { return false }
	KEYS[i].action(KEYS[i].arg)
	return true
}

// A window appeared or went away: arrange once the burst of events is over,
// but only for windows that are (or become) tiled. Tooltips, menus and
// popups come and go all the time and must not cost anything.
tiler_window_event :: proc(hwnd: win.HWND, appearing: bool) {
	if !cfg.wm.enabled { return }
	tiled := slice.contains(tiler.order[:], hwnd)
	if appearing ? !tiled && tileable(hwnd) : tiled { win.SetTimer(main_hwnd, TIMER_ARRANGE, 20, nil) }
}

@(private = "file")
window_string :: proc(hwnd: win.HWND, class: bool) -> string {
	buf: [256]u16
	n := class ? win.GetClassNameW(hwnd, &buf[0], len(buf)) : win.GetWindowTextW(hwnd, &buf[0], len(buf))
	s, _ := win.utf16_to_utf8(buf[:max(n, 0)], context.temp_allocator)
	return s
}

@(private = "file")
tileable :: proc(hwnd: win.HWND) -> bool {
	if !win.IsWindowVisible(hwnd) || win.IsIconic(hwnd) || win.IsZoomed(hwnd) || win.GetWindow(hwnd, win.GW_OWNER) != nil { return false }
	style, ex := u32(win.GetWindowLongW(hwnd, win.GWL_STYLE)), u32(win.GetWindowLongW(hwnd, win.GWL_EXSTYLE))
	if style & win.WS_CHILD != 0 || style & win.WS_THICKFRAME == 0 || ex & (win.WS_EX_TOOLWINDOW | win.WS_EX_NOACTIVATE) != 0 { return false }
	cloaked: u32 // on another virtual desktop, or a suspended UWP frame
	win.DwmGetWindowAttribute(hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_CLOAKED), &cloaked, size_of(cloaked))
	pid: u32
	win.GetWindowThreadProcessId(hwnd, &pid)
	if cloaked != 0 || pid == win.GetCurrentProcessId() || tiler.floating[hwnd] { return false }
	title := window_string(hwnd, false)
	if title == "" { return false }
	class := window_string(hwnd, true)
	for r in cfg.wm.rules {
		if r.floating && (r.class == "" || r.class == class) && (r.title == "" || strings.contains(title, r.title)) { return false }
	}
	return true
}

// The tiled windows in order, optionally only those on `mon`.
@(private = "file")
clients :: proc(mon: win.HMONITOR = nil) -> []win.HWND {
	out := make([dynamic]win.HWND, context.temp_allocator)
	for h in tiler.order {
		if mon == nil || win.MonitorFromWindow(h, .MONITOR_DEFAULTTONEAREST) == mon { append(&out, h) }
	}
	return out[:]
}

tiler_arrange :: proc() {
	win.KillTimer(main_hwnd, TIMER_ARRANGE)
	if !cfg.wm.enabled { return }
	live := make([dynamic]win.HWND, context.temp_allocator)
	win.EnumWindows(proc "system" (hwnd: win.HWND, lp: win.LPARAM) -> win.BOOL {
		context = default_context()
		if tileable(hwnd) { append((^[dynamic]win.HWND)(uintptr(lp)), hwnd) }
		return true
	}, win.LPARAM(uintptr(&live)))

	// Known windows keep their order; new ones become the master (dwm's attach).
	kept := make([dynamic]win.HWND, context.temp_allocator)
	for h in tiler.order { if slice.contains(live[:], h) { append(&kept, h) } }
	fresh := make([dynamic]win.HWND, context.temp_allocator)
	for h in live { if !slice.contains(tiler.order[:], h) { append(&fresh, h) } }
	clear(&tiler.order)
	append(&tiler.order, ..fresh[:])
	append(&tiler.order, ..kept[:])
	gone := make([dynamic]win.HWND, context.temp_allocator)
	for h in tiler.floating { if !win.IsWindow(h) { append(&gone, h) } }
	for h in gone { delete_key(&tiler.floating, h) }

	if tiler.layout == .Float { return }
	done := make([dynamic]win.HMONITOR, context.temp_allocator)
	for h in tiler.order {
		mon := win.MonitorFromWindow(h, .MONITOR_DEFAULTTONEAREST)
		if slice.contains(done[:], mon) { continue }
		append(&done, mon)
		tile_monitor(mon, clients(mon))
	}
}

// dwm's tile() with milk's uniform gaps, or monocle.
@(private = "file")
tile_monitor :: proc(mon: win.HMONITOR, cs: []win.HWND) {
	_, wa := monitor_rects(mon)
	g := i32(f32(cfg.wm.gaps) * monitor_scale(mon))
	wx, wy, ww, wh := wa.left, wa.top, wa.right - wa.left, wa.bottom - wa.top
	if tiler.layout == .Monocle {
		for c in cs { place(c, wx + g, wy + g, ww - 2 * g, wh - 2 * g) }
		return
	}
	n, nm := i32(len(cs)), i32(tiler.nmaster)
	mw := n > nm ? (nm > 0 ? i32(f64(ww - 3 * g) * tiler.mfact) : 0) : ww - 2 * g
	stack_x := wx + g + (mw > 0 ? mw + g : 0)
	stack_w := ww - 2 * g - (mw > 0 ? mw + g : 0)
	my, ty := g, g
	for c, i in cs {
		i := i32(i)
		if i < nm {
			rest := min(n, nm) - i
			h := (wh - my - rest * g) / rest
			place(c, wx + g, wy + my, mw, h)
			my += h + g
		} else {
			rest := n - i
			h := (wh - ty - rest * g) / rest
			place(c, stack_x, wy + ty, stack_w, h)
			ty += h + g
		}
	}
}

// Move a window so that its visible frame covers (x, y, w, h): since Windows
// 10 frames have invisible resize borders outside what DWM draws.
@(private = "file")
place :: proc(hwnd: win.HWND, x, y, w, h: i32) {
	wr, fr: win.RECT
	win.GetWindowRect(hwnd, &wr)
	if win.DwmGetWindowAttribute(hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_EXTENDED_FRAME_BOUNDS), &fr, size_of(fr)) != 0 { fr = wr }
	l, t := fr.left - wr.left, fr.top - wr.top
	target := win.RECT{x - l, y - t, x + w + (wr.right - fr.right), y + h + (wr.bottom - fr.bottom)}
	if target == wr { return }
	// Async: a hung application must not freeze Temenos.
	win.SetWindowPos(hwnd, nil, target.left, target.top, target.right - target.left, target.bottom - target.top,
	                 win.SWP_NOZORDER | win.SWP_NOACTIVATE | win.SWP_NOOWNERZORDER | win.SWP_ASYNCWINDOWPOS)
}

@(private = "file")
set_border :: proc(hwnd: win.HWND, color: u32) {
	c := color
	win.DwmSetWindowAttribute(hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_BORDER_COLOR), &c, size_of(c))
}

// Windows 11 draws the focused window's border in wm.focusColor (Windows 10 ignores it).
tiler_focus_changed :: proc(hwnd: win.HWND) {
	if !cfg.wm.enabled || hwnd == tiler.focused { return }
	if tiler.focused != nil { set_border(tiler.focused, DWMWA_COLOR_DEFAULT) }
	tiler.focused = hwnd
	rgb := cfg.wm.focus_color != "" ? u32(parse_hex(cfg.wm.focus_color)) : theme.accent
	set_border(hwnd, (rgb & 0xFF) << 16 | rgb & 0xFF00 | rgb >> 16 & 0xFF) // COLORREF is 0x00BBGGRR
}

tiler_cycle_layout :: proc() { set_layout((int(tiler.layout) + 1) % len(Layout)) }

@(private = "file")
set_layout :: proc(l: int) {
	tiler.layout = Layout(l)
	tiler_arrange()
	bar_render()
}

@(private = "file")
focus_step :: proc(dir: int) {
	fg := win.GetForegroundWindow()
	cs := clients(win.MonitorFromWindow(fg, .MONITOR_DEFAULTTONEAREST))
	if len(cs) == 0 { return }
	i, _ := slice.linear_search(cs, fg)
	win.SetForegroundWindow(cs[(i + dir + len(cs)) % len(cs)])
}

@(private = "file")
zoom :: proc(_: int) {
	fg := win.GetForegroundWindow()
	i, found := slice.linear_search(tiler.order[:], fg)
	if !found { return }
	if i == 0 && len(tiler.order) > 1 { i = 1 } // the master swaps with the next one
	h := tiler.order[i]
	ordered_remove(&tiler.order, i)
	inject_at(&tiler.order, 0, h)
	tiler_arrange()
}

@(private = "file")
mfact_step :: proc(dir: int) {
	tiler.mfact = clamp(tiler.mfact + 0.05 * f64(dir), 0.05, 0.95)
	tiler_arrange()
}

@(private = "file")
nmaster_step :: proc(dir: int) {
	tiler.nmaster = max(tiler.nmaster + dir, 0)
	tiler_arrange()
}

@(private = "file")
toggle_floating :: proc(_: int) {
	fg := win.GetForegroundWindow()
	if tiler.floating[fg] { delete_key(&tiler.floating, fg) } else { tiler.floating[fg] = true }
	tiler_arrange()
}
