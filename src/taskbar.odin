// The Temenos bar replaces the Windows taskbar (windows.hideTaskbar): the
// taskbar is switched to auto-hide, which gives its space back to the work
// area, and its windows are hidden so it never slides in. What lived in it
// stays reachable from the bar: the notification centre and calendar, quick
// settings, widgets (Windows' own flyouts, opened with their shortcuts) and
// the notification-area icons (the real taskbar peeks out on demand).
// The user's auto-hide setting is saved in the runtime folder before it is
// changed and put back on exit, or on the next start after a crash.
package temenos

import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

@(private = "file") ABS_AUTOHIDE :: 0x1
@(private = "file") STATE_FILE   :: "taskbar-state"
@(private = "file") hidden, peeking: bool

@(private = "file")
window_class :: proc(hwnd: win.HWND) -> string {
	buf: [64]u16
	n := win.GetClassNameW(hwnd, &buf[0], len(buf))
	s, _ := win.utf16_to_utf8(buf[:max(n, 0)], context.temp_allocator)
	return s
}

@(private = "file")
is_taskbar :: proc(hwnd: win.HWND) -> bool {
	c := window_class(hwnd)
	return c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd"
}

@(private = "file")
show_taskbars :: proc(show: bool) {
	for class in ([?]win.wstring{win.L("Shell_TrayWnd"), win.L("Shell_SecondaryTrayWnd")}) {
		for h := win.FindWindowExW(nil, nil, class, nil); h != nil; h = win.FindWindowExW(nil, h, class, nil) {
			win.ShowWindow(h, show ? win.SW_SHOWNA : win.SW_HIDE)
		}
	}
}

@(private = "file")
set_autohide_state :: proc(state: int) {
	abd := win.APPBARDATA{cbSize = size_of(win.APPBARDATA), hWnd = win.FindWindowW(win.L("Shell_TrayWnd"), nil), lParam = win.LPARAM(state)}
	win.SHAppBarMessage(win.ABM_SETSTATE, &abd)
}

// Also called again when Explorer restarts (TaskbarCreated).
taskbar_hide :: proc() {
	if !cfg.bar.enabled || !cfg.windows.hide_taskbar || win.FindWindowW(win.L("Shell_TrayWnd"), nil) == nil { return }
	path := runtime_path(STATE_FILE)
	if !os.exists(path) { // keep the state from before Temenos, even across a crash
		abd := win.APPBARDATA{cbSize = size_of(win.APPBARDATA)}
		state := int(win.SHAppBarMessage(win.ABM_GETSTATE, &abd))
		buf: [16]u8
		if os.write_entire_file(path, transmute([]byte)strconv.write_int(buf[:], i64(state), 10)) != nil { return }
	}
	set_autohide_state(ABS_AUTOHIDE)
	hidden = true
	show_taskbars(false)
}

// Put the taskbar back as the user had it (a no-op when Temenos never hid it).
taskbar_restore :: proc() {
	path := runtime_path(STATE_FILE)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	state, _ := strconv.parse_int(strings.trim_space(string(data)))
	set_autohide_state(state)
	show_taskbars(true)
	os.remove(path)
	hidden = false
}

// Explorer shows the taskbar again now and then (Start, Explorer restart…).
taskbar_shown :: proc(hwnd: win.HWND) {
	if hidden && !peeking && is_taskbar(hwnd) { win.ShowWindow(hwnd, win.SW_HIDE) }
}

// Hide the peeking taskbar once the focus moves on.
taskbar_foreground :: proc(hwnd: win.HWND) {
	if !peeking { return }
	c := window_class(hwnd)
	// The notification area's overflow flyout (Windows 11 / Windows 10) keeps it open.
	if is_taskbar(hwnd) || c == "TopLevelWindowForOverflowXamlIsland" || c == "NotifyIconOverflowWindow" { return }
	peeking = false
	show_taskbars(false)
}

// The notification-area icons: let the real taskbar slide in, focused on them.
taskbar_peek :: proc() {
	if hidden {
		peeking = true
		show_taskbars(true)
	}
	send_chord({win.VK_LWIN}, {'B'})
}

is_windows_11 :: proc() -> bool {
	info := win.OSVERSIONINFOEXW{dwOSVersionInfoSize = size_of(win.OSVERSIONINFOEXW)}
	win.RtlGetVersion(&info)
	return info.dwBuildNumber >= 22000
}

// Notification centre with the calendar (Windows 10: the Action Center).
open_notifications :: proc() { send_chord({win.VK_LWIN}, {is_windows_11() ? 'N' : 'A'}) }
// Wi-Fi, Bluetooth, volume, brightness, battery (Windows 10: the Action Center).
open_quick_settings :: proc() { send_chord({win.VK_LWIN}, {'A'}) }
open_widgets :: proc() { send_chord({win.VK_LWIN}, {'W'}) }

// Segoe Fluent Icons / MDL2 battery levels 0..10, discharging and charging.
@(private = "file", rodata) BATTERY_GLYPHS  := [11]string{"", "", "", "", "", "", "", "", "", "", ""}
@(private = "file", rodata) CHARGING_GLYPHS := [11]string{"", "", "", "", "", "", "", "", "", "", ""}

// The battery icon and "85%", or "" on mains-only machines.
battery :: proc() -> (glyph, percent: string) {
	s: win.SYSTEM_POWER_STATUS
	if !win.GetSystemPowerStatus(&s) || .No_Battery in s.BatteryFlag || s.BatteryLifePercent > 100 { return }
	level := int(s.BatteryLifePercent) / 10
	glyph = s.ACLineStatus == .Online ? CHARGING_GLYPHS[level] : BATTERY_GLYPHS[level]
	return glyph, strings.concatenate({strconv.write_int(make([]u8, 4, context.temp_allocator), i64(s.BatteryLifePercent), 10), "%"}, context.temp_allocator)
}

// Win+D: every window minimised, or back (the corner of the Windows taskbar).
show_desktop :: proc() { send_chord({win.VK_LWIN}, {'D'}) }
