# Temenos

> A lightweight Windows 10 utility that gives each Virtual Desktop its own identity.

Temenos extends Windows 10 Virtual Desktops by associating each workspace with its own desktop shortcuts and wallpaper. It runs quietly in the background and updates the desktop environment automatically when the active Virtual Desktop changes.

The name is inspired by the Greek **τέμενος (temenos)** — a defined or set-apart space.

## Current Features

* **Per-desktop wallpapers** — assign a different image to each Virtual Desktop.
* **Per-desktop shortcuts** — show different `.lnk` and `.url` shortcuts depending on the active desktop.
* **Common shortcuts** — keep selected shortcuts visible on every desktop.
* **Named areas** — use folders such as `Area1 - Work` and `Area2 - Leisure`.
* **Automatic switching** — wallpapers and shortcuts update when switching Virtual Desktops.
* **Wallpaper cache** — wallpapers are validated and staged before being applied, reducing problems when an image is being edited or replaced.
* **Background operation** — Temenos can start automatically with Windows without showing a PowerShell window.
* **Restart without rebooting** — restart the Temenos monitor independently from Windows.
* **Self-contained installation** — the main script uses its own installation directory instead of a hard-coded user path.

## Requirements

* Windows 10
* Windows Virtual Desktops
* Windows PowerShell

No additional runtime or third-party application is required for the current version.

## Installation

A typical installation looks like this:

```text
Documents/
└── Temenos/
    ├── Temenos.ps1
    ├── Iniciar Temenos.vbs
    ├── Reiniciar Temenos.vbs
    ├── Common/
    ├── Area1 - Work/
    ├── Area2 - Leisure/
    ├── Wallpapers/
    └── WallpaperCache/
```

Place `Iniciar Temenos.vbs` in the user's Windows Startup folder, either directly or through a shortcut:

```text
Win + R
shell:startup
```

Temenos can then start automatically when the user logs in.

## Configuring Workspaces

Each Virtual Desktop is identified by its number.

Examples:

```text
Area1 - Work
Area2 - Leisure
Area3 - Study
```

The number (`1`, `2`, `3`, ...) determines which Windows Virtual Desktop the folder belongs to. The text after the number is only a human-readable label.

### Common shortcuts

Shortcuts placed in:

```text
Common/
```

are displayed on every Virtual Desktop.

### Per-desktop shortcuts

Shortcuts placed in:

```text
Area1 - Work/
Area2 - Leisure/
```

are shown only when that corresponding Virtual Desktop is active.

Temenos currently manages only:

* `.lnk` Windows shortcuts
* `.url` Internet shortcuts

## Wallpapers

Place wallpapers in:

```text
Wallpapers/
```

using the corresponding area number:

```text
Wallpapers/
├── Area1.jpg
├── Area2.png
├── Area3.jpg
└── ...
```

Supported formats:

* JPG
* JPEG
* PNG
* BMP

If a desktop has no matching wallpaper, Temenos leaves the current wallpaper unchanged.

Before applying an image, Temenos creates a cached JPEG in:

```text
WallpaperCache/
```

This isolates the active wallpaper from the source file, which is useful when editing images in applications such as Krita.

## How It Works

The current implementation is a PowerShell-based desktop enhancement utility.

Temenos uses:

* Windows Virtual Desktop state stored by Windows
* Native Windows APIs
* Windows Explorer notifications
* A background PowerShell process

The monitor checks the active Virtual Desktop, and when it changes, Temenos updates the visible shortcut set and wallpaper.

## Current Limitations

The current implementation is intentionally lightweight and has some limitations:

* Desktop shortcut positions are not yet persisted independently per workspace.
* The desktop shortcut set is simulated by adding/removing managed shortcuts from the Windows desktop.
* The current monitor uses polling rather than a fully event-driven architecture.
* Multi-monitor workspace behavior is not yet independently configurable.
* Configuration is currently filesystem-based rather than managed through a graphical UI.

## Roadmap

Planned improvements include:

* Persistent icon positions per workspace
* Centralized configuration
* Graphical workspace manager
* Automatic application launching
* Window placement rules
* Custom keyboard shortcuts
* Multi-monitor support
* Event-driven desktop switching
* Backup and restore
* Native Windows executable

## Development

The current codebase is intentionally implemented in PowerShell so that the core behavior can be developed and tested quickly on Windows 10.

The long-term goal is to evolve Temenos into a native Windows utility while keeping the current workspace model and configuration approach where practical.

## Philosophy

A Virtual Desktop should be more than another collection of windows.

With Temenos, each desktop becomes a **context** with its own visual identity, shortcuts, and eventually its own behavior.

> **One computer. Multiple spaces. Each with its own identity.**
