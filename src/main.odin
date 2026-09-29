// Temenos: gives every Windows virtual desktop ("area") its own wallpaper,
// desktop shortcuts and name, with a navbar, a switch indicator and optional
// tiling. One process, one thread for the UI plus a worker that applies the
// area (area.odin); nothing is polled.
//
//   Temenos.exe                  start (replaces a running instance)
//   Temenos.exe --setup          run the setup wizard, then start
//   Temenos.exe --apps           choose the pinned apps, then start
//   Temenos.exe --new-area       create a virtual desktop and exit
//   Temenos.exe --quit           stop the running instance
//   Temenos.exe --test           show the detected state
//   Temenos.exe --runtime <dir>  runtime folder (default Documents\Temenos\runtime)
package temenos

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import win "core:sys/windows"

MAIN_CLASS :: "TemenosMain"

cfg:           Config
theme:         Theme
config_path:   string
runtime_root:  string
main_hwnd:     win.HWND
desk:          struct { index, count: int, id: [16]byte } // the active area (1-based, 0 = unknown)
switch_target: int

default_context :: proc "contextless" () -> runtime.Context { return runtime.default_context() }

main :: proc() {
	args := os.args[1:]
	if slice.contains(args, "--new-area") { new_desktop(); return }
	win.CoInitializeEx(nil, .APARTMENTTHREADED) // shell items (apps, icons), the file dialog, desktops
	if slice.contains(args, "--quit") { close_running_instance(); return }
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

	exe_dir := filepath.dir(os.args[0])
	if exe, err := os.get_executable_directory(context.allocator); err == nil { exe_dir = exe }
	config_path, _ = filepath.join({exe_dir, "Temenos.json"})
	err: string
	cfg, err = load_config(config_path)
	if err != "" { fatal(err) }
	runtime_root = strings.clone(known_folder(win.FOLDERID_Documents))
	runtime_root, _ = filepath.join({runtime_root, "Temenos", "runtime"})
	if i, found := slice.linear_search(args, "--runtime"); found && i + 1 < len(args) { runtime_root = args[i + 1] }
	if !ensure_runtime_dirs() { fatal(fmt.tprintf("Could not create the runtime folder %s", runtime_root)) }
	theme = resolve_theme()

	if slice.contains(args, "--test") { diagnostics(); return }
	if slice.contains(args, "--setup") || slice.contains(args, "--apps") || !os.exists(runtime_path(SETUP_MARKER)) {
		if setup_run(apps_only = slice.contains(args, "--apps") && os.exists(runtime_path(SETUP_MARKER))) {
			if cfg, err = load_config(config_path); err != "" { fatal(err) }
			theme = resolve_theme()
		}
	}
	close_running_instance()
	run()
}

fatal :: proc(message: string) -> ! {
	win.MessageBoxW(nil, win.utf8_to_wstring(message), win.L("Temenos"), win.MB_OK | win.MB_ICONERROR)
	os.exit(1)
}

@(private = "file")
diagnostics :: proc() {
	index, count, id := read_desktops(0)
	wallpaper := wallpaper_source(index)
	vd_init()
	text := fmt.tprintf("Current area: %d\nAreas: %d\nName: %s\nRuntime: %s\nWallpaper: %s\nDirect switching: %s", index, count,
	                    area_name(index, id), runtime_root, wallpaper != "" ? wallpaper : "none configured",
	                    direct_switch_available() ? "yes" : "no (keyboard shortcuts)")
	win.MessageBoxW(nil, win.utf8_to_wstring(text), win.L("Temenos"), win.MB_OK | win.MB_ICONINFORMATION)
}

// Ask a running Temenos to quit (it unregisters its bar and borders), and
// terminate it if it does not within 3 seconds.
@(private = "file")
close_running_instance :: proc() {
	hwnd := win.FindWindowExW(win.HWND_MESSAGE, nil, win.L(MAIN_CLASS), nil)
	if hwnd == nil { return }
	pid: win.DWORD
	win.GetWindowThreadProcessId(hwnd, &pid)
	process := win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_TERMINATE, false, pid)
	win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0)
	if process == nil { return }
	if win.WaitForSingleObject(process, 3000) != win.WAIT_OBJECT_0 { win.TerminateProcess(process, 1) }
	win.CloseHandle(process)
}

// This program's full path (os.args[0] may be relative).
exe_path :: proc() -> string {
	buf: [win.MAX_PATH]u16
	n := win.GetModuleFileNameW(nil, &buf[0], len(buf))
	if n == 0 { return os.args[0] }
	s, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return s
}

// Start a new instance (it replaces this one), with `flag` if given.
restart :: proc(flag := "") {
	exe := win.utf8_to_wstring(exe_path(), context.temp_allocator)
	parts := make([dynamic]string, context.temp_allocator)
	for a in os.args[1:] {
		if a != "--setup" && a != "--apps" { append(&parts, strings.contains(a, " ") ? fmt.tprintf(`"%s"`, a) : a) } // the wizard runs once
	}
	if flag != "" { append(&parts, flag) }
	args := strings.join(parts[:], " ", context.temp_allocator)
	win.ShellExecuteW(nil, win.L("open"), exe, win.utf8_to_wstring(args, context.temp_allocator), nil, win.SW_SHOWNORMAL)
}

@(private = "file")
run :: proc() {
	watcher: Watcher
	if !watcher_open(&watcher) { fatal("Windows virtual desktop registry keys are unavailable.") }

	class: win.wstring = win.L(MAIN_CLASS)
	wc := win.WNDCLASSEXW{cbSize = size_of(win.WNDCLASSEXW), lpfnWndProc = main_proc, hInstance = win.HINSTANCE(win.GetModuleHandleW(nil)), lpszClassName = class}
	win.RegisterClassExW(&wc)
	main_hwnd = win.CreateWindowExW(0, class, class, 0, 0, 0, 0, 0, win.HWND_MESSAGE, nil, wc.hInstance, nil)

	area_worker_start()
	desk.index, desk.count, desk.id = read_desktops(0)
	vd_init()
	if cfg.bar.enabled { bar_create() }
	taskbar_restore() // undo a previous run that could not (crash, or hideTaskbar turned off)
	taskbar_hide()
	if cfg.windows.indicator.enabled { indicator_create() }
	area_keys_start()
	// Out-of-context hooks arrive through this thread's message queue.
	if cfg.bar.enabled || cfg.wm.enabled {
		for r in ([?][2]win.DWORD{{EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND}, {EVENT_SYSTEM_MOVESIZEEND, EVENT_SYSTEM_MOVESIZEEND},
		                           {EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND}, {EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE},
		                           {EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE}, {EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED}}) {
			win.SetWinEventHook(r[0], r[1], nil, win_event, 0, 0, {.SKIPOWNPROCESS}) // out of context
		}
	}
	if cfg.wm.enabled { tiler_start() }
	if desk.index > 0 { area_changed() } // otherwise wait for Windows to publish it

	loop: for {
		r := win.MsgWaitForMultipleObjects(win.DWORD(watcher.count), &watcher.events[0], false, win.INFINITE, win.QS_ALLINPUT)
		if int(r) < watcher.count {
			i := int(r)
			watcher_arm(&watcher, i)
			index, count, id := read_desktops(watcher.source[i])
			if index > 0 && (index != desk.index || count != desk.count) {
				changed := index != desk.index
				desk.index, desk.count, desk.id = index, count, id
				if changed { area_changed() } else { bar_render() }
			}
		}
		msg: win.MSG
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			if msg.message == win.WM_QUIT { break loop }
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
		free_all(context.temp_allocator)
	}
	area_keys_stop()
	tiler_stop()
	taskbar_restore()
	bar_destroy()
}

@(private = "file")
area_changed :: proc() {
	if cfg.windows.indicator.enabled { indicator_show(desk.index, desk.count, area_name(desk.index, desk.id)) }
	bar_render()
	area_request(desk.index)
}

EVENT_SYSTEM_FOREGROUND    :: 0x0003
EVENT_SYSTEM_MOVESIZEEND   :: 0x000B
EVENT_SYSTEM_MINIMIZESTART :: 0x0016
EVENT_SYSTEM_MINIMIZEEND   :: 0x0017
EVENT_OBJECT_DESTROY       :: 0x8001
EVENT_OBJECT_SHOW          :: 0x8002
EVENT_OBJECT_HIDE          :: 0x8003
EVENT_OBJECT_NAMECHANGE    :: 0x800C
EVENT_OBJECT_CLOAKED       :: 0x8017
EVENT_OBJECT_UNCLOAKED     :: 0x8018

@(private = "file")
win_event :: proc "system" (hook: win.HWINEVENTHOOK, event: win.DWORD, hwnd: win.HWND, object, child: win.LONG, thread, time: win.DWORD) {
	context = default_context()
	// Top-level windows only.
	if object != 0 || child != 0 || hwnd == nil || u32(win.GetWindowLongW(hwnd, win.GWL_STYLE)) & win.WS_CHILD != 0 { return }
	switch event {
	case EVENT_SYSTEM_FOREGROUND:
		bar_title()
		tiler_focus_changed(hwnd)
		taskbar_foreground(hwnd)
	case EVENT_OBJECT_NAMECHANGE: // also: a window that got its title may now be tileable
		if hwnd == win.GetForegroundWindow() { bar_title() }
		tiler_window_event(hwnd, true)
	case EVENT_OBJECT_SHOW:
		taskbar_shown(hwnd)
		tiler_window_event(hwnd, true)
	case EVENT_SYSTEM_MINIMIZEEND, EVENT_OBJECT_UNCLOAKED, EVENT_SYSTEM_MOVESIZEEND:
		tiler_window_event(hwnd, true)
	case: // hidden, destroyed, cloaked, minimized
		tiler_window_event(hwnd, false)
	}
}

@(private = "file")
main_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	context = default_context()
	switch msg {
	case win.WM_HOTKEY:
		switch wp {
		case HOTKEY_PREV_AREA: request_switch(desk.index - 1)
		case HOTKEY_NEXT_AREA: request_switch(desk.index + 1)
		case: tiler_hotkey(int(wp))
		}
	case win.WM_TIMER:
		switch wp {
		case TIMER_SWITCH:  switch_when_released()
		case TIMER_ARRANGE: tiler_arrange()
		}
	case WM_APP_SWITCH:
		request_switch(int(wp))
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
	}
	return win.DefWindowProcW(hwnd, msg, wp, lp)
}
