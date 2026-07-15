[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$TempRoot,
    [Parameter(Mandatory = $true)][string]$WaitProcessIds
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

    foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
        if ($item.Name -in @('DeviceLogs', 'update-config.json')) { continue }
        $destination = Join-Path $target $item.Name
        $destinationFull = [IO.Path]::GetFullPath($destination)
        if (-not $destinationFull.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Destinazione non sicura: $destinationFull"
        }
        if (Test-Path -LiteralPath $destinationFull) {
            Remove-Item -LiteralPath $destinationFull -Recurse -Force
        }
        Copy-Item -LiteralPath $item.FullName -Destination $destinationFull -Recurse -Force
    }

    $launcher = Join-Path $target 'DeviceLogCapture.cmd'
    Start-Process -FilePath $launcher -WorkingDirectory $target | Out-Null
} catch {
    $logDir = Join-Path $target 'DeviceLogs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $errorLog = Join-Path $logDir 'update-error.log'
    "[$(Get-Date -Format o)] $($_.Exception.ToString())" | Set-Content -LiteralPath $errorLog -Encoding UTF8
} finally {
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
