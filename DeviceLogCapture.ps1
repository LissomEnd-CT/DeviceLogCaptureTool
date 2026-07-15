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
$CurrentVersion = if (Test-Path -LiteralPath $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { '0.0.0' }
$script:CleanupActions = [System.Collections.Generic.List[scriptblock]]::new()
$script:TargetFilter = ''
$script:ExitCode = 0
$script:CompletedSuccessfully = $false
$script:GitHubHeaders = @{}

if (-not (Test-Path -LiteralPath $SdkManager)) { throw "Gestore SDK non trovato: $SdkManager" }
. $SdkManager
Initialize-ManagedSdkPaths

function Write-Title {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '        DEVICE LOG CAPTURE - Network HAR + Console' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host "Versione $CurrentVersion - webOS, Tizen e Android WebView"
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
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

    $launcher = Get-ChildItem -LiteralPath $extractPath -Filter 'DeviceLogCapture.cmd' -File -Recurse | Select-Object -First 1
    if (-not $launcher) { throw 'Il pacchetto della release non contiene DeviceLogCapture.cmd.' }
    $sourceRoot = $launcher.Directory.FullName
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
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$updaterTemp`" -TargetRoot `"$ScriptRoot`" -SourceRoot `"$sourceRoot`" -TempRoot `"$tempRoot`" -WaitProcessIds `"$idText`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    Write-Host 'Aggiornamento preparato. Il tool verrà riaperto automaticamente.' -ForegroundColor Green
}

function Test-ForUpdates {
    if (-not (Test-Path -LiteralPath $UpdateConfigFile)) {
        Write-Host '[UPDATE] Configurazione GitHub assente; controllo saltato.' -ForegroundColor Yellow
        Write-Host
        return $false
    }
    try { $config = Get-Content $UpdateConfigFile -Raw | ConvertFrom-Json }
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
        $tokenVariable = if ($config.githubTokenEnvironmentVariable) { [string]$config.githubTokenEnvironmentVariable } else { 'DEVICE_LOG_CAPTURE_GITHUB_TOKEN' }
        $token = [Environment]::GetEnvironmentVariable($tokenVariable)
        if ([string]::IsNullOrWhiteSpace($token)) {
            $gh = Get-ToolPath @('gh.exe', 'gh')
            if ($gh) {
                $tokenOutput = & $gh auth token 2>$null
                if ($LASTEXITCODE -eq 0) { $token = ($tokenOutput | Select-Object -First 1).ToString().Trim() }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($token)) { $headers['Authorization'] = "Bearer $token" }
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
        if (-not $script:GitHubHeaders.ContainsKey('Authorization')) {
            Write-Host 'Se la repo è privata, eseguire gh auth login oppure configurare DEVICE_LOG_CAPTURE_GITHUB_TOKEN.' -ForegroundColor DarkYellow
        }
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
    $match = [regex]::Match($Text, '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)')
    if ($match.Success) { return $match.Value }
    return $null
}

function Get-InspectorInfo([string]$Text) {
    $result = [ordered]@{ WsUrl = $null; Host = $null; Port = $null }
    $wsMatch = [regex]::Match($Text, 'wss?://[^\s"'']+', 'IgnoreCase')
    if ($wsMatch.Success) {
        $result.WsUrl = $wsMatch.Value.TrimEnd(')', ']', ',')
        return [pscustomobject]$result
    }

    $queryMatch = [regex]::Match($Text, '[?&]ws=([^&\s]+)', 'IgnoreCase')
    if ($queryMatch.Success) {
        $decoded = [Uri]::UnescapeDataString($queryMatch.Groups[1].Value)
        if ($decoded -notmatch '^wss?://') { $decoded = "ws://$decoded" }
        $result.WsUrl = $decoded
        return [pscustomobject]$result
    }

    $urlMatch = [regex]::Match($Text, 'https?://([^/:\s]+)(?::(\d+))?', 'IgnoreCase')
    if ($urlMatch.Success) {
        $result.Host = $urlMatch.Groups[1].Value
        $result.Port = if ($urlMatch.Groups[2].Success) { [int]$urlMatch.Groups[2].Value } else { 80 }
        return [pscustomobject]$result
    }
    return [pscustomobject]$result
}

function Get-CdpTargets([string]$HostName, [int]$Port) {
    foreach ($route in @('/json/list', '/json')) {
        try {
            $items = @(Invoke-RestMethod -Uri "http://${HostName}:$Port$route" -TimeoutSec 3)
            if ($items.Count -gt 0) { return $items }
        } catch { }
    }
    return @()
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
        for ($i = 0; $i -lt $Targets.Count; $i++) {
            if (("$($Targets[$i].title) $($Targets[$i].url)") -like "*$($script:TargetFilter)*") { $index = $i; break }
        }
    }
    $target = $Targets[$index]
    Write-Host "Target selezionato automaticamente: $($target.title)" -ForegroundColor Cyan
    $ws = $target.webSocketDebuggerUrl
    if (-not $ws) { $ws = "ws://${HostName}:$Port/devtools/page/$($target.id)" }
    else {
        $wsUri = [Uri]$ws
        $ws = "ws://${HostName}:$Port$($wsUri.PathAndQuery)"
    }
    return [pscustomobject]@{ WsUrl = $ws; Target = $target; Host = $HostName; Port = $Port }
}

function Resolve-Direct([string]$InputText) {
    $info = Get-InspectorInfo $InputText
    if ($info.WsUrl) {
        return [pscustomobject]@{ WsUrl = $info.WsUrl; Target = $null; Host = ([Uri]$info.WsUrl).Host; Port = ([Uri]$info.WsUrl).Port }
    }
    if ($info.Host -and $info.Port) {
        $targets = @(Get-CdpTargets $info.Host $info.Port)
        if ($targets.Count) { return Select-CdpTarget $targets $info.Host $info.Port }
    }

    $ip = Get-IPv4 $InputText
    if (-not $ip) { return $null }
    Write-Host "Cerco un endpoint DevTools su $ip..." -ForegroundColor DarkGray
    foreach ($port in @(9222, 9223, 7011, 7014, 9998, 9999, 8080)) {
        $targets = @(Get-CdpTargets $ip $port)
        if ($targets.Count) { return Select-CdpTarget $targets $ip $port }
    }
    return $null
}

function Start-WebOsInspector([string]$InputText, [string]$AppId) {
    $ares = Get-ToolPath @('ares-inspect.cmd', 'ares-inspect') (@(Get-ManagedSdkFallbacks 'ares-inspect') + @("$env:APPDATA\npm\ares-inspect.cmd"))
    $setup = Get-ToolPath @('ares-setup-device.cmd', 'ares-setup-device') (@(Get-ManagedSdkFallbacks 'ares-setup-device') + @("$env:APPDATA\npm\ares-setup-device.cmd"))
    if (-not $ares -or -not $setup) { throw 'webOS CLI non trovato: installare @webos-tools/cli.' }

    $device = $null
    $ip = Get-IPv4 $InputText
    $firstToken = ($InputText.Trim() -split '\s+')[0]
    $deviceList = & $setup --list 2>&1 | Out-String
    if ($ip) {
        foreach ($line in ($deviceList -split "`r?`n")) {
            if ($line -match "^\s*(\S+).*?@$([regex]::Escape($ip)):\d+") { $device = $Matches[1]; break }
        }
    }
    if (-not $device -and $deviceList -match "(?m)^\s*$([regex]::Escape($firstToken))\s+") { $device = $firstToken }
    if (-not $device) { $device = Read-Host 'Nome del device configurato in ares-setup-device (es. K3LP)' }
    if ([string]::IsNullOrWhiteSpace($device)) { throw 'Nome device webOS mancante.' }
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
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        Start-Sleep -Milliseconds 300
        $content = (Get-Content $stdout,$stderr -Raw -ErrorAction SilentlyContinue) -join "`n"
        $match = [regex]::Match($content, 'http://localhost:\d+(?:/devtools/[^\s]+)?')
        if ($match.Success) { $url = $match.Value; break }
    }
    if (-not $url) {
        $details = (Get-Content $stdout,$stderr -Raw -ErrorAction SilentlyContinue) -join "`n"
        throw "ares-inspect non ha restituito un link entro il timeout.`n$details"
    }
    $info = Get-InspectorInfo $url
    if ($info.WsUrl) {
        return [pscustomobject]@{ WsUrl = $info.WsUrl; Target = $null; Host = 'localhost'; Port = ([Uri]$info.WsUrl).Port }
    }
    $targets = @(Get-CdpTargets $info.Host $info.Port)
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
    $index = [int]$choice - 1
    if ($index -lt 0 -or $index -ge $Serials.Count) { throw 'Selezione device non valida.' }
    return $Serials[$index]
}

function Start-AndroidInspector([string]$InputText) {
    $adb = Get-ToolPath @('adb.exe', 'adb') (@(Get-ManagedSdkFallbacks 'adb') + @('C:\platform-tools\adb.exe', "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"))
    if (-not $adb) { throw 'ADB non trovato. Installare Android platform-tools.' }
    $ip = Get-IPv4 $InputText
    if ($ip) {
        $portMatch = [regex]::Match($InputText, "$([regex]::Escape($ip)):(\d+)")
        $adbPort = if ($portMatch.Success -and [int]$portMatch.Groups[1].Value -ne 9922) { [int]$portMatch.Groups[1].Value } else { 5555 }
        Write-Host (& $adb connect "${ip}:$adbPort" 2>&1 | Out-String).Trim()
    }
    $deviceText = & $adb devices 2>&1 | Out-String
    $serials = @([regex]::Matches($deviceText, '(?m)^([^\s]+)\s+device\s*$') | ForEach-Object { $_.Groups[1].Value })
    $serial = Select-ConnectedDevice $serials $ip 'Android'
    $unix = & $adb -s $serial shell cat /proc/net/unix 2>&1 | Out-String
    $sockets = @([regex]::Matches($unix, '@?([A-Za-z0-9_.-]*devtools_remote[A-Za-z0-9_.-]*)\s*$', 'Multiline') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($sockets.Count -eq 0) {
        throw "Nessun socket DevTools Android. Abilitare WebView.setWebContentsDebuggingEnabled(true) e aprire l'app."
    }
    $socket = Select-ConnectedDevice $sockets $null 'WebView/Chrome'
    $localPort = Get-FreeTcpPort
    $forwardResult = & $adb -s $serial forward "tcp:$localPort" "localabstract:$socket" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB forward fallito: $forwardResult" }
    $script:CleanupActions.Add({ & $adb -s $serial forward --remove "tcp:$localPort" 2>&1 | Out-Null }.GetNewClosure())
    Start-Sleep -Milliseconds 400
    $targets = @(Get-CdpTargets 'localhost' $localPort)
    return Select-CdpTarget $targets 'localhost' $localPort
}

function Start-TizenInspector([string]$InputText, [string]$AppId) {
    $sdb = Get-ToolPath @('sdb.exe', 'sdb') (@(Get-ManagedSdkFallbacks 'sdb') + @('C:\tizen-studio\tools\sdb.exe'))
    if (-not $sdb) { throw 'SDB non trovato. Installare Tizen Studio.' }
    $ip = Get-IPv4 $InputText
    if ($ip) {
        $portMatch = [regex]::Match($InputText, "$([regex]::Escape($ip)):(\d+)")
        $sdbPort = if ($portMatch.Success -and [int]$portMatch.Groups[1].Value -ne 9922) { [int]$portMatch.Groups[1].Value } else { 26101 }
        Write-Host (& $sdb connect "${ip}:$sdbPort" 2>&1 | Out-String).Trim()
    }
    $deviceText = & $sdb devices 2>&1 | Out-String
    $serials = @([regex]::Matches($deviceText, '(?m)^([^\s]+)\s+device(?:\s+.*)?$') | ForEach-Object { $_.Groups[1].Value })
    $serial = Select-ConnectedDevice $serials $ip 'Tizen'
    if ($AppId -notmatch '^[a-zA-Z0-9._-]+$') { throw 'App ID Tizen non valido.' }
    $debugOutput = & $sdb -s $serial shell 0 debug $AppId 2>&1 | Out-String
    Write-Host $debugOutput.Trim()
    $portMatch = [regex]::Match($debugOutput, 'port\s*:\s*(\d+)', 'IgnoreCase')
    if (-not $portMatch.Success) {
        throw 'Il runtime Tizen non ha restituito la porta inspector. Verificare Developer Mode e che sia una Web App debuggabile.'
    }
    $remotePort = [int]$portMatch.Groups[1].Value
    $localPort = Get-FreeTcpPort
    $forwardResult = & $sdb -s $serial forward "tcp:$localPort" "tcp:$remotePort" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SDB forward fallito: $forwardResult" }
    $script:CleanupActions.Add({ & $sdb -s $serial forward --remove "tcp:$localPort" 2>&1 | Out-Null }.GetNewClosure())
    Start-Sleep -Milliseconds 400
    $targets = @(Get-CdpTargets 'localhost' $localPort)
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
    $managerPrompt = if ($dependencies.NodeReady) { 'Gestire/installare/aggiornare SDK? [g/N]' } else { 'Node.js 22+ manca. Aprire la gestione automatica? [S/n]' }
    $managerAnswer = Read-Host $managerPrompt
    if (($dependencies.NodeReady -and $managerAnswer -match '^(?i:g|gestisci|s|si|sì|y|yes)$') -or
        (-not $dependencies.NodeReady -and $managerAnswer -notmatch '^(?i:n|no)$')) {
        Show-SdkManager
        $dependencies = Show-DependencyChecks
    }
    if (-not $dependencies.NodeReady) { throw 'Node.js 22 o successivo è obbligatorio. Usare Gestione SDK per installarlo automaticamente.' }
    $node = $dependencies.NodePath

    Write-Host 'Incolla uno dei seguenti valori:' -ForegroundColor Yellow
    Write-Host '  - link DevTools o ws://...'
    Write-Host '  - IP del device'
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
    if ($platform -eq '1' -and -not $dependencies.WebOsReady) { throw 'webOS CLI mancante: installare @webos-tools/cli.' }
    if ($platform -eq '2' -and -not $dependencies.AdbReady) { throw 'ADB mancante: installare Android platform-tools.' }
    if ($platform -eq '3' -and -not $dependencies.SdbReady) { throw 'SDB mancante: installare Tizen Studio.' }

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
    if ($platform -eq '1') {
        $appId = Read-Host 'App ID webOS da ispezionare'
        if ($appId -notmatch '^[a-zA-Z0-9._-]+$') { throw 'App ID webOS non valido.' }
    } elseif ($platform -eq '3') {
        $appId = Read-Host 'App ID/package Tizen da avviare in debug'
        if ($appId -notmatch '^[a-zA-Z0-9._-]+$') { throw 'App ID Tizen non valido.' }
    }
    $captureName = Read-Host "Nome per i file [$nameDefault]"
    if ([string]::IsNullOrWhiteSpace($captureName)) { $captureName = $nameDefault }
    $reloadAnswer = Read-Host 'Ricaricare la pagina appena il recorder è collegato? [s/N]'
    $script:TargetFilter = Read-Host 'Filtro titolo/URL target [prima pagina disponibile]'
    Write-Host
    Write-Host 'Configurazione completata. Avvio collegamento e cattura...' -ForegroundColor Cyan

    $connection = $null
    if ($platform -eq '4') { $connection = Resolve-Direct $inputText }
    elseif ($platform -eq '1') { $connection = Start-WebOsInspector $inputText $appId }
    elseif ($platform -eq '2') { $connection = Start-AndroidInspector $inputText }
    elseif ($platform -eq '3') { $connection = Start-TizenInspector $inputText $appId }
    elseif ($platform -eq '0') {
        $connection = Resolve-Direct $inputText
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
                $connection = Start-TizenInspector $inputText $manualAppId
            }
        }
    }
    if (-not $connection -or -not $connection.WsUrl) { throw 'Impossibile trovare o creare un endpoint DevTools/CDP.' }

    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $runId = [guid]::NewGuid().ToString('N')
    $stopFile = Join-Path $env:TEMP "device-log-stop-$runId"
    $stdout = Join-Path $env:TEMP "device-log-recorder-$runId.out"
    $stderr = "$stdout.err"
    Remove-Item $stopFile,$stdout,$stderr -Force -ErrorAction SilentlyContinue
    $args = @($Recorder, '--ws-url', $connection.WsUrl, '--output', $OutputRoot, '--stop-file', $stopFile, '--name', $captureName)
    if ($reloadAnswer -match '^(s|si|sì|y|yes)$') { $args += '--reload' }
    $process = Start-Process -FilePath $node -ArgumentList $args -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
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
