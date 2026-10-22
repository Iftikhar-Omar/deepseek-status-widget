# DeepSeek Status Widget

A tiny always-on-top Windows desktop widget that shows **whether DeepSeek is charging peak or
off-peak rates right now**, when that flips, and **how much balance is left**.

![preview](preview.png)

## Why

DeepSeek halves its API rates outside peak hours. Peak is **01:00–04:00 and 06:00–10:00 UTC, Monday
to Friday** — in Asia/Dhaka that is 07:00–10:00 and 12:00–16:00. Everything else, weekends included,
is off-peak at half price.

If you point agents at DeepSeek — DeepSeek Harness, Claude Code, Codex, your own scripts — the
difference between "run this now" and "run this in two hours" is real money. This widget answers that
question in a glance instead of a docs tab.

## What it shows

| element | source |
|---|---|
| **PEAK / OFF-PEAK** and a countdown to the next change | local rule |
| progress bar through the current window | local rule |
| **remaining balance** (USD, plus granted CNY) | `GET https://api.deepseek.com/user/balance`, every 5 minutes |
| `updated HH:mm`, or the error if the fetch failed | local |

Roughly **2% of one CPU core** and ~130 MB, which is the PowerShell/WinForms floor. It uses one HTTP
request every five minutes and a one-second timer that only does arithmetic.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (already installed)
- A DeepSeek API key in the `DEEPSEEK_API_KEY` user environment variable — only used to read the
  balance. Without it the schedule still works and the balance shows `n/a`.

```powershell
[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY','sk-...','User')
```

New terminals pick that up immediately; apps already running need a restart.

## Install

```powershell
git clone https://github.com/<you>/deepseek-status-widget.git
cd deepseek-status-widget
.\Start Widget.vbs
```

Double-clicking `Start Widget.vbs` also works — no console window, no installer.

- **Drag** it anywhere; the position is remembered.
- **Right-click** for *Always on top*, *Refresh balance*, *Close widget*.
- Only one instance runs; launching again exits immediately.

Start it at sign-in:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-startup.ps1
```

## Configure

The schedule lives at the top of `PeakWidget.ps1`:

```powershell
$PeakWindowsUtc = @(
    @{ Start = 1; End = 4 }     # UTC hours, end-exclusive
    @{ Start = 6; End = 10 }
)
$CnHolidays = @()               # add 'yyyy-MM-dd' entries; those days become off-peak
```

Chinese public holidays are off-peak all day per DeepSeek's rules, but they change every year, so the
list is empty by default rather than guessing. Add the dates when the State Council publishes them.

## How it works

- The schedule is computed locally: UTC hour windows, weekday check, holiday list. No network call.
- Balance is one `GET /user/balance` with your key, cached for five minutes, fetched asynchronously
  so the UI never blocks.
- Nothing else leaves your machine. No telemetry, no analytics, no update check.
- **No usage or connection metrics**: DeepSeek has no endpoint for either. `/user/usage`,
  `/user/billing`, `/user/credits`, `/dashboard/billing/usage`, `/user/spend` all return 404. Only
  `/user/balance` exists, so that is all the widget can honestly show.

## Development

```powershell
powershell -NoProfile -Sta -File .\PeakWidget.ps1 -Test              # schedule boundaries, no UI
powershell -NoProfile -Sta -File .\PeakWidget.ps1 -Shot preview.png  # render one frame, exit
```

Three Windows details are load-bearing and easy to break:

- **`SetProcessDPIAware()` runs before any UI type.** Without it Windows virtualises the process
  (1536×864 on a 1920×1080 screen at 125%), then scales the window 1.25× and pushes a correctly
  positioned widget off the right edge.
- **`Add-Type -AssemblyName System.Net.Http`.** Windows PowerShell does not load it by default, and
  the failure surfaces as a generic "fetch failed".
- **Transparent labels repaint their parent background over siblings.** A value label wider than its
  text will erase the label next to it.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with DeepSeek. "DeepSeek" is a trademark of its owner; this is an unofficial
community tool.
