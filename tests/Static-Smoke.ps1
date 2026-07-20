[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $root 'DeviceLogCapture.ps1'
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
Import-FunctionFromMain 'Get-CdpTargets'
Import-FunctionFromMain 'Get-DirectInspectorPorts'
Import-FunctionFromMain 'Get-TizenDebugArguments'
Import-FunctionFromMain 'Get-TizenInspectorPort'
Import-FunctionFromMain 'Get-IPv4'
Import-FunctionFromMain 'Select-CdpTarget'
Import-FunctionFromMain 'Resolve-Direct'

$movistar = Get-InspectorInfo 'http://192.168.1.201:9998/Main.html?ws=0.0.0.0:9998/devtools/page/1'
Assert-Equal $movistar.WsUrl 'ws://192.168.1.201:9998/devtools/page/1' 'Riscrittura WebSocket Movistar non valida.'

$webos = Get-InspectorInfo 'http://localhost:64915/devtools/devtools.html?ws=localhost:64915/devtools/page/2'
Assert-Equal $webos.WsUrl 'ws://localhost:64915/devtools/page/2' 'Il tunnel webOS localhost è stato alterato.'

$bob = Get-InspectorInfo 'inspector://192.168.1.50:9224'
Assert-Equal $bob.Host '192.168.1.50' 'Schema inspector:// Movistar BOB non riconosciuto.'
Assert-Equal $bob.Port 9224 'Porta inspector:// Movistar BOB non riconosciuta.'

$directPorts = @(Get-DirectInspectorPorts)
foreach ($requiredPort in @(9224, 9226, 7001, 7014, 8090, 9998, 52223)) {
    if ($requiredPort -notin $directPorts) { throw "Porta inspector diretta mancante: $requiredPort" }
}

$standardTizenArgs = @(Get-TizenDebugArguments '192.168.1.10:26101' 'AbCdEf.App' $false)
Assert-Equal ($standardTizenArgs -join ' ') '-s 192.168.1.10:26101 shell 0 debug AbCdEf.App' 'Comando Tizen standard non valido.'
$legacyTizenArgs = @(Get-TizenDebugArguments '192.168.1.10:26101' 'AbCdEf.App' $true)
Assert-Equal ($legacyTizenArgs -join ' ') '-s 192.168.1.10:26101 shell 0 debug AbCdEf.App 10' 'Il comando Tizen legacy non termina con 10.'
Assert-Equal (Get-TizenInspectorPort 'debug port: 7011') 7011 'Parsing porta Tizen moderna non valido.'
Assert-Equal (Get-TizenInspectorPort "debugging app`n7012") 7012 'Parsing porta Tizen legacy non valido.'

$quoted = ConvertTo-WindowsCommandLineArgument 'C:\Cartella Con Spazi\cdp-capture.js'
Assert-Equal $quoted '"C:\Cartella Con Spazi\cdp-capture.js"' 'Quoting percorso con spazi non valido.'
$quotedTrailingSlash = ConvertTo-WindowsCommandLineArgument 'C:\Cartella Con Spazi\'
Assert-Equal $quotedTrailingSlash '"C:\Cartella Con Spazi\\"' 'Quoting backslash finale non valido.'
$quotedEmbedded = ConvertTo-WindowsCommandLineArgument 'nome "speciale"'
Assert-Equal $quotedEmbedded '"nome \"speciale\""' 'Quoting virgolette interne non valido.'
Assert-Equal (ConvertTo-WindowsCommandLineArgument '') '""' 'Quoting argomento vuoto non valido.'

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

$mainSource = Get-Content -LiteralPath $mainPath -Raw
if ($mainSource -match '\[g/N\]') { throw 'Il refuso [g/N] è ancora presente nel setup.' }
if ($mainSource -notmatch '\[y/N\]') { throw 'Il prompt [y/N] atteso non è presente nel setup.' }

Write-Host 'Static smoke tests: OK'
