#!/bin/bash
# Double-click this file in Finder to launch the widget.
#
# First launch may be blocked by Gatekeeper: right-click the file, choose Open,
# then confirm. After that, double-click works normally.
cd "$(dirname "$0")" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
    osascript -e 'display dialog "python3 was not found. Install it from python.org or run: xcode-select --install" buttons {"OK"}'
    exit 1
fi

exec python3 deepseek_status.py
