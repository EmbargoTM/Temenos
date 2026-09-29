package temenos

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private = "file")
load_text :: proc(t: ^testing.T, text: string) -> (Config, string) {
	path, _ := filepath.join({os.get_env("TEMP", context.temp_allocator), fmt.tprintf("temenos-test-%p.json", t)}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, text) == nil)
	defer os.remove(path)
	return load_config(path)
}

@(private = "file")
V1 :: `{"version": 1, "paths": {"common": "Common", "wallpapers": "Wallpapers", "wallpaperCache": "WallpaperCache"},
"workspaces": {"1": {"name": "", "folder": "Area1", "wallpaper": "Area1.jpg"}, "2": {"name": "Lazer", "folder": "Area2", "wallpaper": null}}`

@(test)
config_v1_loads_with_defaults :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // a config lives as long as the process
	c, err := load_text(t, "\xEF\xBB\xBF" + V1 + "}")
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.workspaces[1].wallpaper, "Area1.jpg")
	testing.expect_value(t, c.workspaces[2].wallpaper, "")
	testing.expect_value(t, c.workspaces[2].name, "Lazer")
	testing.expect(t, c.bar.enabled && !c.wm.enabled)
	testing.expect_value(t, c.windows.area_keys, "ctrl+alt+arrow")
	testing.expect_value(t, len(c.bar.center), 2)
}

@(test)
config_rejects_bad_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	with :: proc(old, new: string) -> string {
		s, _ := strings.replace_all(V1 + "}", old, new, context.temp_allocator)
		return s
	}
	bad := [?]struct { json, error: string }{
		{`{"version": 2}`, "version"},
		{with(`"Area2"`, `"../x"`), "Invalid relative path"},
		{with(`"Area2"`, `"Area1"`), "unique"},
		{with(`"Area1.jpg"`, `"C:\\x.jpg"`), "Invalid relative path"},
		{V1 + `, "bar": {"start": ["nope"]}}`, "Unknown bar widget"},
		{V1 + `, "windows": {"areaKeys": "win+arrow"}}`, "areaKeys"},
		{V1 + `, "wm": {"masterFactor": 2}}`, "masterFactor"},
	}
	for b in bad {
		_, err := load_text(t, b.json)
		testing.expectf(t, strings.contains(err, b.error), "%q: got %q, want %q", b.json, err, b.error)
	}
}
