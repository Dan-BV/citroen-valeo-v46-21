# Pull the phone's Bluetooth HCI snoop log off the device.
#
# The snoop lives in /data/misc/bluetooth/logs, which is unreadable by the adb
# shell user, so the only unrooted way in is a bugreport: dumpstate copies that
# whole directory into the zip. See tools/btsnoop/README.md.
#
# The BT stack keeps ONE current file (BT_HCI_<date>.cfa.curf) and does not keep
# the previous one across a stack restart, so a reboot - or a flat battery -
# destroys the capture. Pull before rebooting.
#
# Usage: pwsh -File pull_btsnoop.ps1 [-Tag drive]

param([string]$Tag = "")

$ErrorActionPreference = "Stop"

$root    = Split-Path -Parent $PSScriptRoot | Split-Path -Parent
$adb     = Join-Path $root "tools\platform-tools\adb.exe"
$dataDir = Join-Path $PSScriptRoot "data"
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmm"
$name    = if ($Tag) { "$stamp`_$Tag" } else { $stamp }

if (-not (Test-Path $adb)) { throw "adb not found at $adb" }
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$devices = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "\sdevice$" }
if (-not $devices) { throw "no device in 'adb devices' - check USB and the debugging prompt" }

# Warn early: without 'full' the snoop file will be missing or truncated.
$mode = (& $adb shell getprop persist.bluetooth.btsnooplogmode).Trim()
if ($mode -ne "full") {
    Write-Warning "persist.bluetooth.btsnooplogmode is '$mode', expected 'full' - the capture may be empty"
}

$zip = Join-Path $dataDir "bugreport_$name.zip"
Write-Host "Generating bugreport (a few minutes)..."
& $adb bugreport $zip
if (-not (Test-Path $zip)) { throw "bugreport was not produced" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entries = $archive.Entries | Where-Object { $_.FullName -like "FS/data/misc/bluetooth/logs/*" }
    if (-not $entries) {
        Write-Warning "no Bluetooth log in the bugreport - snoop logging was off, or the file was lost on reboot"
    }
    foreach ($e in $entries) {
        $out = Join-Path $dataDir "$name`_$($e.Name)"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
        $mtime = $e.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host ("  {0}  {1,9:N0} bytes  last written {2}" -f (Split-Path -Leaf $out), $e.Length, $mtime)
    }
} finally {
    $archive.Dispose()
}

# The app's own frame log carries the application-level handshake (adapter
# serial, firmware versions, model) and survives a reboot, unlike the snoop.
$appLog = "/sdcard/Android/data/com.us.thinkdiag.plus/files/ThinkCar/ThinkDiag/Log/DiagnoseLog"
$latest = (& $adb shell "ls -t $appLog 2>/dev/null | head -2") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
foreach ($f in $latest) {
    & $adb pull "$appLog/$f" (Join-Path $dataDir "$name`_$f") 2>&1 | Out-Null
    Write-Host "  pulled app log: $f"
}

Write-Host "`nDone -> $dataDir"
Write-Host "Next: python tools/btsnoop/parse_btsnoop.py <the .curf file>"
