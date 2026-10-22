' Launch the DeepSeek status widget without a console window.
' Resolves its own folder, so the repository can live anywhere.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\PeakWidget.ps1""", 0, False
