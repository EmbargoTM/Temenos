# Temenos

> A lightweight Windows 10 utility that gives each Virtual Desktop its own identity.

Temenos extends Windows 10 Virtual Desktops by associating each workspace with its own desktop shortcuts and wallpaper. It runs quietly in the background and updates the desktop environment automatically when the active Virtual Desktop changes.

The name is inspired by the Greek **τέμενος (temenos)** — a defined or set-apart space.

## Current Features

* **Per-desktop wallpapers** — assign a different image to each Virtual Desktop.
* **Per-desktop shortcuts** — show different `.lnk` and `.url` shortcuts depending on the active desktop.
* **Common shortcuts** — keep selected shortcuts visible on every desktop.
* **Named areas** — configure workspace names, shortcut folders, and wallpapers in `Temenos.json`.
* **Automatic switching** — wallpapers and shortcuts update when switching Virtual Desktops.
* **Active area indicator** — briefly displays the active area's number and name at the top of the screen.
* **Wallpaper cache** — wallpapers are validated and staged before being applied, reducing problems when an image is being edited or replaced.
* **Background operation** — Temenos can start automatically with Windows without showing a PowerShell window.
* **Restart without rebooting** — restart the Temenos monitor independently from Windows.
* **Repository-based execution** — launchers run the current script from the clone and keep runtime data in a separate directory.

## Requirements

* Windows 10
* Windows Virtual Desktops
* Windows PowerShell

No additional runtime or third-party application is required for the current version.

## Installation

A clone can run directly from its repository directory. Code stays in the clone; runtime data is stored separately in the user's Documents folder:

```text
GitHub/Temenos/
├── Iniciar Temenos.vbs
├── Reiniciar Temenos.vbs
├── Temenos.json
├── src/
│   ├── Temenos.ps1
│   ├── Config.ps1
│   ├── DesktopEvents.ps1
│   └── Indicator.ps1
├── README.md
└── LICENSE

Documents/Temenos/runtime/
├── Common/
├── Area1/
├── Area2/
├── Area3/
├── Area4/
├── Area5/
├── Wallpapers/
└── WallpaperCache/
```

The VBS launchers locate the repository relative to themselves and run `src/Temenos.ps1`. The runtime directory is passed separately, so editing or pulling code in the clone affects the next launch without copying an older script into Documents. `Reiniciar Temenos.vbs` starts the current script; the running instance is replaced using the PID file in the runtime directory.

Place a shortcut to `Iniciar Temenos.vbs` in the user's Windows Startup folder:

```text
Win + R
shell:startup
```

Temenos can then start automatically when the user logs in. Both launchers can also be run directly from the repository.

## Configuring Workspaces

`Temenos.json` defines each workspace. Its numeric key is the Windows Virtual Desktop number; `name` is shown in the indicator, `folder` selects shortcuts under the runtime directory, and `wallpaper` selects a file under `Wallpapers/`.

Example:

```json
{
  "version": 1,
  "paths": {
    "common": "Common",
    "wallpapers": "Wallpapers",
    "wallpaperCache": "WallpaperCache"
  },
  "workspaces": {
    "1": { "name": "Work", "folder": "Area1", "wallpaper": "Work.jpg" },
    "2": { "name": "Leisure", "folder": "Area2", "wallpaper": "Leisure.png" }
  }
}
```

Add one entry per workspace. Set `name` to an empty string to show only `AREA N`. Set `wallpaper` to `null` to leave the current wallpaper unchanged. Workspace folders and the common folder are created under `Documents/Temenos/runtime/` when Temenos starts. Shortcut and shared-folder paths must be relative to the runtime folder; each wallpaper path is relative to the configured wallpapers folder. Restart Temenos after editing the config.

If Windows has a workspace number missing from the config, Temenos shows `AREA N`, keeps common shortcuts, and leaves the wallpaper unchanged until an entry is added.

### Common shortcuts

Shortcuts placed in the runtime directory at `Documents/Temenos/runtime/Common/`:

```text
Common/
```

are displayed on every Virtual Desktop.

### Per-desktop shortcuts

Shortcuts placed in each workspace's configured runtime folder, for example `Documents/Temenos/runtime/Area1/`:

```text
Area1/
Area2/
```

are shown only when that corresponding Virtual Desktop is active.

Temenos currently manages only:

* `.lnk` Windows shortcuts
* `.url` Internet shortcuts

## Wallpapers

Place wallpapers in the runtime directory at:

```text
Wallpapers/
```

using the filename configured for that workspace in `Temenos.json`:

```text
Wallpapers/
├── Work.jpg
├── Leisure.png
├── Study.jpg
└── ...
```

Supported formats:

* JPG
* JPEG
* PNG
* BMP

If a desktop has no matching wallpaper, Temenos leaves the current wallpaper unchanged.

Before applying an image, Temenos creates a cached JPEG in the runtime directory at:

```text
WallpaperCache/
```

This isolates the active wallpaper from the source file, which is useful when editing images in applications such as Krita.

## How It Works

The current implementation is a PowerShell-based desktop enhancement utility.

Temenos uses:

* Windows Virtual Desktop state stored by Windows
* Native Windows APIs
* Registry change notifications for active Virtual Desktop state
* A background PowerShell process

The monitor waits for Windows to signal a Virtual Desktop registry change, then reads the active desktop once and updates the visible shortcut set and wallpaper. It does not run a periodic detection loop. A small on-screen indicator displays the active area's number and name at startup and after a switch.

## Current Limitations

The current implementation is intentionally lightweight and has some limitations:

* Desktop shortcut positions are not yet persisted independently per workspace.
* The desktop shortcut set is simulated by adding/removing managed shortcuts from the Windows desktop.
* Multi-monitor workspace behavior is not yet independently configurable.
* Configuration is edited in `Temenos.json`; there is no graphical workspace manager yet.
* Desktop-change notifications watch the same Windows registry keys Temenos uses to read the active desktop.

## Roadmap

The roadmap prioritizes a sound core before convenience features:

| Priority | Category | Objective |
| --- | --- | --- |
| 1 | ✅ Complete | Active area visual indicator |
| 2 | ✅ Complete | Centralized configuration |
| 3 | ✅ Complete | Replace polling with events |
| 4 | 🔴 Architecture | Multi-monitor support |
| 5 | 🟠 Important | Persist icon positions per workspace |
| 6 | 🟠 Important | Backup and restore |
| 7 | 🟠 MVP | Logs and diagnostic mode |

The indicator reads the workspace name from `Temenos.json`. The configuration loader validates the file and provides workspace metadata to the existing wallpaper and shortcut managers. Remaining improvements will continue as separate modules while PowerShell remains the implementation language.

## Development

The current codebase is intentionally implemented in PowerShell so that the core behavior can be developed and tested quickly on Windows 10.

The long-term goal is to evolve Temenos into a native Windows utility while keeping the current workspace model and configuration approach where practical.

## Philosophy

A Virtual Desktop should be more than another collection of windows.

With Temenos, each desktop becomes a **context** with its own visual identity, shortcuts, and eventually its own behavior.

> **One computer. Multiple spaces. Each with its own identity.**
