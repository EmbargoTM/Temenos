// Temenos.json: the v1 workspace model (paths + workspaces) plus the optional
// sections shared with milk (appearance, bar, wm) and the Windows-only one
// ("windows", the counterpart of milk's "linux"). Every optional key has a
// default, so a v1 file without the new sections keeps working.
package temenos

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

Workspace :: struct {
	name:      string,
	folder:    string,
	wallpaper: string, // "" or null: keep the current wallpaper
}

// A window whose class (exact) and title (substring) match is never tiled.
Rule :: struct {
	class:    string,
	title:    string,
	floating: bool,
}

Config :: struct {
	version:    int,
	paths: struct {
		common:          string,
		wallpapers:      string,
		wallpaper_cache: string `json:"wallpaperCache"`,
	},
	workspaces: map[int]Workspace,
	appearance: struct {
		theme:           string, // milk | matcha | blueberry
		variant:         string, // auto (follow Windows) | light | dark
		animation_scale: f64 `json:"animationScale"`, // 0 = no animations
	},
	bar: struct {
		enabled:         bool,
		position:        string, // top | bottom
		style:           string, // full | floating
		height:          int,    // pixels at 100% scaling
		margin:          int,    // floating: gap to the screen edges
		radius:          int,    // floating: corner radius
		opacity:         f64,
		font:            string, // "" = Segoe UI Variable (Windows 11) or Segoe UI (Windows 10)
		font_size:       int `json:"fontSize"`,
		spacing:         int,
		title_max_width: int `json:"titleMaxWidth"`,
		date_format:     string `json:"dateFormat"`,  // Windows date picture; "" = "Terça, 29 de Setembro" in the user's language
		clock_format:    string `json:"clockFormat"`, // Windows time picture ("HH:mm")
		start:           []string,
		center:          []string,
		end:             []string,
		commands:        map[string]string, // widget id -> command run on click
		apps:            []string, // pinned apps: "shell:AppsFolder\<app id>" or a file path
	},
	wm: struct {
		enabled:       bool,
		mod_key:       string `json:"modKey"`, // alt | super
		gaps:          int,
		master_factor: f64 `json:"masterFactor"`,
		master_count:  int `json:"masterCount"`,
		focus_color:   string `json:"focusColor"`, // border of the focused window (Windows 11); "" = theme accent
		rules:         []Rule,
	},
	windows: struct {
		area_keys:    string `json:"areaKeys"`, // win+number (Win+1..9) | ctrl+alt+arrow (previous/next area)
		hide_taskbar: bool `json:"hideTaskbar"`, // the bar replaces the Windows taskbar
		indicator: struct {
			enabled:   bool,
			duration:  f64,    // seconds
			position:  string, // top | bottom | center; "" = the bar's edge
			font_size: f64 `json:"fontSize"`, // points
		},
	},
}

WIDGETS :: []string{"launcher", "workspaces", "new_area", "active_window", "layout", "date", "clock",
                    "notifications", "quick_settings", "widgets", "tray", "show_desktop", "apps"}

// Globals, not literals inside default_config: a slice literal there would
// point into its stack frame once it returns.
@(private = "file", rodata) DEFAULT_START  := []string{"launcher", "apps"}
@(private = "file", rodata) DEFAULT_CENTER := []string{"workspaces", "new_area"}
@(private = "file", rodata) DEFAULT_END    := []string{"layout", "tray", "quick_settings", "date", "clock", "show_desktop"}

@(private = "file")
default_config :: proc() -> (c: Config) {
	c.appearance = {theme = "milk", variant = "auto", animation_scale = 1}
	c.bar = {
		enabled = true, position = "top", style = "floating", height = 36, margin = 8, radius = 12,
		opacity = 1, font_size = 13, spacing = 6, title_max_width = 420,
		date_format = "", clock_format = "HH:mm",
		start = DEFAULT_START, center = DEFAULT_CENTER, end = DEFAULT_END,
	}
	c.wm = {enabled = false, mod_key = "alt", gaps = 8, master_factor = 0.55, master_count = 1}
	c.windows.area_keys = "ctrl+alt+arrow"
	c.windows.hide_taskbar = true
	c.windows.indicator = {enabled = true, duration = 1.6, font_size = 11}
	return
}

load_config :: proc(path: string) -> (cfg: Config, err: string) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil { return cfg, fmt.aprintf("Configuration file not found: %s", path) }
	data = data[3:] if len(data) >= 3 && string(data[:3]) == "\xEF\xBB\xBF" else data
	cfg = default_config()
	if uerr := json.unmarshal(data, &cfg, .JSON5); uerr != nil {
		return cfg, fmt.aprintf("Could not read Temenos.json: %v", uerr)
	}
	if cfg.windows.indicator.position == "" { cfg.windows.indicator.position = cfg.bar.enabled ? cfg.bar.position : "top" }
	return cfg, validate(&cfg)
}

@(private = "file")
is_unsafe_relative :: proc(value: string) -> bool {
	if strings.trim_space(value) == "" || value[0] == '/' || value[0] == '\\' { return true }
	if len(value) >= 2 && value[1] == ':' { return true } // C:\ and drive-relative C:x
	for part in strings.split_multi(value, {"/", "\\"}, context.temp_allocator) {
		if part == "." || part == ".." { return true }
	}
	return false
}

@(private = "file")
one_of :: proc(value: string, choices: ..string) -> bool {
	for c in choices { if c == value { return true } }
	return false
}

@(private = "file")
validate :: proc(c: ^Config) -> string {
	if c.version != 1 { return "Unsupported Temenos.json version. Expected version 1." }
	seen := make(map[string]bool, context.temp_allocator)
	shared := [3]struct { value, field: string }{
		{c.paths.common, "paths.common"}, {c.paths.wallpapers, "paths.wallpapers"}, {c.paths.wallpaper_cache, "paths.wallpaperCache"},
	}
	for p in shared {
		if is_unsafe_relative(p.value) { return fmt.aprintf("Invalid relative path in Temenos.json: %s", p.field) }
		if seen[p.value] { return fmt.aprintf("Runtime paths must be unique: %s", p.value) }
		seen[p.value] = true
	}
	if len(c.workspaces) == 0 { return "Temenos.json must define at least one workspace." }
	for index, ws in c.workspaces {
		if index < 1 { return fmt.aprintf("Invalid workspace id '%d' in Temenos.json. Use positive numbers.", index) }
		if is_unsafe_relative(ws.folder) { return fmt.aprintf("Invalid relative path in Temenos.json: workspaces.%d.folder", index) }
		if seen[ws.folder] { return fmt.aprintf("Workspace folders must be unique and differ from the shared paths: %s", ws.folder) }
		seen[ws.folder] = true
		if strings.trim_space(ws.wallpaper) != "" && is_unsafe_relative(ws.wallpaper) {
			return fmt.aprintf("Invalid relative path in Temenos.json: workspaces.%d.wallpaper", index)
		}
	}

	a, b, w, ind := &c.appearance, &c.bar, &c.wm, &c.windows.indicator
	switch {
	case !one_of(a.theme, ..THEME_NAMES):              return "appearance.theme must be milk, matcha or blueberry."
	case !one_of(a.variant, ..VARIANTS):                return "appearance.variant must be auto, light or dark."
	case a.animation_scale < 0 || a.animation_scale > 3:   return "appearance.animationScale must be between 0 and 3."
	case !one_of(b.position, "top", "bottom"):             return "bar.position must be top or bottom."
	case !one_of(b.style, "full", "floating"):             return "bar.style must be full or floating."
	case b.height < 16 || b.height > 200:                  return "bar.height must be between 16 and 200."
	case b.font_size < 6 || b.font_size > 64:              return "bar.fontSize must be between 6 and 64."
	case b.margin < 0 || b.margin > 100 || b.radius < 0 || b.radius > 100: return "bar.margin and bar.radius must be between 0 and 100."
	case b.opacity < 0 || b.opacity > 1:                   return "bar.opacity must be between 0 and 1."
	case b.spacing < 0 || b.title_max_width < 40:          return "bar.spacing must be positive and bar.titleMaxWidth at least 40."
	case !one_of(w.mod_key, "alt", "super"):               return "wm.modKey must be alt or super."
	case w.gaps < 0 || w.gaps > 200:                       return "wm.gaps must be between 0 and 200."
	case w.master_factor < 0.05 || w.master_factor > 0.95: return "wm.masterFactor must be between 0.05 and 0.95."
	case w.master_count < 0:                               return "wm.masterCount must not be negative."
	case w.focus_color != "" && parse_hex(w.focus_color) < 0: return "wm.focusColor must be a #RRGGBB colour."
	case !one_of(c.windows.area_keys, "win+number", "ctrl+alt+arrow"): return "windows.areaKeys must be win+number or ctrl+alt+arrow."
	case !one_of(ind.position, "top", "bottom", "center"): return "windows.indicator.position must be top, bottom or center."
	case ind.duration <= 0 || ind.font_size < 4:          return "windows.indicator.duration must be positive and fontSize at least 4."
	}
	for group in ([][]string{b.start, b.center, b.end}) {
		for id in group {
			if !one_of(id, ..WIDGETS) { return fmt.aprintf("Unknown bar widget %q (valid: %s)", id, strings.join(WIDGETS, ", ", context.temp_allocator)) }
		}
	}
	return ""
}

// "#RRGGBB" -> 0xRRGGBB, -1 when malformed.
parse_hex :: proc(s: string) -> int {
	if len(s) != 7 || s[0] != '#' { return -1 }
	n := 0
	for ch in s[1:] {
		d: int
		switch ch {
		case '0' ..= '9': d = int(ch - '0')
		case 'a' ..= 'f': d = int(ch - 'a') + 10
		case 'A' ..= 'F': d = int(ch - 'A') + 10
		case: return -1
		}
		n = n * 16 + d
	}
	return n
}

// Colours are 0xRRGGBB.
Theme :: struct { background, foreground, muted, accent, accent_fg, surface: u32 }

// milk's presets (src/config/config.odin in milk).
@(private = "file", rodata)
THEMES := [?]struct { name: string, light, dark: Theme }{
	{"milk",      {0xF5EEE6, 0x3C3A38, 0xA89E94, 0x4A3F35, 0xF5EEE6, 0xE9E0D6}, {0x211D1A, 0xEDE3D8, 0x8C8279, 0xD9C3A5, 0x211D1A, 0x2E2925}},
	{"matcha",    {0xEEF2E6, 0x2F3A2B, 0x8F9A86, 0x4E6B3A, 0xEEF2E6, 0xDDE5D1}, {0x1B211A, 0xE1E9D8, 0x7F8B76, 0xA7C58A, 0x1B211A, 0x263025}},
	{"blueberry", {0xECEEF6, 0x2B3040, 0x8A90A6, 0x3F4F86, 0xECEEF6, 0xDCE0EE}, {0x191B24, 0xE0E4F2, 0x7D839C, 0x9FB0F0, 0x191B24, 0x242735}},
}

@(rodata) THEME_NAMES := []string{"milk", "matcha", "blueberry"}
@(rodata) VARIANTS    := []string{"auto", "light", "dark"}

// "auto" follows the Windows app mode (Settings > Personalization > Colors).
theme_for :: proc(name, variant: string) -> Theme {
	dark := variant == "dark"
	if variant == "auto" {
		light: u32 = 1
		size := win.DWORD(size_of(light))
		win.RegGetValueW(win.HKEY_CURRENT_USER, win.L(`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`),
		                 win.L("AppsUseLightTheme"), win.RRF_RT_REG_DWORD, nil, &light, &size)
		dark = light == 0
	}
	for t in THEMES {
		if t.name == name { return dark ? t.dark : t.light }
	}
	return THEMES[0].light
}

resolve_theme :: proc() -> Theme { return theme_for(cfg.appearance.theme, cfg.appearance.variant) }
