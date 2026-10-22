#!/bin/sh
# Run the widget from a terminal, or double-click it in a file manager that is
# configured to run executables. For a proper application-menu entry run:
#   ./install-linux.sh
cd "$(dirname "$0")" || exit 1
exec python3 deepseek_status.py
