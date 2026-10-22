#!/usr/bin/env python3
"""DeepSeek status widget for Windows, macOS and Linux.

Shows whether DeepSeek API pricing is peak or off-peak right now, when it flips,
and the remaining account balance.

Requires only the Python standard library (tkinter must be present):
  - Windows / macOS: included with python.org builds
  - Debian/Ubuntu:  sudo apt install python3-tk

Run:  python3 deepseek_status.py
"""
import json
import os
import sys
import threading
import time
import urllib.request
from datetime import datetime, timedelta, timezone

# tkinter is imported lazily: the CLI modes (--selftest, --line, --waybar) are used
# on headless machines and CI runners where tkinter may not be installed.
tk = None


def load_tk():
    global tk
    if tk is None:
        import tkinter as _tk

        tk = _tk
    return tk

# --- schedule ---------------------------------------------------------------
# Peak: 01:00-04:00 and 06:00-10:00 UTC, Monday-Friday. Everything else,
# including weekends and Chinese public holidays, is off-peak at half price.
# Source: https://api-docs.deepseek.com/quick_start/pricing/  (verified 2026-10-22)
# Keep in sync with PeakWidget.ps1.
PEAK_WINDOWS_UTC = ((1, 4), (6, 10))
CN_HOLIDAYS = set()  # add "YYYY-MM-DD" entries; those days become off-peak

BEIJING = timezone(timedelta(hours=8))

BG = "#17181c"
PANEL = "#282a32"
TEXT = "#e7e8ea"
MUTED = "#8a8f98"
PEAK = "#e5484d"
OFF = "#30a46c"

BALANCE_TTL_SECONDS = 300


def is_peak(dt_utc):
    bj = dt_utc.astimezone(BEIJING)
    if bj.date().isoformat() in CN_HOLIDAYS:
        return False
    if bj.weekday() >= 5:  # Saturday, Sunday
        return False
    return any(start <= dt_utc.hour < end for start, end in PEAK_WINDOWS_UTC)


def transition(dt_utc, direction):
    """Next instant, on a minute grid, where peak/off-peak flips."""
    base = dt_utc.replace(second=0, microsecond=0)
    current = is_peak(base)
    for i in range(1, 60 * 24 * 10):
        t = base + timedelta(minutes=i * direction)
        if is_peak(t) != current:
            # Backward scan lands on the last minute of the old run.
            return t + timedelta(minutes=1) if direction < 0 else t
    return base + timedelta(days=10)


def fmt_span(delta):
    s = int(max(0, delta.total_seconds()))
    d, r = divmod(s, 86400)
    h, r = divmod(r, 3600)
    m, sec = divmod(r, 60)
    if d:
        return "{}d {}h".format(d, h)
    if h:
        return "{}h {}m".format(h, m)
    if m:
        return "{}m {}s".format(m, sec)
    return "{}s".format(sec)


def api_key():
    key = os.environ.get("DEEPSEEK_API_KEY")
    if key:
        return key
    if sys.platform == "win32":
        try:
            import winreg

            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
                value, _ = winreg.QueryValueEx(k, "DEEPSEEK_API_KEY")
                return value
        except OSError:
            return None
    return None


def state_dir():
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
    elif sys.platform == "darwin":
        base = os.path.join(os.path.expanduser("~"), "Library", "Application Support")
    else:
        base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    path = os.path.join(base, "deepseek-status-widget")
    os.makedirs(path, exist_ok=True)
    return path


def fetch_balance():
    key = api_key()
    if not key:
        return {"ok": False, "error": "no DEEPSEEK_API_KEY"}
    req = urllib.request.Request(
        "https://api.deepseek.com/user/balance",
        headers={"Authorization": "Bearer " + key},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            payload = json.load(resp)
    except Exception as exc:  # noqa: BLE001 - surfaced in the UI
        return {"ok": False, "error": "fetch failed ({} )".format(type(exc).__name__)}
    infos = payload.get("balance_infos") or []
    usd = next((i for i in infos if i.get("currency") == "USD"), None)
    cny = next((i for i in infos if i.get("currency") == "CNY"), None)
    return {
        "ok": True,
        "available": payload.get("is_available"),
        "usd": float(usd["total_balance"]) if usd else None,
        "cny": float(cny["total_balance"]) if cny else None,
    }


def enable_dpi_awareness():
    """Windows scales non-DPI-aware windows by the display scale factor, which
    moves a correctly positioned window and blurs it. Opt in before creating Tk."""
    if sys.platform != "win32":
        return
    try:
        import ctypes

        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)  # system DPI aware
        except Exception:  # noqa: BLE001 - older Windows
            ctypes.windll.user32.SetProcessDPIAware()
    except Exception:  # noqa: BLE001 - never block startup on this
        pass


def selftest():
    base = datetime(2026, 10, 22, tzinfo=timezone.utc)  # Thursday
    for hour in (0, 1, 4, 6, 10, 12):
        t = base + timedelta(hours=hour)
        print(
            "{} {} {} next {}".format(
                t.strftime("%H:%M"),
                t.strftime("%a"),
                "PEAK" if is_peak(t) else "OFF ",
                transition(t, 1).strftime("%H:%M"),
            )
        )
    sat = datetime(2026, 10, 24, 2, tzinfo=timezone.utc)
    print("Saturday 02:00 ->", "PEAK" if is_peak(sat) else "OFF")
    return 0


def line_mode(as_json=False):
    """One-line status for Linux/macOS bars: waybar, polybar, i3blocks, sketchybar."""
    now = datetime.now(timezone.utc)
    peak = is_peak(now)
    nxt = transition(now, 1)
    remaining = fmt_span(nxt - now)
    switch = "off-peak" if peak else "peak"

    balance = fetch_balance()
    money = "balance n/a"
    if balance.get("ok"):
        if balance.get("usd") is not None:
            money = "${:.2f}".format(balance["usd"])
        elif balance.get("cny") is not None:
            money = "{:.2f} CNY".format(balance["cny"])

    state = "PEAK" if peak else "OFF-PEAK"
    text = "{} - {} in {} - {}".format(state, switch, remaining, money)
    tooltip = "DeepSeek {}\n{} in {}\n{}".format(state.lower(), switch, remaining, money)

    if as_json:
        print(json.dumps({
            "text": text,
            "tooltip": tooltip,
            "class": "peak" if peak else "off-peak",
            "alt": "peak" if peak else "off-peak",
        }))
    else:
        print(text)
    return 0


class Widget:
    def __init__(self):
        load_tk()
        self.root = tk.Tk()
        # Tk divides wm geometry by its DPI scaling factor, so a 344x152 request
        # becomes 275x122 at 125%. Everything here is sized in pixels already, so
        # pin the scaling to the 96-DPI baseline and let geometry mean pixels.
        try:
            self.root.tk.call("tk", "scaling", 96.0 / 72.0)
        except Exception:  # noqa: BLE001
            pass
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.configure(bg=BG)

        self.width, self.height = 344, 152
        self.balance = None
        self.balance_error = None
        self.balance_at = None

        self._build()
        self._place()
        self._bind_drag()
        self._bind_menu()

        self._cache = None
        self._refresh_state()
        self._kick_balance()
        self.root.after(1000, self._tick)

    # -- layout ------------------------------------------------------------
    def _font(self, size, bold=False):
        family = "Segoe UI" if sys.platform == "win32" else ("Helvetica Neue" if sys.platform == "darwin" else "DejaVu Sans")
        # Negative size = pixels. Point sizes scale with display DPI and make the
        # layout overlap on a 125%/150% display.
        return (family, -size, "bold") if bold else (family, -size)

    def _label(self, text, x, y, size, color, bold=False, anchor="nw"):
        # "nw"/"ne" anchor the label's top corner at (x, y); "w"/"e" would centre
        # it vertically on y and push tall text outside the window.
        lbl = tk.Label(self.root, text=text, bg=BG, fg=color, font=self._font(size, bold), anchor="w" if anchor.endswith("w") else "e")
        lbl.place(x=x, y=y, anchor=anchor)
        return lbl

    def _build(self):
        self.state_lbl = self._label("PEAK", 16, 8, 26, PEAK, True)
        self.clock_lbl = self._label("", 328, 12, 12, MUTED, anchor="ne")
        self.count_lbl = self._label("", 16, 42, 14, TEXT)
        self.bar = tk.Canvas(self.root, width=self.width - 32, height=3, bg=BG, highlightthickness=0, bd=0)
        self.bar.place(x=16, y=64)
        self.bar_bg = self.bar.create_rectangle(0, 0, self.width - 32, 3, fill=PANEL, width=0)
        self.bar_fg = self.bar.create_rectangle(0, 0, 0, 3, fill=PEAK, width=0)

        self._label("REMAINING BALANCE", 16, 76, 10, MUTED)
        self.balance_lbl = self._label("--", 16, 90, 26, TEXT)
        self.cny_lbl = self._label("", 170, 100, 11, MUTED)
        self.foot_lbl = self._label("", 328, 132, 10, MUTED, anchor="ne")

    def _place(self):
        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()
        x, y = screen_w - self.width - 24, 24
        pos_file = os.path.join(state_dir(), "pos.json")
        try:
            with open(pos_file, "r", encoding="utf-8") as fh:
                saved = json.load(fh)
                x, y = int(saved["x"]), int(saved["y"])
        except (OSError, ValueError, KeyError):
            pass
        x = max(8, min(x, screen_w - self.width - 8))
        y = max(8, min(y, screen_h - self.height - 8))
        self.root.geometry("{}x{}+{}+{}".format(self.width, self.height, x, y))

    def _save_pos(self):
        try:
            with open(os.path.join(state_dir(), "pos.json"), "w", encoding="utf-8") as fh:
                json.dump({"x": self.root.winfo_x(), "y": self.root.winfo_y()}, fh)
        except OSError:
            pass

    def _bind_drag(self):
        def start(event):
            self._drag = (event.x_root - self.root.winfo_x(), event.y_root - self.root.winfo_y())

        def move(event):
            if getattr(self, "_drag", None):
                x = event.x_root - self._drag[0]
                y = event.y_root - self._drag[1]
                self.root.geometry("+{}+{}".format(x, y))

        def stop(_event):
            self._drag = None
            self._save_pos()

        for widget in (self.root, self.state_lbl, self.count_lbl, self.balance_lbl):
            widget.bind("<Button-1>", start)
            widget.bind("<B1-Motion>", move)
            widget.bind("<ButtonRelease-1>", stop)

    def _bind_menu(self):
        menu = tk.Menu(self.root, tearoff=0)
        menu.add_command(label="Refresh balance", command=self._kick_balance)
        menu.add_separator()
        menu.add_command(label="Close widget", command=self.root.destroy)
        self.root.bind("<Button-3>", lambda e: menu.tk_popup(e.x_root, e.y_root))

    # -- updates -----------------------------------------------------------
    def _refresh_state(self):
        now = datetime.now(timezone.utc)
        if not self._cache or now >= self._cache["next"] or now < self._cache["prev"]:
            self._cache = {
                "next": transition(now, 1),
                "prev": transition(now, -1),
                "peak": is_peak(now),
            }
        cache = self._cache
        remaining = cache["next"] - now
        if cache["peak"]:
            self.state_lbl.configure(text="PEAK", fg=PEAK)
            self.count_lbl.configure(text="Off-peak in " + fmt_span(remaining))
        else:
            self.state_lbl.configure(text="OFF-PEAK", fg=OFF)
            self.count_lbl.configure(text="Peak in " + fmt_span(remaining))
        self.clock_lbl.configure(text=now.astimezone().strftime("%H:%M %a"))

        total = (cache["next"] - cache["prev"]).total_seconds()
        done = (now - cache["prev"]).total_seconds()
        frac = min(1.0, max(0.0, done / total)) if total > 0 else 0.0
        self.bar.coords(self.bar_fg, 0, 0, int((self.width - 32) * frac), 3)
        self.bar.itemconfigure(self.bar_fg, fill=PEAK if cache["peak"] else OFF)

    def _apply_balance(self):
        if self.balance and self.balance.get("ok"):
            usd, cny = self.balance.get("usd"), self.balance.get("cny")
            if usd is not None:
                self.balance_lbl.configure(text="${:.2f}".format(usd))
                self.cny_lbl.configure(text="+ {:.2f} CNY".format(cny) if cny else "")
            elif cny is not None:
                self.balance_lbl.configure(text="{:.2f} CNY".format(cny))
                self.cny_lbl.configure(text="")
            else:
                self.balance_lbl.configure(text="--")
            stamp = self.balance_at.strftime("%H:%M") if self.balance_at else ""
            self.foot_lbl.configure(text="updated {}".format(stamp))
        elif self.balance_error:
            self.balance_lbl.configure(text="n/a")
            self.cny_lbl.configure(text="")
            self.foot_lbl.configure(text=self.balance_error)
        else:
            self.foot_lbl.configure(text="loading")

    def _kick_balance(self):
        def work():
            started = time.time()
            result = fetch_balance()
            self.balance = result
            self.balance_at = datetime.now()
            self.balance_error = None if result.get("ok") else result.get("error")
            self._next_balance = started + BALANCE_TTL_SECONDS
            self.root.after(0, self._apply_balance)

        threading.Thread(target=work, daemon=True).start()

    def _tick(self):
        self._refresh_state()
        if self.balance is None and self.balance_error is None:
            self._apply_balance()
        if getattr(self, "_next_balance", 0) <= time.time():
            self._kick_balance()
        self.root.after(1000, self._tick)

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if "--waybar" in sys.argv:
        sys.exit(line_mode(as_json=True))
    if "--line" in sys.argv:
        sys.exit(line_mode(as_json=False))
    enable_dpi_awareness()
    Widget().run()
