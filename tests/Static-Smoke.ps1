[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $root 'DeviceLogCapture.ps1'
$script:DeviceProfilesFile = Join-Path $root 'lib\device-profiles.json'
$script:DeviceProfiles = $null
$script:DiscoveryDiagnostics = [System.Collections.Generic.List[string]]::new()
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "DeviceLogCapture.ps1 non supera il parser PowerShell." }

function Import-FunctionFromMain([string]$Name) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if (-not $definition) { throw "Funzione non trovata: $Name" }
    $source = [regex]::Replace(
        $definition.Extent.Text,
        "^function\s+$([regex]::Escape($Name))",
        "function script:$Name"
    )
    Invoke-Expression $source
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message`nAtteso: $Expected`nOttenuto: $Actual"
    }
}

Import-FunctionFromMain 'ConvertTo-WindowsCommandLineArgument'
Import-FunctionFromMain 'Get-InspectorInfo'
Import-FunctionFromMain 'Get-ExplicitInspectorPort'
Import-FunctionFromMain 'ConvertTo-ReachableWebSocket'
Import-FunctionFromMain 'ConvertTo-CdpTargetList'
Import-FunctionFromMain 'Get-CdpTargets'
Import-FunctionFromMain 'Wait-CdpTargets'
Import-FunctionFromMain 'Get-DeviceProfiles'
Import-FunctionFromMain 'Get-DeviceProfile'
Import-FunctionFromMain 'Get-DeviceProfileForPort'
Import-FunctionFromMain 'Get-DirectInspectorPorts'
Import-FunctionFromMain 'Get-TizenDebugArguments'
Import-FunctionFromMain 'Get-TizenInspectorPort'
Import-FunctionFromMain 'Get-TizenLegacyAttempts'
Import-FunctionFromMain 'Get-IPv4'
Import-FunctionFromMain 'Get-WebOsInspectorUrl'
Import-FunctionFromMain 'Get-AndroidDevToolsSocketsFromUnix'
Import-FunctionFromMain 'Select-CdpTarget'
Import-FunctionFromMain 'Get-InspectorLandingConnection'
Import-FunctionFromMain 'Resolve-Direct'

Assert-Equal (Get-IPv4 'device 192.168.1.20:9222') '192.168.1.20' 'Parsing IPv4 valido non riuscito.'
if (Get-IPv4 'device 999.168.1.20:9222') { throw 'Un IPv4 non valido è stato accettato.' }

$movistar = Get-InspectorInfo 'http://192.168.1.201:9998/Main.html?ws=0.0.0.0:9998/devtools/page/1'
Assert-Equal $movistar.WsUrl 'ws://192.168.1.201:9998/devtools/page/1' 'Riscrittura WebSocket Movistar non valida.'
$embeddedMovistar = Get-InspectorInfo 'http://192.168.1.201:9998/Main.html?ws=ws://0.0.0.0:9998/devtools/page/2'
Assert-Equal $embeddedMovistar.WsUrl 'ws://192.168.1.201:9998/devtools/page/2' 'Riscrittura WebSocket con schema nella query non valida.'

$webos = Get-InspectorInfo 'http://localhost:64915/devtools/devtools.html?ws=localhost:64915/devtools/page/2'
Assert-Equal $webos.WsUrl 'ws://localhost:64915/devtools/page/2' 'Il tunnel webOS localhost è stato alterato.'

$bob = Get-InspectorInfo 'inspector://192.168.1.50:9224'
Assert-Equal $bob.Host '192.168.1.50' 'Schema inspector:// Movistar BOB non riconosciuto.'
Assert-Equal $bob.Port 9224 'Porta inspector:// Movistar BOB non riconosciuta.'
$httpsInfo = Get-InspectorInfo 'https://device.test/debug'
Assert-Equal $httpsInfo.Port 443 'Porta HTTPS predefinita non valida.'
Assert-Equal $httpsInfo.Scheme 'https' 'Schema HTTPS non conservato per la discovery.'
$secureWsInfo = Get-InspectorInfo 'https://device.test/devtools.html?ws=device.test:443/devtools/page/1'
if ($secureWsInfo.WsUrl -notmatch '^wss://') { throw 'Un link inspector HTTPS deve produrre un WebSocket WSS.' }
Assert-Equal (Get-InspectorInfo 'inspector://192.168.1.50').Port 9224 'Porta inspector:// predefinita non valida.'
Assert-Equal (Get-ExplicitInspectorPort '192.168.1.50:7001') 7001 'Parsing IP:porta non valido.'

$rewrittenWs = ConvertTo-ReachableWebSocket 'wss://0.0.0.0:1/devtools/page/abc?x=1' 'device.test' 9443
Assert-Equal $rewrittenWs 'wss://device.test:9443/devtools/page/abc?x=1' 'Riscrittura WSS non valida.'

$nestedTargets = @(ConvertTo-CdpTargetList ([pscustomobject]@{ targets = @(
    [pscustomobject]@{ id = 'page'; type = 'page' },
    [pscustomobject]@{ id = 'browser'; type = 'browser'; webSocketDebuggerUrl = 'ws://x/devtools/browser/1' }
) }))
Assert-Equal $nestedTargets.Count 1 'Normalizzazione target annidati non valida.'
Assert-Equal $nestedTargets[0].id 'page' 'Il target browser non è stato escluso.'

$directPorts = @(Get-DirectInspectorPorts)
foreach ($requiredPort in @(9222, 9224, 9226, 9229, 7001, 7014, 8090, 9998, 52223)) {
    if ($requiredPort -notin $directPorts) { throw "Porta inspector diretta mancante: $requiredPort" }
}
$legacyProfile = Get-DeviceProfile 'movistar-legacy'
Assert-Equal ([bool]$legacyProfile.disableReload) $true 'Reload legacy non disabilitato dal profilo.'
Assert-Equal ([bool]$legacyProfile.forceNetworkHook) $true 'Hook network legacy non abilitato dal profilo.'
$tizenDirectProfile = Get-DeviceProfile 'tizen-hbbtv'
if ($tizenDirectProfile.hint -notmatch 'modalità') { throw 'Il catalogo profili non viene letto correttamente come UTF-8.' }

$standardTizenArgs = @(Get-TizenDebugArguments '192.168.1.10:26101' 'AbCdEf.App' $false)
Assert-Equal ($standardTizenArgs -join ' ') '-s 192.168.1.10:26101 shell 0 debug AbCdEf.App' 'Comando Tizen standard non valido.'
$legacyTizenArgs = @(Get-TizenDebugArguments '192.168.1.10:26101' 'AbCdEf.App' $true)
Assert-Equal ($legacyTizenArgs -join ' ') '-s 192.168.1.10:26101 shell 0 debug AbCdEf.App 10' 'Il comando Tizen legacy non termina con 10.'
Assert-Equal (Get-TizenInspectorPort 'debug port: 7011') 7011 'Parsing porta Tizen moderna non valido.'
Assert-Equal (Get-TizenInspectorPort "debugging app`n7012") 7012 'Parsing porta Tizen legacy non valido.'
Assert-Equal (Get-TizenInspectorPort 'debug url: http://127.0.0.1:45678/devtools') 45678 'La porta Tizen è stata confusa con un ottetto IPv4.'
$autoAttempts = @(Get-TizenLegacyAttempts 'auto')
Assert-Equal $autoAttempts.Count 2 'La modalità Tizen auto non esegue due tentativi.'
Assert-Equal $autoAttempts[0] $false 'Il primo tentativo Tizen auto deve essere standard.'
Assert-Equal $autoAttempts[1] $true 'Il secondo tentativo Tizen auto deve essere legacy.'

$webOsUrl = Get-WebOsInspectorUrl 'Application Debugging - https://127.0.0.1:65000/devtools/devtools.html?ws=127.0.0.1:65000/devtools/page/ABC'
Assert-Equal $webOsUrl 'https://127.0.0.1:65000/devtools/devtools.html?ws=127.0.0.1:65000/devtools/page/ABC' 'Parsing link webOS alternativo non valido.'

$unixTable = "00000000: 00000002 00000000 00010000 0001 01 1 @webview_devtools_remote_42`n00000000: 00000002 00000000 00010000 0001 01 2 @chrome_devtools_remote"
$androidSockets = @(Get-AndroidDevToolsSocketsFromUnix $unixTable)
Assert-Equal $androidSockets.Count 2 'Parsing socket Android multipli non valido.'
if ('webview_devtools_remote_42' -notin $androidSockets -or 'chrome_devtools_remote' -notin $androidSockets) { throw 'Socket Android attesi mancanti.' }

$quoted = ConvertTo-WindowsCommandLineArgument 'C:\Cartella Con Spazi\cdp-capture.js'
Assert-Equal $quoted '"C:\Cartella Con Spazi\cdp-capture.js"' 'Quoting percorso con spazi non valido.'
$quotedTrailingSlash = ConvertTo-WindowsCommandLineArgument 'C:\Cartella Con Spazi\'
Assert-Equal $quotedTrailingSlash '"C:\Cartella Con Spazi\\"' 'Quoting backslash finale non valido.'
$quotedEmbedded = ConvertTo-WindowsCommandLineArgument 'nome "speciale"'
Assert-Equal $quotedEmbedded '"nome \"speciale\""' 'Quoting virgolette interne non valido.'
Assert-Equal (ConvertTo-WindowsCommandLineArgument '') '""' 'Quoting argomento vuoto non valido.'

$script:restAttempts = 0
function Invoke-RestMethod {
    $script:restAttempts++
    if ($script:restAttempts -lt 3) { throw 'Inspector non ancora pronto' }
    return [pscustomobject]@{ id = 'ready'; title = 'Target pronto' }
}
$waitedTargets = @(Wait-CdpTargets 'localhost' 65000 2)
Assert-Equal $waitedTargets.Count 1 'Il retry CDP non ha atteso il target.'
if ($script:restAttempts -lt 3) { throw 'Il retry CDP non ha eseguito più tentativi.' }

function Invoke-RestMethod {
    return ,@(
        [pscustomobject]@{ id = '1'; title = 'Pagina uno' },
        [pscustomobject]@{ id = '2'; title = 'Pagina due' }
    )
}
$targets = @(Get-CdpTargets 'device.test' 9998)
Assert-Equal $targets.Count 2 'La discovery PowerShell 5.1 non ha preservato i target multipli.'
Assert-Equal $targets[1].id '2' 'Il secondo target non è accessibile.'
$script:TargetFilter = ''
$bareEndpoint = Resolve-Direct '192.168.1.80:45678'
Assert-Equal $bareEndpoint.Host '192.168.1.80' 'Endpoint IP:porta non riconosciuto.'
Assert-Equal $bareEndpoint.Port 45678 'Porta endpoint esplicita alterata.'

function Invoke-RestMethod { throw 'JSON endpoint assente' }
function Invoke-WebRequest {
    return [pscustomobject]@{
        Content = '<a href="devtools.html?ws=0.0.0.0:52223/devtools/page/legacy-1">Inspect</a>'
        BaseResponse = $null
    }
}
$landingEndpoint = Resolve-Direct 'http://192.168.1.90:52223/' 'panasonic-viera'
Assert-Equal $landingEndpoint.WsUrl 'ws://192.168.1.90:52223/devtools/page/legacy-1' 'Discovery dalla landing page legacy non valida.'

$mainSource = Get-Content -LiteralPath $mainPath -Raw
if ($mainSource -match '\[g/N\]') { throw 'Il refuso [g/N] è ancora presente nel setup.' }
if ($mainSource -match '\(\?i:g\|gestisci\|') { throw 'Le vecchie risposte g/gestisci sono ancora accettate dal prompt [y/N].' }
if ($mainSource -notmatch 'DeviceProfilesFile -Raw -Encoding UTF8') { throw 'Il catalogo profili non forza UTF-8 su Windows PowerShell 5.1.' }
if ($mainSource -notmatch '\[y/N\]') { throw 'Il prompt [y/N] atteso non è presente nel setup.' }
if ($mainSource -match 'gh auth token|DEVICE_LOG_CAPTURE_GITHUB_TOKEN') { throw "L'auto-update pubblico non deve leggere token locali." }

Write-Host 'Static smoke tests: OK'
