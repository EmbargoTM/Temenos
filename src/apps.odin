// Pinned apps (bar.apps): anything Start's "All apps" lists, desktop programs
// and Store apps alike, found through the shell's Applications folder. An app
// is stored as its launch target, "shell:AppsFolder\<app id>" (a file path
// works too), which ShellExecute opens and the shell draws an icon for.
package temenos

import "core:slice"
import "core:strings"
import win "core:sys/windows"

App :: struct { name, target: string }

// An app's icon: premultiplied BGRA rows, top-down.
Icon :: struct { px: []u32, w, h: i32 }

@(private = "file") Com :: struct { vtbl: [^]rawptr }

@(private = "file", rodata) BHID_ENUM_ITEMS      := win.GUID{0x94F60519, 0x2850, 0x4924, {0xAA, 0x5A, 0xD1, 0x5E, 0x84, 0x86, 0x80, 0x39}}
@(private = "file", rodata) IID_ENUM_SHELL_ITEMS := win.GUID{0x70629033, 0xE363, 0x4A28, {0xA5, 0x67, 0x0D, 0xB7, 0x80, 0x06, 0xE6, 0xD7}}
@(private = "file", rodata) IID_IMAGE_FACTORY    := win.GUID{0xBCC18B79, 0xBA16, 0x442F, {0x80, 0xC4, 0x8A, 0x59, 0xC3, 0x0C, 0x46, 0x3B}}
@(private = "file") SIIGBF_ICONONLY :: 0x4

@(private = "file")
item_name :: proc(item: ^win.IShellItem, kind: win.SIGDN, allocator := context.allocator) -> string {
	p: win.LPWSTR
	if item->GetDisplayName(kind, &p) != 0 { return "" }
	defer win.CoTaskMemFree(p)
	s, _ := win.wstring_to_utf8(cstring16(p), -1, allocator)
	return s
}

// Every app of Start's "All apps", sorted by name.
list_apps :: proc(allocator := context.allocator) -> []App {
	folder: ^win.IShellItem
	if win.SHCreateItemFromParsingName(win.L("shell:AppsFolder"), nil, win.IID_IShellItem, (^rawptr)(&folder)) != 0 { return nil }
	defer folder->Release()
	items: ^win.IEnumShellItems
	if folder->BindToHandler(nil, BHID_ENUM_ITEMS, &IID_ENUM_SHELL_ITEMS, (^rawptr)(&items)) != 0 { return nil }
	defer items->Release()
	apps := make([dynamic]App, allocator)
	for {
		item: ^win.IShellItem
		fetched: u32
		if items->Next(1, &item, &fetched) != 0 || fetched == 0 { break }
		name := item_name(item, .NORMALDISPLAY, allocator)
		id := item_name(item, .PARENTRELATIVEPARSING, context.temp_allocator)
		item->Release()
		if name == "" || id == "" { continue }
		append(&apps, App{name, strings.concatenate({`shell:AppsFolder\`, id}, allocator)})
	}
	slice.sort_by(apps[:], proc(a, b: App) -> bool {
		return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
	})
	return apps[:]
}

// The name the shell shows for a target ("" when it no longer exists).
app_name :: proc(target: string, allocator := context.allocator) -> string {
	item: ^win.IShellItem
	if win.SHCreateItemFromParsingName(win.utf8_to_wstring(target, context.temp_allocator), nil, win.IID_IShellItem, (^rawptr)(&item)) != 0 { return "" }
	defer item->Release()
	return item_name(item, .NORMALDISPLAY, allocator)
}

// The app's icon at `size` pixels, as the shell draws it (Start, Explorer).
app_icon :: proc(target: string, size: i32, allocator := context.allocator) -> (icon: Icon, ok: bool) {
	factory: ^Com
	if win.SHCreateItemFromParsingName(win.utf8_to_wstring(target, context.temp_allocator), nil, &IID_IMAGE_FACTORY, (^rawptr)(&factory)) != 0 { return }
	defer (proc "system" (^Com) -> u32)(factory.vtbl[2])(factory)
	bmp: win.HBITMAP
	if (proc "system" (^Com, win.SIZE, i32, ^win.HBITMAP) -> win.HRESULT)(factory.vtbl[3])(factory, {size, size}, SIIGBF_ICONONLY, &bmp) != 0 { return }
	defer win.DeleteObject(win.HGDIOBJ(bmp))
	info: win.BITMAP
	win.GetObjectW(win.HANDLE(bmp), size_of(info), &info)
	icon.w, icon.h = info.bmWidth, abs(info.bmHeight)
	if icon.w <= 0 || icon.h <= 0 { return }
	icon.px = make([]u32, icon.w * icon.h, allocator)
	bi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = icon.w, biHeight = -icon.h, biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	dc := win.GetDC(nil)
	defer win.ReleaseDC(nil, dc)
	if win.GetDIBits(dc, bmp, 0, u32(icon.h), raw_data(icon.px), &bi, win.DIB_RGB_COLORS) == 0 {
		delete(icon.px, allocator)
		return {}, false
	}
	// Old icons without an alpha channel come back fully transparent.
	if !slice.any_of_proc(icon.px, proc(p: u32) -> bool { return p >> 24 != 0 }) {
		for &p in icon.px { p |= 0xFF00_0000 }
	}
	return icon, true
}

launch_app :: proc(target: string) {
	win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(target, context.temp_allocator), nil, nil, win.SW_SHOWNORMAL)
}
