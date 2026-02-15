# Spacey

Hyprland-inspired tiling window manager for macOS. Uses native macOS Spaces (not virtual workspaces), auto-tiles windows with BSP/dwindle layout, and provides HJKL navigation.

Works on macOS Sequoia with SIP enabled. No root access needed.

## Install

```bash
cd ~/Downloads/spacey
./Scripts/build.sh
./Scripts/install.sh   # installs to ~/Applications + /usr/local/bin/spacey
```

To start at login: **System Settings > General > Login Items > add Spacey**

### Required Permissions

Grant both in **System Settings > Privacy & Security**:

| Permission           | Why                            |
| -------------------- | ------------------------------ |
| **Accessibility**    | Move and resize windows        |
| **Input Monitoring** | Global hotkeys (Alt+Shift+...) |

### Space Switching Setup

To move windows between spaces AND switch to the target space, you need macOS keyboard shortcuts enabled:

1. **System Settings > Keyboard > Keyboard Shortcuts > Mission Control**
2. Enable **"Switch to Desktop 1"** through **"Switch to Desktop 9"**
3. Set the modifier to **Alt** (Option+1, Option+2, etc.)

Spacey defaults to Alt. If you use Ctrl instead, set it in the config:

```ini
[layout]
space_switch_modifier = alt   # default: alt
```

Without these shortcuts, Spacey can still move windows between spaces, but won't be able to switch the visible space automatically.

## Keybinds

All hotkeys use **Alt+Shift** as the modifier.

### Window Management

| Keybind                         | Action                                               |
| ------------------------------- | ---------------------------------------------------- |
| `Alt+Shift+1` ... `Alt+Shift+9` | Move focused window to space 1-9 and switch there    |
| `Alt+Shift+Q`                   | Close focused window                                 |
| `Alt+Shift+Space`               | Toggle float (remove/add window from tiling)         |
| `Alt+Shift+F`                   | Toggle fullscreen (window fills entire tiling area)  |
| `Alt+Shift+Enter`               | Swap focused window with the master (largest) window |

### Focus Navigation

| Keybind       | Action                        |
| ------------- | ----------------------------- |
| `Alt+Shift+H` | Focus window to the **left**  |
| `Alt+Shift+J` | Focus window **below**        |
| `Alt+Shift+K` | Focus window **above**        |
| `Alt+Shift+L` | Focus window to the **right** |

### Layout Control

| Keybind       | Action                                       |
| ------------- | -------------------------------------------- |
| `Alt+Shift+T` | Cycle layout mode (dwindle <-> master-stack) |
| `Alt+Shift+M` | Increase master count (+1, max 5)            |
| `Alt+Shift+N` | Decrease master count (-1, min 1)            |

### Resize Mode

| Keybind       | Action                 |
| ------------- | ---------------------- |
| `Alt+Shift+R` | **Enter** resize mode  |
| `H`           | Shrink split leftward  |
| `J`           | Shrink split downward  |
| `K`           | Shrink split upward    |
| `L`           | Expand split rightward |
| `Escape`      | **Exit** resize mode   |

In resize mode, HJKL adjusts the nearest split boundary. No modifier keys needed. Press Escape to return to normal mode.

### Scratchpad

| Keybind       | Action                       |
| ------------- | ---------------------------- |
| `Alt+Shift+S` | Toggle scratchpad visibility |

The scratchpad is a hidden floating workspace (like Hyprland's special workspace). Windows in the scratchpad appear centered at 80% screen size when shown, and move off-screen when hidden. Configure which apps go to the scratchpad in the config file.

## Menu Bar

Spacey shows a bold **S** in the menu bar. Click it for:

- **Layout: Dwindle/Master-Stack** - cycle layout mode
- **Retile** - re-scan windows and re-apply tiling
- **Reload Config** - reload `~/.config/spacey/config`
- **Quit Spacey** - exit the app

## CLI

Spacey also works as a CLI tool (useful for Sketchybar integration):

```bash
spacey --focus-space N      # Switch to space N
spacey --move-to-space N    # Move focused window to space N
spacey --list-spaces        # List all spaces
spacey --help               # Show help
```

### Sketchybar Integration

Replace `yabai` calls in your Sketchybar config:

```lua
-- Before:
sbar.exec("yabai -m space --focus " .. env.SID)
-- After:
sbar.exec("spacey --focus-space " .. env.SID)
```

## Config

Edit `~/.config/spacey/config` (created on first install):

```ini
[layout]
auto_ratio = true            # auto-adjust split ratio for your display aspect ratio
# master_ratio = 0.50        # uncomment to manually set (overrides auto_ratio)
sketchybar_height = 40       # pixels reserved at top for Sketchybar
inner_gap = 8                # gap between windows (px)
outer_gap = 8                # gap at screen edges (px)
mode = dwindle               # dwindle or master-stack
nmaster = 1                  # number of master windows
animation_enabled = true     # smooth tiling animations
animation_duration = 0.25    # animation duration in seconds
# space_switch_modifier = alt   # alt (default) or ctrl

[rules]
float = Finder, System Settings, Calculator, Archive Utility
exclude = Sketchybar
scratchpad = Spotify
# space.3 = Slack, Discord   # auto-move these apps to space 3
```

### Auto Ratio

With `auto_ratio = true` (default), Spacey detects your display aspect ratio and adjusts the master/stack split:

| Display                | Aspect Ratio | Auto Split |
| ---------------------- | ------------ | ---------- |
| Standard (16:9)        | 1.78         | 50/50      |
| Wide                   | ~2.0         | 47/53      |
| Ultrawide (21:9)       | 2.33         | 42/58      |
| Super ultrawide (32:9) | 3.56         | 38/62      |

Set `master_ratio` explicitly to override.

## Layout Modes

### Dwindle (default)

Like Hyprland's dwindle layout. Each new window splits the focused window, alternating direction based on the region's aspect ratio:

```
1 window:     2 windows:        3 windows:          4 windows:
+----------+  +-----+-----+    +-----+-----+    +-----+-----+
|          |  |     |     |    |     |  W2 |    |     |  W2 |
|    W1    |  |  W1 |  W2 |    |  W1 +-----+    |  W1 +--+--+
|          |  |     |     |    |     |  W3 |    |     |W3|W4|
+----------+  +-----+-----+    +-----+-----+    +-----+--+--+
```

### Master-Stack

First split is always horizontal (master | stack), subsequent splits in the stack are vertical:

```
3 windows:          4 windows:
+-----+-----+    +-----+-----+
|     |  W2 |    |     |  W2 |
|  W1 +-----+    |  W1 +-----+
|     |  W3 |    |     |  W3 |
+-----+-----+    |     +-----+
                  |     |  W4 |
                  +-----+-----+
```

## How It Works

- **Private CGS APIs** (`CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces`) move windows between real macOS Spaces. Same approach as Amethyst/yabai. Works on Sequoia without SIP.
- **CGEventTap** captures global hotkeys at the session level.
- **AXUIElement** (Accessibility API) reads and sets window frames.
- **CVDisplayLink** syncs animations to your display's refresh rate (60Hz, 120Hz, ProMotion).
- **BSP tree** (binary space partition) manages the tiling layout with value-semantic `indirect enum`.

## Uninstall

```bash
rm -rf ~/Applications/Spacey.app
sudo rm -f /usr/local/bin/spacey
rm -rf ~/.config/spacey
```
