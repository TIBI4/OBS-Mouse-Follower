# OBS Mouse Follower

Lightweight OBS Lua script that crops a monitor capture to follow the mouse.

## Features

- Uses or creates the `Mouse Follower` scene.
- Creates one `Display Follower N` source per detected monitor.
- Switches displays automatically when the cursor moves between monitors.
- Supports mouse follow, zoom toggle, and rectangle zoom.
- Keeps the crop region inside monitor bounds.

## Install

1. Open `OBS Studio > Tools > Scripts`.
2. Click `+` and load `obs-mouse-follower.lua`.
3. Assign the script hotkeys in `Settings > Hotkeys`.

## Hotkeys

- `Toggle mouse follow`: enable or disable camera follow.
- `Toggle zoom`: zoom in or out.
- `Set rectangle`: hold to set the first corner, release to zoom to the selection.

## Settings

- Per-display disable toggles
- `Show cursor`
- `Follow speed (%)`
- `Follow border (%)`
- `Zoom easing speed (%)`
- `Lock sensitivity (ms)`
- `Display switch delay (ms)`
- `Display switch rectangle mode`
- `Tick interval (ms)`
- `Auto-lock on direction reversal`
- `Keep OBS aspect ratio on rectangle select`

## Requirements

- OBS Studio
- Windows with LuaJIT FFI support for `user32.dll`

By [TIBI4.com](https://tibi4.com)
