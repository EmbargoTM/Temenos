// The bar's volume icon, updated the moment the volume changes: Core Audio
// calls back (on its own threads) when the default output device's level or
// mute changes, and when the default device itself changes (headphones
// plugged in); the callbacks only post to the bar, which does the rest on
// the UI thread.
package temenos

import "base:runtime"
import "core:math"
import win "core:sys/windows"

WM_APP_VOLUME       :: win.WM_APP + 3 // wParam: muted, lParam: level 0..100
WM_APP_AUDIO_DEVICE :: win.WM_APP + 4 // the default output device changed

Volume :: struct {
	level: int, // 0..100
	muted: bool,
	known: bool, // false: no output device
}
volume: Volume

@(private = "file") Com :: struct { vtbl: [^]rawptr }
@(private = "file") Sink :: struct { vtbl: ^[8]rawptr } // our callback objects: static, no state

@(private = "file", rodata) CLSID_MM_DEVICE_ENUMERATOR := win.GUID{0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}}
@(private = "file", rodata) IID_MM_DEVICE_ENUMERATOR   := win.GUID{0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}}
@(private = "file", rodata) IID_AUDIO_ENDPOINT_VOLUME  := win.GUID{0x5CDF2C82, 0x841E, 0x4546, {0x97, 0x22, 0x0C, 0xF7, 0x40, 0x78, 0x22, 0x9A}}
@(private = "file", rodata) IID_VOLUME_CALLBACK        := win.GUID{0x657804FA, 0xD6AD, 0x4496, {0x8A, 0x60, 0x35, 0x27, 0x52, 0xAF, 0x4F, 0x89}}
@(private = "file", rodata) IID_NOTIFICATION_CLIENT    := win.GUID{0x7991EEC9, 0x7E89, 0x4D85, {0x83, 0x90, 0x6C, 0x70, 0x3C, 0xEC, 0x60, 0xC0}}
@(private = "file", rodata) IID_UNKNOWN                := win.GUID{0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

// Vtable slots (mmdeviceapi.h, endpointvolume.h).
@(private = "file") ENUM_DEFAULT_ENDPOINT, ENUM_REGISTER_CLIENT, ENUM_UNREGISTER_CLIENT :: 4, 6, 7
@(private = "file") DEVICE_ACTIVATE :: 3
@(private = "file") VOL_REGISTER, VOL_UNREGISTER, VOL_GET_LEVEL, VOL_GET_MUTE :: 3, 4, 9, 15
@(private = "file") E_RENDER, E_CONSOLE :: 0, 0
@(private = "file") E_NOINTERFACE :: win.HRESULT(-2147467262) // 0x80004002

@(private = "file")
Volume_Notification :: struct {
	event_context: win.GUID,
	muted:         win.BOOL,
	master:        f32,
	channels:      u32,
	volumes:       [1]f32,
}

@(private = "file") enumerator, endpoint: ^Com
@(private = "file") volume_vtbl, device_vtbl: [8]rawptr
@(private = "file") volume_sink, device_sink: Sink

@(private = "file")
release :: proc(o: ^Com) {
	if o != nil { (proc "system" (^Com) -> u32)(o.vtbl[2])(o) }
}

@(private = "file")
answer :: proc "contextless" (this: ^Sink, riid: ^win.GUID, own: win.GUID, out: ^rawptr) -> win.HRESULT {
	if riid^ != IID_UNKNOWN && riid^ != own { out^ = nil; return E_NOINTERFACE }
	out^ = this
	return 0
}
@(private = "file") static_ref :: proc "system" (this: ^Sink) -> u32 { return 1 }
@(private = "file") ignore_1 :: proc "system" (this: ^Sink, a: rawptr) -> win.HRESULT { return 0 }
@(private = "file") ignore_2 :: proc "system" (this: ^Sink, a: rawptr, b: u32) -> win.HRESULT { return 0 }

@(private = "file")
on_volume :: proc "system" (this: ^Sink, data: ^Volume_Notification) -> win.HRESULT {
	context = runtime.default_context()
	win.PostMessageW(bar_hwnd(), WM_APP_VOLUME, win.WPARAM(data.muted ? 1 : 0), win.LPARAM(math.round(data.master * 100)))
	return 0
}

@(private = "file")
on_default_device :: proc "system" (this: ^Sink, flow, role: i32, id: win.LPCWSTR) -> win.HRESULT {
	context = runtime.default_context()
	if flow == E_RENDER && role == E_CONSOLE { win.PostMessageW(bar_hwnd(), WM_APP_AUDIO_DEVICE, 0, 0) }
	return 0
}

// Call on the UI thread, after COM is initialised (vd_init).
volume_start :: proc() {
	volume_vtbl = {
		rawptr(proc "system" (this: ^Sink, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return answer(this, riid, IID_VOLUME_CALLBACK, out) }),
		rawptr(static_ref), rawptr(static_ref), rawptr(on_volume), nil, nil, nil, nil,
	}
	device_vtbl = {
		rawptr(proc "system" (this: ^Sink, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT { return answer(this, riid, IID_NOTIFICATION_CLIENT, out) }),
		rawptr(static_ref), rawptr(static_ref),
		rawptr(ignore_2),          // OnDeviceStateChanged
		rawptr(ignore_1),          // OnDeviceAdded
		rawptr(ignore_1),          // OnDeviceRemoved
		rawptr(on_default_device), // OnDefaultDeviceChanged
		rawptr(ignore_2),          // OnPropertyValueChanged (the PROPERTYKEY arrives by reference)
	}
	volume_sink.vtbl, device_sink.vtbl = &volume_vtbl, &device_vtbl
	if win.CoCreateInstance(&CLSID_MM_DEVICE_ENUMERATOR, nil, win.CLSCTX_INPROC_SERVER, &IID_MM_DEVICE_ENUMERATOR, (^rawptr)(&enumerator)) != 0 {
		enumerator = nil
		return
	}
	(proc "system" (^Com, ^Sink) -> win.HRESULT)(enumerator.vtbl[ENUM_REGISTER_CLIENT])(enumerator, &device_sink)
	volume_attach()
}

// (Re)attach to the default output device.
volume_attach :: proc() {
	if endpoint != nil {
		(proc "system" (^Com, ^Sink) -> win.HRESULT)(endpoint.vtbl[VOL_UNREGISTER])(endpoint, &volume_sink)
		release(endpoint)
		endpoint = nil
	}
	volume.known = false
	if enumerator == nil { return }
	device: ^Com
	if (proc "system" (^Com, i32, i32, ^rawptr) -> win.HRESULT)(enumerator.vtbl[ENUM_DEFAULT_ENDPOINT])(enumerator, E_RENDER, E_CONSOLE, (^rawptr)(&device)) != 0 { return }
	defer release(device)
	if (proc "system" (^Com, ^win.GUID, u32, rawptr, ^rawptr) -> win.HRESULT)(device.vtbl[DEVICE_ACTIVATE])(device, &IID_AUDIO_ENDPOINT_VOLUME, win.CLSCTX_ALL, nil, (^rawptr)(&endpoint)) != 0 {
		endpoint = nil
		return
	}
	level: f32
	muted: win.BOOL
	(proc "system" (^Com, ^f32) -> win.HRESULT)(endpoint.vtbl[VOL_GET_LEVEL])(endpoint, &level)
	(proc "system" (^Com, ^win.BOOL) -> win.HRESULT)(endpoint.vtbl[VOL_GET_MUTE])(endpoint, &muted)
	volume = {int(math.round(level * 100)), bool(muted), true}
	(proc "system" (^Com, ^Sink) -> win.HRESULT)(endpoint.vtbl[VOL_REGISTER])(endpoint, &volume_sink)
}

volume_stop :: proc() {
	if endpoint != nil {
		(proc "system" (^Com, ^Sink) -> win.HRESULT)(endpoint.vtbl[VOL_UNREGISTER])(endpoint, &volume_sink)
		release(endpoint)
		endpoint = nil
	}
	if enumerator != nil {
		(proc "system" (^Com, ^Sink) -> win.HRESULT)(enumerator.vtbl[ENUM_UNREGISTER_CLIENT])(enumerator, &device_sink)
		release(enumerator)
		enumerator = nil
	}
}

// Segoe Fluent Icons / MDL2: mute, then no, low, medium and high sound waves.
volume_glyph :: proc() -> string {
	switch {
	case !volume.known || volume.muted: return ""
	case volume.level == 0:             return ""
	case volume.level < 34:             return ""
	case volume.level < 67:             return ""
	}
	return ""
}
