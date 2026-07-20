[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$updater = Join-Path $root 'lib\Apply-Update.ps1'
$base = Join-Path $env:TEMP "DeviceLogCapture-updater-smoke-$([guid]::NewGuid().ToString('N'))"

function New-TestPackage([string]$Path, [string]$Marker) {
    New-Item -ItemType Directory -Path (Join-Path $Path 'lib') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'DeviceLogCapture.cmd') -Value "@echo off`r`necho $Marker" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Path 'DeviceLogCapture.ps1') -Value "Write-Output '$Marker'" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Path 'VERSION') -Value '9.9.9' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Path 'lib\cdp-capture.js') -Value "console.log('$Marker');" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Path 'lib\device-profiles.json') -Value '{"schemaVersion":1,"profiles":[]}' -Encoding ASCII
}

try {
    $target = Join-Path $base 'success-target'
    $temp = Join-Path $base 'success-temp'
    $source = Join-Path $temp 'source'
    New-TestPackage $target 'old'
    New-TestPackage $source 'new'
    New-Item -ItemType Directory -Path (Join-Path $target 'DeviceLogs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'DeviceLogs\preserve.log') -Value 'local' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $target 'update-config.json') -Value '{"local":true}' -Encoding ASCII

    & $updater -TargetRoot $target -SourceRoot $source -TempRoot $temp -WaitProcessIds '999999' -ExpectedVersion '9.9.9' -NoRestart
    if ((Get-Content -LiteralPath (Join-Path $target 'DeviceLogCapture.ps1') -Raw) -notmatch 'new') { throw 'Aggiornamento riuscito non applicato.' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'DeviceLogs\preserve.log'))) { throw 'I log locali non sono stati preservati.' }
    if ((Get-Content -LiteralPath (Join-Path $target 'update-config.json') -Raw) -notmatch 'local') { throw 'La configurazione locale non è stata preservata.' }

    $target = Join-Path $base 'rollback-target'
    $temp = Join-Path $base 'rollback-temp'
    $source = Join-Path $temp 'source'
    New-TestPackage $target 'old'
    New-TestPackage $source 'new'
    function Copy-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force)
        if ($Destination -like '*DeviceLogCapture.ps1') { throw 'errore copia simulato' }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
    & $updater -TargetRoot $target -SourceRoot $source -TempRoot $temp -WaitProcessIds '999999' -ExpectedVersion '9.9.9' -NoRestart
    if ((Get-Content -LiteralPath (Join-Path $target 'DeviceLogCapture.cmd') -Raw) -notmatch 'old') { throw 'Rollback aggiornamento non riuscito.' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'DeviceLogCapture.ps1'))) { throw 'Rollback incompleto: file precedente assente.' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'DeviceLogs\update-error.log'))) { throw 'Errore aggiornamento non registrato.' }

    Remove-Item Function:\Copy-Item -ErrorAction SilentlyContinue
    $target = Join-Path $base 'unsafe-target'
    $temp = Join-Path $base 'unsafe-temp'
    $source = Join-Path $temp 'source'
    New-TestPackage $target 'old'
    New-TestPackage $source 'new'
    Set-Content -LiteralPath (Join-Path $source 'capture.har') -Value '{}' -Encoding ASCII
    & $updater -TargetRoot $target -SourceRoot $source -TempRoot $temp -WaitProcessIds '999999' -ExpectedVersion '9.9.9' -NoRestart
    if ((Get-Content -LiteralPath (Join-Path $target 'DeviceLogCapture.cmd') -Raw) -notmatch 'old') { throw 'Un pacchetto con log utente è stato applicato.' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'DeviceLogs\update-error.log'))) { throw 'Il rifiuto del pacchetto non è stato registrato.' }

    Write-Host 'Updater smoke tests: OK'
} finally {
    Remove-Item Function:\Copy-Item -ErrorAction SilentlyContinue
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
