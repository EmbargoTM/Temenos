# Temenos

> A lightweight Windows 10 and 11 desktop that gives each Virtual Desktop its own identity.

Temenos turns every Windows Virtual Desktop into an *area* with its own wallpaper, desktop shortcuts and name. It adds a navbar that replaces the Windows taskbar, a modern area indicator and optional window tiling. It is a single native program with no runtime to install.

The name comes from the Greek **τέμενος (temenos)**, a space set apart.

Temenos is written in [Odin](https://odin-lang.org), like [milk](https://github.com/mirvoxtm/milk), its Linux sibling. milk grew from Temenos's idea, and this version takes milk's configuration, themes, bar, dwm layouts and indicator back to Windows, in a much smaller program.

## Features

* **Per-area wallpapers and shortcuts.** Each area shows its own `.lnk`/`.url` shortcuts on the desktop, plus common ones shown everywhere. An area can rotate through multiple wallpapers automatically.
* **Navbar.** Start, your pinned apps, the area dots (click to switch, scroll to step through them), a button for a new area, the tiling layout, the notification-area icons, Wi‑Fi, volume and battery, the date ("Terça, 29 de Setembro"), the clock and the show-desktop corner. The volume icon follows the volume the moment it changes. You choose where each item goes and how tall the bar is. It registers as an AppBar, so maximized windows stay clear of it, and it steps aside for fullscreen apps.
* **Replaces the taskbar, if you like.** The setup lets you keep the Windows taskbar instead. With the Temenos bar, the Windows taskbar is hidden while Temenos runs. The bar opens Windows' own notification center and calendar, quick settings and widgets, and shows the real taskbar briefly when you open the tray. Your taskbar settings come back when Temenos quits, and also on its next start if it crashed.
* **Pinned apps.** Pick apps from everything in Start's "All apps" (Store apps included), with their real icons and a search, in the setup or from the bar's **Pinned apps…** menu item.
* **Area indicator.** A pill with `AREA N · Name` and the area dots slides out from behind the bar and fades away. It can be turned off.
* **Window tiling (optional).** milk's dwm layouts (master/stack, monocle, floating) for the windows of the current area, on each monitor. On Windows 11 the focused window's border takes the accent colour.
* **Area keys.** Choose between Win+1…9 (jump to an area) and Ctrl+Alt+←/→ (previous/next area).
* **Setup wizard.** Runs on the first start and from the bar's right-click menu. It sets the theme; the Temenos bar or the Windows taskbar; the bar's position, style, height and the place of each item; the pinned apps; the keys and tiling; wallpapers for every current area and the area indicator; and whether Temenos starts with Windows. Every choice restyles the wizard as you make it.
* **Better Windows 11 support.** Crisp on scaled displays (per-monitor DPI), uses Segoe UI Variable and Fluent icons, follows the light/dark app mode, reads desktop names given in Task View, and jumps straight to an area with a single animation. Windows 10 falls back to Segoe UI, MDL2 icons and the Action Center.

## Requirements

* Windows 10 or 11
* To build it: the [Odin compiler](https://odin-lang.org/docs/install/) and the Visual Studio build tools (MSVC linker)

## Building and running

```text
build.bat
```

This produces `Temenos.exe` next to `Temenos.json`. Run it to start Temenos. Running it again replaces the running instance, so it also works as a restart.

```text
Temenos.exe                  start (replaces a running instance)
Temenos.exe --setup          run the setup wizard, then start
Temenos.exe --apps           choose the pinned apps, then start
Temenos.exe --new-area       create a virtual desktop and exit
Temenos.exe --quit           stop the running instance
Temenos.exe --test           show the detected state
Temenos.exe --runtime <dir>  use another runtime folder
```

To start Temenos with Windows, choose **Start Temenos with Windows** on the wizard's last page. It adds a per-user startup entry (no admin rights needed), which Task Manager's Startup apps page also lists and can turn off. `Criar Atalho Nova Area.vbs` creates a `+ Nova Área` desktop shortcut that runs `Temenos.exe --new-area`, which you can pin.

Right-clicking the bar offers Task Manager, Pinned apps…, Setup…, Edit Temenos.json, Restart and Quit. Run `Temenos.exe --test` after `build.bat` to check the setup; `odin test src` runs the configuration checks.

Code stays in the clone. Runtime data lives in `Documents/Temenos/runtime/`:

```text
Documents/Temenos/runtime/
├── Common/          shortcuts shown in every area
├── Area1/ … AreaN/  shortcuts of each area (as configured)
├── Wallpapers/
└── WallpaperCache/
```

## Configuring

`Temenos.json` sits next to `Temenos.exe`. The setup wizard edits it too. Restart Temenos after editing it. Comments are allowed (JSON5). Only `version`, `paths` and `workspaces` are required; each other key falls back to the default shown here:

```json
{
  "version": 1,
  "paths": { "common": "Common", "wallpapers": "Wallpapers", "wallpaperCache": "WallpaperCache" },
  "workspaces": {
    "1": { "name": "Work", "folder": "Area1", "wallpaper": "Work.jpg" },
    "2": { "name": "", "folder": "Area2", "wallpapers": ["Home.jpg", "Home-evening.png"], "wallpaperIntervalMinutes": 30 }
  },
  "appearance": { "theme": "milk", "variant": "auto", "animationScale": 1 },
  "bar": {
    "enabled": true, "position": "top", "style": "floating",
    "height": 36, "margin": 8, "radius": 12, "opacity": 1,
    "font": "", "fontSize": 13, "spacing": 6, "titleMaxWidth": 420,
    "dateFormat": "", "clockFormat": "HH:mm",
    "start": ["launcher", "apps"],
    "center": ["workspaces", "new_area"],
    "end": ["layout", "tray", "quick_settings", "date", "clock", "show_desktop"],
    "apps": [],
    "commands": {}
  },
  "wm": {
    "enabled": false, "modKey": "alt", "gaps": 8,
    "masterFactor": 0.55, "masterCount": 1, "focusColor": "", "rules": []
  },
  "windows": {
    "areaKeys": "ctrl+alt+arrow",
    "hideTaskbar": true,
    "indicator": { "enabled": true, "duration": 1.6, "position": "", "fontSize": 11 }
  }
}
```

**Workspaces.** The numeric key is the Virtual Desktop's position in Task View; it can be any positive number. `name` is shown by the indicator; when it is empty, the name given in Windows 11 Task View is used, and otherwise just `AREA N`. `folder` holds the area's shortcuts. A configured `folder` may have any relative name. For an unconfigured area N, Temenos prefers an existing folder named exactly `AreaN`; otherwise it uses a single existing runtime folder whose name contains `AreaN` (without confusing `Area1` with `Area10`). If no matching folder exists, Temenos creates `AreaN`; if multiple non-exact folders match, it leaves shortcuts unmanaged rather than choosing arbitrarily. `wallpaper` names one JPG, PNG or BMP in `Wallpapers/`; `wallpapers` can list several images and takes precedence when non-empty. Temenos rotates through that list every `wallpaperIntervalMinutes` minutes (default 30; use 0 for the default). Leave both fields empty or set `wallpaper` to `null` to keep the current wallpaper. The setup lets you multi-select images for an area. For an unconfigured new area N, files named `AreaN.ext`, `AreaN-1.ext`, `AreaN-2.ext`… in `Wallpapers/` are also discovered and rotated automatically. The setup copies external images into that folder without overwriting an image another area uses. Paths must be relative and stay inside the runtime folder. Before applying a wallpaper, Temenos decodes it and applies a copy from `WallpaperCache/`, so a file still being written or edited (in Krita, say) never breaks the desktop.

**Appearance.** Themes are `milk`, `matcha` and `blueberry`. `variant` is `light`, `dark` or `auto`, which follows the Windows app mode. `animationScale` of 0 turns animations off.

**Bar.** `position` is `top` or `bottom`, and `style` is `floating` or `full`. Sizes are in pixels at 100% scaling. Widgets:

| id | shows | click |
| --- | --- | --- |
| `launcher` | Start logo | Start menu |
| `apps` | pinned apps (`apps`) | open the app |
| `active_window` | title of the focused window | — |
| `workspaces` | area dots | switch area (scroll: next/previous) |
| `new_area` | + | new virtual desktop |
| `layout` | tiling layout (`[]=`, `[M]`, `><>`) | next layout |
| `tray` | ^ | the notification-area icons |
| `quick_settings` | Wi‑Fi, volume level, battery level and % | quick settings |
| `widgets` | widgets (Windows 11) | widgets board |
| `date`, `clock` | the date and time | notification center and calendar |
| `notifications` | bell | notification center |
| `show_desktop` | thin line at the end | show the desktop (Win+D) |

`apps` lists the pinned apps as launch targets: `shell:AppsFolder\<app id>` (what the setup stores) or a file path. `dateFormat` empty gives the weekday and day of month in your Windows language, with capitals ("Terça, 29 de Setembro", "Tuesday, September 29"); otherwise it is a Windows date picture such as `ddd dd MMM`.

`commands` maps a widget id to a command that replaces its click action, for example `"clock": "ms-settings:dateandtime"` or `"launcher": "\"C:\\Program Files\\App\\app.exe\" --flag"`.

**Tiling** (`wm.enabled`). Normal windows of the current area are tiled on each monitor. Minimized, maximized, fixed-size, owned and tool windows float, as do windows matched by `rules` (`{"class": "…", "title": "…", "floating": true}`, where the class must match exactly and the title as a substring). Keys, with Mod = `modKey` (`alt` or `super`):

| keys | action |
| --- | --- |
| Mod+J / Mod+K | focus next / previous |
| Mod+Enter | swap with the master |
| Mod+H / Mod+L | master narrower / wider |
| Mod+I / Mod+D | more / fewer masters |
| Mod+T / Mod+M / Mod+F | tile / monocle / float |
| Mod+Shift+Space | float or tile the focused window |

Windows reserves most Win+letter shortcuts, so `alt` is the default.

**Windows.** Temenos reads up to 256 virtual desktops from Windows. `areaKeys` is `win+number` (Win+1…9 jumps to an area, taking those keys from the taskbar) or `ctrl+alt+arrow` (previous/next area, including areas beyond 9). `hideTaskbar` hides the Windows taskbar while the bar is enabled. The indicator's `position` is `top`, `bottom` or `center`; an empty value uses the bar's edge.

## How it works

Temenos is one process. The UI thread waits on registry change notifications for the Virtual Desktop state Explorer keeps (the global key on Windows 11 and the per-session key on Windows 10) and on window messages, so nothing is polled. A worker thread applies each area's shortcuts and wallpaper, so the bar and the indicator stay smooth. WinEvent hooks tell the bar and the tiler about focus and window changes. The bar, indicator and wizard are layered windows drawn on a small CPU canvas with anti-aliased shapes.

Switching areas goes through the shell's internal desktop manager when Temenos recognises the Windows build (Windows 11 24H2 and later), and otherwise through Explorer's own shortcuts, which take one animation per step.

## Limitations

* Desktop icon positions are not kept per area, and shortcuts are still added to and removed from the real Desktop folder.
* The bar lives on the primary monitor, and extra monitors keep their taskbars hidden while Temenos hides the taskbar.
* Windows cannot move another program's window to a different area through its documented APIs, so there is no "send window to area N" key.
* If Temenos is killed, the taskbar stays hidden until Temenos starts again (which restores or re-hides it) or Explorer restarts.

## Philosophy

A Virtual Desktop should be more than another collection of windows.

With Temenos, each desktop becomes a **context** with its own visual identity, shortcuts, and behaviour.

> **One computer. Multiple spaces. Each with its own identity.**
