// The area indicator, in milk's style: a pill "AREA N · Name" in the theme
// accent, with the area dots, that slides out from behind the bar (or the
// screen edge), rests for windows.indicator.duration seconds and slides back.
// It is click-through and never takes focus; the content is painted once per
// switch and the animation only moves and fades the layered window.
package temenos

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:time"
import win "core:sys/windows"

@(private = "file") ENTER :: 0.26 // seconds at animationScale 1
@(private = "file") EXIT  :: 0.20
@(private = "file") TIMER :: 1

@(private = "file")
Toast :: struct {
	hwnd:        win.HWND,
	cv:          Canvas,
	phase:       enum { Hidden, Entering, Resting, Leaving },
	phase_start: time.Tick,
	rest, start: [2]i32,
}
@(private = "file") toast: Toast

@(private = "file")
anim :: proc(seconds: f64) -> f64 { return seconds * cfg.appearance.animation_scale }

indicator_create :: proc() {
	class: win.wstring = win.L("TemenosIndicator")
	wc := win.WNDCLASSEXW{cbSize = size_of(win.WNDCLASSEXW), lpfnWndProc = toast_proc, hInstance = win.HINSTANCE(win.GetModuleHandleW(nil)), lpszClassName = class}
	win.RegisterClassExW(&wc)
	toast.hwnd = win.CreateWindowExW(win.WS_EX_LAYERED | win.WS_EX_TRANSPARENT | win.WS_EX_TOOLWINDOW | win.WS_EX_TOPMOST | win.WS_EX_NOACTIVATE,
	                                 class, win.L("Temenos indicator"), win.WS_POPUP, 0, 0, 0, 0, nil, nil, wc.hInstance, nil)
}

indicator_show :: proc(index, count: int, name: string) {
	if toast.hwnd == nil { return }
	mon := primary_monitor()
	_, work := monitor_rects(mon)
	s := monitor_scale(mon)
	font := make_font(i32(cfg.windows.indicator.font_size * 96 / 72 * f64(s) + 0.5), 600)
	defer win.DeleteObject(win.HGDIOBJ(font))
	caption := name == "" ? fmt.tprintf("AREA %d", index) : fmt.tprintf("AREA %d · %s", index, name)

	canvas_resize(&toast.cv, 1, 1) // a DC for measuring
	pad_x, pad_y, gap, shadow := 18 * s, 9 * s, 12 * s, 14 * s
	text_w := f32(text_width(&toast.cv, font, caption))
	metrics: win.TEXTMETRICW
	win.GetTextMetricsW(toast.cv.mask_dc, &metrics)
	pill_h := f32(metrics.tmHeight) + 2 * pad_y
	dots := count > 1 ? dots_width(count, s) + gap : 0
	pill_w := pad_x + dots + text_w + pad_x
	canvas_resize(&toast.cv, i32(pill_w + 2 * shadow), i32(pill_h + 2 * shadow))

	cv := &toast.cv
	canvas_clear(cv)
	fill_round(cv, shadow, shadow + 3 * s, pill_w, pill_h, pill_h / 2, 0x000000, 0.30, 10 * s)
	fill_round(cv, shadow, shadow, pill_w, pill_h, pill_h / 2, theme.accent)
	if count > 1 { draw_dots(cv, shadow + pad_x, shadow + pill_h / 2, count, index - 1, s, theme.accent_fg, theme.accent_fg, 0.45) }
	draw_text(cv, font, caption, i32(shadow + pad_x + dots), i32(shadow) + text_center_offset(cv, font, i32(pill_h)), i32(text_w) + 2, i32(pill_h), theme.accent_fg)

	// Rest just inside the work area (below / above the bar); start hidden behind it.
	margin := i32(12 * s) - i32(shadow)
	x := work.left + (work.right - work.left - cv.w) / 2
	switch cfg.windows.indicator.position {
	case "top":
		toast.rest, toast.start = {x, work.top + margin}, {x, work.top - cv.h}
	case "bottom":
		toast.rest, toast.start = {x, work.bottom - margin - cv.h}, {x, work.bottom}
	case:
		y := work.top + (work.bottom - work.top - cv.h) / 2
		toast.rest, toast.start = {x, y}, {x, y + i32(24 * s)}
	}

	animated := anim(ENTER) > 0
	first := animated ? toast.start : toast.rest
	present(cv, toast.hwnd, first.x, first.y, animated ? 0 : 255)
	// Just below the bar in the topmost band, so it comes out from behind it.
	win.SetWindowPos(toast.hwnd, bar_hwnd() if bar_hwnd() != nil else win.HWND_TOPMOST, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE)
	win.ShowWindow(toast.hwnd, win.SW_SHOWNOACTIVATE)
	toast.phase = animated ? .Entering : .Resting
	toast.phase_start = time.tick_now()
	win.SetTimer(toast.hwnd, TIMER, 15, nil)
}

@(private = "file")
toast_tick :: proc() {
	t := time.duration_seconds(time.tick_since(toast.phase_start))
	lerp :: proc(a, b: [2]i32, e: f64) -> [2]i32 {
		return {a.x + i32(math.round(f64(b.x - a.x) * e)), a.y + i32(math.round(f64(b.y - a.y) * e))}
	}
	switch toast.phase {
	case .Hidden:
		win.KillTimer(toast.hwnd, TIMER)
	case .Entering:
		p := min(t / anim(ENTER), 1)
		e := 1 - math.pow(1 - p, 3) // decelerate
		pos := lerp(toast.start, toast.rest, e)
		present_move(toast.hwnd, pos.x, pos.y, u8(255 * e))
		if p >= 1 { toast.phase, toast.phase_start = .Resting, time.tick_now() }
	case .Resting:
		if t < cfg.windows.indicator.duration { return }
		toast.phase, toast.phase_start = .Leaving, time.tick_now()
		if anim(EXIT) <= 0 { indicator_hide() }
	case .Leaving:
		p := min(t / anim(EXIT), 1)
		e := p * p * p // accelerate
		pos := lerp(toast.rest, toast.start, e)
		present_move(toast.hwnd, pos.x, pos.y, u8(255 * (1 - e)))
		if p >= 1 { indicator_hide() }
	}
}

indicator_hide :: proc() {
	if toast.hwnd == nil { return }
	win.KillTimer(toast.hwnd, TIMER)
	win.ShowWindow(toast.hwnd, win.SW_HIDE)
	toast.phase = .Hidden
}

@(private = "file")
toast_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	if msg == win.WM_TIMER { toast_tick(); return 0 }
	return win.DefWindowProcW(hwnd, msg, wp, lp)
}
