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

$movistar = Get-InspectorInfo 'http://192.168.1.201:9998/Main.html?ws=0.0.0.0:9998/devtools/page/1'
Assert-Equal $movistar.WsUrl 'ws://192.168.1.201:9998/devtools/page/1' 'Riscrittura WebSocket Movistar non valida.'

$webos = Get-InspectorInfo 'http://localhost:64915/devtools/devtools.html?ws=localhost:64915/devtools/page/2'
Assert-Equal $webos.WsUrl 'ws://localhost:64915/devtools/page/2' 'Il tunnel webOS localhost è stato alterato.'

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

Write-Host 'Static smoke tests: OK'
