// The setup wizard (milk's OOBE, for Windows): a card in the Temenos look
// that runs on the first start (no <runtime>/.setup-done), from the bar's
// "Setup…" item (--setup) and, for the pinned apps alone, from "Pinned
// apps…" (--apps). Pages: welcome, look, bar (Temenos or the Windows
// taskbar), bar layout, pinned apps, keys and tiling, areas (wallpapers and
// the indicator), done. Every choice restyles the card at once. Finishing
// writes the choices into Temenos.json (parsed, changed, written back
// atomically with sorted keys, like milk) and copies new wallpapers into the
// runtime folder; skipping (Esc) changes nothing. Both create the marker, so
// the wizard only comes back on request.
package temenos

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import win "core:sys/windows"
import stbi "vendor:stb/image"

SETUP_MARKER :: ".setup-done"

foreign import advapi32 "system:Advapi32.lib"
@(default_calling_convention = "system")
foreign advapi32 {
	RegDeleteKeyValueW :: proc(hKey: win.HKEY, lpSubKey, lpValueName: win.LPCWSTR) -> win.LSTATUS ---
}

// "Start with Windows" is the per-user Run entry: no admin rights needed, and
// Task Manager's Startup apps page shows it and can turn it off as well.
@(private = "file") RUN_KEY :: `Software\Microsoft\Windows\CurrentVersion\Run`

autostart_enabled :: proc() -> bool {
	return win.RegGetValueW(win.HKEY_CURRENT_USER, win.L(RUN_KEY), win.L("Temenos"), win.RRF_RT_REG_SZ, nil, nil, nil) == 0
}

set_autostart :: proc(on: bool) -> bool {
	if !on {
		r := RegDeleteKeyValueW(win.HKEY_CURRENT_USER, win.L(RUN_KEY), win.L("Temenos"))
		return r == 0 || r == i32(win.ERROR_FILE_NOT_FOUND)
	}
	// Started the way this instance was: same runtime folder when one was given.
	cmd := fmt.tprintf(`"%s"`, exe_path())
	if i, found := slice.linear_search(os.args[1:], "--runtime"); found && i + 2 < len(os.args) {
		cmd = fmt.tprintf(`%s --runtime "%s"`, cmd, os.args[i + 2])
	}
	value := win.utf8_to_utf16(strings.concatenate({cmd, "\x00"}, context.temp_allocator), context.temp_allocator)
	return win.RegSetKeyValueW(win.HKEY_CURRENT_USER, win.L(RUN_KEY), win.L("Temenos"), win.REG_SZ, raw_data(value), win.DWORD(len(value) * 2)) == 0
}

@(private = "file") CARD_W, CARD_H, SHADOW :: 760, 500, 28

@(private = "file")
Page :: enum { Welcome, Look, Bar, Layout, Apps, Keys, Areas, Done }

@(private = "file")
Action :: enum {
	None, Next, Back, Skip, Theme, Variant, Milk_Bar, Bar_Top, Bar_Floating, Bar_Height, Move_Widget,
	Pin, Unpin, Win_Number, Tiling, Super, Wallpaper, Indicator, Autostart,
}

@(private = "file")
Hit :: struct { x, y, w, h: f32, action: Action, arg: int }

// Bar items as the layout page names them, and the order they keep in a group.
@(private = "file", rodata)
WIDGET_LABELS := [Widget_Kind]string{
	.Launcher = "Start", .Workspaces = "Area dots", .New_Area = "New area", .Active_Window = "Window title",
	.Layout = "Tiling layout", .Date = "Date", .Clock = "Clock", .Notifications = "Notifications",
	.Quick_Settings = "Wi-Fi · volume · battery", .Widgets = "Widgets", .Tray = "Tray icons",
	.Show_Desktop = "Show desktop", .Apps = "Pinned apps",
}
@(private = "file", rodata)
WIDGET_ORDER := [?]Widget_Kind{.Launcher, .Widgets, .Apps, .Active_Window, .Workspaces, .New_Area, .Layout, .Tray,
                                .Quick_Settings, .Date, .Clock, .Notifications, .Show_Desktop}

@(private = "file") APP_COLS, APP_ROWS :: 6, 3

@(private = "file")
Wizard :: struct {
	hwnd:            win.HWND,
	cv:              Canvas,
	base:            []u32, // shadow and card, redrawn only when the theme changes
	base_theme:      Theme,
	s:               f32,
	th:              Theme,
	title_font, body_font, small_font: win.HFONT,
	page:            Page,
	apps_only:       bool, // opened from "Pinned apps…": one page, then save
	hits:            [dynamic]Hit,
	hover:           Hit,
	tracking:        bool,
	state:           enum { Running, Finished, Skipped },
	// Choices, preset from Temenos.json.
	theme, variant:  int,
	milk_bar:        bool, // the Temenos bar in place of the Windows taskbar
	bar_top, bar_floating: bool,
	bar_height:      int,
	zone:            [Widget_Kind]int, // 0 left, 1 centre, 2 right, 3 hidden
	order:           [dynamic]Widget_Kind,
	pinned:          [dynamic]string, // app targets, in bar order
	win_number, tiling, super, indicator: bool,
	autostart:       bool, // Windows state, not Temenos.json: the Run entry
	// Pinned apps page.
	all_apps:        []App,
	search:          [dynamic]u8,
	app_scroll:      int,          // first visible row
	icons:           map[string]Icon,
	// Areas page.
	areas:           []int,          // configured areas, sorted
	picked:          map[int][]string, // area -> chosen images (absolute)
	thumbs:          map[int]Icon,
	thumbs_loaded:   bool,
}
@(private = "file") wz: Wizard

// Run the wizard; true when the user finished it (Temenos.json was rewritten).
setup_run :: proc(apps_only := false) -> bool {
	wz = {}
	wz.apps_only = apps_only
	wz.page = apps_only ? .Apps : .Welcome
	wz.theme, _ = slice.linear_search(THEME_NAMES, cfg.appearance.theme)
	wz.variant, _ = slice.linear_search(VARIANTS, cfg.appearance.variant)
	wz.milk_bar, wz.bar_top, wz.bar_floating = cfg.bar.enabled, cfg.bar.position == "top", cfg.bar.style == "floating"
	wz.bar_height = cfg.bar.height
	wz.win_number, wz.tiling, wz.super = cfg.windows.area_keys == "win+number", cfg.wm.enabled, cfg.wm.mod_key == "super"
	wz.indicator = cfg.windows.indicator.enabled
	wz.autostart = autostart_enabled() || !os.exists(runtime_path(SETUP_MARKER)) // yes on a first run
	for app in cfg.bar.apps { append(&wz.pinned, strings.clone(app)) }
	// Items keep the order Temenos.json gives them; the others follow in WIDGET_ORDER.
	for &z in wz.zone { z = 3 }
	for group, g in ([3][]string{cfg.bar.start, cfg.bar.center, cfg.bar.end}) {
		for id in group {
			for name, kind in WIDGET_IDS {
				if name == id && wz.zone[kind] == 3 { wz.zone[kind] = g; append(&wz.order, kind) }
			}
		}
	}
	for kind in WIDGET_ORDER { if !slice.contains(wz.order[:], kind) { append(&wz.order, kind) } }
	areas := make([dynamic]int)
	for index in cfg.workspaces { append(&areas, index) }
	_, desktop_count, _ := read_desktops(0)
	for index in 1 ..< desktop_count + 1 {
		if !slice.contains(areas[:], index) { append(&areas, index) }
	}
	slice.sort(areas[:])
	wz.areas = areas[:]
	if apps_only { wz.all_apps = list_apps() }

	mon := primary_monitor()
	_, work := monitor_rects(mon)
	wz.s = monitor_scale(mon)
	u := wz.s
	wz.title_font = make_font(i32(26 * u), 600)
	wz.body_font = make_font(i32(14 * u))
	wz.small_font = make_font(i32(12 * u))
	w, h := i32((CARD_W + 2 * SHADOW) * u), i32((CARD_H + 2 * SHADOW) * u)
	canvas_resize(&wz.cv, w, h)

	class: win.wstring = win.L("TemenosSetup")
	wc := win.WNDCLASSEXW{cbSize = size_of(win.WNDCLASSEXW), lpfnWndProc = wizard_proc, hInstance = win.HINSTANCE(win.GetModuleHandleW(nil)),
	                      lpszClassName = class, hCursor = win.LoadCursorA(nil, win.IDC_ARROW)}
	win.RegisterClassExW(&wc)
	wz.hwnd = win.CreateWindowExW(win.WS_EX_LAYERED | win.WS_EX_APPWINDOW, class, win.L("Temenos setup"), win.WS_POPUP,
	                              work.left + (work.right - work.left - w) / 2, work.top + (work.bottom - work.top - h) / 2, w, h,
	                              nil, nil, wc.hInstance, nil)
	render()
	win.ShowWindow(wz.hwnd, win.SW_SHOW)
	win.SetForegroundWindow(wz.hwnd)

	msg: win.MSG
	for wz.state == .Running && win.GetMessageW(&msg, nil, 0, 0) > 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
		free_all(context.temp_allocator)
	}
	if wz.hwnd != nil { win.DestroyWindow(wz.hwnd) }
	canvas_free(&wz.cv)
	delete(wz.base)
	for f in ([?]win.HFONT{wz.title_font, wz.body_font, wz.small_font}) { win.DeleteObject(win.HGDIOBJ(f)) }
	for _, icon in wz.icons { delete(icon.px) }
	for _, icon in wz.thumbs { delete(icon.px) }
	if !apps_only { _ = os.write_entire_file(runtime_path(SETUP_MARKER), transmute([]byte)fmt.tprintf("Temenos setup %v\n", wz.state)) }
	return wz.state == .Finished
}

// ---------------------------------------------------------------------------
// Drawing helpers (card coordinates in logical pixels -> canvas pixels)
// ---------------------------------------------------------------------------
@(private = "file")
px :: proc(v: f32) -> f32 { return (v + SHADOW) * wz.s }

@(private = "file")
add_hit :: proc(x, y, w, h: f32, action: Action, arg: int) { append(&wz.hits, Hit{x, y, w, h, action, arg}) }

@(private = "file")
hot :: proc(action: Action, arg: int) -> bool { return wz.hover.action == action && wz.hover.arg == arg }

@(private = "file")
text :: proc(font: win.HFONT, s: string, x, y, w, h: f32, rgb: u32, flags: win.UINT = 0) {
	draw_text(&wz.cv, font, s, i32(px(x)), i32(px(y)), i32(w * wz.s), i32(h * wz.s), rgb, 1, flags)
}

// A pill button; returns its width (logical).
@(private = "file")
chip :: proc(x, y: f32, label: string, selected: bool, action: Action, arg: int, accent := false, small := false) -> f32 {
	u, th := wz.s, wz.th
	font := small ? wz.small_font : wz.body_font
	w := f32(text_width(&wz.cv, font, label)) / u + (small ? 24 : 32)
	h: f32 = small ? 26 : 34
	filled := selected || accent
	fill_round(&wz.cv, px(x), px(y), w * u, h * u, h * u / 2, filled ? th.accent : (small ? th.background : th.surface))
	if hot(action, arg) { fill_round(&wz.cv, px(x), px(y), w * u, h * u, h * u / 2, filled ? th.accent_fg : th.accent, 0.14) }
	text(font, label, x, y, w, h, filled ? th.accent_fg : th.foreground, TEXT_CENTER)
	add_hit(x, y, w, h, action, arg)
	return w
}

// A caption and one chip per option; returns the y below it.
@(private = "file")
choice :: proc(x, y: f32, caption: string, options: []string, selected: int, action: Action) -> f32 {
	text(wz.small_font, caption, x, y, 320, 20, wz.th.muted)
	cx := x
	for o, i in options { cx += chip(cx, y + 24, o, i == selected, action, i) + 8 }
	return y + 24 + 34 + 16
}

// A miniature desktop: the Temenos bar (top/bottom, floating/full, height)
// or the Windows taskbar, the indicator pill and some windows (0 none,
// 1 floating, 2 tiled).
@(private = "file")
mock :: proc(x, y, w, h: f32, th: Theme, milk, top, floating: bool, windows: int, pill := true, bar_height := 36) {
	cv, u := &wz.cv, wz.s
	X, Y, W, H := px(x), px(y), w * u, h * u
	fill_round(cv, X, Y + 4 * u, W, H, 12 * u, 0, 0.18, 14 * u)
	fill_round(cv, X, Y, W, H, 12 * u, th.surface)
	bh := H * 0.1 * f32(bar_height) / 36
	m := floating ? H * 0.035 : 0
	area_top, area_bottom := Y, Y + H
	if milk {
		by := top ? Y + m : Y + H - m - bh
		fill_round(cv, X + m, by, W - 2 * m, bh, floating ? bh / 2 : 0, th.background)
		ds := bh / 30
		draw_dots(cv, X + W / 2 - dots_width(4, ds) / 2, by + bh / 2, 4, 1, ds, th.accent, th.muted, 0.6)
		fill_round(cv, X + m + bh * 0.45, by + bh * 0.3, bh * 0.4, bh * 0.4, bh * 0.1, th.foreground)
		fill_round(cv, X + W - m - bh * 1.8, by + bh * 0.36, bh * 1.2, bh * 0.28, bh * 0.14, th.muted)
		if top { area_top = by + bh + m } else { area_bottom = by - m }
	} else { // the Windows 11 taskbar: centred icons along the bottom
		tb := H * 0.085
		fill_round(cv, X, Y + H - tb, W, tb, 0, th.background)
		for k in 0 ..< 5 {
			q := tb * 0.5
			fill_round(cv, X + W / 2 + (f32(k) - 2.5) * q * 1.6 + q * 0.3, Y + H - tb / 2 - q / 2, q, q, q * 0.25, th.muted)
		}
		area_bottom = Y + H - tb
	}
	g := H * 0.045
	win_ :: proc(cv: ^Canvas, x, y, w, h, u: f32, th: Theme) {
		fill_round(cv, x, y + 2 * u, w, h, 6 * u, 0, 0.18, 6 * u)
		fill_round(cv, x, y, w, h, 6 * u, th.background)
		fill_round(cv, x + 6 * u, y + 6 * u, w * 0.3, 4 * u, 2 * u, th.muted, 0.7)
	}
	switch windows {
	case 1:
		win_(cv, X + W * 0.1, area_top + g * 2, W * 0.5, (area_bottom - area_top) * 0.55, u, th)
		win_(cv, X + W * 0.38, area_top + g * 4, W * 0.48, (area_bottom - area_top) * 0.6, u, th)
	case 2:
		ah := area_bottom - area_top - 2 * g
		mw := (W - 3 * g) * 0.55
		win_(cv, X + g, area_top + g, mw, ah, u, th)
		sh := (ah - g) / 2
		win_(cv, X + 2 * g + mw, area_top + g, W - 3 * g - mw, sh, u, th)
		win_(cv, X + 2 * g + mw, area_top + 2 * g + sh, W - 3 * g - mw, sh, u, th)
	}
	if pill {
		pw, ph := W * 0.3, H * 0.08
		py := !milk || top ? area_top + g : area_bottom - g - ph
		fill_round(cv, X + (W - pw) / 2, py, pw, ph, ph / 2, th.accent)
	}
}

// Pages that only exist for the Temenos bar.
@(private = "file")
skipped :: proc(p: Page) -> bool { return (p == .Layout || p == .Apps) && !wz.milk_bar }

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------
@(private = "file")
render :: proc() {
	wz.th = theme_for(THEME_NAMES[wz.theme], VARIANTS[wz.variant])
	th, cv, u := wz.th, &wz.cv, wz.s
	clear(&wz.hits)
	if wz.base == nil || wz.base_theme != th {
		canvas_clear(cv)
		fill_round(cv, px(0), px(6), CARD_W * u, CARD_H * u, 18 * u, 0, 0.35, 22 * u)
		fill_round(cv, px(0), px(0), CARD_W * u, CARD_H * u, 18 * u, th.background)
		delete(wz.base)
		wz.base, wz.base_theme = slice.clone(cv.px), th
	} else {
		copy(cv.px, wz.base)
	}
	if !wz.apps_only { draw_dots(cv, px(40), px(40), len(Page), int(wz.page), u, th.accent, th.muted, 0.5) }
	skip_label := wz.apps_only ? "Cancel" : "Skip setup"
	if wz.page != .Done {
		w := f32(text_width(cv, wz.small_font, skip_label)) / u + 20
		if hot(.Skip, 0) { fill_round(cv, px(CARD_W - 40 - w), px(28), w * u, 24 * u, 12 * u, th.surface) }
		text(wz.small_font, skip_label, CARD_W - 40 - w, 28, w, 24, th.muted, TEXT_CENTER)
		add_hit(CARD_W - 40 - w, 28, w, 24, .Skip, 0)
	}

	title, subtitle := "", ""
	next := "Next"
	switch wz.page {
	case .Welcome:
		title, subtitle, next = "Welcome to Temenos", "Every virtual desktop becomes an area with its own wallpaper, shortcuts and name.", "Get started"
		mock(140, 150, 480, 270, th, true, true, true, 1)
	case .Look:
		title, subtitle = "Pick a look", "Colours for the bar, the area indicator and the focus border."
		for name, i in THEME_NAMES {
			x := f32(60 + i * 220)
			t := theme_for(name, VARIANTS[wz.variant])
			if i == wz.theme { fill_round(cv, px(x - 4), px(146), 208 * u, 120 * u, 16 * u, th.accent) }
			else if hot(.Theme, i) { fill_round(cv, px(x - 4), px(146), 208 * u, 120 * u, 16 * u, th.muted, 0.5) }
			mock(x, 150, 200, 112, t, true, true, true, 1, false)
			text(wz.body_font, fmt.tprintf("%s%s", strings.to_upper(name[:1], context.temp_allocator), name[1:]), x, 272, 200, 22, th.foreground, TEXT_CENTER)
			add_hit(x - 4, 146, 208, 150, .Theme, i)
		}
		choice(60, 316, "Mode", {"Follow Windows", "Light", "Dark"}, wz.variant, .Variant)
	case .Bar:
		title, subtitle = "Your bar", "The Temenos bar in place of the Windows taskbar, or Windows' own."
		y := choice(40, 150, "Bar", {"Temenos", "Windows taskbar"}, wz.milk_bar ? 0 : 1, .Milk_Bar)
		if wz.milk_bar {
			y = choice(40, y, "Position", {"Top", "Bottom"}, wz.bar_top ? 0 : 1, .Bar_Top)
			y = choice(40, y, "Style", {"Floating", "Full width"}, wz.bar_floating ? 0 : 1, .Bar_Floating)
			text(wz.small_font, "Height", 40, y, 320, 20, th.muted)
			cx := 40 + chip(40, y + 24, "−", false, .Bar_Height, -1) + 8
			text(wz.body_font, fmt.tprintf("%d px", wz.bar_height), cx, y + 24, 64, 34, th.foreground, TEXT_CENTER)
			chip(cx + 64 + 8, y + 24, "+", false, .Bar_Height, +1)
		}
		mock(380, 160, 340, 200, th, wz.milk_bar, wz.bar_top, wz.bar_floating, 1, true, wz.bar_height)
	case .Layout:
		title, subtitle = "Arrange the bar", "Click an item to move it: left → centre → right → hidden."
		zones := [4]struct { x, y, w, h: f32, name: string }{
			{40, 146, 218, 176, "Left"}, {271, 146, 218, 176, "Centre"}, {502, 146, 218, 176, "Right"}, {40, 334, 680, 78, "Hidden"},
		}
		for z, zi in zones {
			fill_round(cv, px(z.x), px(z.y), z.w * u, z.h * u, 12 * u, th.surface)
			text(wz.small_font, z.name, z.x + 12, z.y + 8, z.w - 24, 18, th.muted)
			cx, cy := z.x + 10, z.y + 32
			for kind in wz.order {
				if wz.zone[kind] != zi { continue }
				label := WIDGET_LABELS[kind]
				w := f32(text_width(cv, wz.small_font, label)) / u + 24
				if cx + w > z.x + z.w - 10 && cx > z.x + 10 { cx, cy = z.x + 10, cy + 32 }
				cx += chip(cx, cy, label, false, .Move_Widget, int(kind), false, true) + 6
			}
		}
	case .Apps:
		title = "Pinned apps"
		subtitle = fmt.tprintf("Click apps to pin them to the bar, in that order. %d pinned; click a pinned icon to unpin it.", len(wz.pinned))
		apps_page()
		if wz.apps_only { next = "Save" }
	case .Keys:
		title, subtitle = "Keys and tiling", "Switch areas from the keyboard, and let Temenos tile your windows if you like."
		y := choice(40, 150, "Switch areas with", {"Win + 1…9", "Ctrl + Alt + ← →"}, wz.win_number ? 0 : 1, .Win_Number)
		y = choice(40, y, "Window tiling", {"Off", "On"}, wz.tiling ? 1 : 0, .Tiling)
		if wz.tiling {
			choice(40, y, "Tiling key", {"Alt", "Win"}, wz.super ? 1 : 0, .Super)
			m := wz.super ? "Win" : "Alt"
			text(wz.small_font, fmt.tprintf("%s+J/K focus · %s+Enter master · %s+H/L resize · %s+T/M/F layout · %s+Shift+Space float", m, m, m, m, m),
			     40, 390, 680, 20, th.muted)
		}
		mock(420, 160, 300, 190, th, wz.milk_bar, wz.bar_top, wz.bar_floating, wz.tiling ? 2 : 1, false, wz.bar_height)
	case .Areas:
		title, subtitle = "Areas", "Click an area to choose its wallpapers."
		wallpaper_grid()
		choice(40, 362, "Show the area indicator when switching", {"Yes", "No"}, wz.indicator ? 0 : 1, .Indicator)
	case .Done:
		title, subtitle, next = "All set", "Run this setup again from the bar's right-click menu.", "Finish"
		rows := [?][2]string{
			{"Look", fmt.tprintf("%s, %s", THEME_NAMES[wz.theme], wz.variant == 0 ? "following Windows" : VARIANTS[wz.variant])},
			{"Bar", wz.milk_bar ? fmt.tprintf("Temenos, %s, %s, %d px", wz.bar_top ? "top" : "bottom", wz.bar_floating ? "floating" : "full width", wz.bar_height) : "the Windows taskbar"},
			{"Pinned apps", wz.milk_bar ? fmt.tprintf("%d", len(wz.pinned)) : "—"},
			{"Switch areas", wz.win_number ? "Win + 1…9" : "Ctrl + Alt + ← →"},
			{"Tiling", wz.tiling ? (wz.super ? "on, Win key" : "on, Alt key") : "off"},
			{"Area indicator", wz.indicator ? "shown" : "hidden"},
			{"New wallpapers", fmt.tprintf("%d", len(wz.picked))},
		}
		for r, i in rows {
			y := 146 + f32(i) * 30
			text(wz.body_font, r[0], 40, y, 200, 28, th.muted)
			text(wz.body_font, r[1], 240, y, 480, 28, th.foreground)
		}
		choice(40, 362, "Start Temenos with Windows", {"Yes", "No"}, wz.autostart ? 0 : 1, .Autostart)
	}
	text(wz.title_font, title, 40, 64, 680, 40, th.foreground)
	text(wz.body_font, subtitle, 40, 106, 680, 24, th.muted)

	nw := f32(text_width(cv, wz.body_font, next)) / u + 40
	chip(CARD_W - 40 - nw, CARD_H - 40 - 34, next, false, .Next, 0, true)
	if wz.page != .Welcome && !wz.apps_only {
		bw := f32(text_width(cv, wz.body_font, "Back")) / u + 32
		chip(CARD_W - 40 - nw - 10 - bw, CARD_H - 40 - 34, "Back", false, .Back, 0)
	}
	rc: win.RECT
	win.GetWindowRect(wz.hwnd, &rc)
	present(cv, wz.hwnd, rc.left, rc.top)
}

// Apps matching the search, as indexes into all_apps.
@(private = "file")
filtered_apps :: proc() -> []int {
	query := strings.to_lower(string(wz.search[:]), context.temp_allocator)
	out := make([dynamic]int, context.temp_allocator)
	for app, i in wz.all_apps {
		if query == "" || strings.contains(strings.to_lower(app.name, context.temp_allocator), query) { append(&out, i) }
	}
	return out[:]
}

@(private = "file")
cached_icon :: proc(target: string, size: i32) -> (Icon, bool) {
	if icon, ok := wz.icons[target]; ok { return icon, icon.px != nil }
	icon, _ := app_icon(target, size)
	wz.icons[strings.clone(target)] = icon
	return icon, icon.px != nil
}

@(private = "file")
apps_page :: proc() {
	th, cv, u := wz.th, &wz.cv, wz.s
	// Search field, and the pinned apps in bar order beside it.
	fill_round(cv, px(40), px(140), 380 * u, 34 * u, 17 * u, th.surface)
	query := string(wz.search[:])
	text(wz.body_font, query != "" ? fmt.tprintf("%s|", query) : "Type to search apps", 58, 140, 350, 34, query != "" ? th.foreground : th.muted)
	for target, i in wz.pinned {
		x := 436 + f32(i) * 36
		if x + 32 > 720 { break }
		fill_round(cv, px(x), px(141), 32 * u, 32 * u, 8 * u, hot(.Unpin, i) ? th.accent : th.surface, hot(.Unpin, i) ? 0.3 : 1)
		if icon, ok := cached_icon(target, i32(24 * u)); ok { draw_bitmap(cv, icon, px(x + 16), px(157)) }
		add_hit(x, 141, 32, 32, .Unpin, i)
	}
	// The grid: whole rows only, scrolled with the wheel.
	matches := filtered_apps()
	rows := (len(matches) + APP_COLS - 1) / APP_COLS
	wz.app_scroll = clamp(wz.app_scroll, 0, max(rows - APP_ROWS, 0))
	tw, tile_h, gap: f32 = 108, 72, 6
	for slot in 0 ..< APP_COLS * APP_ROWS {
		n := wz.app_scroll * APP_COLS + slot
		if n >= len(matches) { break }
		index := matches[n]
		app := wz.all_apps[index]
		x, y := 40 + f32(slot % APP_COLS) * (tw + gap), 186 + f32(slot / APP_COLS) * (tile_h + gap)
		pinned := slice.contains(wz.pinned[:], app.target)
		fill_round(cv, px(x), px(y), tw * u, tile_h * u, 10 * u, pinned ? th.accent : th.surface, pinned ? 0.28 : 1)
		if hot(.Pin, index) { fill_round(cv, px(x), px(y), tw * u, tile_h * u, 10 * u, th.accent, 0.14) }
		if pinned { fill_round(cv, px(x + tw - 14), px(y + 8), 6 * u, 6 * u, 3 * u, th.accent) }
		if icon, ok := cached_icon(app.target, i32(32 * u)); ok { draw_bitmap(cv, icon, px(x + tw / 2), px(y + 26)) }
		text(wz.small_font, app.name, x + 6, y + 46, tw - 12, 20, th.foreground, TEXT_CENTER)
		add_hit(x, y, tw, tile_h, .Pin, index)
	}
	if rows > APP_ROWS { // scrollbar
		track := APP_ROWS * (tile_h + gap) - gap
		thumb := track * f32(APP_ROWS) / f32(rows)
		ty := 186 + (track - thumb) * f32(wz.app_scroll) / f32(rows - APP_ROWS)
		fill_round(cv, px(CARD_W - 32), px(ty), 4 * u, thumb * u, 2 * u, th.muted, 0.6)
	}
	if len(matches) == 0 { text(wz.body_font, "No app matches the search.", 40, 186, 680, 34, th.muted, TEXT_CENTER) }
}

@(private = "file")
wallpaper_grid :: proc() {
	th, u := wz.th, wz.s
	cols := max(5, (len(wz.areas) + 1) / 2)
	gap: f32 = 14
	tw := (680 - f32(cols - 1) * gap) / f32(cols)
	th_h := tw * 9 / 16
	for area, i in wz.areas {
		x, y := 40 + f32(i % cols) * (tw + gap), 146 + f32(i / cols) * (th_h + 34)
		fill_round(&wz.cv, px(x - 3), px(y - 3), (tw + 6) * u, (th_h + 6) * u, 11 * u, hot(.Wallpaper, area) ? th.accent : th.surface)
		if t, ok := wz.thumbs[area]; ok {
			blit_rounded(&wz.cv, t.px, t.w, t.h, i32(px(x)), i32(px(y)), 8 * u)
		} else {
			fill_round(&wz.cv, px(x), px(y), tw * u, th_h * u, 8 * u, th.background)
			text(wz.title_font, "+", x, y, tw, th_h, th.muted, TEXT_CENTER)
		}
		name := area_name(area, {})
		label := name == "" ? fmt.tprintf("AREA %d", area) : fmt.tprintf("AREA %d · %s", area, name)
		text(wz.small_font, label, x, y + th_h + 6, tw, 20, th.foreground, TEXT_CENTER)
		add_hit(x - 3, y - 3, tw + 6, th_h + 30, .Wallpaper, area)
	}
}

// ---------------------------------------------------------------------------
// Wallpapers
// ---------------------------------------------------------------------------
@(private = "file")
thumb_size :: proc() -> (w, h: i32) {
	cols := max(5, (len(wz.areas) + 1) / 2)
	tw := (680 - f32(cols - 1) * 14) / f32(cols)
	return i32(tw * wz.s), i32(tw * 9 / 16 * wz.s)
}

// A cropped, downscaled copy of the image (cover fit), or false.
@(private = "file")
load_thumb :: proc(path: string) -> (t: Icon, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	w, h, n: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &n, 4)
	if pixels == nil { return }
	defer stbi.image_free(pixels)
	t.w, t.h = thumb_size()
	// Crop the source to the thumbnail's aspect ratio, centred.
	cw, ch := w, i32(i64(w) * i64(t.h) / i64(t.w))
	if ch > h { cw, ch = i32(i64(h) * i64(t.w) / i64(t.h)), h }
	ox, oy := (w - cw) / 2, (h - ch) / 2
	out := make([]u8, t.w * t.h * 4, context.temp_allocator)
	stbi.resize_uint8(pixels[(oy * w + ox) * 4:], cw, ch, w * 4, raw_data(out), t.w, t.h, 0, 4)
	t.px = make([]u32, t.w * t.h)
	for &p, i in t.px { p = u32(out[i * 4]) << 16 | u32(out[i * 4 + 1]) << 8 | u32(out[i * 4 + 2]) }
	return t, true
}

@(private = "file")
set_thumb :: proc(area: int, path: string) {
	t, ok := load_thumb(path)
	if !ok { return }
	if old, had := wz.thumbs[area]; had { delete(old.px) }
	wz.thumbs[area] = t
}

@(private = "file")
pick_wallpaper :: proc(area: int) {
	buf: [1024]u16
	filter := win.utf8_to_wstring("Images (*.jpg, *.png, *.bmp)\x00*.jpg;*.jpeg;*.png;*.bmp\x00", context.temp_allocator)
	ofn := win.OPENFILENAMEW{lStructSize = size_of(win.OPENFILENAMEW), hwndOwner = wz.hwnd, lpstrFilter = filter, lpstrFile = cstring16(&buf[0]),
	                         nMaxFile = len(buf), Flags = win.OFN_FILEMUSTEXIST | win.OFN_PATHMUSTEXIST | win.OFN_NOCHANGEDIR | win.OFN_EXPLORER | win.OFN_ALLOWMULTISELECT}
	if !win.GetOpenFileNameW(&ofn) { return }
	// Explorer returns either one full path, or a directory followed by file names.
	parts := make([dynamic]string, context.temp_allocator)
	start := 0
	for i in 0 ..< len(buf) {
		if buf[i] == 0 {
			if i == start { break }
			part, _ := win.wstring_to_utf8(cstring16(&buf[start]), i - start, context.temp_allocator)
			append(&parts, part)
			start = i + 1
		}
	}
	if len(parts) == 0 { return }
	paths := make([dynamic]string, context.allocator)
	if len(parts) == 1 {
		append(&paths, strings.clone(parts[0]))
	} else {
		for file in parts[1:] {
			path, _ := filepath.join({parts[0], file}, context.allocator)
			append(&paths, path)
		}
	}
	for path in paths {
		if _, ok := load_thumb(path); !ok {
			win.MessageBoxW(wz.hwnd, win.L("A selected file is not an image Temenos can read."), win.L("Temenos"), win.MB_OK | win.MB_ICONWARNING)
			for p in paths { delete(p) }
			delete(paths)
			return
		}
	}
	if old, had := wz.picked[area]; had { for path in old { delete(path) }; delete(old) }
	wz.picked[area] = paths[:]
	set_thumb(area, paths[0])
}

// Where each area's wallpapers go, as names inside Wallpapers/. Images already
// there are used in place; external files are copied without overwriting files
// another area may use.
@(private = "file")
place_wallpapers :: proc() -> (names: map[int][]string, ok: bool) {
	folder := runtime_path(cfg.paths.wallpapers)
	inside :: proc(src, folder: string) -> bool { return strings.equal_fold(filepath.dir(src), folder) }
	names = make(map[int][]string, 16, context.temp_allocator)
	used := make(map[string]bool, 16, context.temp_allocator)
	for area in wz.areas {
		ws := cfg.workspaces[area]
		if len(ws.wallpapers) > 0 {
			names[area] = ws.wallpapers
		} else if ws.wallpaper != "" {
			names[area] = []string{ws.wallpaper}
		} else {
			names[area] = wallpaper_names(area)
		}
		for name in names[area] { used[strings.to_lower(name, context.temp_allocator)] = true }
	}
	for area, sources in wz.picked {
		selected := make([dynamic]string, context.temp_allocator)
		for source, i in sources {
			ext := strings.to_lower(filepath.ext(source), context.temp_allocator)
			stem := fmt.tprintf("Area%d-%d", area, i + 1)
			name := inside(source, folder) ? filepath.base(source) : fmt.tprintf("%s%s", stem, ext)
			if !inside(source, folder) {
				for k := 2; used[strings.to_lower(name, context.temp_allocator)]; k += 1 { name = fmt.tprintf("%s-%d%s", stem, k, ext) }
				dst := runtime_path(cfg.paths.wallpapers, name)
				if !win.CopyFileW(win.utf8_to_wstring(source, context.temp_allocator), win.utf8_to_wstring(dst, context.temp_allocator), false) {
					message := fmt.tprintf("Could not copy %s to %s (Windows error %d).", source, dst, win.GetLastError())
					win.MessageBoxW(wz.hwnd, win.utf8_to_wstring(message, context.temp_allocator), win.L("Temenos"), win.MB_OK | win.MB_ICONERROR)
					return names, false
				}
			}
			used[strings.to_lower(name, context.temp_allocator)] = true
			append(&selected, name)
		}
		names[area] = selected[:]
	}
	return names, true
}

// ---------------------------------------------------------------------------
// Applying
// ---------------------------------------------------------------------------
@(private = "file")
finish :: proc() -> bool {
	// Wallpapers first: Temenos.json may only name files that exist.
	names := place_wallpapers() or_return

	data, err := os.read_entire_file(config_path, context.temp_allocator)
	if err != nil { return false }
	data = data[3:] if len(data) >= 3 && string(data[:3]) == "\xEF\xBB\xBF" else data
	value, perr := json.parse(data, .JSON5, true, context.temp_allocator)
	root, is_obj := value.(json.Object)
	if perr != nil || !is_obj { return false }
	// Maps may move when they grow: store every changed child back.
	set :: proc(parent: ^json.Object, key: string, v: json.Value) { parent[key] = v }
	child :: proc(parent: json.Object, key: string) -> json.Object {
		if c, ok := parent[key].(json.Object); ok { return c }
		return make(json.Object, 8, context.temp_allocator)
	}
	strings_array :: proc(items: []string) -> json.Value {
		a := make(json.Array, 0, len(items), context.temp_allocator)
		for s in items { append(&a, json.Value(s)) }
		return a
	}
	appearance := child(root, "appearance")
	set(&appearance, "theme", THEME_NAMES[wz.theme])
	set(&appearance, "variant", VARIANTS[wz.variant])
	set(&root, "appearance", appearance)
	b := child(root, "bar")
	set(&b, "enabled", wz.milk_bar)
	set(&b, "position", wz.bar_top ? "top" : "bottom")
	set(&b, "style", wz.bar_floating ? "floating" : "full")
	set(&b, "height", i64(wz.bar_height))
	for key, g in ([3]string{"start", "center", "end"}) {
		ids := make([dynamic]string, context.temp_allocator)
		for kind in wz.order { if wz.zone[kind] == g { append(&ids, WIDGET_IDS[kind]) } }
		set(&b, key, strings_array(ids[:]))
	}
	set(&b, "apps", strings_array(wz.pinned[:]))
	set(&root, "bar", b)
	wm := child(root, "wm")
	set(&wm, "enabled", wz.tiling)
	set(&wm, "modKey", wz.super ? "super" : "alt")
	set(&root, "wm", wm)
	windows := child(root, "windows")
	set(&windows, "areaKeys", wz.win_number ? "win+number" : "ctrl+alt+arrow")
	set(&windows, "hideTaskbar", wz.milk_bar)
	indicator := child(windows, "indicator")
	set(&indicator, "enabled", wz.indicator)
	set(&windows, "indicator", indicator)
	set(&root, "windows", windows)
	workspaces := child(root, "workspaces")
	for area, area_names in names {
		key := fmt.tprintf("%d", area)
		entry := child(workspaces, key)
		if _, exists := cfg.workspaces[area]; !exists {
			set(&entry, "name", "")
			set(&entry, "folder", workspace_folder(area))
		}
		set(&entry, "wallpaper", len(area_names) > 0 ? area_names[0] : "")
		set(&entry, "wallpapers", strings_array(area_names))
		set(&workspaces, key, entry)
	}
	set(&root, "workspaces", workspaces)

	out, merr := json.marshal(json.Value(root), {pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil { return false }
	tmp := strings.concatenate({config_path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, out) != nil { return false }
	return bool(win.MoveFileExW(win.utf8_to_wstring(tmp, context.temp_allocator), win.utf8_to_wstring(config_path, context.temp_allocator), win.MOVEFILE_REPLACE_EXISTING))
}

@(private = "file")
go_to :: proc(p: Page, step: int) {
	p := p
	for skipped(p) { p = Page(int(p) + step) }
	wz.page = p
	if wz.page == .Areas && !wz.thumbs_loaded {
		wz.thumbs_loaded = true
		win.SetCursor(win.LoadCursorA(nil, win.IDC_WAIT))
		for area in wz.areas { if p := wallpaper_source(area); p != "" { set_thumb(area, p) } }
	}
	if wz.page == .Apps && wz.all_apps == nil {
		win.SetCursor(win.LoadCursorA(nil, win.IDC_WAIT))
		wz.all_apps = list_apps()
	}
}

@(private = "file")
act :: proc(h: Hit) {
	switch h.action {
	case .None:
	case .Next:
		if wz.page == .Done || wz.apps_only {
			if !finish() {
				win.MessageBoxW(wz.hwnd, win.L("Could not update Temenos.json."), win.L("Temenos"), win.MB_OK | win.MB_ICONERROR)
				return
			}
			if !wz.apps_only && !set_autostart(wz.autostart) {
				win.MessageBoxW(wz.hwnd, win.L("Could not change whether Temenos starts with Windows."), win.L("Temenos"), win.MB_OK | win.MB_ICONWARNING)
			}
			wz.state = .Finished
			return
		}
		go_to(Page(int(wz.page) + 1), +1)
	case .Back:         if !wz.apps_only && wz.page != .Welcome { go_to(Page(int(wz.page) - 1), -1) }
	case .Skip:         wz.state = .Skipped
	case .Theme:        wz.theme = h.arg
	case .Variant:      wz.variant = h.arg
	case .Milk_Bar:     wz.milk_bar = h.arg == 0
	case .Bar_Top:      wz.bar_top = h.arg == 0
	case .Bar_Floating: wz.bar_floating = h.arg == 0
	case .Bar_Height:   wz.bar_height = clamp(wz.bar_height + 4 * h.arg, 24, 64)
	case .Move_Widget:  wz.zone[Widget_Kind(h.arg)] = (wz.zone[Widget_Kind(h.arg)] + 1) % 4
	case .Pin:
		target := wz.all_apps[h.arg].target
		if i, found := slice.linear_search(wz.pinned[:], target); found {
			delete(wz.pinned[i])
			ordered_remove(&wz.pinned, i)
		} else {
			append(&wz.pinned, strings.clone(target))
		}
	case .Unpin:
		delete(wz.pinned[h.arg])
		ordered_remove(&wz.pinned, h.arg)
	case .Win_Number:   wz.win_number = h.arg == 0
	case .Tiling:       wz.tiling = h.arg == 1
	case .Super:        wz.super = h.arg == 1
	case .Indicator:    wz.indicator = h.arg == 0
	case .Autostart:    wz.autostart = h.arg == 0
	case .Wallpaper:    pick_wallpaper(h.arg)
	}
	if wz.state == .Running { render() }
}

@(private = "file")
hit_at :: proc(lp: win.LPARAM) -> Hit {
	x := f32(i16(lp & 0xFFFF)) / wz.s - SHADOW
	y := f32(i16(lp >> 16 & 0xFFFF)) / wz.s - SHADOW
	#reverse for h in wz.hits {
		if x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h { return h }
	}
	return {}
}

@(private = "file")
wizard_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	switch msg {
	case win.WM_NCHITTEST: // drag the card by any empty spot
		pt := win.POINT{i32(i16(lp & 0xFFFF)), i32(i16(lp >> 16 & 0xFFFF))}
		win.ScreenToClient(hwnd, &pt)
		return hit_at(win.LPARAM(uint(u16(pt.x)) | uint(u16(pt.y)) << 16)).action == .None ? win.HTCAPTION : win.HTCLIENT
	case win.WM_MOUSEMOVE:
		if !wz.tracking {
			tme := win.TRACKMOUSEEVENT{cbSize = size_of(win.TRACKMOUSEEVENT), dwFlags = win.TME_LEAVE, hwndTrack = hwnd}
			wz.tracking = bool(win.TrackMouseEvent(&tme))
		}
		if h := hit_at(lp); h.action != wz.hover.action || h.arg != wz.hover.arg { wz.hover = h; render() }
		win.SetCursor(win.LoadCursorA(nil, wz.hover.action == .None ? win.IDC_ARROW : win.IDC_HAND))
	case win.WM_MOUSELEAVE:
		wz.tracking, wz.hover = false, {}
		render()
	case win.WM_MOUSEWHEEL:
		if wz.page == .Apps {
			wz.app_scroll += i16(wp >> 16) > 0 ? -1 : 1
			wz.hover = {}
			render()
		}
	case win.WM_NCLBUTTONDBLCLK:
		return 0 // no maximize from the "caption"
	case win.WM_SETCURSOR:
		return 1 // set on WM_MOUSEMOVE
	case win.WM_LBUTTONUP:
		act(hit_at(lp))
	case win.WM_CHAR: // the apps page's search field
		if wz.page != .Apps { break }
		switch {
		case wp == 8: // backspace
			for len(wz.search) > 0 {
				b := pop(&wz.search)
				if b & 0xC0 != 0x80 { break } // removed a whole UTF-8 sequence
			}
		case wp >= 32 && wp != 127:
			bytes, n := utf8.encode_rune(rune(wp))
			append(&wz.search, ..bytes[:n])
		case: break
		}
		wz.app_scroll = 0
		render()
	case win.WM_KEYDOWN:
		switch wp {
		case win.VK_RETURN: act({action = .Next})
		case win.VK_ESCAPE:
			if wz.page == .Apps && len(wz.search) > 0 { clear(&wz.search); render() } else { act({action = .Skip}) }
		case win.VK_LEFT:   if wz.page != .Apps { act({action = .Back}) }
		case win.VK_RIGHT:  if wz.page != .Apps && wz.page != .Done { act({action = .Next}) }
		}
	case win.WM_CLOSE:
		wz.state = .Skipped
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wp, lp)
}
