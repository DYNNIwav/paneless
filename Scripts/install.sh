#!/bin/bash
set -e

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"
APP_DIR="$PROJECT_DIR/Spacey.app"

if [ ! -d "$APP_DIR" ]; then
    echo "Spacey.app not found. Building first..."
    ./Scripts/build.sh
fi

INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"

echo "Installing Spacey.app to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/Spacey.app"
cp -R "$APP_DIR" "$INSTALL_DIR/Spacey.app"

# Also install CLI to /usr/local/bin for Sketchybar/skhd integration
echo "Installing CLI to /usr/local/bin/spacey..."
sudo mkdir -p /usr/local/bin
sudo cp "$APP_DIR/Contents/MacOS/Spacey" /usr/local/bin/spacey

# Create default config if it doesn't exist
CONFIG_DIR="$HOME/.config/spacey"
if [ ! -f "$CONFIG_DIR/config" ]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config" << 'EOF'
[layout]
inner_gap = 8
outer_gap = 8
master_ratio = 0.50
# auto_ratio = true
sketchybar_height = 0
mode = dwindle
nmaster = 1
# space_switch_modifier = alt

[animation]
enabled = true
duration = 0.15
# Custom bezier curve (like Hyprland): p1x, p1y, p2x, p2y
# curve = 0.05, 0.9, 0.1, 1.0

[border]
enabled = false
width = 2
active_color = #66ccff
inactive_color = #444444
radius = 10

[rules]
float = Finder, System Settings, Calculator, Archive Utility, System Preferences
# sticky = Finder
scratchpad = Spotify
# scratchpad.music = Spotify
# scratchpad.chat = Discord, Slack
# space.3 = Slack, Discord

# [bindings]
# Override default keybindings. Format: modifiers, key = action
# alt+shift, h = focus_left
# alt+shift, j = focus_down
# alt+shift, k = focus_up
# alt+shift, l = focus_right
# alt+shift, return = swap_master
# alt+shift, space = toggle_float
# alt+shift, f = toggle_fullscreen
# alt+shift, q = close
# alt+shift, r = resize_mode
# alt+shift, s = toggle_scratchpad
# alt+shift, t = cycle_layout
# alt+shift, m = increase_master
# alt+shift, n = decrease_master
# alt+shift, comma = focus_monitor left
# alt+shift, period = focus_monitor right
# alt+shift, 1 = move_to_space 1
EOF
    echo "Created default config at $CONFIG_DIR/config"
fi

echo ""
echo "Installed! To start Spacey:"
echo "  open ~/Applications/Spacey.app"
echo ""
echo "To start at login:"
echo "  System Settings > General > Login Items > add Spacey"
echo ""
echo "Required permissions (System Settings > Privacy & Security):"
echo "  - Accessibility"
echo "  - Input Monitoring"
echo ""
echo "IPC commands (from terminal or skhd):"
echo "  spacey --dispatch focus left"
echo "  spacey --dispatch toggle float"
echo "  spacey --query windows"
echo "  spacey --query active-window"
echo ""
echo "Sketchybar integration:"
echo "  Replace 'yabai -m space --focus' with 'spacey --focus-space'"
