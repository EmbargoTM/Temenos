// Windows virtual desktops ("areas"): the active one is read from the
// registry state Explorer keeps, and the same keys are watched with
// RegNotifyChangeKeyValue, so nothing is polled. Windows 11 keeps
// CurrentVirtualDesktop in the global key, Windows 10 in the per-session one;
// both are read and watched. Switching goes straight to the target through
// the shell's internal desktop manager when this Windows build is a known
// one, else it sends Explorer's own shortcuts (Ctrl+Win+Left/Right, one hop
// each); a new desktop is always Ctrl+Win+D.
package temenos

import "core:fmt"
import "core:slice"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	ProcessIdToSessionId :: proc(pid: win.DWORD, session: ^win.DWORD) -> win.BOOL ---
}

foreign import advapi32 "system:Advapi32.lib"
@(default_calling_convention = "system")
foreign advapi32 {
	RegNotifyChangeKeyValue :: proc(hKey: win.HKEY, bWatchSubtree: win.BOOL, dwNotifyFilter: win.DWORD, hEvent: win.HANDLE, fAsynchronous: win.BOOL) -> win.LSTATUS ---
}

VD_KEY :: `Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops`

Watcher :: struct {
	keys:   [2]win.HKEY,
	events: [2]win.HANDLE,
	source: [2]int, // 0 = global key, 1 = per-session key
	count:  int,
}

@(private = "file")
session_key :: proc() -> string {
	sid: win.DWORD
	ProcessIdToSessionId(win.GetCurrentProcessId(), &sid)
	return fmt.tprintf(`Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\%d\VirtualDesktops`, sid)
}

watcher_open :: proc(w: ^Watcher) -> bool {
	for path, i in ([2]string{VD_KEY, session_key()}) {
		key: win.HKEY
		if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, win.utf8_to_wstring(path), 0, win.KEY_NOTIFY | win.KEY_QUERY_VALUE, &key) != 0 { continue }
		w.keys[w.count] = key
		w.events[w.count] = win.CreateEventW(nil, true, false, nil)
		w.source[w.count] = i
		if !watcher_arm(w, w.count) { win.RegCloseKey(key); continue }
		w.count += 1
	}
	return w.count > 0
}

// Re-arm before reading, so a change made while reading signals again.
watcher_arm :: proc(w: ^Watcher, i: int) -> bool {
	win.ResetEvent(w.events[i])
	return RegNotifyChangeKeyValue(w.keys[i], false, win.REG_NOTIFY_CHANGE_LAST_SET, w.events[i], true) == 0
}

@(private = "file")
reg_binary :: proc(path, value: string, buf: []byte) -> int {
	size := win.DWORD(len(buf))
	if win.RegGetValueW(win.HKEY_CURRENT_USER, win.utf8_to_wstring(path), win.utf8_to_wstring(value),
	                    win.RRF_RT_REG_BINARY, nil, raw_data(buf), &size) != 0 { return 0 }
	return int(size)
}

// The active desktop (1-based, 0 = unknown), how many there are and the
// active one's id. `preferred` is the key that signalled (read first).
read_desktops :: proc(preferred: int) -> (index, count: int, id: [16]byte) {
	all: [4096]byte
	n := reg_binary(VD_KEY, "VirtualDesktopIDs", all[:]) / 16
	// Windows writes the list once a second desktop is created.
	if n == 0 { return 1, 1, id }
	paths := [2]string{VD_KEY, session_key()}
	if preferred == 1 { paths = {paths[1], paths[0]} }
	for p in paths {
		if reg_binary(p, "CurrentVirtualDesktop", id[:]) == 16 { break }
	}
	for i in 0 ..< n {
		if slice.equal(all[i * 16:][:16], id[:]) { return i + 1, n, id }
	}
	return 0, n, id
}

// ---------------------------------------------------------------------------
// Direct switching: IVirtualDesktopManagerInternal, the undocumented
// interface behind Task View. Its id changes whenever its layout does, so an
// unknown build fails QueryService and Temenos keeps using the shortcuts.
// ponytail: only the Windows 11 24H2+ id (build 26100 and later); older ids
// (and their method order) can be added here if needed.
// ---------------------------------------------------------------------------
@(private = "file") Com :: struct { vtbl: [^]rawptr }
@(private = "file") vd_manager: ^Com

@(private = "file", rodata) CLSID_IMMERSIVE_SHELL  := win.GUID{0xC2F03A33, 0x21F5, 0x47FA, {0xB4, 0xBB, 0x15, 0x63, 0x62, 0xA2, 0xF2, 0x39}}
@(private = "file", rodata) SID_VDM_INTERNAL       := win.GUID{0xC5E0CDCA, 0x7B6E, 0x41B2, {0x9F, 0xC4, 0xD9, 0x39, 0x75, 0xCC, 0x46, 0x7B}}
@(private = "file", rodata) IID_SERVICE_PROVIDER   := win.GUID{0x6D5140C1, 0x7436, 0x11CE, {0x80, 0x34, 0x00, 0xAA, 0x00, 0x60, 0x09, 0xFA}}
@(private = "file", rodata) IID_VDM_INTERNAL_24H2  := win.GUID{0x53F5CA0B, 0x158F, 0x4124, {0x90, 0x0C, 0x05, 0x71, 0x58, 0x06, 0x0B, 0x27}}
@(private = "file", rodata) IID_VIRTUAL_DESKTOP    := win.GUID{0x3F07F4BE, 0xB107, 0x441A, {0xAF, 0x0F, 0x39, 0xD8, 0x25, 0x29, 0x07, 0x2C}}
@(private = "file", rodata) IID_OBJECT_ARRAY       := win.GUID{0x92CA9DCD, 0x5622, 0x4BBA, {0xA8, 0x05, 0x5E, 0x9F, 0x54, 0x1B, 0xD8, 0xC9}}

@(private = "file") VDM_GET_COUNT    :: 3 // vtable slots of the 24H2 layout
@(private = "file") VDM_GET_DESKTOPS :: 7
@(private = "file") VDM_SWITCH       :: 9

@(private = "file")
release :: proc(o: ^Com) {
	if o != nil { (proc "system" (^Com) -> u32)(o.vtbl[2])(o) }
}

vd_init :: proc() {
	win.CoInitializeEx(nil, .APARTMENTTHREADED)
	sp: ^Com
	if win.CoCreateInstance(&CLSID_IMMERSIVE_SHELL, nil, win.CLSCTX_LOCAL_SERVER, &IID_SERVICE_PROVIDER, (^rawptr)(&sp)) != 0 { return }
	defer release(sp)
	m: ^Com
	query := (proc "system" (^Com, ^win.GUID, ^win.GUID, ^rawptr) -> win.HRESULT)(sp.vtbl[3])
	if query(sp, &SID_VDM_INTERNAL, &IID_VDM_INTERNAL_24H2, (^rawptr)(&m)) != 0 || m == nil { return }
	// Sanity check before trusting the layout: it must count what the registry lists.
	count: i32
	_, registry_count, _ := read_desktops(0)
	if (proc "system" (^Com, ^i32) -> win.HRESULT)(m.vtbl[VDM_GET_COUNT])(m, &count) != 0 || int(count) != registry_count {
		release(m)
		return
	}
	vd_manager = m
}

direct_switch_available :: proc() -> bool { return vd_manager != nil }

// Switch straight to area `index`; false when the direct path is unavailable.
@(private = "file")
switch_direct :: proc(index: int) -> bool {
	if vd_manager == nil { return false }
	desktops: ^Com // IObjectArray
	if (proc "system" (^Com, ^rawptr) -> win.HRESULT)(vd_manager.vtbl[VDM_GET_DESKTOPS])(vd_manager, (^rawptr)(&desktops)) != 0 { return false }
	defer release(desktops)
	desktop: ^Com // IVirtualDesktop; GetAt checks the interface id for us
	if (proc "system" (^Com, u32, ^win.GUID, ^rawptr) -> win.HRESULT)(desktops.vtbl[4])(desktops, u32(index - 1), &IID_VIRTUAL_DESKTOP, (^rawptr)(&desktop)) != 0 { return false }
	defer release(desktop)
	return (proc "system" (^Com, ^Com) -> win.HRESULT)(vd_manager.vtbl[VDM_SWITCH])(vd_manager, desktop) == 0
}

// The name given in Windows 11 (Task View > Rename), "" when none.
windows_desktop_name :: proc(id: [16]byte) -> string {
	g := transmute(win.GUID)id
	path := fmt.tprintf(`%s\Desktops\{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}`, VD_KEY, g.Data1, g.Data2, g.Data3,
	                    g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7])
	buf: [256]u16
	size := win.DWORD(size_of(buf))
	if win.RegGetValueW(win.HKEY_CURRENT_USER, win.utf8_to_wstring(path), win.L("Name"), win.RRF_RT_REG_SZ, nil, &buf, &size) != 0 { return "" }
	s, _ := win.wstring_to_utf8(cstring16(&buf[0]), -1, context.temp_allocator)
	return s
}

// The configured name, else the Windows 11 name.
area_name :: proc(index: int, id: [16]byte) -> string {
	if ws, ok := cfg.workspaces[index]; ok && ws.name != "" { return ws.name }
	return windows_desktop_name(id)
}

KEYEVENTF_EXTENDEDKEY :: 0x0001
KEYEVENTF_KEYUP       :: 0x0002

// Hold `mods`, tap each of `keys`, release `mods`.
send_chord :: proc(mods: []win.WORD, keys: []win.WORD) {
	inputs := make([dynamic]win.INPUT, context.temp_allocator)
	key :: proc(vk: win.WORD, up: bool) -> (in_: win.INPUT) {
		in_.type = .KEYBOARD
		in_.ki.wVk = vk
		extended := vk == win.VK_LWIN || (vk >= win.VK_LEFT && vk <= win.VK_DOWN)
		in_.ki.dwFlags = (up ? KEYEVENTF_KEYUP : 0) | (extended ? KEYEVENTF_EXTENDEDKEY : 0)
		return
	}
	for m in mods { append(&inputs, key(m, false)) }
	for k in keys { append(&inputs, key(k, false), key(k, true)) }
	#reverse for m in mods { append(&inputs, key(m, true)) }
	win.SendInput(win.UINT(len(inputs)), raw_data(inputs), size_of(win.INPUT))
}

new_desktop :: proc() { send_chord({win.VK_LCONTROL, win.VK_LWIN}, {'D'}) }

TIMER_SWITCH  :: 2
WM_APP_SWITCH :: win.WM_APP + 2 // wParam: area; posted by the keyboard hook

// Switch to area `target`: directly when possible, otherwise with the
// shortcuts once the user lets go of every modifier (Explorer listens for
// exactly Ctrl+Win+arrow, so a held Alt or Shift would spoil it).
request_switch :: proc(target: int) {
	if target < 1 || target > desk.count || target == desk.index { return }
	if switch_direct(target) { return }
	switch_target = target
	win.SetTimer(main_hwnd, TIMER_SWITCH, 15, nil)
}

switch_when_released :: proc() {
	for vk in ([?]i32{win.VK_SHIFT, win.VK_CONTROL, win.VK_MENU, win.VK_LWIN, win.VK_RWIN}) {
		if win.GetAsyncKeyState(vk) < 0 { return }
	}
	win.KillTimer(main_hwnd, TIMER_SWITCH)
	delta := switch_target - desk.index
	if desk.index == 0 || delta == 0 { return }
	keys := make([]win.WORD, abs(delta), context.temp_allocator)
	slice.fill(keys, delta > 0 ? win.VK_RIGHT : win.VK_LEFT)
	send_chord({win.VK_LCONTROL, win.VK_LWIN}, keys)
}

// ---------------------------------------------------------------------------
// Area keys (windows.areaKeys)
// ---------------------------------------------------------------------------
HOTKEY_PREV_AREA :: 100
HOTKEY_NEXT_AREA :: 101

MOD_ALT      :: 0x0001
MOD_CONTROL  :: 0x0002
MOD_SHIFT    :: 0x0004
MOD_WIN      :: 0x0008
MOD_NOREPEAT :: 0x4000

WH_KEYBOARD_LL  :: 13
LLKHF_INJECTED  :: 0x10
@(private = "file") VK_MASK :: 0xE8 // unassigned: tapped so releasing Win does not open Start

@(private = "file") keyboard_hook: win.HHOOK

// Ctrl+Alt+Left/Right are free, so they are ordinary hotkeys. Explorer owns
// Win+1..9 (pinned taskbar apps), so those are taken with a low-level hook.
area_keys_start :: proc() {
	if cfg.windows.area_keys == "ctrl+alt+arrow" {
		win.RegisterHotKey(main_hwnd, HOTKEY_PREV_AREA, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, win.VK_LEFT)
		win.RegisterHotKey(main_hwnd, HOTKEY_NEXT_AREA, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, win.VK_RIGHT)
	} else {
		keyboard_hook = win.SetWindowsHookExW(WH_KEYBOARD_LL, win_number_hook, nil, 0)
	}
}

area_keys_stop :: proc() {
	if keyboard_hook != nil { win.UnhookWindowsHookEx(keyboard_hook) }
}

@(private = "file")
win_number_hook :: proc "system" (code: i32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	context = default_context()
	kb := (^win.KBDLLHOOKSTRUCT)(uintptr(lp))
	down := wp == win.WM_KEYDOWN || wp == win.WM_SYSKEYDOWN
	if code == 0 && down && kb.flags & LLKHF_INJECTED == 0 && kb.vkCode >= '1' && kb.vkCode <= '9' &&
	   (win.GetAsyncKeyState(win.VK_LWIN) < 0 || win.GetAsyncKeyState(win.VK_RWIN) < 0) &&
	   win.GetAsyncKeyState(win.VK_SHIFT) >= 0 && win.GetAsyncKeyState(win.VK_CONTROL) >= 0 && win.GetAsyncKeyState(win.VK_MENU) >= 0 {
		send_chord({}, {VK_MASK})
		// Hooks must return at once: switch from the message loop.
		win.PostMessageW(main_hwnd, WM_APP_SWITCH, win.WPARAM(kb.vkCode - '0'), 0)
		return 1 // swallowed: the taskbar never sees Win+N
	}
	return win.CallNextHookEx(nil, code, wp, lp)
}
