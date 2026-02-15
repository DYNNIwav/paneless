#!/bin/bash
set -e

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"
APP_DIR="$PROJECT_DIR/Paneless.app"

if [ ! -d "$APP_DIR" ]; then
    echo "Paneless.app not found. Building first..."
    ./Scripts/build.sh
fi

INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"

echo "Installing Paneless.app to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/Paneless.app"
cp -R "$APP_DIR" "$INSTALL_DIR/Paneless.app"

# Also install CLI to /usr/local/bin for Sketchybar/skhd integration
echo "Installing CLI to /usr/local/bin/paneless..."
sudo mkdir -p /usr/local/bin
sudo cp "$APP_DIR/Contents/MacOS/Paneless" /usr/local/bin/paneless

# Create default config if it doesn't exist
CONFIG_DIR="$HOME/.config/paneless"
if [ ! -f "$CONFIG_DIR/config" ]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config" << 'EOF'
# Paneless Configuration
# Reload with Alt+Shift+R (or your reload_config binding)

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

# [app_rules]
# Arc = left
# Ghostty = right
# Slack = workspace 3

[workspaces]
# 1 = Code
# 2 = Browser
# 3 = Chat

# [bindings]
# Uncomment to override default keybindings.
# Format: modifier, key = action
#
# alt+shift, h = focus_prev
# alt+shift, l = focus_next
# alt+shift, j = rotate_next
# alt+shift, k = rotate_prev
# alt+shift, return = swap_master
# alt+shift, space = cycle_layout
# alt+shift, t = toggle_float
# alt+shift, f = toggle_fullscreen
# alt+shift, q = close
# alt+shift, r = reload_config
# alt+shift, equal = increase_gap
# alt+shift, minus = decrease_gap
# alt+shift, rightbracket = grow_focused
# alt+shift, leftbracket = shrink_focused
# alt+shift, m = minimize
# alt+shift, comma = focus_monitor left
# alt+shift, period = focus_monitor right
# cmd+shift, h = position_left
# cmd+shift, l = position_right
# cmd+shift, k = position_up
# cmd+shift, j = position_down
# cmd+shift, f = position_fill
#
# Window marks (vim-style):
# alt+shift, a = set_mark a
# alt, a = jump_mark a
EOF
    echo "Created default config at $CONFIG_DIR/config"
fi

echo ""
echo "Installed! To start Paneless:"
echo "  open ~/Applications/Paneless.app"
echo ""
echo "To start at login:"
echo "  System Settings > General > Login Items > add Paneless"
echo ""
echo "Required permissions (System Settings > Privacy & Security):"
echo "  - Accessibility"
echo "  - Input Monitoring"
echo ""
echo "CLI commands:"
echo "  paneless --focus-workspace 3"
echo "  paneless --list-workspaces"
echo "  paneless --help"
