#!/bin/sh
# One-time installer: puts "DeepSeek Status" in your application menu so it can
# be launched with a single click, like any other app.
#
#   ./install-linux.sh
#
# Undo:
#   rm ~/.local/bin/deepseek-status
#   rm ~/.local/share/applications/deepseek-status.desktop
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$(command -v python3 || true)"

if [ -z "$PY" ]; then
    echo "python3 not found. Install it first (e.g. sudo apt install python3 python3-tk)." >&2
    exit 1
fi

if ! "$PY" -c "import tkinter" 2>/dev/null; then
    echo "python3-tk is missing. Install it (Debian/Ubuntu: sudo apt install python3-tk)." >&2
    echo "The --line and --waybar modes work without it." >&2
fi

BIN_DIR="$HOME/.local/bin"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$BIN_DIR" "$APPS_DIR"

LAUNCHER="$BIN_DIR/deepseek-status"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
exec "$PY" "$DIR/deepseek_status.py" "\$@"
EOF
chmod 755 "$LAUNCHER"

ENTRY="$APPS_DIR/deepseek-status.desktop"
cat > "$ENTRY" <<EOF
[Desktop Entry]
Type=Application
Name=DeepSeek Status
Comment=DeepSeek peak/off-peak countdown and remaining balance
Exec=$LAUNCHER
Terminal=false
Categories=Utility;
StartupNotify=false
EOF
chmod 755 "$ENTRY"

echo "Installed:"
echo "  $LAUNCHER"
echo "  $ENTRY"
echo
echo "It should now appear in your application menu as \"DeepSeek Status\"."
echo "On older desktops you may need to log out and back in."
