[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Manage-Sdks.ps1')

$temp = Join-Path $env:TEMP "DeviceLogCapture-sdk-smoke-$([guid]::NewGuid().ToString('N'))"
$destination = Join-Path $temp 'managed\tool'
$sourceOne = Join-Path $temp 'source-one'
$sourceTwo = Join-Path $temp 'source-two'
try {
    New-Item -ItemType Directory -Path $destination,$sourceOne -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $destination 'version.txt') -Value 'old' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $sourceOne 'version.txt') -Value 'new' -Encoding ASCII
    $verified = Install-ManagedDirectoryAtomically $sourceOne $destination {
        param($installedRoot)
        return (Get-Content -LiteralPath (Join-Path $installedRoot 'version.txt') -Raw).Trim()
    }
    if ($verified -ne 'new') { throw 'Installazione atomica non verificata.' }

    New-Item -ItemType Directory -Path $sourceTwo -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sourceTwo 'version.txt') -Value 'broken' -Encoding ASCII
    try {
        Install-ManagedDirectoryAtomically $sourceTwo $destination { throw 'verifica simulata fallita' }
        throw 'La verifica simulata avrebbe dovuto fallire.'
    } catch {
        if ($_.Exception.Message -eq 'La verifica simulata avrebbe dovuto fallire.') { throw }
    }
    $restored = (Get-Content -LiteralPath (Join-Path $destination 'version.txt') -Raw).Trim()
    if ($restored -ne 'new') { throw 'Rollback SDK non riuscito.' }
    Write-Host 'SDK smoke tests: OK'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
