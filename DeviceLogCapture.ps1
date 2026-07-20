[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Recorder = Join-Path $ScriptRoot 'lib\cdp-capture.js'
$OutputRoot = Join-Path $ScriptRoot 'DeviceLogs'
$VersionFile = Join-Path $ScriptRoot 'VERSION'
$UpdateConfigFile = Join-Path $ScriptRoot 'update-config.json'
$SdkManager = Join-Path $ScriptRoot 'lib\Manage-Sdks.ps1'
$DeviceProfilesFile = Join-Path $ScriptRoot 'lib\device-profiles.json'
$CurrentVersion = if (Test-Path -LiteralPath $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { '0.0.0' }
$script:CleanupActions = [System.Collections.Generic.List[scriptblock]]::new()
$script:TargetFilter = ''
$script:ExitCode = 0
$script:CompletedSuccessfully = $false
$script:GitHubHeaders = @{}
$script:DeviceProfiles = $null
$script:DiscoveryDiagnostics = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $SdkManager)) { throw "Gestore SDK non trovato: $SdkManager" }
. $SdkManager
Initialize-ManagedSdkPaths

function Write-Title {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '        DEVICE LOG CAPTURE - Network HAR + Console' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host "Versione $CurrentVersion - TV, STB, webOS, Tizen e Android WebView"
    Write-Host
}

function Get-ToolPath([string[]]$Names, [string[]]$Fallbacks = @()) {
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($candidate in $Fallbacks) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function ConvertTo-WindowsCommandLineArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            if ($backslashes) { [void]$builder.Append([string]::new([char]92, $backslashes * 2)) }
            [void]$builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes) { [void]$builder.Append([string]::new([char]92, $backslashes)) }
        [void]$builder.Append($character)
        $backslashes = 0
    }
    if ($backslashes) { [void]$builder.Append([string]::new([char]92, $backslashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-ToolText([string]$FilePath, [string[]]$Arguments = @()) {
    # ADB/SDB can write normal daemon startup messages to stderr. With the global
    # ErrorActionPreference=Stop, Windows PowerShell 5.1 would turn those into a
    # false dependency failure even when the command exits successfully.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        return (& $FilePath @Arguments 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Invoke-ToolResult([string]$FilePath, [string[]]$Arguments = @()) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $FilePath @Arguments 2>&1 | Out-String)
        return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Show-DependencyChecks {
    Write-Host 'Verifica dipendenze e configurazione:' -ForegroundColor Yellow
    $rows = [System.Collections.Generic.List[object]]::new()

    $node = Get-ToolPath @('node.exe', 'node') (@(Get-ManagedSdkFallbacks 'node') + @('C:\Program Files\nodejs\node.exe'))
    $nodeReady = $false
    $nodeDetail = 'Non trovato - installare Node.js 22 o successivo'
    if ($node) {
        try {
            $nodeVersion = (& $node --version 2>&1 | Select-Object -First 1).ToString().Trim()
            $majorMatch = [regex]::Match($nodeVersion, 'v?(\d+)')
            $nodeReady = $majorMatch.Success -and [int]$majorMatch.Groups[1].Value -ge 22
            $nodeDetail = if ($nodeReady) { "$nodeVersion - $node" } else { "$nodeVersion - serve versione 22+" }
        } catch { $nodeDetail = "Errore eseguendo $node" }
    }
    $rows.Add([pscustomobject]@{ Dipendenza = 'Node.js'; Stato = if ($nodeReady) { 'OK' } else { 'ERRORE' }; Dettagli = $nodeDetail })

    $ares = Get-ToolPath @('ares-inspect.cmd', 'ares-inspect') (@(Get-ManagedSdkFallbacks 'ares-inspect') + @("$env:APPDATA\npm\ares-inspect.cmd"))
    $setup = Get-ToolPath @('ares-setup-device.cmd', 'ares-setup-device') (@(Get-ManagedSdkFallbacks 'ares-setup-device') + @("$env:APPDATA\npm\ares-setup-device.cmd"))
    if ($ares -and $setup) {
        try {
            $aresDevices = Invoke-ToolText $setup @('--list')
            $deviceCount = @([regex]::Matches($aresDevices, '(?m)^\S.*?@[^:]+:\d+\s+')).Count
            $aresState = if ($deviceCount -gt 0) { 'OK' } else { 'WARN' }
            $aresDetail = "webOS CLI presente; device configurati: $deviceCount"
        } catch { $aresState = 'WARN'; $aresDetail = 'webOS CLI presente, configurazione non leggibile' }
    } else { $aresState = 'MANCANTE'; $aresDetail = 'Installare @webos-tools/cli' }
    $rows.Add([pscustomobject]@{ Dipendenza = 'webOS CLI'; Stato = $aresState; Dettagli = $aresDetail })

    $adb = Get-ToolPath @('adb.exe', 'adb') (@(Get-ManagedSdkFallbacks 'adb') + @('C:\platform-tools\adb.exe', "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"))
    if ($adb) {
        try {
            $adbDevices = Invoke-ToolText $adb @('devices')
            $androidReady = @([regex]::Matches($adbDevices, '(?m)^\S+\s+device\s*$')).Count
            $androidUnauthorized = @([regex]::Matches($adbDevices, '(?m)^\S+\s+unauthorized\s*$')).Count
            $adbDetail = "ADB presente; connessi: $androidReady"
            if ($androidUnauthorized) { $adbDetail += "; non autorizzati: $androidUnauthorized" }
            $adbState = 'OK'
        } catch { $adbState = 'WARN'; $adbDetail = 'ADB presente, verifica device fallita' }
    } else { $adbState = 'MANCANTE'; $adbDetail = 'Installare Android platform-tools' }
    $rows.Add([pscustomobject]@{ Dipendenza = 'ADB'; Stato = $adbState; Dettagli = $adbDetail })

    $sdb = Get-ToolPath @('sdb.exe', 'sdb') (@(Get-ManagedSdkFallbacks 'sdb') + @('C:\tizen-studio\tools\sdb.exe'))
    if ($sdb) {
        try {
            $sdbDevices = Invoke-ToolText $sdb @('devices')
            $tizenReady = @([regex]::Matches($sdbDevices, '(?m)^\S+\s+device(?:\s+.*)?$')).Count
            $sdbState = 'OK'; $sdbDetail = "SDB presente; connessi: $tizenReady"
        } catch { $sdbState = 'WARN'; $sdbDetail = 'SDB presente, verifica device fallita' }
    } else { $sdbState = 'MANCANTE'; $sdbDetail = 'Installare Tizen Studio / SDB' }
    $rows.Add([pscustomobject]@{ Dipendenza = 'SDB'; Stato = $sdbState; Dettagli = $sdbDetail })

    foreach ($row in $rows) {
        $color = if ($row.Stato -eq 'OK') { 'Green' } elseif ($row.Stato -eq 'ERRORE') { 'Red' } else { 'Yellow' }
        Write-Host ("  {0,-11} {1,-10} {2}" -f "[$($row.Stato)]", $row.Dipendenza, $row.Dettagli) -ForegroundColor $color
    }
    Write-Host
    return [pscustomobject]@{
        NodePath = $node
        NodeReady = $nodeReady
        WebOsReady = [bool]($ares -and $setup)
        AdbReady = [bool]$adb
        SdbReady = [bool]$sdb
    }
}

function Convert-ToVersion([string]$Value) {
    $clean = ($Value.Trim() -replace '^[vV]', '' -replace '[-+].*$', '')
    try { return [version]$clean } catch { return [version]'0.0.0' }
}

function Start-SelfUpdate($Release, $Config) {
    $assetName = if ($Config.releaseAsset) { [string]$Config.releaseAsset } else { 'DeviceLogCaptureTool.zip' }
    $asset = @($Release.assets | Where-Object { $_.name -eq $assetName }) | Select-Object -First 1
    if (-not $asset) { $asset = @($Release.assets | Where-Object { $_.name -like '*.zip' }) | Select-Object -First 1 }
    $hasAuthorization = $script:GitHubHeaders.ContainsKey('Authorization')
    $downloadUrl = if ($asset -and $hasAuthorization -and $asset.url) { $asset.url } elseif ($asset) { $asset.browser_download_url } else { $Release.zipball_url }
    if (-not $downloadUrl -or $downloadUrl -notmatch '^https://') { throw 'La release non contiene un download ZIP HTTPS valido.' }

    $tempRoot = Join-Path $env:TEMP "DeviceLogCapture-update-$([guid]::NewGuid().ToString('N'))"
    $zipPath = Join-Path $tempRoot 'release.zip'
    $extractPath = Join-Path $tempRoot 'extracted'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    Write-Host 'Download aggiornamento...' -ForegroundColor Cyan
    $downloadHeaders = @{}
    foreach ($key in $script:GitHubHeaders.Keys) { $downloadHeaders[$key] = $script:GitHubHeaders[$key] }
    $downloadHeaders['Accept'] = 'application/octet-stream'
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $zipPath -TimeoutSec 60 -Headers $downloadHeaders
    if ($asset -and $asset.digest -and ([string]$asset.digest) -match '^sha256:([a-fA-F0-9]{64})$') {
        $expectedDigest = $Matches[1].ToUpperInvariant()
        $actualDigest = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualDigest -ne $expectedDigest) { throw "SHA-256 dell'aggiornamento non corrispondente alla release GitHub." }
        Write-Host "Integrità SHA-256 dell'aggiornamento verificata." -ForegroundColor Green
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

    $launcher = Get-ChildItem -LiteralPath $extractPath -Filter 'DeviceLogCapture.cmd' -File -Recurse | Select-Object -First 1
    if (-not $launcher) { throw 'Il pacchetto della release non contiene DeviceLogCapture.cmd.' }
    $sourceRoot = $launcher.Directory.FullName
    $packageVersionFile = Join-Path $sourceRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $packageVersionFile)) { throw 'Il pacchetto della release non contiene VERSION.' }
    $packageVersion = (Get-Content -LiteralPath $packageVersionFile -Raw -Encoding UTF8).Trim()
    $releaseVersion = ([string]$Release.tag_name).Trim() -replace '^[vV]', ''
    if ((Convert-ToVersion $packageVersion) -ne (Convert-ToVersion $releaseVersion)) {
        throw "La versione del pacchetto ($packageVersion) non corrisponde alla release ($releaseVersion)."
    }
    $updaterSource = Join-Path $ScriptRoot 'lib\Apply-Update.ps1'
    if (-not (Test-Path -LiteralPath $updaterSource)) { throw 'Helper di aggiornamento mancante.' }
    $updaterTemp = Join-Path $tempRoot 'Apply-Update.ps1'
    Copy-Item -LiteralPath $updaterSource -Destination $updaterTemp -Force

    $waitIds = @($PID)
    try {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        $parentProcess = Get-Process -Id $parent.ParentProcessId -ErrorAction SilentlyContinue
        if ($parentProcess -and $parentProcess.ProcessName -eq 'cmd') { $waitIds += $parent.ParentProcessId }
    } catch { }
    $idText = $waitIds -join ','
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$updaterTemp`" -TargetRoot `"$ScriptRoot`" -SourceRoot `"$sourceRoot`" -TempRoot `"$tempRoot`" -WaitProcessIds `"$idText`" -ExpectedVersion `"$releaseVersion`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    Write-Host 'Aggiornamento preparato. Il tool verrà riaperto automaticamente.' -ForegroundColor Green
}

function Test-ForUpdates {
    if (-not (Test-Path -LiteralPath $UpdateConfigFile)) {
        Write-Host '[UPDATE] Configurazione GitHub assente; controllo saltato.' -ForegroundColor Yellow
        Write-Host
        return $false
    }
    try { $config = Get-Content $UpdateConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Write-Host '[UPDATE] update-config.json non valido; controllo saltato.' -ForegroundColor Yellow
        Write-Host
        return $false
    }
    $repository = ([string]$config.githubRepository).Trim()
    $repository = $repository -replace '^https://github\.com/', '' -replace '\.git$', ''
    if ($repository -match '^OWNER/' -or $repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        Write-Host '[UPDATE] Repository GitHub non ancora configurato.' -ForegroundColor DarkYellow
        Write-Host
        return $false
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'DeviceLogCaptureTool'; 'Accept' = 'application/vnd.github+json' }
        $script:GitHubHeaders = $headers
        $apiUrl = "https://api.github.com/repos/$repository/releases/latest"
        $release = Invoke-RestMethod -UseBasicParsing -Uri $apiUrl -TimeoutSec 10 -Headers $headers
        $latestText = ([string]$release.tag_name) -replace '^[vV]', ''
        if ((Convert-ToVersion $latestText) -le (Convert-ToVersion $CurrentVersion)) {
            Write-Host "[UPDATE] Versione $CurrentVersion aggiornata." -ForegroundColor Green
            Write-Host
            return $false
        }
        Write-Host "Nuova versione disponibile: $latestText (installata: $CurrentVersion)" -ForegroundColor Yellow
        $answer = Read-Host 'Aggiornare adesso? [s/N - INVIO per più tardi]'
        if ($answer -notmatch '^(?i:s|si|sì|y|yes)$') {
            Write-Host 'Aggiornamento rimandato.' -ForegroundColor DarkYellow
            Write-Host
            return $false
        }
        Start-SelfUpdate $release $config
        return $true
    } catch {
        Write-Host "[UPDATE] Controllo non riuscito: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'Il tool continuerà normalmente.' -ForegroundColor DarkGray
        Write-Host
        return $false
    }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Stop-ProcessTree([int]$ProcessId) {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) { Stop-ProcessTree -ProcessId $child.ProcessId }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Get-IPv4([string]$Text) {
    foreach ($match in [regex]::Matches($Text, '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)')) {
        $address = $null
        if ([Net.IPAddress]::TryParse($match.Value, [ref]$address) -and $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
            return $address.ToString()
        }
    }
    return $null
}

function Get-InspectorInfo([string]$Text) {
    $result = [ordered]@{ WsUrl = $null; Host = $null; Port = $null; Scheme = 'http' }
    $wsMatch = [regex]::Match($Text, 'wss?://[^\s"'']+', 'IgnoreCase')
    if ($wsMatch.Success -and $Text -notmatch '[?&]ws=') {
        $result.WsUrl = [Net.WebUtility]::HtmlDecode($wsMatch.Value.TrimEnd(')', ']', ',', ';'))
        try {
            $wsUri = [Uri]$result.WsUrl
            $result.Host = $wsUri.Host
            $result.Port = $wsUri.Port
            $result.Scheme = if ($wsUri.Scheme -eq 'wss') { 'https' } else { 'http' }
        } catch { }
        return [pscustomobject]$result
    }

    $queryMatch = [regex]::Match($Text, '[?&]ws=([^&\s"''<>]+)', 'IgnoreCase')
    if ($queryMatch.Success) {
        $decoded = [Uri]::UnescapeDataString($queryMatch.Groups[1].Value)
        $pageUsesTls = $Text -match 'https://'
        if ($decoded -notmatch '^wss?://') { $decoded = if ($pageUsesTls) { "wss://$decoded" } else { "ws://$decoded" } }
        try {
            $decodedUri = [Uri]$decoded
            if ($decodedUri.Host -in @('0.0.0.0', '[::]', '::')) {
                $pageMatch = [regex]::Match($Text, 'https?://([^/:\s]+)', 'IgnoreCase')
                if ($pageMatch.Success) {
                    $builder = [UriBuilder]$decodedUri
                    $builder.Host = $pageMatch.Groups[1].Value
                    $decoded = $builder.Uri.AbsoluteUri
                }
            }
        } catch { }
        $result.WsUrl = $decoded
        try {
            $decodedUri = [Uri]$decoded
            $result.Host = $decodedUri.Host
            $result.Port = $decodedUri.Port
            $result.Scheme = if ($decodedUri.Scheme -eq 'wss') { 'https' } else { 'http' }
        } catch { }
        return [pscustomobject]$result
    }

    $urlMatch = [regex]::Match($Text, '(?<scheme>https?|inspector)://(?<host>[^/:\s]+)(?::(?<port>\d+))?', 'IgnoreCase')
    if ($urlMatch.Success) {
        $scheme = $urlMatch.Groups['scheme'].Value.ToLowerInvariant()
        $result.Scheme = if ($scheme -eq 'https') { 'https' } else { 'http' }
        $result.Host = $urlMatch.Groups['host'].Value
        $result.Port = if ($urlMatch.Groups['port'].Success) {
            [int]$urlMatch.Groups['port'].Value
        } elseif ($scheme -eq 'https') {
            443
        } elseif ($scheme -eq 'inspector') {
            9224
        } else {
            80
        }
        return [pscustomobject]$result
    }
    return [pscustomobject]$result
}

function ConvertTo-ReachableWebSocket([string]$WsUrl, [string]$HostName, [int]$Port) {
    if ([string]::IsNullOrWhiteSpace($WsUrl)) { return $null }
    try {
        $uri = [Uri]$WsUrl
        if ($uri.Scheme -notin @('ws', 'wss')) { return $null }
        $builder = [UriBuilder]$uri
        $builder.Host = $HostName
        $builder.Port = $Port
        return $builder.Uri.AbsoluteUri
    } catch {
        return $null
    }
}

function ConvertTo-CdpTargetList($Response) {
    if ($null -eq $Response) { return @() }
    if ($Response.PSObject.Properties['targets']) { $items = @($Response.targets) }
    elseif ($Response -is [Array]) { $items = @($Response) }
    elseif ($Response.PSObject.Properties['id'] -or $Response.PSObject.Properties['webSocketDebuggerUrl'] -or $Response.PSObject.Properties['websocketDebuggerUrl']) { $items = @($Response) }
    else {
        $items = @($Response.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object {
            $_ -and ($_.PSObject.Properties['id'] -or $_.PSObject.Properties['webSocketDebuggerUrl'] -or $_.PSObject.Properties['websocketDebuggerUrl'])
        })
    }
    return @($items | Where-Object {
        $_ -and ([string]$_.type -ne 'browser') -and ($_.id -or $_.webSocketDebuggerUrl -or $_.websocketDebuggerUrl -or $_.webSocketUrl)
    })
}

function Get-CdpTargets([string]$HostName, [int]$Port, [int]$TimeoutSeconds = 3, [string]$Scheme = 'http') {
    if ($Scheme -notin @('http', 'https')) { throw "Schema discovery non supportato: $Scheme" }
    foreach ($route in @('/json/list', '/json')) {
        try {
            $response = Invoke-RestMethod -Uri "${Scheme}://${HostName}:$Port$route" -TimeoutSec $TimeoutSeconds
            $items = @(ConvertTo-CdpTargetList $response)
            if ($items.Count -gt 0) { return $items }
            $script:DiscoveryDiagnostics.Add("${HostName}:$Port$route ha risposto senza target pagina.")
        } catch {
            $script:DiscoveryDiagnostics.Add("${HostName}:$Port$route non disponibile: $($_.Exception.Message)")
        }
    }
    return @()
}

function Wait-CdpTargets([string]$HostName, [int]$Port, [int]$TimeoutSeconds = 12, [string]$Scheme = 'http') {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $targets = @(Get-CdpTargets $HostName $Port 1 $Scheme)
        if ($targets.Count) { return $targets }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @()
}

function Get-InspectorLandingConnection([string]$HostName, [int]$Port, [string]$PathAndQuery = '/', [int]$TimeoutSeconds = 2, [string]$Scheme = 'http') {
    if ($Scheme -notin @('http', 'https')) { throw "Schema landing non supportato: $Scheme" }
    $paths = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($PathAndQuery)) { $paths.Add($PathAndQuery) }
    if (-not $paths.Contains('/')) { $paths.Add('/') }
    foreach ($path in $paths) {
        if (-not $path.StartsWith('/')) { $path = "/$path" }
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "${Scheme}://${HostName}:$Port$path" -TimeoutSec $TimeoutSeconds -MaximumRedirection 5
            $responseUri = if ($response.BaseResponse -and $response.BaseResponse.ResponseUri) { $response.BaseResponse.ResponseUri.AbsoluteUri } else { "${Scheme}://${HostName}:$Port$path" }
            $content = "$responseUri`n$($response.Content)"
            $info = Get-InspectorInfo $content
            if ($info.WsUrl) {
                $ws = ConvertTo-ReachableWebSocket $info.WsUrl $HostName $Port
                if ($ws) { return [pscustomobject]@{ WsUrl = $ws; Target = $null; Host = $HostName; Port = $Port } }
            }
            $pathMatch = [regex]::Match($content, '(?<path>/devtools/(?:page|browser)/[A-Za-z0-9._:-]+)', 'IgnoreCase')
            if ($pathMatch.Success) {
                $wsScheme = if ($Scheme -eq 'https') { 'wss' } else { 'ws' }
                return [pscustomobject]@{ WsUrl = "${wsScheme}://${HostName}:$Port$($pathMatch.Groups['path'].Value)"; Target = $null; Host = $HostName; Port = $Port }
            }
            $script:DiscoveryDiagnostics.Add("${HostName}:$Port$path è raggiungibile ma non espone un WebSocket inspector.")
        } catch {
            $script:DiscoveryDiagnostics.Add("Landing ${HostName}:$Port$path non disponibile: $($_.Exception.Message)")
        }
    }
    return $null
}

function Get-DeviceProfiles {
    if ($script:DeviceProfiles) { return @($script:DeviceProfiles) }
    if (-not (Test-Path -LiteralPath $DeviceProfilesFile)) {
        throw "Catalogo profili device non trovato: $DeviceProfilesFile"
    }
    # Windows PowerShell 5.1 interpreta l'UTF-8 senza BOM come ANSI se non viene
    # specificato l'encoding. Il catalogo e distribuito come UTF-8 standard.
    try { $catalog = Get-Content -LiteralPath $DeviceProfilesFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Catalogo profili device non valido: $($_.Exception.Message)" }
    if ([int]$catalog.schemaVersion -ne 1) { throw "Versione catalogo profili non supportata: $($catalog.schemaVersion)" }
    $profiles = @($catalog.profiles)
    if ($profiles.Count -eq 0) { throw 'Il catalogo profili device è vuoto.' }
    $ids = @{}
    foreach ($profile in $profiles) {
        $id = ([string]$profile.id).Trim()
        if ($id -notmatch '^[a-z0-9-]+$' -or $ids.ContainsKey($id)) { throw "ID profilo device non valido o duplicato: $id" }
        if ([string]::IsNullOrWhiteSpace([string]$profile.label)) { throw "Etichetta mancante per il profilo $id." }
        if ($null -eq $profile.disableReload -or $null -eq $profile.forceNetworkHook) { throw "Flag compatibilità mancanti nel profilo $id." }
        foreach ($portValue in @($profile.ports)) {
            $port = 0
            if (-not [int]::TryParse([string]$portValue, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                throw "Porta non valida nel profilo ${id}: $portValue"
            }
        }
        $ids[$id] = $true
    }
    if (-not $ids.ContainsKey('auto')) { throw 'Il catalogo deve contenere il profilo auto.' }
    $script:DeviceProfiles = $profiles
    return @($script:DeviceProfiles)
}

function Get-ExplicitInspectorPort([string]$Text) {
    $info = Get-InspectorInfo $Text
    if ($info.WsUrl) {
        try { return ([Uri]$info.WsUrl).Port } catch { return $null }
    }
    if ($info.Port) { return [int]$info.Port }
    $bare = [regex]::Match($Text, '^\s*(?:\d{1,3}\.){3}\d{1,3}:(\d{1,5})\s*/?\s*$')
    if ($bare.Success) { return [int]$bare.Groups[1].Value }
    return $null
}

function Get-DeviceProfile([string]$ProfileId) {
    return @(Get-DeviceProfiles | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1)[0]
}

function Get-DeviceProfileForPort([int]$Port) {
    return @(Get-DeviceProfiles | Where-Object { $_.id -ne 'auto' -and $Port -in @($_.ports) } | Select-Object -First 1)[0]
}

function Get-DirectInspectorPorts([string]$ProfileId = 'auto') {
    $profiles = @(Get-DeviceProfiles)
    $profile = @($profiles | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1)[0]
    if (-not $profile) { throw "Profilo device sconosciuto: $ProfileId" }
    $ports = [System.Collections.Generic.List[int]]::new()
    if ($ProfileId -ne 'auto') {
        foreach ($port in @($profile.ports)) { if (-not $ports.Contains([int]$port)) { $ports.Add([int]$port) } }
    }
    foreach ($candidate in $profiles) {
        foreach ($port in @($candidate.ports)) { if (-not $ports.Contains([int]$port)) { $ports.Add([int]$port) } }
    }
    return @($ports)
}

function Select-DirectDeviceProfile([string]$DefaultProfileId = 'auto') {
    $profiles = @(Get-DeviceProfiles)
    Write-Host
    Write-Host 'Famiglia device / inspector diretto:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $ports = @($profiles[$i].ports) -join ', '
        $portText = if ($ports) { " - porte $ports" } else { '' }
        Write-Host ("  [{0}] {1}{2}" -f $i, $profiles[$i].label, $portText)
    }
    $defaultIndex = 0
    for ($i = 0; $i -lt $profiles.Count; $i++) { if ($profiles[$i].id -eq $DefaultProfileId) { $defaultIndex = $i; break } }
    $answer = Read-Host "Selezione [$defaultIndex]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $profiles[$defaultIndex] }
    if ($answer -notmatch '^\d+$' -or [int]$answer -ge $profiles.Count) { throw 'Selezione profilo device non valida.' }
    return $profiles[[int]$answer]
}

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds = 250) {
    $client = [Net.Sockets.TcpClient]::new()
    $asyncResult = $null
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($asyncResult)
        return $client.Connected
    } catch {
        return $false
    } finally {
        if ($asyncResult -and $asyncResult.AsyncWaitHandle) { $asyncResult.AsyncWaitHandle.Close() }
        $client.Close()
    }
}

function Select-CdpTarget($Targets, [string]$HostName, [int]$Port) {
    if ($Targets.Count -eq 0) { throw "Nessuna pagina ispezionabile su ${HostName}:$Port." }
    Write-Host
    Write-Host 'Pagine disponibili:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $Targets.Count; $i++) {
        $title = if ($Targets[$i].title) { $Targets[$i].title } else { '(senza titolo)' }
        $url = if ($Targets[$i].url) { $Targets[$i].url } else { '' }
        Write-Host ("  [{0}] {1}" -f ($i + 1), $title)
        if ($url) { Write-Host "      $url" -ForegroundColor DarkGray }
    }
    $index = 0
    if (-not [string]::IsNullOrWhiteSpace($script:TargetFilter)) {
        $filterMatched = $false
        for ($i = 0; $i -lt $Targets.Count; $i++) {
            if (("$($Targets[$i].title) $($Targets[$i].url)") -like "*$($script:TargetFilter)*") {
                $index = $i
                $filterMatched = $true
                break
            }
        }
        if (-not $filterMatched) {
            Write-Host "Nessun target corrisponde al filtro '$($script:TargetFilter)'; uso il candidato migliore." -ForegroundColor Yellow
        }
    }
    if ([string]::IsNullOrWhiteSpace($script:TargetFilter) -or -not $filterMatched) {
        for ($i = 0; $i -lt $Targets.Count; $i++) {
            $type = ([string]$Targets[$i].type).ToLowerInvariant()
            $url = [string]$Targets[$i].url
            if ($type -in @('', 'page', 'webview') -and $url -notmatch '^devtools://') { $index = $i; break }
        }
    }
    $target = $Targets[$index]
    Write-Host "Target selezionato automaticamente: $($target.title)" -ForegroundColor Cyan
    $ws = if ($target.webSocketDebuggerUrl) { $target.webSocketDebuggerUrl } elseif ($target.websocketDebuggerUrl) { $target.websocketDebuggerUrl } else { $target.webSocketUrl }
    if (-not $ws) { $ws = "ws://${HostName}:$Port/devtools/page/$($target.id)" }
    else {
        $ws = ConvertTo-ReachableWebSocket $ws $HostName $Port
        if (-not $ws) { throw "WebSocket del target non valido su ${HostName}:$Port." }
    }
    return [pscustomobject]@{ WsUrl = $ws; Target = $target; Host = $HostName; Port = $Port }
}

function Resolve-Direct([string]$InputText, [string]$ProfileId = 'auto') {
    $script:DiscoveryDiagnostics.Clear()
    $info = Get-InspectorInfo $InputText
    if ($info.WsUrl) {
        return [pscustomobject]@{ WsUrl = $info.WsUrl; Target = $null; Host = ([Uri]$info.WsUrl).Host; Port = ([Uri]$info.WsUrl).Port }
    }
    if ($info.Host -and $info.Port) {
        $targets = @(Get-CdpTargets $info.Host $info.Port 3 $info.Scheme)
        if ($targets.Count) { return Select-CdpTarget $targets $info.Host $info.Port }
        $path = '/'
        try {
            $inputUri = [Uri]($InputText -replace '^inspector://', 'http://')
            $path = $inputUri.PathAndQuery
        } catch { }
        $landing = Get-InspectorLandingConnection $info.Host $info.Port $path 2 $info.Scheme
        if ($landing) { return $landing }
    }

    $bareEndpoint = [regex]::Match($InputText, '^\s*((?:\d{1,3}\.){3}\d{1,3}):(\d{1,5})\s*/?\s*$')
    if ($bareEndpoint.Success) {
        $bareHost = $bareEndpoint.Groups[1].Value
        if ((Get-IPv4 $bareHost) -ne $bareHost) { throw 'Indirizzo IPv4 endpoint non valido.' }
        $barePort = [int]$bareEndpoint.Groups[2].Value
        if ($barePort -lt 1 -or $barePort -gt 65535) { throw 'Porta endpoint non valida.' }
        $targets = @(Get-CdpTargets $bareHost $barePort)
        if ($targets.Count) { return Select-CdpTarget $targets $bareHost $barePort }
        $landing = Get-InspectorLandingConnection $bareHost $barePort
        if ($landing) { return $landing }
        return $null
    }

    $ip = Get-IPv4 $InputText
    if (-not $ip) { return $null }
    Write-Host "Cerco un endpoint DevTools su $ip..." -ForegroundColor DarkGray
    foreach ($port in @(Get-DirectInspectorPorts $ProfileId)) {
        if (-not (Test-TcpPort $ip $port)) { continue }
        $targets = @(Get-CdpTargets $ip $port 1)
        if ($targets.Count) { return Select-CdpTarget $targets $ip $port }
        $landing = Get-InspectorLandingConnection $ip $port '/' 1
        if ($landing) { return $landing }
    }
    return $null
}

function Get-WebOsInspectorUrl([string]$OutputText) {
    $match = [regex]::Match($OutputText, 'https?://(?:localhost|127\.0\.0\.1):\d+(?:/devtools/[^\s"'']+)?', 'IgnoreCase')
    if ($match.Success) { return $match.Value.TrimEnd(')', ']', ',', ';') }
    return $null
}

function Start-WebOsInspector([string]$InputText, [string]$AppId) {
    $ares = Get-ToolPath @('ares-inspect.cmd', 'ares-inspect') (@(Get-ManagedSdkFallbacks 'ares-inspect') + @("$env:APPDATA\npm\ares-inspect.cmd"))
    $setup = Get-ToolPath @('ares-setup-device.cmd', 'ares-setup-device') (@(Get-ManagedSdkFallbacks 'ares-setup-device') + @("$env:APPDATA\npm\ares-setup-device.cmd"))
    if (-not $ares -or -not $setup) { throw 'webOS CLI non trovato: installare @webos-tools/cli.' }

    $device = $null
    $ip = Get-IPv4 $InputText
    $firstToken = ($InputText.Trim() -split '\s+')[0]
    $deviceListResult = Invoke-ToolResult $setup @('--list')
    if ($deviceListResult.ExitCode -ne 0) { throw "ares-setup-device --list fallito: $($deviceListResult.Output.Trim())" }
    $deviceList = $deviceListResult.Output
    if ($ip) {
        foreach ($line in ($deviceList -split "`r?`n")) {
            if ($line -match "^\s*(\S+).*?@$([regex]::Escape($ip)):\d+") { $device = $Matches[1]; break }
        }
    }
    if (-not $device -and $deviceList -match "(?m)^\s*$([regex]::Escape($firstToken))\s+") { $device = $firstToken }
    if (-not $device) { $device = Read-Host 'Nome del device configurato in ares-setup-device (es. K3LP)' }
    if ([string]::IsNullOrWhiteSpace($device)) { throw 'Nome device webOS mancante.' }
    if ($device -notmatch '^[a-zA-Z0-9._-]+$') { throw 'Nome device webOS non valido.' }
    if ($AppId -notmatch '^[a-zA-Z0-9._-]+$') { throw 'App ID webOS non valido.' }

    $stdout = Join-Path $env:TEMP "device-log-ares-$([guid]::NewGuid()).out"
    $stderr = "$stdout.err"
    $arguments = @('/d', '/c', "`"$ares`" $AppId -d $device")
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    $script:CleanupActions.Add({
        if (-not $process.HasExited) { Stop-ProcessTree -ProcessId $process.Id; Start-Sleep -Milliseconds 300 }
        Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }.GetNewClosure())
    Write-Host 'Avvio ares-inspect e attendo il tunnel...' -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds(35)
    $url = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $content = (Get-Content $stdout,$stderr -Raw -ErrorAction SilentlyContinue) -join "`n"
        $url = Get-WebOsInspectorUrl $content
        if ($url) { break }
        if ($process.HasExited) { break }
    }
    if (-not $url) {
        $details = (Get-Content $stdout,$stderr -Raw -ErrorAction SilentlyContinue) -join "`n"
        throw "ares-inspect non ha restituito un link entro il timeout.`n$details"
    }
    $info = Get-InspectorInfo $url
    if ($info.WsUrl) {
        return [pscustomobject]@{ WsUrl = $info.WsUrl; Target = $null; Host = 'localhost'; Port = ([Uri]$info.WsUrl).Port }
    }
    $targets = @(Wait-CdpTargets $info.Host $info.Port 12 $info.Scheme)
    return Select-CdpTarget $targets $info.Host $info.Port
}

function Select-ConnectedDevice([string[]]$Serials, [string]$Suggested, [string]$Label) {
    if ($Suggested) {
        $match = $Serials | Where-Object { $_ -like "*$Suggested*" } | Select-Object -First 1
        if ($match) { return $match }
    }
    if ($Serials.Count -eq 1) { return $Serials[0] }
    if ($Serials.Count -eq 0) { throw "Nessun device $Label connesso." }
    Write-Host "Device $Label disponibili:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Serials.Count; $i++) { Write-Host "  [$($i + 1)] $($Serials[$i])" }
    $choice = Read-Host 'Selezione [1]'
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 1 }
    if ([string]$choice -notmatch '^\d+$') { throw 'Selezione device non valida.' }
    $index = [int]$choice - 1
    if ($index -lt 0 -or $index -ge $Serials.Count) { throw 'Selezione device non valida.' }
    return $Serials[$index]
}

function Get-AndroidDevToolsSocketsFromUnix([string]$UnixTable) {
    return @([regex]::Matches($UnixTable, '@?([A-Za-z0-9_.-]*devtools_remote[A-Za-z0-9_.-]*)\s*$', 'Multiline') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Wait-AndroidDevToolsSockets([string]$AdbPath, [string]$Serial, [int]$TimeoutSeconds = 12) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $unixResult = Invoke-ToolResult $AdbPath @('-s', $Serial, 'shell', 'cat', '/proc/net/unix')
        if ($unixResult.ExitCode -eq 0) {
            $sockets = @(Get-AndroidDevToolsSocketsFromUnix $unixResult.Output)
            if ($sockets.Count) { return $sockets }
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return @()
}

function Start-AndroidInspector([string]$InputText) {
    $adb = Get-ToolPath @('adb.exe', 'adb') (@(Get-ManagedSdkFallbacks 'adb') + @('C:\platform-tools\adb.exe', "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"))
    if (-not $adb) { throw 'ADB non trovato. Installare Android platform-tools.' }
    $ip = Get-IPv4 $InputText
    if ($ip) {
        $portMatch = [regex]::Match($InputText, "$([regex]::Escape($ip)):(\d+)")
        $adbPort = if ($portMatch.Success -and [int]$portMatch.Groups[1].Value -ne 9922) { [int]$portMatch.Groups[1].Value } else { 5555 }
        $adbEndpoint = "${ip}:$adbPort"
        $connectResult = Invoke-ToolResult $adb @('connect', $adbEndpoint)
        Write-Host $connectResult.Output.Trim()
        if ($connectResult.ExitCode -ne 0) { throw "Connessione ADB fallita verso ${adbEndpoint}." }
        $script:CleanupActions.Add({ & $adb disconnect $adbEndpoint 2>&1 | Out-Null }.GetNewClosure())
    }
    $deviceResult = Invoke-ToolResult $adb @('devices')
    if ($deviceResult.ExitCode -ne 0) { throw "Impossibile leggere i device ADB: $($deviceResult.Output.Trim())" }
    $deviceText = $deviceResult.Output
    $serials = @([regex]::Matches($deviceText, '(?m)^([^\s]+)\s+device\s*$') | ForEach-Object { $_.Groups[1].Value })
    $unauthorized = @([regex]::Matches($deviceText, '(?m)^([^\s]+)\s+unauthorized\s*$') | ForEach-Object { $_.Groups[1].Value })
    if ($serials.Count -eq 0 -and $unauthorized.Count) {
        throw 'Device Android non autorizzato: confermare la richiesta RSA sul device e riprovare.'
    }
    $serial = Select-ConnectedDevice $serials $ip 'Android'
    Write-Host 'Attendo una WebView Android ispezionabile...' -ForegroundColor DarkGray
    $sockets = @(Wait-AndroidDevToolsSockets $adb $serial 12)
    if ($sockets.Count -eq 0) {
        throw "Nessun socket DevTools Android. Abilitare WebView.setWebContentsDebuggingEnabled(true) e aprire l'app."
    }
    $socket = Select-ConnectedDevice $sockets $script:TargetFilter 'WebView/Chrome'
    $localPort = Get-FreeTcpPort
    $forwardResult = Invoke-ToolResult $adb @('-s', $serial, 'forward', "tcp:$localPort", "localabstract:$socket")
    if ($forwardResult.ExitCode -ne 0) { throw "ADB forward fallito: $($forwardResult.Output.Trim())" }
    $script:CleanupActions.Add({ & $adb -s $serial forward --remove "tcp:$localPort" 2>&1 | Out-Null }.GetNewClosure())
    $targets = @(Wait-CdpTargets 'localhost' $localPort 12)
    return Select-CdpTarget $targets 'localhost' $localPort
}

function Get-TizenDebugArguments([string]$Serial, [string]$AppId, [bool]$LegacyTizen) {
    $arguments = @('-s', $Serial, 'shell', '0', 'debug', $AppId)
    if ($LegacyTizen) { $arguments += '10' }
    return $arguments
}

function Get-TizenInspectorPort([string]$DebugOutput) {
    $patterns = @(
        '(?im)https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|[^/:\s]+):(\d{2,5})\b',
        '(?im)(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{2,5})\b',
        '(?im)\b(?:inspector|debug(?:ger)?|port)(?:\s+port)?\s*[:=]?\s*(\d{2,5})\b',
        '(?im)^\s*(\d{2,5})\s*$'
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($DebugOutput, $pattern)) {
            $port = [int]$match.Groups[1].Value
            if ($port -ge 1 -and $port -le 65535) { return $port }
        }
    }
    return $null
}

function Read-TizenDebugMode {
    Write-Host 'Modalità debug Tizen: [0] Auto  [1] Standard  [2] Legacy Tizen 4 o precedente'
    $answer = Read-Host 'Selezione [0]'
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq '0') { return 'auto' }
    if ($answer -eq '1') { return 'standard' }
    if ($answer -eq '2') { return 'legacy' }
    throw 'Modalità debug Tizen non valida.'
}

function Get-TizenLegacyAttempts([string]$DebugMode) {
    if ($DebugMode -eq 'auto') { return @($false, $true) }
    if ($DebugMode -eq 'standard') { return @($false) }
    if ($DebugMode -eq 'legacy') { return @($true) }
    throw "Modalità Tizen sconosciuta: $DebugMode"
}

function Start-TizenInspector([string]$InputText, [string]$AppId, [string]$DebugMode = 'auto') {
    $sdb = Get-ToolPath @('sdb.exe', 'sdb') (@(Get-ManagedSdkFallbacks 'sdb') + @('C:\tizen-studio\tools\sdb.exe'))
    if (-not $sdb) { throw 'SDB non trovato. Installare Tizen Studio.' }
    $ip = Get-IPv4 $InputText
    if ($ip) {
        $portMatch = [regex]::Match($InputText, "$([regex]::Escape($ip)):(\d+)")
        $sdbPort = if ($portMatch.Success -and [int]$portMatch.Groups[1].Value -ne 9922) { [int]$portMatch.Groups[1].Value } else { 26101 }
        $sdbEndpoint = "${ip}:$sdbPort"
        $connectResult = Invoke-ToolResult $sdb @('connect', $sdbEndpoint)
        Write-Host $connectResult.Output.Trim()
        if ($connectResult.ExitCode -ne 0) { throw "Connessione SDB fallita verso ${sdbEndpoint}." }
        $script:CleanupActions.Add({ & $sdb disconnect $sdbEndpoint 2>&1 | Out-Null }.GetNewClosure())
    }
    $deviceResult = Invoke-ToolResult $sdb @('devices')
    if ($deviceResult.ExitCode -ne 0) { throw "Impossibile leggere i device SDB: $($deviceResult.Output.Trim())" }
    $deviceText = $deviceResult.Output
    $serials = @([regex]::Matches($deviceText, '(?m)^([^\s]+)\s+device(?:\s+.*)?$') | ForEach-Object { $_.Groups[1].Value })
    $serial = Select-ConnectedDevice $serials $ip 'Tizen'
    if ($AppId -notmatch '^[a-zA-Z0-9._-]+$') { throw 'App ID Tizen non valido.' }
    $attempts = @(Get-TizenLegacyAttempts $DebugMode)
    $remotePort = $null
    $lastDebugOutput = ''
    foreach ($legacyAttempt in $attempts) {
        if ($legacyAttempt) {
            Write-Host "Debug Tizen legacy: aggiungo l'argomento finale 10." -ForegroundColor DarkYellow
        } else {
            Write-Host 'Debug Tizen standard...' -ForegroundColor DarkGray
        }
        $debugArgs = @(Get-TizenDebugArguments $serial $AppId $legacyAttempt)
        $debugResult = Invoke-ToolResult $sdb $debugArgs
        $lastDebugOutput = $debugResult.Output
        if (-not [string]::IsNullOrWhiteSpace($lastDebugOutput)) { Write-Host $lastDebugOutput.Trim() }
        if ($debugResult.ExitCode -eq 0) { $remotePort = Get-TizenInspectorPort $lastDebugOutput }
        if ($remotePort) { break }
        if ($DebugMode -eq 'auto' -and -not $legacyAttempt) {
            Write-Host 'Il comando standard non ha restituito una porta; provo automaticamente la sintassi Tizen <= 4.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 300
        }
    }
    if (-not $remotePort) {
        throw "Il runtime Tizen non ha restituito una porta inspector valida. Verificare App ID, certificati e Developer Mode. Output: $($lastDebugOutput.Trim())"
    }
    $localPort = Get-FreeTcpPort
    $forwardResult = Invoke-ToolResult $sdb @('-s', $serial, 'forward', "tcp:$localPort", "tcp:$remotePort")
    if ($forwardResult.ExitCode -ne 0) { throw "SDB forward fallito: $($forwardResult.Output.Trim())" }
    $script:CleanupActions.Add({ & $sdb -s $serial forward --remove "tcp:$localPort" 2>&1 | Out-Null }.GetNewClosure())
    $targets = @(Wait-CdpTargets 'localhost' $localPort 12)
    return Select-CdpTarget $targets 'localhost' $localPort
}

function Invoke-Cleanup {
    for ($i = $script:CleanupActions.Count - 1; $i -ge 0; $i--) {
        try { & $script:CleanupActions[$i] } catch { }
    }
}

try {
    Write-Title
    if (Test-ForUpdates) { exit 0 }
    if (-not (Test-Path -LiteralPath $Recorder)) { throw "Recorder non trovato: $Recorder" }
    $dependencies = Show-DependencyChecks
    $managerPrompt = if ($dependencies.NodeReady) { 'Gestire/installare/aggiornare SDK? [y/N]' } else { 'Node.js 22+ manca. Aprire la gestione automatica? [Y/n]' }
    $managerAnswer = Read-Host $managerPrompt
    if (($dependencies.NodeReady -and $managerAnswer -match '^(?i:s|si|sì|y|yes)$') -or
        (-not $dependencies.NodeReady -and $managerAnswer -notmatch '^(?i:n|no)$')) {
        Show-SdkManager
        $dependencies = Show-DependencyChecks
    }
    if (-not $dependencies.NodeReady) { throw 'Node.js 22 o successivo è obbligatorio. Usare Gestione SDK per installarlo automaticamente.' }
    $node = $dependencies.NodePath

    Write-Host 'Incolla uno dei seguenti valori:' -ForegroundColor Yellow
    Write-Host '  - link DevTools, inspector:// o ws://...'
    Write-Host '  - IP del device'
    Write-Host '  - endpoint IP:porta'
    Write-Host '  - riga completa del device (es. K3LP prisoner@192.168.0.105:9922 ...)'
    $inputText = Read-Host 'Device / IP / link'
    if ([string]::IsNullOrWhiteSpace($inputText)) { throw 'Nessun device specificato.' }

    $directInfo = Get-InspectorInfo $inputText
    if ($directInfo.WsUrl -or $directInfo.Host) { $defaultPlatform = '4' }
    elseif ($inputText -match 'prisoner@|:9922') { $defaultPlatform = '1' }
    elseif ($inputText -match ':26101') { $defaultPlatform = '3' }
    elseif ($inputText -match ':5555') { $defaultPlatform = '2' }
    else { $defaultPlatform = '0' }

    Write-Host
    Write-Host 'Piattaforma: [0] Auto  [1] webOS  [2] Android  [3] Tizen  [4] Link/endpoint CDP'
    $platform = Read-Host "Selezione [$defaultPlatform]"
    if ([string]::IsNullOrWhiteSpace($platform)) { $platform = $defaultPlatform }
    if ($platform -notmatch '^[0-4]$') { throw 'Selezione piattaforma non valida.' }
    if ($platform -eq '1' -and -not $dependencies.WebOsReady) { throw 'webOS CLI mancante: installare @webos-tools/cli.' }
    if ($platform -eq '2' -and -not $dependencies.AdbReady) { throw 'ADB mancante: installare Android platform-tools.' }
    if ($platform -eq '3' -and -not $dependencies.SdbReady) { throw 'SDB mancante: installare Tizen Studio.' }

    $directProfileId = 'auto'
    if ($platform -in @('0', '4')) {
        $explicitPort = Get-ExplicitInspectorPort $inputText
        $inferredProfile = if ($explicitPort) { Get-DeviceProfileForPort $explicitPort } else { $null }
        if ($explicitPort) {
            if ($inferredProfile) { $directProfileId = $inferredProfile.id }
            $profileLabel = if ($inferredProfile) { $inferredProfile.label } else { 'endpoint personalizzato' }
            Write-Host "Endpoint esplicito rilevato: porta $explicitPort ($profileLabel)." -ForegroundColor DarkGray
            if ($inferredProfile -and $inferredProfile.hint) { Write-Host "Nota: $($inferredProfile.hint)" -ForegroundColor DarkYellow }
        } else {
            $selectedProfile = Select-DirectDeviceProfile 'auto'
            $directProfileId = $selectedProfile.id
            if ($selectedProfile.hint) { Write-Host "Nota: $($selectedProfile.hint)" -ForegroundColor DarkYellow }
        }
    }

    $ipForName = Get-IPv4 $inputText
    $firstTokenForName = ($inputText.Trim() -split '\s+')[0]
    $platformName = switch ($platform) { '1' { 'webos' } '2' { 'android' } '3' { 'tizen' } default { 'device' } }
    if ($firstTokenForName -match '^[a-zA-Z][a-zA-Z0-9_-]{1,30}$' -and $firstTokenForName -notmatch '^https?$') {
        $nameDefault = $firstTokenForName
    } elseif ($ipForName) { $nameDefault = "$platformName-$ipForName" }
    else { $nameDefault = $platformName }
    Write-Host
    Write-Host "Configurazione cattura (prima dell'avvio dell'app):" -ForegroundColor Yellow
    $appId = $null
    $tizenDebugMode = 'auto'
    if ($platform -eq '1') {
        $appId = Read-Host 'App ID webOS da ispezionare'
        if ($appId -notmatch '^[a-zA-Z0-9._-]+$') { throw 'App ID webOS non valido.' }
    } elseif ($platform -eq '3') {
        $appId = Read-Host 'App ID/package Tizen da avviare in debug'
        if ($appId -notmatch '^[a-zA-Z0-9._-]+$') { throw 'App ID Tizen non valido.' }
        $tizenDebugMode = Read-TizenDebugMode
    }
    $captureName = Read-Host "Nome per i file [$nameDefault]"
    if ([string]::IsNullOrWhiteSpace($captureName)) { $captureName = $nameDefault }
    $reloadAnswer = Read-Host 'Ricaricare la pagina appena il recorder è collegato? [s/N]'
    $script:TargetFilter = Read-Host 'Filtro titolo/URL target [prima pagina disponibile]'
    Write-Host
    Write-Host 'Configurazione completata. Avvio collegamento e cattura...' -ForegroundColor Cyan

    $connection = $null
    if ($platform -eq '4') { $connection = Resolve-Direct $inputText $directProfileId }
    elseif ($platform -eq '1') { $connection = Start-WebOsInspector $inputText $appId }
    elseif ($platform -eq '2') { $connection = Start-AndroidInspector $inputText }
    elseif ($platform -eq '3') { $connection = Start-TizenInspector $inputText $appId $tizenDebugMode }
    elseif ($platform -eq '0') {
        $connection = Resolve-Direct $inputText $directProfileId
        if (-not $connection) {
            Write-Host 'Endpoint diretto non trovato. Specificare la piattaforma.' -ForegroundColor Yellow
            $manual = Read-Host '[1] webOS  [2] Android  [3] Tizen'
            if ($manual -eq '1') {
                $manualAppId = Read-Host 'App ID webOS da ispezionare'
                $connection = Start-WebOsInspector $inputText $manualAppId
            }
            elseif ($manual -eq '2') { $connection = Start-AndroidInspector $inputText }
            elseif ($manual -eq '3') {
                $manualAppId = Read-Host 'App ID/package Tizen da avviare in debug'
                $manualMode = Read-TizenDebugMode
                $connection = Start-TizenInspector $inputText $manualAppId $manualMode
            }
        }
    }
    if (-not $connection -or -not $connection.WsUrl) {
        $diagnostics = @($script:DiscoveryDiagnostics | Select-Object -Last 6)
        if ($diagnostics.Count) {
            Write-Host 'Ultimi tentativi di discovery:' -ForegroundColor DarkYellow
            $diagnostics | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray }
        }
        throw 'Impossibile trovare o creare un endpoint DevTools/CDP/WebKit.'
    }

    $activeProfile = if ($directProfileId -ne 'auto') { Get-DeviceProfile $directProfileId } else { Get-DeviceProfileForPort $connection.Port }
    if ($activeProfile -and [bool]$activeProfile.disableReload -and $reloadAnswer -match '^(s|si|sì|y|yes)$') {
        Write-Host "Reload automatico non sicuro per $($activeProfile.label)." -ForegroundColor Yellow
        Write-Host "Reload disattivato: riaprire manualmente l'app per acquisire i log iniziali." -ForegroundColor Yellow
        $reloadAnswer = ''
    }

    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $runId = [guid]::NewGuid().ToString('N')
    $stopFile = Join-Path $env:TEMP "device-log-stop-$runId"
    $stdout = Join-Path $env:TEMP "device-log-recorder-$runId.out"
    $stderr = "$stdout.err"
    Remove-Item $stopFile,$stdout,$stderr -Force -ErrorAction SilentlyContinue
    $args = @($Recorder, '--ws-url', $connection.WsUrl, '--output', $OutputRoot, '--stop-file', $stopFile, '--name', $captureName)
    if ($reloadAnswer -match '^(s|si|sì|y|yes)$') { $args += '--reload' }
    if ($activeProfile -and [bool]$activeProfile.forceNetworkHook) { $args += '--compat-network-hook' }
    $quotedArguments = @(
        $args | ForEach-Object {
            ConvertTo-WindowsCommandLineArgument -Value ([string]$_)
        }
    )
    $argumentLine = $quotedArguments -join ' '
    $process = Start-Process -FilePath $node -ArgumentList $argumentLine -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    $script:CleanupActions.Add({ if (-not $process.HasExited) { Stop-ProcessTree -ProcessId $process.Id }; Remove-Item $stopFile,$stdout,$stderr -Force -ErrorAction SilentlyContinue }.GetNewClosure())

    $deadline = (Get-Date).AddSeconds(12)
    $ready = $false
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        Start-Sleep -Milliseconds 200
        $text = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue)
        if ($text -match 'Registrazione in corso') { $ready = $true; break }
    }
    if (-not $ready) {
        $details = ((Get-Content $stdout,$stderr -Raw -ErrorAction SilentlyContinue) -join "`n").Trim()
        throw "Il recorder non è riuscito a collegarsi. Chiudere eventuali DevTools già aperti.`n$details"
    }

    Write-Host
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ' CATTURA ATTIVA' -ForegroundColor Green
    Write-Host ' Usa normalmente il device e riproduci il problema.'
    Write-Host ' Torna qui quando hai finito.'
    Write-Host '============================================================' -ForegroundColor Green
    do { $stopAnswer = Read-Host 'Scrivi STOP e premi INVIO per terminare' } while ($stopAnswer -notmatch '(?i)^stop$')
    New-Item -ItemType File -Path $stopFile -Force | Out-Null
    if (-not $process.WaitForExit(20000)) { throw 'Il recorder non si è chiuso entro 20 secondi.' }
    $process.WaitForExit()
    $process.Refresh()
    $resultText = ((Get-Content $stdout,$stderr -Raw -ErrorAction SilentlyContinue) -join "`n").Trim()
    Write-Host
    Write-Host $resultText
    $recorderExitCode = $process.ExitCode
    if ($null -eq $recorderExitCode -and $resultText -match 'Cattura terminata') { $recorderExitCode = 0 }
    if ($recorderExitCode -ne 0) { throw "Recorder terminato con codice $recorderExitCode." }
    Write-Host
    Write-Host "File disponibili in: $OutputRoot" -ForegroundColor Cyan
    $script:CompletedSuccessfully = $true
} catch {
    Write-Host
    Write-Host "ERRORE: $($_.Exception.Message)" -ForegroundColor Red
    $script:ExitCode = 1
} finally {
    Invoke-Cleanup
}

if ($script:CompletedSuccessfully) {
    Write-Host 'Pulizia completata: tunnel e processi temporanei chiusi.' -ForegroundColor Green
}
if (-not [Console]::IsInputRedirected) {
    [void](Read-Host 'Premi INVIO per chiudere')
}
exit $script:ExitCode
