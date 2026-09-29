// The navbar: milk's bar reduced to what Windows does not already offer.
// Start / centre / end groups of widgets (launcher, active window, area dots,
// new area, tiling layout, date, clock) plus what the hidden Windows taskbar
// held (tray, Wi-Fi/volume/battery, widgets, notifications, show desktop; see
// taskbar.odin and volume.odin) on the primary monitor. It registers as an AppBar, so Windows keeps maximized
// windows (and the work area) clear of it, and steps aside for fullscreen
// apps. Right-click: Task Manager, setup, edit Temenos.json, restart, quit.
package temenos

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetDateFormatEx :: proc(locale: win.LPCWSTR, flags: win.DWORD, date: ^win.SYSTEMTIME, format: win.LPCWSTR, out: win.LPWSTR, size: i32, calendar: win.LPCWSTR) -> i32 ---
	GetTimeFormatEx :: proc(locale: win.LPCWSTR, flags: win.DWORD, t: ^win.SYSTEMTIME, format: win.LPCWSTR, out: win.LPWSTR, size: i32) -> i32 ---
}

@(private = "file") WM_APPBAR   :: win.WM_APP + 1
@(private = "file") ICON_GAP    :: 6 // between icons, and between an icon and its text
@(private = "file") TIMER_CLOCK :: 1
@(private = "file") MENU_TASK_MANAGER, MENU_SETTINGS, MENU_EDIT, MENU_RESTART, MENU_QUIT, MENU_APPS :: 1, 2, 3, 4, 5, 6

Widget_Kind :: enum { Launcher, Workspaces, New_Area, Active_Window, Layout, Date, Clock, Notifications, Quick_Settings, Widgets, Tray, Show_Desktop, Apps }

@(private = "file")
Widget :: struct {
	kind: Widget_Kind,
	id:   string,
	x, w:   i32,    // window coordinates; w == 0: hidden
	icon:   string, // glyphs of Segoe Fluent Icons / Segoe MDL2 Assets, one square slot each
	text:   string,
	iw, tw: i32,    // their widths
}

@(private = "file")
Bar :: struct {
	hwnd:            win.HWND,
	cv:              Canvas,
	font, icons:     win.HFONT,
	icon_px:         i32,      // icon slot size (the taskbar's 16 px at 100%)
	app_icons:       [dynamic]Icon, // one per cfg.bar.apps entry (px nil: not found)
	app_px, app_slot: i32,
	hover_app:       int,      // pinned app under the pointer, -1 = none
	text_dy:         i32,      // moves text so its digits sit on the centre line
	rect:            win.RECT, // window, screen coordinates
	body:            win.RECT, // the visible bar, window coordinates
	s:               f32,      // DPI scale
	start_n, center_n: int,    // widgets are stored start group, then centre, then end
	widgets:         [dynamic]Widget,
	hover:           int,
	title:           string,
	registered:      bool,
	tracking:        bool,
	taskbar_created: win.UINT,
}
@(private = "file") bar: Bar

bar_hwnd :: proc() -> win.HWND { return bar.hwnd }

bar_create :: proc() {
	class: win.wstring = win.L("TemenosBar")
	wc := win.WNDCLASSEXW{cbSize = size_of(win.WNDCLASSEXW), lpfnWndProc = bar_proc, hInstance = win.HINSTANCE(win.GetModuleHandleW(nil)),
	                      lpszClassName = class, hCursor = win.LoadCursorA(nil, win.IDC_ARROW)}
	win.RegisterClassExW(&wc)
	bar.hwnd = win.CreateWindowExW(win.WS_EX_LAYERED | win.WS_EX_TOOLWINDOW | win.WS_EX_TOPMOST | win.WS_EX_NOACTIVATE,
	                               class, win.L("Temenos bar"), win.WS_POPUP, 0, 0, 0, 0, nil, nil, wc.hInstance, nil)
	bar.hover = -1
	bar.taskbar_created = win.RegisterWindowMessageW(win.L("TaskbarCreated"))
	for group, g in ([3][]string{cfg.bar.start, cfg.bar.center, cfg.bar.end}) {
		for id in group {
			for name, kind in WIDGET_IDS {
				if name == id { append(&bar.widgets, Widget{kind = kind, id = name}) }
			}
		}
		if g == 0 { bar.start_n = len(bar.widgets) }
		if g == 1 { bar.center_n = len(bar.widgets) - bar.start_n }
	}
	volume_start()
	bar_title()
	bar_dock()
	win.ShowWindow(bar.hwnd, win.SW_SHOWNOACTIVATE)
	clock_timer()
}

@(rodata) WIDGET_IDS := [Widget_Kind]string{
	.Launcher = "launcher", .Workspaces = "workspaces", .New_Area = "new_area", .Active_Window = "active_window",
	.Layout = "layout", .Date = "date", .Clock = "clock", .Notifications = "notifications",
	.Quick_Settings = "quick_settings", .Widgets = "widgets", .Tray = "tray", .Show_Desktop = "show_desktop", .Apps = "apps",
}

bar_destroy :: proc() {
	if bar.hwnd == nil { return }
	abd := win.APPBARDATA{cbSize = size_of(win.APPBARDATA), hWnd = bar.hwnd}
	win.SHAppBarMessage(win.ABM_REMOVE, &abd)
	volume_stop()
	win.DestroyWindow(bar.hwnd)
	bar.hwnd = nil
}

// Reserve the screen edge and (re)compute the geometry, scale and font.
@(private = "file")
bar_dock :: proc() {
	abd := win.APPBARDATA{cbSize = size_of(win.APPBARDATA), hWnd = bar.hwnd, uCallbackMessage = WM_APPBAR}
	if !bar.registered { bar.registered = win.SHAppBarMessage(win.ABM_NEW, &abd) != 0 }
	mon := primary_monitor()
	full, _ := monitor_rects(mon)
	bar.s = monitor_scale(mon)
	m := cfg.bar.style == "floating" ? i32(f32(cfg.bar.margin) * bar.s) : 0
	h := i32(f32(cfg.bar.height) * bar.s) + 2 * m
	top := cfg.bar.position == "top"
	abd.uEdge = top ? win.ABE_TOP : win.ABE_BOTTOM
	abd.rc = full
	fit :: proc(rc: ^win.RECT, top: bool, h: i32) { if top { rc.bottom = rc.top + h } else { rc.top = rc.bottom - h } }
	fit(&abd.rc, top, h)
	win.SHAppBarMessage(win.ABM_QUERYPOS, &abd) // moves the rectangle off other bars (the taskbar)
	fit(&abd.rc, top, h)
	win.SHAppBarMessage(win.ABM_SETPOS, &abd)
	bar.rect = abd.rc
	bar.body = {m, m, abd.rc.right - abd.rc.left - m, h - m}
	if bar.font != nil { win.DeleteObject(win.HGDIOBJ(bar.font)); win.DeleteObject(win.HGDIOBJ(bar.icons)) }
	bar.font = make_font(i32(f32(cfg.bar.font_size) * bar.s), 400, cfg.bar.font)
	bar.icon_px = i32(f32(cfg.bar.font_size + 3) * bar.s + 0.5)
	bar.icons = icon_font(bar.icon_px)
	canvas_resize(&bar.cv, abd.rc.right - abd.rc.left, h)
	bar.text_dy = text_center_offset(&bar.cv, bar.font, h - 2 * m)
	// Pinned app icons at the size the shell draws them for this scale.
	for icon in bar.app_icons { delete(icon.px) }
	clear(&bar.app_icons)
	bar.app_px = i32(min(24, f32(cfg.bar.height) * 0.62) * bar.s)
	bar.app_slot = bar.app_px + i32(14 * bar.s)
	for target in cfg.bar.apps {
		icon, _ := app_icon(target, bar.app_px)
		append(&bar.app_icons, icon)
	}
	bar_render()
}

@(private = "file")
format_now :: proc(format: string, date: bool) -> string {
	buf: [128]u16
	f := win.utf8_to_wstring(format, context.temp_allocator)
	n := date ? GetDateFormatEx(nil, 0, nil, f, &buf[0], len(buf), nil) : GetTimeFormatEx(nil, 0, nil, f, &buf[0], len(buf))
	if n <= 0 { return "" }
	s, _ := win.wstring_to_utf8(cstring16(&buf[0]), -1, context.temp_allocator)
	return s
}

// "Terça, 29 de Setembro": the weekday and the locale's day-and-month pattern
// unless bar.dateFormat gives a Windows picture; day and month names start
// with a capital, and Portuguese weekdays drop "-feira".
@(private = "file")
format_date :: proc() -> string {
	picture := cfg.bar.date_format
	if picture == "" {
		buf: [64]u16
		n := win.GetLocaleInfoEx(nil, LOCALE_SMONTHDAY, &buf[0], len(buf))
		month_day, _ := win.utf16_to_utf8(buf[:max(n - 1, 0)], context.temp_allocator)
		picture = fmt.tprintf("dddd, %s", month_day != "" ? month_day : "d MMMM")
	}
	s := format_now(picture, true)
	for part in ([2]string{"dddd", "MMMM"}) {
		name := format_now(part, true)
		if name == "" { continue }
		nice := strings.trim_suffix(name, "-feira")
		_, first := utf8.decode_rune_in_string(nice)
		nice = strings.concatenate({strings.to_upper(nice[:first], context.temp_allocator), nice[first:]}, context.temp_allocator)
		s, _ = strings.replace_all(s, name, nice, context.temp_allocator)
	}
	return s
}

@(private = "file") LOCALE_SMONTHDAY :: win.LCTYPE(0x78)

@(private = "file")
clock_timer :: proc() {
	ms := 60_000 - (time.to_unix_nanoseconds(time.now()) / 1_000_000) % 60_000
	win.SetTimer(bar.hwnd, TIMER_CLOCK, win.UINT(ms + 50), nil)
}

@(private = "file")
interactive :: proc(w: Widget) -> bool {
	if cmd, ok := cfg.bar.commands[w.id]; ok && cmd != "" { return true }
	#partial switch w.kind {
	case .Active_Window: return false
	case .Layout:        return cfg.wm.enabled
	}
	return true
}

@(private = "file")
bar_layout :: proc() {
	s := bar.s
	pad := i32(8 * s)
	win11 := is_windows_11()
	for &w in bar.widgets {
		w.icon, w.text = "", ""
		switch w.kind {
		case .Launcher:       w.w = i32(30 * s); continue
		case .Workspaces:     w.w = i32(dots_width(desk.count, s)) + 2 * pad; continue
		case .Show_Desktop:   w.w = i32(14 * s); continue
		case .Apps:           w.w = i32(len(cfg.bar.apps)) * bar.app_slot; continue
		case .New_Area:       w.icon = "\uE710"
		case .Notifications:  w.icon = "\uEA8F"
		case .Quick_Settings:
			glyph, percent := battery()
			w.icon, w.text = strings.concatenate({"\uE701", volume_glyph(), glyph}, context.temp_allocator), percent
		case .Widgets:        w.icon = win11 ? "\uECA5" : "" // Windows 10 has no widgets board
		case .Tray:           w.icon = "\uE70E"
		case .Active_Window:  w.text = bar.title
		case .Layout:         w.text = cfg.wm.enabled ? LAYOUT_SYMBOLS[tiler_layout()] : ""
		case .Date:           w.text = format_date()
		case .Clock:          w.text = format_now(cfg.bar.clock_format, false)
		}
		glyphs := i32(utf8.rune_count(w.icon))
		w.iw = glyphs > 0 ? glyphs * bar.icon_px + (glyphs - 1) * i32(ICON_GAP * s) : 0
		w.tw = w.text != "" ? min(text_width(&bar.cv, bar.font, w.text), i32(f32(cfg.bar.title_max_width) * s)) : 0
		content := w.iw + w.tw + (w.iw > 0 && w.tw > 0 ? i32(ICON_GAP * s) : 0)
		w.w = content > 0 ? content + 2 * pad : 0
	}
	gap := i32(f32(cfg.bar.spacing) * s)
	place :: proc(ws: []Widget, x0, gap: i32, assign: bool) -> (width: i32) {
		x := x0
		for &w in ws {
			if w.w == 0 { continue }
			if x > x0 { x += gap }
			if assign { w.x = x }
			x += w.w
		}
		return x - x0
	}
	start, center, end := bar.widgets[:bar.start_n], bar.widgets[bar.start_n:][:bar.center_n], bar.widgets[bar.start_n + bar.center_n:]
	edge := i32(6 * s)
	end_w, center_w := place(end, 0, gap, false), place(center, 0, gap, false)
	start_end := bar.body.left + edge + place(start, bar.body.left + edge, gap, true)
	end_x := bar.body.right - edge - end_w
	place(end, end_x, gap, true)
	// The centre group is centred on the bar, but never overlaps its neighbours.
	cx := clamp((bar.body.left + bar.body.right - center_w) / 2, start_end + 2 * gap, max(end_x - 2 * gap - center_w, start_end + 2 * gap))
	place(center, cx, gap, true)
}

bar_render :: proc() {
	if bar.hwnd == nil { return }
	bar_layout()
	cv, s := &bar.cv, bar.s
	body := bar.body
	bh := body.bottom - body.top
	canvas_clear(cv)
	radius := cfg.bar.style == "floating" ? f32(cfg.bar.radius) * s : 0
	if cfg.bar.style == "floating" { fill_round(cv, f32(body.left), f32(body.top) + 2 * s, f32(body.right - body.left), f32(bh), radius, 0, 0.25, 8 * s) }
	fill_round(cv, f32(body.left), f32(body.top), f32(body.right - body.left), f32(bh), radius, theme.background, f32(cfg.bar.opacity))
	pad := i32(8 * s)
	cy := f32(body.top) + f32(bh) / 2
	for w, i in bar.widgets {
		if w.w == 0 { continue }
		if i == bar.hover && interactive(w) && w.kind != .Apps {
			hh := f32(bh) * 0.72
			fill_round(cv, f32(w.x), cy - hh / 2, f32(w.w), hh, hh / 2, theme.surface)
		}
		switch w.kind {
		case .Launcher: // the Start logo: four rounded squares
			q, g := 6 * s, 1.6 * s
			x0, y0 := f32(w.x) + f32(w.w) / 2 - q - g / 2, cy - q - g / 2
			for k in 0 ..< 4 { fill_round(cv, x0 + f32(k % 2) * (q + g), y0 + f32(k / 2) * (q + g), q, q, 1.5 * s, theme.foreground) }
		case .Workspaces:
			draw_dots(cv, f32(w.x + pad), cy, desk.count, desk.index - 1, s, theme.accent, theme.muted, 0.6)
		case .Apps:
			for icon, k in bar.app_icons {
				slot_x := f32(w.x + i32(k) * bar.app_slot)
				if i == bar.hover && k == bar.hover_app {
					hh := f32(bh) * 0.8
					fill_round(cv, slot_x + 2 * s, cy - hh / 2, f32(bar.app_slot) - 4 * s, hh, 6 * s, theme.surface)
				}
				if icon.px != nil { draw_bitmap(cv, icon, slot_x + f32(bar.app_slot) / 2, cy) }
			}
		case .Show_Desktop: // the thin line at the corner, like the Windows 11 taskbar's
			fill_round(cv, f32(w.x) + f32(w.w) / 2 - 0.5 * s, cy - 8 * s, 1 * s, 16 * s, 0.5 * s, theme.muted)
		case .New_Area, .Active_Window, .Layout, .Date, .Clock, .Notifications, .Quick_Settings, .Widgets, .Tray:
			color := theme.foreground
			#partial switch w.kind {
			case .New_Area, .Date, .Tray: color = theme.muted
			case .Layout:                 color = theme.accent
			}
			gap := w.iw > 0 && w.tw > 0 ? i32(ICON_GAP * s) : 0
			x := w.x + (w.w - w.iw - gap - w.tw) / 2
			slot := f32(bar.icon_px) + ICON_GAP * s
			k: f32
			for r, at in w.icon {
				draw_icon(cv, bar.icons, w.icon[at:][:utf8.rune_size(r)], f32(x) + k * slot + f32(bar.icon_px) / 2, cy, bar.icon_px, color)
				k += 1
			}
			if w.tw > 0 { draw_text(cv, bar.font, w.text, x + w.iw + gap, body.top + bar.text_dy, w.tw + 1, bh, color) }
		}
	}
	present(cv, bar.hwnd, bar.rect.left, bar.rect.top)
}

// Title of the foreground window (empty for the desktop and the taskbar).
bar_title :: proc() {
	if bar.hwnd == nil { return }
	fg := win.GetForegroundWindow()
	title := ""
	class: [64]u16
	win.GetClassNameW(fg, &class[0], len(class))
	cls, _ := win.wstring_to_utf8(cstring16(&class[0]), -1, context.temp_allocator)
	if fg != nil && fg != bar.hwnd && cls != "Progman" && cls != "WorkerW" && cls != "Shell_TrayWnd" && cls != "Shell_SecondaryTrayWnd" {
		buf: [256]u16
		n := win.GetWindowTextW(fg, &buf[0], len(buf))
		title, _ = win.utf16_to_utf8(buf[:n], context.temp_allocator)
	}
	if title == bar.title { return }
	delete(bar.title)
	bar.title = strings.clone(title)
	bar_render()
}

@(private = "file")
hit :: proc(x: i32) -> int {
	for w, i in bar.widgets {
		if w.w > 0 && x >= w.x && x < w.x + w.w { return i }
	}
	return -1
}

// Run a user command: "program args", "\"C:\\path with spaces\\app.exe\" args", a URL or a document.
run_command :: proc(cmd: string) {
	file, params := strings.trim_space(cmd), ""
	if strings.has_prefix(file, "\"") {
		if end := strings.index_byte(file[1:], '"'); end >= 0 { file, params = file[1:end + 1], file[end + 2:] }
	} else if sp := strings.index_byte(file, ' '); sp >= 0 {
		file, params = file[:sp], file[sp + 1:]
	}
	win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(file, context.temp_allocator),
	                  win.utf8_to_wstring(strings.trim_space(params), context.temp_allocator), nil, win.SW_SHOWNORMAL)
}

@(private = "file")
click :: proc(x: i32) {
	i := hit(x)
	if i < 0 { return }
	w := bar.widgets[i]
	if cmd, ok := cfg.bar.commands[w.id]; ok && cmd != "" { run_command(cmd); return }
	#partial switch w.kind {
	case .Launcher:                     send_chord({}, {win.VK_LWIN})
	case .New_Area:                     new_desktop()
	case .Layout:                       tiler_cycle_layout()
	case .Notifications, .Date, .Clock: open_notifications()
	case .Quick_Settings:               open_quick_settings()
	case .Widgets:                      open_widgets()
	case .Tray:                         taskbar_peek()
	case .Show_Desktop:                 show_desktop()
	case .Apps:
		if k := int((x - w.x) / max(bar.app_slot, 1)); k >= 0 && k < len(cfg.bar.apps) { launch_app(cfg.bar.apps[k]) }
	case .Workspaces:
		pad := 8 * bar.s
		for k in 0 ..< desk.count {
			dx, dw := dot_x(k, desk.index - 1, bar.s)
			left := f32(w.x) + pad + dx
			if f32(x) >= left - 4 * bar.s && f32(x) < left + dw + 4 * bar.s { request_switch(k + 1) }
		}
	}
}

@(private = "file")
menu :: proc() {
	m := win.CreatePopupMenu()
	defer win.DestroyMenu(m)
	win.AppendMenuW(m, win.MF_STRING, MENU_TASK_MANAGER, win.L("Task Manager"))
	win.AppendMenuW(m, win.MF_SEPARATOR, 0, nil)
	win.AppendMenuW(m, win.MF_STRING, MENU_APPS, win.L("Pinned apps…"))
	win.AppendMenuW(m, win.MF_STRING, MENU_SETTINGS, win.L("Setup…"))
	win.AppendMenuW(m, win.MF_STRING, MENU_EDIT, win.L("Edit Temenos.json"))
	win.AppendMenuW(m, win.MF_SEPARATOR, 0, nil)
	win.AppendMenuW(m, win.MF_STRING, MENU_RESTART, win.L("Restart Temenos"))
	win.AppendMenuW(m, win.MF_STRING, MENU_QUIT, win.L("Quit Temenos"))
	pt: win.POINT
	win.GetCursorPos(&pt)
	win.SetForegroundWindow(bar.hwnd) // lets the menu close when clicking elsewhere
	switch win.TrackPopupMenu(m, win.TPM_RETURNCMD | win.TPM_NONOTIFY, pt.x, pt.y, 0, bar.hwnd, nil) {
	case MENU_TASK_MANAGER: run_command("taskmgr.exe")
	case MENU_APPS:         restart("--apps")
	case MENU_SETTINGS:     restart("--setup")
	case MENU_EDIT:         win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(config_path, context.temp_allocator), nil, nil, win.SW_SHOWNORMAL)
	case MENU_RESTART:      restart()
	case MENU_QUIT:         win.PostMessageW(main_hwnd, win.WM_CLOSE, 0, 0)
	}
}

@(private = "file")
bar_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	x := i32(i16(lp & 0xFFFF))
	switch msg {
	case win.WM_MOUSEMOVE:
		if !bar.tracking {
			tme := win.TRACKMOUSEEVENT{cbSize = size_of(win.TRACKMOUSEEVENT), dwFlags = win.TME_LEAVE, hwndTrack = hwnd}
			bar.tracking = bool(win.TrackMouseEvent(&tme))
		}
		h := hit(x)
		app := h >= 0 && bar.widgets[h].kind == .Apps ? int((x - bar.widgets[h].x) / max(bar.app_slot, 1)) : -1
		if h != bar.hover || app != bar.hover_app { bar.hover, bar.hover_app = h, app; bar_render() }
	case win.WM_MOUSELEAVE:
		bar.tracking, bar.hover, bar.hover_app = false, -1, -1
		bar_render()
	case win.WM_LBUTTONUP:
		click(x)
	case win.WM_RBUTTONUP:
		menu()
	case win.WM_MOUSEWHEEL:
		request_switch(desk.index + (i16(wp >> 16) > 0 ? -1 : 1))
	case win.WM_TIMER:
		bar_render()
		clock_timer()
	case WM_APPBAR:
		switch wp {
		case win.ABN_POSCHANGED: bar_dock()
		case win.ABN_FULLSCREENAPP: // step aside while a fullscreen app (game, video) runs
			win.SetWindowPos(hwnd, lp != 0 ? win.HWND_BOTTOM : win.HWND_TOPMOST, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE)
		}
	case win.WM_WINDOWPOSCHANGED:
		abd := win.APPBARDATA{cbSize = size_of(win.APPBARDATA), hWnd = hwnd}
		win.SHAppBarMessage(win.ABM_WINDOWPOSCHANGED, &abd)
	case win.WM_DISPLAYCHANGE, win.WM_DPICHANGED:
		bar_dock()
	case WM_APP_VOLUME: // from Core Audio, the moment the level or mute changes
		volume = {level = int(lp), muted = wp != 0, known = true}
		bar_render()
	case WM_APP_AUDIO_DEVICE:
		volume_attach()
		bar_render()
	case win.WM_POWERBROADCAST: // plugged in, unplugged, battery level
		bar_render()
	case win.WM_ENDSESSION: // logoff ends Temenos without WM_CLOSE
		if wp != 0 { taskbar_restore() }
	case win.WM_SETTINGCHANGE:
		if lp == 0 { break }
		if area, _ := win.wstring_to_utf8(cstring16(rawptr(uintptr(lp))), -1, context.temp_allocator); area == "ImmersiveColorSet" {
			theme = resolve_theme() // Windows switched between light and dark
			bar_render()
		}
	case:
		if msg == bar.taskbar_created { // Explorer restarted: it forgot the AppBar and shows its taskbar
			bar.registered = false
			bar_dock()
			taskbar_hide()
		}
	}
	return win.DefWindowProcW(hwnd, msg, wp, lp)
}
