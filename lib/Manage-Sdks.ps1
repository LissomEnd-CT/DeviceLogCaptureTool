$script:ManagedSdkRoot = Join-Path $env:LOCALAPPDATA 'DeviceLogCaptureTool\Sdk'
$script:ManagedNodeRoot = Join-Path $script:ManagedSdkRoot 'node'
$script:ManagedWebOsRoot = Join-Path $script:ManagedSdkRoot 'webos-cli'
$script:ManagedAndroidRoot = Join-Path $script:ManagedSdkRoot 'android\platform-tools'
$script:ManagedTizenRoot = Join-Path $script:ManagedSdkRoot 'tizen\tools'

function Add-SdkSessionPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $parts = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts -notcontains $Path) { $env:Path = "$Path;$env:Path" }
}

function Initialize-ManagedSdkPaths {
    # Reverse order because each path is prepended. Managed tools then win over stale global copies.
    Add-SdkSessionPath $script:ManagedTizenRoot
    Add-SdkSessionPath $script:ManagedAndroidRoot
    Add-SdkSessionPath $script:ManagedWebOsRoot
    Add-SdkSessionPath $script:ManagedNodeRoot
}

function Get-ManagedSdkFallbacks([string]$Tool) {
    switch ($Tool) {
        'node' { return @((Join-Path $script:ManagedNodeRoot 'node.exe')) }
        'npm' { return @((Join-Path $script:ManagedNodeRoot 'npm.cmd')) }
        'ares-inspect' { return @((Join-Path $script:ManagedWebOsRoot 'ares-inspect.cmd')) }
        'ares-setup-device' { return @((Join-Path $script:ManagedWebOsRoot 'ares-setup-device.cmd')) }
        'adb' { return @((Join-Path $script:ManagedAndroidRoot 'adb.exe')) }
        'sdb' { return @((Join-Path $script:ManagedTizenRoot 'sdb.exe')) }
        default { return @() }
    }
}

function New-SdkTempDirectory([string]$Name) {
    $path = Join-Path $env:TEMP "DeviceLogCapture-$Name-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-OfficialDownload([string]$Uri, [string]$Destination) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "  Download: $Uri" -ForegroundColor DarkGray
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "Download vuoto o non disponibile: $Uri"
    }
}

function Install-NodeLtsManaged {
    Write-Host 'Node.js LTS: ricerca della release ufficiale...' -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Windows PowerShell 5.1 already returns the top-level JSON array as Object[].
    # Wrapping the command in @() would create a nested array and merge all version fields.
    $releases = Invoke-RestMethod -UseBasicParsing -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
    $release = $null
    foreach ($candidate in $releases) {
        $majorMatch = [regex]::Match([string]$candidate.version, '^v(\d+)\.')
        if ($candidate.lts -and $majorMatch.Success -and [int]$majorMatch.Groups[1].Value -ge 22 -and
            @($candidate.files) -contains 'win-x64-zip') {
            $release = $candidate
            break
        }
    }
    if (-not $release) { throw 'Nessuna release Node.js LTS Windows x64 compatibile trovata.' }

    $version = [string]$release.version
    $packageName = "node-$version-win-x64.zip"
    $baseUrl = "https://nodejs.org/dist/$version"
    $currentNode = Get-ToolPath @('node.exe', 'node') (Get-ManagedSdkFallbacks 'node')
    if ($currentNode) {
        $currentText = (& $currentNode --version 2>&1 | Select-Object -First 1).ToString().Trim()
        if ((Convert-ToVersion $currentText) -ge (Convert-ToVersion $version)) {
            Write-Host "  [OK] Node.js $currentText è già aggiornato." -ForegroundColor Green
            return
        }
    }

    $temp = New-SdkTempDirectory 'node'
    try {
        $zip = Join-Path $temp $packageName
        $sums = Join-Path $temp 'SHASUMS256.txt'
        Invoke-OfficialDownload "$baseUrl/$packageName" $zip
        Invoke-OfficialDownload "$baseUrl/SHASUMS256.txt" $sums
        $sumLine = Get-Content -LiteralPath $sums | Where-Object { $_ -match "^([a-fA-F0-9]{64})\s+$([regex]::Escape($packageName))$" } | Select-Object -First 1
        if (-not $sumLine) { throw 'Checksum Node.js non trovato nel manifest ufficiale.' }
        $expected = ([regex]::Match($sumLine, '^[a-fA-F0-9]{64}')).Value.ToUpperInvariant()
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) { throw 'Verifica SHA-256 del pacchetto Node.js fallita.' }

        $extract = Join-Path $temp 'extract'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $packageRoot = Join-Path $extract "node-$version-win-x64"
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'node.exe'))) { throw 'node.exe non trovato nel pacchetto ufficiale.' }
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:ManagedNodeRoot) -Force | Out-Null
        if (Test-Path -LiteralPath $script:ManagedNodeRoot) { Remove-Item -LiteralPath $script:ManagedNodeRoot -Recurse -Force }
        Move-Item -LiteralPath $packageRoot -Destination $script:ManagedNodeRoot
        Initialize-ManagedSdkPaths
        $installed = & (Join-Path $script:ManagedNodeRoot 'node.exe') --version 2>&1
        Write-Host "  [OK] Node.js $installed installato e verificato." -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-WebOsCliManaged {
    Write-Host 'webOS CLI: installazione/aggiornamento tramite npm...' -ForegroundColor Cyan
    $npm = Get-ToolPath @('npm.cmd', 'npm') (Get-ManagedSdkFallbacks 'npm')
    if (-not $npm) {
        Install-NodeLtsManaged
        $npm = Get-ToolPath @('npm.cmd', 'npm') (Get-ManagedSdkFallbacks 'npm')
    }
    if (-not $npm) { throw "npm non è disponibile dopo l'installazione di Node.js." }
    New-Item -ItemType Directory -Path $script:ManagedWebOsRoot -Force | Out-Null
    & $npm install --global --prefix $script:ManagedWebOsRoot '--allow-scripts=@webos-tools/cli,fsevents,ssh2' '@webos-tools/cli@latest'
    if ($LASTEXITCODE -ne 0) { throw "npm ha terminato con codice $LASTEXITCODE." }
    Initialize-ManagedSdkPaths
    $inspect = Join-Path $script:ManagedWebOsRoot 'ares-inspect.cmd'
    $setup = Join-Path $script:ManagedWebOsRoot 'ares-setup-device.cmd'
    if (-not (Test-Path -LiteralPath $inspect) -or -not (Test-Path -LiteralPath $setup)) {
        throw 'Il pacchetto npm non ha installato tutti i comandi Ares richiesti.'
    }
    $versionOutput = & $inspect --version 2>&1
    $verifyExitCode = $LASTEXITCODE
    $version = ($versionOutput | Select-Object -First 1).ToString().Trim()
    if ($verifyExitCode -ne 0) { throw 'ares-inspect è stato installato ma la verifica è fallita.' }
    Write-Host "  [OK] webOS CLI $version installata e verificata." -ForegroundColor Green
}

function Install-AndroidPlatformToolsManaged {
    Write-Host 'Android Platform Tools: download del pacchetto ufficiale Google...' -ForegroundColor Cyan
    $temp = New-SdkTempDirectory 'android'
    try {
        $zip = Join-Path $temp 'platform-tools-latest-windows.zip'
        Invoke-OfficialDownload 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' $zip
        $extract = Join-Path $temp 'extract'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $packageRoot = Join-Path $extract 'platform-tools'
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'adb.exe'))) { throw 'adb.exe non trovato nel pacchetto ufficiale.' }
        $activeAdb = Get-ToolPath @('adb.exe', 'adb') (Get-ManagedSdkFallbacks 'adb')
        if ($activeAdb) { & $activeAdb kill-server 2>&1 | Out-Null }
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:ManagedAndroidRoot) -Force | Out-Null
        if (Test-Path -LiteralPath $script:ManagedAndroidRoot) { Remove-Item -LiteralPath $script:ManagedAndroidRoot -Recurse -Force }
        Move-Item -LiteralPath $packageRoot -Destination $script:ManagedAndroidRoot
        Initialize-ManagedSdkPaths
        $version = (& (Join-Path $script:ManagedAndroidRoot 'adb.exe') version 2>&1 | Select-Object -First 1).ToString().Trim()
        if ($LASTEXITCODE -ne 0) { throw 'ADB è stato installato ma la verifica è fallita.' }
        Write-Host "  [OK] $version" -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-LatestTizenSdbPackage {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $baseUrl = 'https://download.tizen.org/sdk/tizenstudio/official/binary/'
    $page = (Invoke-WebRequest -UseBasicParsing -Uri $baseUrl -TimeoutSec 60).Content
    $matches = [regex]::Matches($page, 'href="(sdb_([0-9]+(?:\.[0-9]+)*)_windows-64\.zip)"', 'IgnoreCase')
    $packages = foreach ($match in $matches) {
        [pscustomobject]@{ Name = $match.Groups[1].Value; Version = Convert-ToVersion $match.Groups[2].Value }
    }
    $latest = $packages | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $latest) { throw 'Il repository ufficiale Tizen non espone un pacchetto SDB Windows x64.' }
    return [pscustomobject]@{ Name = $latest.Name; Version = $latest.Version; Url = "$baseUrl$($latest.Name)" }
}

function Install-TizenSdbManaged {
    Write-Host 'Tizen SDB: ricerca del pacchetto ufficiale più recente...' -ForegroundColor Cyan
    $package = Get-LatestTizenSdbPackage
    $temp = New-SdkTempDirectory 'tizen'
    try {
        $zip = Join-Path $temp $package.Name
        Invoke-OfficialDownload $package.Url $zip
        $extract = Join-Path $temp 'extract'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $packageRoot = Join-Path $extract 'data\tools'
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'sdb.exe'))) { throw 'sdb.exe non trovato nel pacchetto ufficiale.' }
        $activeSdb = Get-ToolPath @('sdb.exe', 'sdb') (Get-ManagedSdkFallbacks 'sdb')
        if ($activeSdb) { & $activeSdb kill-server 2>&1 | Out-Null }
        Get-Process sdb -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:ManagedTizenRoot) -Force | Out-Null
        if (Test-Path -LiteralPath $script:ManagedTizenRoot) { Remove-Item -LiteralPath $script:ManagedTizenRoot -Recurse -Force }
        Move-Item -LiteralPath $packageRoot -Destination $script:ManagedTizenRoot
        Initialize-ManagedSdkPaths
        $version = (& (Join-Path $script:ManagedTizenRoot 'sdb.exe') version 2>&1 | Select-Object -First 1).ToString().Trim()
        if ($LASTEXITCODE -ne 0) { throw 'SDB è stato installato ma la verifica è fallita.' }
        Write-Host "  [OK] Tizen SDB $version installato e verificato." -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SdkInstallAction([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        return $true
    } catch {
        Write-Host "  [ERRORE] $Name`: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Show-SdkManager {
    do {
        Write-Host
        Write-Host 'Gestione automatica SDK e dipendenze' -ForegroundColor Yellow
        Write-Host "Cartella gestita: $script:ManagedSdkRoot" -ForegroundColor DarkGray
        Write-Host '  [1] Installa/aggiorna Node.js LTS'
        Write-Host '  [2] Installa/aggiorna webOS CLI (Ares)'
        Write-Host '  [3] Installa/aggiorna Android Platform Tools (ADB)'
        Write-Host '  [4] Installa/aggiorna Tizen SDB'
        Write-Host '  [5] Installa/aggiorna tutto'
        Write-Host '  [0] Torna alla cattura'
        $choice = Read-Host 'Selezione'
        $actions = @(switch ($choice) {
            '1' { [pscustomobject]@{ Name = 'Node.js LTS'; Action = { Install-NodeLtsManaged } } }
            '2' { [pscustomobject]@{ Name = 'webOS CLI'; Action = { Install-WebOsCliManaged } } }
            '3' { [pscustomobject]@{ Name = 'Android Platform Tools'; Action = { Install-AndroidPlatformToolsManaged } } }
            '4' { [pscustomobject]@{ Name = 'Tizen SDB'; Action = { Install-TizenSdbManaged } } }
            '5' {
                [pscustomobject]@{ Name = 'Node.js LTS'; Action = { Install-NodeLtsManaged } }
                [pscustomobject]@{ Name = 'webOS CLI'; Action = { Install-WebOsCliManaged } }
                [pscustomobject]@{ Name = 'Android Platform Tools'; Action = { Install-AndroidPlatformToolsManaged } }
                [pscustomobject]@{ Name = 'Tizen SDB'; Action = { Install-TizenSdbManaged } }
            }
            '0' { }
            default { $null }
        })
        if ($choice -notin @('0', '1', '2', '3', '4', '5')) {
            Write-Host 'Selezione non valida.' -ForegroundColor Yellow
            continue
        }
        foreach ($entry in $actions) { [void](Invoke-SdkInstallAction $entry.Name $entry.Action) }
        if ($choice -ne '0') {
            Write-Host
            Show-DependencyChecks | Out-Null
        }
    } while ($choice -ne '0')
}
