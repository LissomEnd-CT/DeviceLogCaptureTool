[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$TempRoot,
    [Parameter(Mandatory = $true)][string]$WaitProcessIds,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
$source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$temp = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\')
$driveRoot = [IO.Path]::GetPathRoot($target).TrimEnd('\')
if ($target.Length -lt 10 -or $target -eq $driveRoot) { throw 'Cartella target non sicura.' }
if (-not (Test-Path -LiteralPath (Join-Path $source 'DeviceLogCapture.cmd'))) { throw 'Pacchetto sorgente non valido.' }

try {
    $deadline = (Get-Date).AddSeconds(30)
    $ids = @($WaitProcessIds -split ',' | ForEach-Object { if ($_ -match '^\d+$') { [int]$_ } })
    while ((Get-Date) -lt $deadline) {
        $running = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }

    $required = @('DeviceLogCapture.cmd', 'DeviceLogCapture.ps1', 'VERSION', 'lib\cdp-capture.js', 'lib\device-profiles.json')
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative))) { throw "File richiesto assente nel pacchetto: $relative" }
    }
    $sourceVersion = (Get-Content -LiteralPath (Join-Path $source 'VERSION') -Raw -Encoding UTF8).Trim()
    if ($sourceVersion -ne $ExpectedVersion) { throw "Versione pacchetto inattesa: $sourceVersion (attesa: $ExpectedVersion)." }
    $unexpectedLogs = @(Get-ChildItem -LiteralPath $source -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.har', '.log') })
    if ($unexpectedLogs.Count) { throw 'Il pacchetto contiene file HAR/LOG e non verrà installato.' }

    $backupRoot = Join-Path $temp 'backup'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $installedNames = [System.Collections.Generic.List[string]]::new()
    $backedUpNames = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
            if ($item.Name -in @('DeviceLogs', 'update-config.json')) { continue }
            $destinationFull = [IO.Path]::GetFullPath((Join-Path $target $item.Name))
            if (-not $destinationFull.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Destinazione non sicura: $destinationFull"
            }
            if (Test-Path -LiteralPath $destinationFull) {
                Move-Item -LiteralPath $destinationFull -Destination (Join-Path $backupRoot $item.Name)
                $backedUpNames.Add($item.Name)
            }
            $installedNames.Add($item.Name)
            Copy-Item -LiteralPath $item.FullName -Destination $destinationFull -Recurse -Force
        }
        foreach ($relative in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $target $relative))) { throw "Verifica aggiornamento fallita: $relative" }
        }
    } catch {
        $updateFailure = $_
        foreach ($name in $installedNames) {
            Remove-Item -LiteralPath (Join-Path $target $name) -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($name in $backedUpNames) {
            $backupItem = Join-Path $backupRoot $name
            if (Test-Path -LiteralPath $backupItem) { Move-Item -LiteralPath $backupItem -Destination (Join-Path $target $name) -Force }
        }
        throw $updateFailure
    }

    if (-not $NoRestart) {
        $launcher = Join-Path $target 'DeviceLogCapture.cmd'
        Start-Process -FilePath $launcher -WorkingDirectory $target | Out-Null
    }
} catch {
    $logDir = Join-Path $target 'DeviceLogs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $errorLog = Join-Path $logDir 'update-error.log'
    "[$(Get-Date -Format o)] $($_.Exception.ToString())" | Set-Content -LiteralPath $errorLog -Encoding UTF8
} finally {
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
