# Paneless

Painless window management for macOS. A fast tiling window manager with virtual workspaces, smooth animations, and compositor-level dimming.

Built with Swift. Works on macOS Sonoma, Sequoia, and Tahoe without disabling SIP.

## Features

- **Virtual Workspaces** — 9 workspaces per monitor, instant switching with Alt+1-9. Named workspaces (e.g., `1:Code`, `2:Browser`) shown in the menu bar. No native Spaces animation delays.
- **Two Tiling Modes** — **Hyprland mode** (default): master-stack layouts with 3 variants (side-by-side, stacked, monocle). **Niri mode**: infinite scrolling columns like [Niri](https://github.com/YaLTeR/niri), with per-column width control and multi-window column stacking.
- **Smooth Animations** — GPU-composited popin/popout animations with Hyprland-style bezier curves. New windows scale in (80% → 100%), closing windows shrink + fade out. Configurable: `animations = false` to disable.
- **Window Dimming** — Compositor-level dimming that follows window shape, rounded corners, and shadows perfectly. Configurable intensity.
- **Multi-Monitor** — Independent workspace sets per monitor. Focus and move windows between monitors with keybindings.
- **Smart Auto-Float** — Dialogs, small windows, and secondary app windows are automatically floated. Configurable per-app rules.
- **Sticky Windows** — Pin apps (e.g. Spotify) to be visible on ALL workspaces.
- **Window Marks** — Vim-style marks: tag any window with `set_mark X` and jump to it with `jump_mark X`, even across workspaces.
- **Fuzzy Workspace Restoration** — Workspace assignments persist across sessions and crashes. Windows are automatically restored to their previous workspaces on startup.
- **Minimize to Workspace** — Alt+Shift+M hides window, Alt+Shift+number to restore.
- **Window Borders** — Hyprland-style colored borders around the focused window.
- **Window Swallowing** — When a terminal (Ghostty, iTerm2, etc.) launches a GUI app, the GUI app replaces the terminal in the tiling layout. When the GUI app closes, the terminal reappears at its original position. Configurable per-app or global with `swallow_all`.
- **Focus Follows App** — When an app on a different workspace is activated (Cmd+Tab, clicking a link, Spotlight), Paneless auto-switches to that app's workspace. Enabled by default.
- **Focus Follows Mouse** — Optional: auto-focus the tiled window under the cursor.
- **Mouse Drag Resize** — Ctrl+drag on the split divider to resize tiled windows.
- **Crash Recovery** — Orphaned windows from a previous crash are restored on startup. Workspace assignments persist across sessions.
- **Menu Bar** — Shows focused app, layout, active workspace with app icons. Click to switch workspaces or cycle layouts.
- **Hyperkey** — Use a single key (Caps Lock, F18, backtick, etc.) as Ctrl+Opt+Cmd+Shift when held. Bind actions like `hyper, h = focus_prev` for clean, dedicated window management shortcuts.
- **Configurable Keybindings** — All keybindings can be remapped via config file.

## Requirements

- macOS 14 (Sonoma) or later (tested on Sonoma, Sequoia, and Tahoe)
- Xcode Command Line Tools (for building)

### Required Permissions

Grant both in **System Settings > Privacy & Security**:

| Permission | Why |
|---|---|
| **Accessibility** | Move and resize windows |
| **Input Monitoring** | Global hotkeys |

## Installation

### Homebrew

```bash
brew install --cask DYNNIwav/paneless/paneless
```

### From Source

```bash
git clone https://github.com/DYNNIwav/paneless.git
cd paneless
./Scripts/build.sh
./Scripts/install.sh
```

This installs `Paneless.app` to `~/Applications/` and the `paneless` CLI to `/usr/local/bin/`.

### Post-Install

To start: `open ~/Applications/Paneless.app`

To start at login: **System Settings > General > Login Items > add Paneless**.

## Keybindings

### Window Focus & Layout

| Binding | Action |
|---------|--------|
| `Alt+Shift+H` | Focus previous window |
| `Alt+Shift+L` | Focus next window |
| `Alt+Shift+J` | Rotate windows forward (Hyprland) / Focus down in column (Niri) |
| `Alt+Shift+K` | Rotate windows backward (Hyprland) / Focus up in column (Niri) |
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

### Niri Mode

| Binding | Action |
|---------|--------|
| `Alt+Shift+H/L` | Scroll to previous/next column |
| `Alt+Shift+J/K` | Focus up/down within a column |
| `Alt+Shift+Space` | Cycle column width (full / half / third) |
| `Alt+Shift+C` | Consume: absorb window from right column into current |
| `Alt+Shift+X` | Expel: eject focused window into its own column |
| `Alt+Shift+]/[` | Grow/shrink column width |

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

### Niri Mode

Set `tiling_mode = niri` in config. Windows are arranged as columns in an infinite horizontal strip. The active column is centered on screen; off-screen columns are hidden.

```
3 columns (active = B):          Column with 2 stacked windows:

  ←hidden→ +--------+ ←hidden→   +--------+
            |        |            |   W1   |
            |   B    |            +--------+
            |        |            |   W2   |
  ←hidden→ +--------+ ←hidden→   +--------+
```

Use `Alt+Shift+C` to consume an adjacent window into the current column (vertical stack), and `Alt+Shift+X` to expel it back into its own column.

## Configuration

Config file: `~/.config/paneless/config`

A default config is created on first install. Edit it and Paneless auto-reloads on save. A green "Reloaded" indicator briefly appears in the menu bar to confirm the reload.

```ini
[layout]
inner_gap = 8
outer_gap = 8
animations = true
# native_animation = false
# single_window_padding = 0
# focus_follows_mouse = false
# force_promotion = false
# auto_float_dialogs = true

# Dim unfocused windows using compositor brightness
# 0.0 = off, 0.15 = subtle, 0.3 = moderate, 0.5 = strong
dim_unfocused = 0.03

# Tiling mode: "hyprland" (default) or "niri" (scrolling columns)
# tiling_mode = niri
# niri_column_width = 1.0

# Auto-switch workspace when an app on another workspace gets activated
# focus_follows_app = true

# Hyperkey: a single key that acts as Ctrl+Opt+Cmd+Shift when held.
# Works globally, so other apps also see the hyper modifier combo.
# Recommended: remap Caps Lock to F18 via hidutil, then set hyperkey = f18
#   hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}'
# hyperkey = f18

[border]
enabled = false
width = 2
active_color = #66ccff
inactive_color = #444444
radius = 10

[rules]
float = Finder, System Settings, Calculator, Archive Utility, System Preferences
# exclude = SomeApp
# sticky = Spotify

# Window swallowing: terminal launches GUI app → GUI replaces terminal in tile
# swallow = Ghostty, Terminal, iTerm2, Alacritty, WezTerm, kitty
# swallow_all = false

[app_rules]
# Pin apps to specific positions or workspaces
# Arc = left
# Ghostty = right
# Slack = workspace 3

[menubar]
# Customize workspace number colors (hex)
# Defaults to Catppuccin Mocha/Latte based on dark/light mode
# active_color = #89b4fa
# inactive_color = #7f849c

[workspaces]
# Named workspaces (shown in menu bar)
# 1 = Code
# 2 = Browser
# 3 = Chat

[bindings]
# Custom bindings are merged with defaults (custom takes priority).
# Format: modifiers, key = action
alt+shift, h = focus_prev
alt+shift, l = focus_next
alt+shift, j = rotate_next
alt+shift, k = rotate_prev
alt+shift, return = swap_master
alt+shift, space = cycle_layout
alt+shift, t = toggle_float
alt+shift, f = toggle_fullscreen
alt+shift, q = close
alt+shift, r = reload_config
alt+shift, equal = increase_gap
alt+shift, minus = decrease_gap
alt+shift, rightbracket = grow_focused
alt+shift, leftbracket = shrink_focused
alt+shift, m = minimize
alt+shift, comma = focus_monitor left
alt+shift, period = focus_monitor right
cmd+shift, h = position_left
cmd+shift, l = position_right
cmd+shift, k = position_up
cmd+shift, j = position_down
cmd+shift, f = position_fill

# Window marks (vim-style):
# alt+shift, a = set_mark a
# alt, a = jump_mark a

# Niri mode (when tiling_mode = niri):
# alt+shift, c = niri_consume
# alt+shift, x = niri_expel

# Hyperkey bindings (requires hyperkey = ... in [layout]):
# hyper, h = focus_prev
# hyper, l = focus_next
# hyper, j = rotate_next
# hyper, k = rotate_prev
# hyper, f = toggle_fullscreen
# hyper, t = toggle_float
# hyper, q = close
# hyper, space = cycle_layout
# hyper, 1 = switch_workspace 1
```

### Config Reference

| Section | Key | Default | Description |
|---------|-----|---------|-------------|
| layout | `inner_gap` | 8 | Gap between windows (px) |
| layout | `outer_gap` | 8 | Gap between windows and screen edges (px) |
| layout | `dim_unfocused` | 0 | Dim amount for unfocused windows (0.0 - 1.0) |
| layout | `single_window_padding` | 0 | Extra padding when only 1 window is tiled |
| layout | `focus_follows_mouse` | false | Focus window under cursor |
| layout | `animations` | true | GPU-composited Hyprland-style animations (set false for instant) |
| layout | `native_animation` | false | Use native macOS compositor tiling (Sequoia+, no gaps) |
| layout | `auto_float_dialogs` | true | Auto-float dialogs and small windows |
| layout | `tiling_mode` | hyprland | Tiling mode: `hyprland` or `niri` |
| layout | `niri_column_width` | 1.0 | Default Niri column width as fraction (1.0 = full, 0.5 = half) |
| layout | `focus_follows_app` | true | Auto-switch workspace when an app on another workspace is activated |
| layout | `hyperkey` | *(disabled)* | Key that acts as Ctrl+Opt+Cmd+Shift when held, globally (`f18`, `caps_lock`, `grave`, etc.) |
| layout | `force_promotion` | false | Force ProMotion to stay at 120Hz |
| border | `enabled` | false | Show window borders |
| border | `width` | 2 | Border thickness (px) |
| border | `active_color` | #66ccff | Focused window border color (hex) |
| border | `inactive_color` | #444444 | Unfocused window border color (hex) |
| border | `radius` | 10 | Border corner radius |
| rules | `float` | Finder, System Settings, ... | Comma-separated apps that always float |
| rules | `exclude` | *(empty)* | Comma-separated apps ignored by Paneless |
| rules | `sticky` | *(empty)* | Comma-separated apps visible on ALL workspaces |
| rules | `swallow` | Ghostty, Terminal, iTerm2, ... | Comma-separated terminal apps eligible for window swallowing |
| rules | `swallow_all` | false | Swallow from any app (not just terminals) |
| app_rules | `App = left` | | Pin app to first tiled position |
| app_rules | `App = right` | | Pin app to last tiled position |
| app_rules | `App = workspace N` | | Auto-assign app to workspace N |
| menubar | `active_color` | Catppuccin Blue | Active workspace number color (hex) |
| menubar | `inactive_color` | Catppuccin Overlay1 | Inactive workspace number color (hex) |
| workspaces | `N = Name` | | Label workspace N (shown in menu bar and dropdown) |

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
| `minimize` | Minimize focused window (hide off-screen, restore with Alt+Shift+M) |
| `retile` | Reset layout and re-scan windows |
| `reload_config` | Reload config file |
| `set_mark X` | Mark focused window as "X" (vim-style) |
| `jump_mark X` | Jump to window marked "X" (switches workspace if needed) |
| `niri_consume` | Niri: absorb window from right column into current column |
| `niri_expel` | Niri: eject focused window from column into its own column |

## CLI

The `paneless` binary doubles as a CLI for scripting and integration:

```bash
paneless --focus-workspace 3       # Switch to workspace 3
paneless --list-workspaces         # List workspaces with windows
paneless --help                    # Show help
```

## How It Works

**Virtual workspaces** are implemented without native macOS Spaces. All windows live on a single Space. Workspace switching is instant — no native Spaces animation delays.

**Window dimming** is compositor-level — it follows window shape, rounded corners, and shadows perfectly without overlays.

**Animation** uses GPU-composited scale transforms via `SLSSetWindowTransform` for popin/popout effects with Hyprland-style bezier curves. Window position changes are atomic via `SLSDisableUpdate`/`SLSReenableUpdate` for tear-free moves.

**Window detection** uses a multi-layer system that intercepts new windows before they render, so tiling appears instant with no visual flash at the app's default position.

## Uninstall

```bash
rm -rf ~/Applications/Paneless.app
sudo rm -f /usr/local/bin/paneless
rm -rf ~/.config/paneless
```

## Acknowledgements

Inspired by [Hyprland](https://hyprland.org/), [AeroSpace](https://github.com/nikitabobko/AeroSpace), [yabai](https://github.com/koekeishiya/yabai), [Amethyst](https://github.com/ianyh/Amethyst), and [rift](https://github.com/acsandmann/rift).

## License

MIT
