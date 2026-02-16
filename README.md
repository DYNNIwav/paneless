# Spacey

A fast tiling window manager for macOS with virtual workspaces, Hyprland-style dimming, and smooth animations.

Built with Swift using the Accessibility API and private CGS/SLS APIs. Works on macOS Sequoia without disabling SIP.

## Features

- **Virtual Workspaces** — 9 workspaces per monitor, instant switching with Alt+1-9. No native Spaces animation delays.
- **Automatic Tiling** — New windows are tiled automatically. 3 layout variants: side-by-side, stacked, and monocle.
- **Hyprland-Style Animation** — GPU-composited animations using SLSSetWindowTransform (same technique as yabai). Exact Hyprland bezier curves and timing. New windows scale in (popin 87%), closing windows fade + shrink. Configurable: `animations = false` to disable.
- **Window Dimming** — Unfocused tiled windows are dimmed with configurable opacity. Floating windows are never covered.
- **Multi-Monitor** — Independent workspace sets per monitor. Focus and move windows between monitors with keybindings.
- **Smart Auto-Float** — Dialogs, small windows, and secondary app windows are automatically floated. Configurable per-app rules.
- **Sticky Windows** — Pin apps (e.g. Spotify) to be visible on ALL workspaces.
- **Scratchpad** — Toggle a drop-down terminal (Ghostty) with Alt+Shift+G.
- **Minimize to Workspace** — Alt+Shift+M hides window, Alt+Shift+number to restore.
- **Window Borders** — Hyprland-style colored borders around the focused window.
- **Focus Follows Mouse** — Optional: auto-focus the tiled window under the cursor.
- **Mouse Drag Resize** — Ctrl+drag on the split divider to resize tiled windows.
- **Crash Recovery** — Orphaned windows from a previous crash are restored on startup. Workspace assignments persist across sessions.
- **Menu Bar** — Shows layout, active workspace, and window title. Click to switch workspaces or cycle layouts.
- **Configurable Keybindings** — All keybindings can be remapped via config file.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (for building)

### Required Permissions

Grant both in **System Settings > Privacy & Security**:

| Permission | Why |
|---|---|
| **Accessibility** | Move and resize windows |
| **Input Monitoring** | Global hotkeys |

## Installation

```bash
git clone https://github.com/DYNNIwav/spacey.git
cd spacey
./Scripts/build.sh
./Scripts/install.sh
```

This installs `Spacey.app` to `~/Applications/` and the `spacey` CLI to `/usr/local/bin/`.

To start:

```bash
open ~/Applications/Spacey.app
```

To start at login: **System Settings > General > Login Items > add Spacey**.

## Keybindings

### Window Focus & Layout

| Binding | Action |
|---------|--------|
| `Alt+Shift+H` | Focus previous window |
| `Alt+Shift+L` | Focus next window |
| `Alt+Shift+J` | Rotate windows forward |
| `Alt+Shift+K` | Rotate windows backward |
| `Alt+Shift+Enter` | Swap with master (first window) |
| `Alt+Shift+Space` | Cycle layout (side-by-side / stacked / monocle) |
| `Alt+Shift+T` | Toggle float |
| `Alt+Shift+F` | Toggle fullscreen |
| `Alt+Shift+Q` | Close focused window |

### Window Positioning

| Binding | Action |
|---------|--------|
| `Cmd+Shift+H` | Move to first position |
| `Cmd+Shift+L` | Move to last position |
| `Cmd+Shift+K` | Swap one position earlier |
| `Cmd+Shift+J` | Swap one position later |
| `Cmd+Shift+F` | Fill entire tiling region |

### Sizing

| Binding | Action |
|---------|--------|
| `Alt+Shift+]` | Grow focused (increase split ratio) |
| `Alt+Shift+[` | Shrink focused (decrease split ratio) |
| `Alt+Shift+=` | Increase gaps |
| `Alt+Shift+-` | Decrease gaps |
| `Ctrl+Drag` | Mouse drag resize on split divider |

### Monitors

| Binding | Action |
|---------|--------|
| `Alt+Shift+,` | Focus monitor left |
| `Alt+Shift+.` | Focus monitor right |

### Virtual Workspaces

| Binding | Action |
|---------|--------|
| `Alt+1` ... `Alt+9` | Switch to workspace |
| `Alt+Shift+1` ... `Alt+Shift+9` | Move focused window to workspace |

Workspace keybindings are always active, even with a custom `[bindings]` section.

## Layout Variants

Cycle with `Alt+Shift+Space`:

**Side-by-side** (`[]=`) — Master on the left, remaining windows stacked on the right.

```
2 windows:        3 windows:
+-----+-----+    +-----+-----+
|     |     |    |     |  W2 |
|  W1 |  W2 |    |  W1 +-----+
|     |     |    |     |  W3 |
+-----+-----+    +-----+-----+
```

**Stacked** (`TTT`) — Windows stacked top to bottom.

```
2 windows:        3 windows:
+-----------+    +-----------+
|    W1     |    |    W1     |
+-----------+    +-----------+
|    W2     |    |    W2     |
+-----------+    +-----------+
                 |    W3     |
                 +-----------+
```

**Monocle** (`[M]`) — All windows fill the screen, overlapping. Only the focused window is visible.

## Configuration

Config file: `~/.config/spacey/config`

A default config is created on first install. Edit it and Spacey auto-reloads on save.

```ini
[layout]
inner_gap = 12
outer_gap = 12
sketchybar_height = 0
dim_unfocused = 0.3
single_window_padding = 20
focus_follows_mouse = false
native_animation = false
auto_float_dialogs = true

[border]
enabled = false
width = 2
active_color = #66ccff
inactive_color = #444444
radius = 10

[rules]
float = Finder, System Settings, Calculator, Archive Utility
# exclude = SomeApp

[app_rules]
# Pin apps to specific positions in the tiled layout
# Arc = left
# Ghostty = right

# [bindings]
# Custom keybindings override ALL defaults (except workspace switching).
# Format: modifiers, key = action
# alt+shift, h = focus_left
# alt+shift, l = focus_right
# alt+shift, j = focus_down
# alt+shift, k = focus_up
# alt+shift, return = swap_master
# alt+shift, space = cycle_layout
# alt+shift, t = toggle_float
# alt+shift, f = toggle_fullscreen
# alt+shift, q = close
```

### Config Reference

| Section | Key | Default | Description |
|---------|-----|---------|-------------|
| layout | `inner_gap` | 8 | Gap between windows (px) |
| layout | `outer_gap` | 8 | Gap between windows and screen edges (px) |
| layout | `sketchybar_height` | 0 | Reserved height at top for status bars |
| layout | `dim_unfocused` | 0 | Dim amount for unfocused windows (0.0 - 1.0) |
| layout | `single_window_padding` | 0 | Extra padding when only 1 window is tiled |
| layout | `focus_follows_mouse` | false | Focus window under cursor |
| layout | `animations` | true | GPU-composited Hyprland-style animations (set false for instant) |
| layout | `native_animation` | false | Use native macOS compositor tiling (Sequoia+, no gaps) |
| layout | `auto_float_dialogs` | true | Auto-float dialogs and small windows |
| layout | `force_promotion` | false | Force ProMotion to stay at 120Hz |
| border | `enabled` | false | Show window borders |
| border | `width` | 2 | Border thickness (px) |
| border | `active_color` | #66ccff | Focused window border color (hex) |
| border | `inactive_color` | #444444 | Unfocused window border color (hex) |
| border | `radius` | 10 | Border corner radius |
| rules | `float` | Finder, System Settings, ... | Comma-separated apps that always float |
| rules | `exclude` | *(empty)* | Comma-separated apps ignored by Spacey |
| rules | `sticky` | *(empty)* | Comma-separated apps visible on ALL workspaces |
| app_rules | `App = left` | | Pin app to first tiled position |
| app_rules | `App = right` | | Pin app to last tiled position |
| app_rules | `App = workspace N` | | Auto-assign app to workspace N |

### Bindable Actions

For use in the `[bindings]` section:

| Action | Description |
|--------|-------------|
| `focus_left` / `focus_right` / `focus_up` / `focus_down` | Focus window in direction |
| `focus_next` / `focus_prev` | Cycle focus through tiled windows |
| `swap_master` | Swap focused with first window |
| `toggle_float` | Toggle floating on focused window |
| `toggle_fullscreen` | Toggle fullscreen |
| `close` | Close focused window |
| `cycle_layout` | Cycle layout variant |
| `rotate_next` / `rotate_prev` | Rotate window positions |
| `position_left` / `position_right` / `position_up` / `position_down` | Move window in tiled list |
| `position_fill` | Fill tiling region |
| `position_center` | Center window at 60% width |
| `increase_gap` / `decrease_gap` | Adjust gaps by 4px |
| `grow_focused` / `shrink_focused` | Adjust split ratio by 5% |
| `focus_monitor left` / `focus_monitor right` | Focus neighbor monitor |
| `move_to_monitor left` / `move_to_monitor right` | Move window to neighbor monitor |
| `switch_workspace N` | Switch to workspace N (1-9) |
| `move_to_workspace N` | Move window to workspace N (1-9) |
| `retile` | Reset layout and re-scan windows |
| `reload_config` | Reload config file |

## CLI

The `spacey` binary doubles as a CLI for scripting and integration:

```bash
spacey --focus-workspace 3       # Switch to workspace 3
spacey --list-workspaces         # List workspaces with windows
spacey --help                    # Show help
```

### Sketchybar Integration

Replace `yabai -m space --focus N` with:

```bash
spacey --focus-workspace N
```

## How It Works

**Virtual workspaces** are implemented without native macOS Spaces. All windows live on a single Space. Switching workspaces hides windows by moving them off-screen (rift-style: bottom-right corner, 1px visible) and shows the target workspace's windows by restoring their positions. All moves are batched with `SLSDisableUpdate`/`SLSReenableUpdate` to prevent flickering.

**Window dimming** uses transparent NSWindow overlays positioned directly above each unfocused tiled window via `CGSOrderWindow`. Floating windows are never covered by dim overlays.

**Animation** uses GPU-composited transforms (`SLSSetWindowTransform`) — the same technique as yabai. Windows are set to their final position via one batched AX call, then a reverse affine transform is applied so they visually appear at the start position. The transform animates back to identity at 120fps using Hyprland's exact cubic bezier curves (easeOutQuint). This means zero AX IPC per animation frame — all visual work is done by the compositor.

**Window detection** uses a 3-layer system: (1) a background-thread CGWindowList interceptor polling at 8ms during app launches that hides windows before they render, (2) AX observer callbacks that hide windows immediately in the callback thread, and (3) adaptive main-thread polling (0.5s active, 3s idle) as a fallback. New windows are hidden (alpha=0) at detection and faded in with a Hyprland-style popin animation at their tiled position.

## Uninstall

```bash
rm -rf ~/Applications/Spacey.app
sudo rm -f /usr/local/bin/spacey
rm -rf ~/.config/spacey
```

## Acknowledgements

Inspired by [Hyprland](https://hyprland.org/), [AeroSpace](https://github.com/nikitabobko/AeroSpace), [yabai](https://github.com/koekeishiya/yabai), [Amethyst](https://github.com/ianyh/Amethyst), and [rift](https://github.com/acsandmann/rift).

## License

MIT
