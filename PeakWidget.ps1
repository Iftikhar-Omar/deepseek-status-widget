param([switch]$Test, [string]$Shot)

# DPI awareness before any UI type: coordinates are then physical pixels.
Add-Type @"
using System.Runtime.InteropServices;
public static class Dpi {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
[void][Dpi]::SetProcessDPIAware()

# One widget per session. Diagnostic modes are exempt so they can run while a
# widget is up, which is what CI and local checks need.
if (-not $Test -and -not $Shot) {
    $script:singleton = New-Object System.Threading.Mutex($false, 'DshPeakWidget.Singleton')
    if (-not $script:singleton.WaitOne(0)) { exit }
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Windows PowerShell does not load System.Net.Http by default.
Add-Type -AssemblyName System.Net.Http

# --- schedule: 01-04 and 06-10 UTC, Mon-Fri; weekends + CN holidays off-peak --
$PeakWindowsUtc = @(
    @{ Start = 1; End = 4 }
    @{ Start = 6; End = 10 }
)
$CnHolidays = @()

function Test-PeakUtc {
    param([datetime]$Utc)
    if ($CnHolidays -contains $Utc.Date.ToString('yyyy-MM-dd')) { return $false }
    if ($Utc.DayOfWeek -eq [DayOfWeek]::Saturday -or $Utc.DayOfWeek -eq [DayOfWeek]::Sunday) { return $false }
    foreach ($w in $PeakWindowsUtc) {
        if ($Utc.Hour -ge $w.Start -and $Utc.Hour -lt $w.End) { return $true }
    }
    return $false
}

function Find-Transition {
    param([datetime]$Utc, [int]$Direction)
    $t0 = $Utc.AddSeconds(-$Utc.Second).AddMilliseconds(-$Utc.Millisecond)
    $current = Test-PeakUtc -Utc $t0
    for ($i = 1; $i -le 60 * 24 * 9; $i++) {
        $t = $t0.AddMinutes($i * $Direction)
        if ((Test-PeakUtc -Utc $t) -ne $current) {
            if ($Direction -lt 0) { return $t.AddMinutes(1) }
            return $t
        }
    }
    return $Utc.AddMinutes(60 * 24)
}

function Format-Span {
    param([timespan]$Span)
    if ($Span.TotalSeconds -lt 0) { $Span = [timespan]::Zero }
    $d = [int][math]::Floor($Span.TotalDays)
    if ($d -gt 0) { return ('{0}d {1}h' -f $d, $Span.Hours) }
    if ($Span.Hours -gt 0) { return ('{0}h {1}m' -f $Span.Hours, $Span.Minutes) }
    if ($Span.Minutes -gt 0) { return ('{0}m {1}s' -f $Span.Minutes, $Span.Seconds) }
    return ('{0}s' -f $Span.Seconds)
}

function Test-WidgetSchedule {
    $base = [datetime]::new(2026, 10, 22, 0, 0, 0, [DateTimeKind]::Utc)
    foreach ($h in 0, 1, 4, 6, 10, 12) {
        $t = $base.AddHours($h)
        '{0:HH:mm} {1,-9} {2,-4} next {3:HH:mm}' -f $t, $t.DayOfWeek, $(if (Test-PeakUtc -Utc $t) { 'PEAK' } else { 'OFF' }), (Find-Transition -Utc $t -Direction 1)
    }
}

if ($Test) { Test-WidgetSchedule; exit }

# --- palette ----------------------------------------------------------------
$colBg    = [System.Drawing.Color]::FromArgb(23, 24, 28)
$colPanel = [System.Drawing.Color]::FromArgb(40, 42, 50)
$colText  = [System.Drawing.Color]::FromArgb(231, 232, 234)
$colMuted = [System.Drawing.Color]::FromArgb(138, 143, 152)
$colPeak  = [System.Drawing.Color]::FromArgb(229, 72, 77)
$colOff   = [System.Drawing.Color]::FromArgb(48, 164, 108)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Size = New-Object System.Drawing.Size(372, 164)
$form.BackColor = $colBg
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.Text = 'DeepSeek status'
$form.AutoScaleMode = 'None'

function New-Label {
    param($Text, $X, $Y, $W, $H, $Size, $Color, $Bold = $false, $Align = 'Left')
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($Align -eq 'Right') { $l.TextAlign = 'MiddleRight' }
    return $l
}

$lblState = New-Label 'PEAK' 18 8 210 34 20 $colPeak $true
$lblClock = New-Label '' 250 12 104 18 9 $colMuted $false 'Right'
$lblCount = New-Label '' 18 44 336 18 10 $colText
$lblBalCap = New-Label 'REMAINING BALANCE' 18 80 220 14 7.5 $colMuted
$lblBalVal = New-Label '--' 18 94 126 38 20 $colText
$lblBalAlt = New-Label '' 150 104 90 18 8 $colMuted
$lblFoot = New-Label '' 18 136 336 14 7 $colMuted $false 'Right'

foreach ($c in @($lblState, $lblClock, $lblCount, $lblBalCap, $lblBalVal, $lblBalAlt, $lblFoot)) {
    $form.Controls.Add($c)
}

# --- position ---------------------------------------------------------------
$StateDir = Join-Path $env:LOCALAPPDATA 'DshPeakWidget'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$PosFile = Join-Path $StateDir 'pos.txt'
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

$script:wantedX = $null
$script:wantedY = $null
if (Test-Path $PosFile) {
    try {
        $saved = (Get-Content $PosFile -Raw).Trim() -split ','
        if ($saved.Count -eq 2) { $script:wantedX = [int]$saved[0]; $script:wantedY = [int]$saved[1] }
    } catch { }
}
$form.Location = New-Object System.Drawing.Point(($screen.Right - 400), ($screen.Top + 24))

function Set-Position {
    $w = $form.Width; $h = $form.Height
    if ($null -ne $script:wantedX) { $x = $script:wantedX } else { $x = $screen.Right - $w - 24 }
    if ($null -ne $script:wantedY) { $y = $script:wantedY } else { $y = $screen.Top + 24 }
    $x = [math]::Min($x, $screen.Right - $w - 8); $x = [math]::Max($x, $screen.Left + 8)
    $y = [math]::Min($y, $screen.Bottom - $h - 8); $y = [math]::Max($y, $screen.Top + 8)
    $form.Location = New-Object System.Drawing.Point($x, $y)
}

# --- balance: one async GET every 5 minutes, never blocks the UI ------------
$script:http = $null
$script:balanceTask = $null
$script:balance = $null
$script:balanceAt = $null
$script:balanceError = $null

if (-not $env:DEEPSEEK_API_KEY) {
    $env:DEEPSEEK_API_KEY = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
}

function Update-BalanceLabels {
    if ($script:balance) {
        $usd = $script:balance.usd
        $cny = $script:balance.cny
        if ($null -ne $usd) {
            $lblBalVal.Text = ('${0:0.00}' -f $usd)
            $lblBalAlt.Text = if ($null -ne $cny -and $cny -gt 0) { ('+ {0:0.00} CNY' -f $cny) } else { '' }
        } elseif ($null -ne $cny) {
            $lblBalVal.Text = ('{0:0.00} CNY' -f $cny)
            $lblBalAlt.Text = ''
        } else {
            $lblBalVal.Text = '--'
            $lblBalAlt.Text = ''
        }
        $stamp = if ($script:balanceAt) { $script:balanceAt.ToString('HH:mm') } else { '' }
        $lblFoot.Text = if ($script:balance.available -eq $false) { 'account unavailable' } else { "updated $stamp" }
    } elseif ($script:balanceError) {
        $lblBalVal.Text = 'n/a'
        $lblBalAlt.Text = ''
        $lblFoot.Text = $script:balanceError
    } else {
        $lblBalVal.Text = '--'
        $lblBalAlt.Text = ''
        $lblFoot.Text = 'loading'
    }
}

function Start-BalanceFetch {
    if (-not $env:DEEPSEEK_API_KEY) { $script:balanceError = 'no DEEPSEEK_API_KEY'; Update-BalanceLabels; return }
    if ($script:balanceTask -and -not $script:balanceTask.IsCompleted) { return }
    try {
        if (-not $script:http) {
            $script:http = New-Object System.Net.Http.HttpClient
            $script:http.Timeout = [timespan]::FromSeconds(10)
            $script:http.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $env:DEEPSEEK_API_KEY)
        }
        $script:balanceTask = $script:http.GetStringAsync('https://api.deepseek.com/user/balance')
        $script:balanceError = $null
    } catch {
        $script:balanceError = 'fetch failed'
        Update-BalanceLabels
    }
}

function Poll-Balance {
    if (-not $script:balanceTask) { return }
    if (-not $script:balanceTask.IsCompleted) { return }
    try {
        $j = $script:balanceTask.GetAwaiter().GetResult() | ConvertFrom-Json
        $usd = $j.balance_infos | Where-Object { $_.currency -eq 'USD' } | Select-Object -First 1
        $cny = $j.balance_infos | Where-Object { $_.currency -eq 'CNY' } | Select-Object -First 1
        $script:balance = @{
            usd = if ($usd) { [double]$usd.total_balance } else { $null }
            cny = if ($cny) { [double]$cny.total_balance } else { $null }
            available = [bool]$j.is_available
        }
        $script:balanceAt = Get-Date
        $script:balanceError = $null
    } catch {
        $script:balanceError = 'fetch failed'
    }
    $script:balanceTask = $null
    Update-BalanceLabels
}

# --- update loop ------------------------------------------------------------
$script:peak = $false
$script:frac = 0.0
$script:tick = 0
$script:cache = $null
$script:lastFrac = -1.0
$script:lastPeak = $null

function Update-Widget {
    $nowUtc = (Get-Date).ToUniversalTime()

    # The boundary scan walks up to 9 days of minutes. Recomputing it every second
    # cost ~11% of a core, so cache the window and only rescan when it is crossed.
    if (-not $script:cache -or $nowUtc -ge $script:cache.Next -or $nowUtc -lt $script:cache.Prev) {
        $script:cache = @{
            Next = Find-Transition -Utc $nowUtc -Direction 1
            Prev = Find-Transition -Utc $nowUtc -Direction -1
            Peak = Test-PeakUtc -Utc $nowUtc
        }
    }
    $peak = $script:cache.Peak
    $next = $script:cache.Next
    $prev = $script:cache.Prev
    $script:peak = $peak

    if ($peak) {
        $lblState.Text = 'PEAK'
        $lblState.ForeColor = $colPeak
        $lblCount.Text = 'off-peak in ' + (Format-Span ($next - $nowUtc))
    } else {
        $lblState.Text = 'OFF-PEAK'
        $lblState.ForeColor = $colOff
        $lblCount.Text = 'peak in ' + (Format-Span ($next - $nowUtc))
    }

    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, [System.TimeZoneInfo]::Local)
    $lblClock.Text = $local.ToString('HH:mm ddd')

    $total = ($next - $prev).TotalSeconds
    $done = ($nowUtc - $prev).TotalSeconds
    $script:frac = if ($total -gt 0) { [math]::Min(1.0, [math]::Max(0.0, $done / $total)) } else { 0.0 }

    # Repaint only when the bar actually moves or the state flips.
    if ($peak -ne $script:lastPeak -or [math]::Abs($script:frac - $script:lastFrac) -gt 0.002) {
        $script:lastPeak = $peak
        $script:lastFrac = $script:frac
        $form.Invalidate()
    }
}

$form.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $x = 18; $y = 66; $w = 336; $h = 3
    $bg = New-Object System.Drawing.SolidBrush($colPanel)
    $g.FillRectangle($bg, $x, $y, $w, $h)
    $bg.Dispose()
    $fw = [int]($w * $script:frac)
    if ($fw -gt 0) {
        $c = if ($script:peak) { $colPeak } else { $colOff }
        $fg = New-Object System.Drawing.SolidBrush($c)
        $g.FillRectangle($fg, $x, $y, $fw, $h)
        $fg.Dispose()
    }
})

# --- drag / menu ------------------------------------------------------------
$script:dragging = $false
$script:dragOffset = New-Object System.Drawing.Point(0, 0)
foreach ($c in @($form, $lblState, $lblClock, $lblCount, $lblBalCap, $lblBalVal, $lblBalAlt)) {
    $c.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:dragging = $true
            $script:dragOffset = $e.Location
        }
    })
    $c.Add_MouseMove({
        param($sender, $e)
        if ($script:dragging) {
            $sp = [System.Windows.Forms.Control]::MousePosition
            $form.Location = New-Object System.Drawing.Point(($sp.X - $script:dragOffset.X), ($sp.Y - $script:dragOffset.Y))
        }
    })
    $c.Add_MouseUp({
        param($sender, $e)
        $script:dragging = $false
        "$($form.Location.X),$($form.Location.Y)" | Set-Content -Path $PosFile -Encoding ascii
    })
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miTop = $menu.Items.Add('Always on top')
$miTop.CheckOnClick = $true
$miTop.Checked = $true
$miTop.Add_Click({ $form.TopMost = $miTop.Checked })
$miRef = $menu.Items.Add('Refresh balance')
$miRef.Add_Click({ Start-BalanceFetch })
$null = $menu.Items.Add('-')
$miClose = $menu.Items.Add('Close widget')
$miClose.Add_Click({ $form.Close() })
$form.ContextMenuStrip = $menu

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    Update-Widget
    Poll-Balance
    $script:tick++
    if ($script:tick -eq 1 -or ($script:tick % 300 -eq 0)) { Start-BalanceFetch }
})

$form.Add_Shown({
    Set-Position
    Update-Widget
    Update-BalanceLabels
    Start-BalanceFetch
    if ($Shot) {
        Write-Host ("size={0}x{1} pos={2},{3} screen={4}x{5}" -f $form.Width, $form.Height, $form.Location.X, $form.Location.Y, $screen.Width, $screen.Height)
        $st = New-Object System.Windows.Forms.Timer
        $st.Interval = 3000
        $st.Add_Tick({
            param($sender, $e)
            $sender.Stop()
            try {
                Poll-Balance
                Update-Widget
                $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
            } catch { Write-Host ("shot failed: " + $_.Exception.Message) }
            $form.Close()
        })
        $st.Start()
        return
    }
    $timer.Start()
})

[void]$form.Show()
[System.Windows.Forms.Application]::Run($form)
