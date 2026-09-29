// What an area looks like: its desktop shortcuts and its wallpaper. Applied
// on a worker thread (copying files and SPI_SETDESKWALLPAPER can take a
// moment, and a hung window can stall the wallpaper broadcast), so the bar
// and the indicator stay smooth. Quick switches coalesce: only the latest
// area is applied.
package temenos

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"
import stbi "vendor:stb/image"

@(private = "file") pending: int // area to apply next (atomic), 0 = none
@(private = "file") wake: win.HANDLE

area_worker_start :: proc() {
	wake = win.CreateEventW(nil, false, false, nil)
	thread.create_and_start(proc() {
		for {
			win.WaitForSingleObject(wake, win.INFINITE)
			if index := sync.atomic_exchange(&pending, 0); index > 0 { apply_area(index) }
			free_all(context.temp_allocator)
		}
	})
}

area_request :: proc(index: int) {
	sync.atomic_store(&pending, index)
	win.SetEvent(wake)
}

runtime_path :: proc(parts: ..string) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, runtime_root)
	append(&all, ..parts)
	p, _ := filepath.join(all[:], context.temp_allocator)
	return p
}

known_folder :: proc(id: win.GUID) -> string {
	id := id
	p: win.LPWSTR
	if win.SHGetKnownFolderPath(&id, 0, nil, &p) != 0 { return "" }
	defer win.CoTaskMemFree(p)
	s, _ := win.wstring_to_utf8(cstring16(p), -1, context.temp_allocator)
	return s
}

// Every runtime folder: root, shared paths and one per workspace.
ensure_runtime_dirs :: proc() -> bool {
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, runtime_root, runtime_path(cfg.paths.common), runtime_path(cfg.paths.wallpapers), runtime_path(cfg.paths.wallpaper_cache))
	for _, ws in cfg.workspaces { append(&dirs, runtime_path(ws.folder)) }
	for d in dirs {
		if os.make_directory_all(d) != nil && !os.is_dir(d) { return false }
	}
	return true
}

// The .lnk/.url files of a runtime folder.
@(private = "file")
shortcuts_in :: proc(dir: string) -> []string {
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for e in entries {
		ext := strings.to_lower(filepath.ext(e.name), context.temp_allocator)
		if e.type == .Regular && (ext == ".lnk" || ext == ".url") { append(&names, e.name) }
	}
	return names[:]
}

@(private = "file")
apply_area :: proc(index: int) {
	desktop := known_folder(win.FOLDERID_Desktop)
	if desktop == "" { return }
	path :: proc(dir, name: string) -> win.wstring {
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		return win.utf8_to_wstring(p, context.temp_allocator)
	}

	// Remove every managed shortcut, then copy the common ones and the area's.
	managed := make([dynamic]string, context.temp_allocator)
	append(&managed, runtime_path(cfg.paths.common))
	for _, ws in cfg.workspaces { append(&managed, runtime_path(ws.folder)) }
	for dir in managed {
		for name in shortcuts_in(dir) { win.DeleteFileW(path(desktop, name)) }
	}
	visible := make([dynamic]string, context.temp_allocator)
	append(&visible, runtime_path(cfg.paths.common))
	ws, configured := cfg.workspaces[index]
	if configured { append(&visible, runtime_path(ws.folder)) }
	for dir in visible {
		for name in shortcuts_in(dir) { win.CopyFileW(path(dir, name), path(desktop, name), false) }
	}

	if configured { set_wallpaper(index, ws.wallpaper) }
	win.SHChangeNotify(win.SHCNE_ASSOCCHANGED, win.SHCNF_IDLIST, nil, nil)
}

// Decode the image (a file still being written or not an image leaves the
// current wallpaper alone), copy the validated bytes into the cache and apply
// the copy, so editing the source (e.g. in Krita) never touches the desktop.
@(private = "file")
set_wallpaper :: proc(index: int, name: string) {
	if strings.trim_space(name) == "" { return }
	data, err := os.read_entire_file(runtime_path(cfg.paths.wallpapers, name), context.temp_allocator)
	if err != nil || len(data) == 0 { return }
	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 0)
	if pixels == nil { return }
	stbi.image_free(pixels)
	if w < 2 || h < 2 { return }

	cached := runtime_path(cfg.paths.wallpaper_cache, fmt.tprintf("Area%d%s", index, strings.to_lower(filepath.ext(name), context.temp_allocator)))
	tmp := strings.concatenate({cached, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil { return }
	target := win.utf8_to_wstring(cached, context.temp_allocator)
	if !win.MoveFileExW(win.utf8_to_wstring(tmp, context.temp_allocator), target, win.MOVEFILE_REPLACE_EXISTING) { return }
	win.SystemParametersInfoW(win.SPI_SETDESKWALLPAPER, 0, rawptr(target), win.SPIF_UPDATEINIFILE | win.SPIF_SENDCHANGE)
}

wallpaper_source :: proc(index: int) -> string {
	ws, ok := cfg.workspaces[index]
	if !ok || strings.trim_space(ws.wallpaper) == "" { return "" }
	p := runtime_path(cfg.paths.wallpapers, ws.wallpaper)
	return os.is_file(p) ? p : ""
}
