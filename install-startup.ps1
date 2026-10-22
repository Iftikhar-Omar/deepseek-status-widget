# Adds the widget to the current user's Startup folder so it appears on every sign-in.
# Run:  powershell -ExecutionPolicy Bypass -File .\install-startup.ps1
# Undo: delete the shortcut it prints at the end.

$ErrorActionPreference = 'Stop'

$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'DeepSeek Status Widget.lnk'
$vbs = Join-Path $PSScriptRoot 'Start Widget.vbs'

if (-not (Test-Path $vbs)) { throw "Launcher not found next to this script: $vbs" }

$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($lnkPath)
$lnk.TargetPath = 'wscript.exe'
$lnk.Arguments = '"' + $vbs + '"'
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.Description = 'DeepSeek peak/off-peak + balance widget'
$lnk.Save()

"Created: $lnkPath"
"Remove with: Remove-Item '$lnkPath'"
