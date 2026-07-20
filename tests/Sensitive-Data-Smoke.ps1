[CmdletBinding()]
param([switch]$IncludeHistory)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$self = $MyInvocation.MyCommand.Path
$patterns = [ordered]@{
    'GitHub token' = ('github' + '_pat_|gh[pousr]_[A-Za-z0-9_]{20,}')
    'Credenziale assegnata' = ('(pass' + 'word|passwd|secret|api[_-]?key)\s*[:=]')
    'Chiave privata' = ('BEGIN (RSA |EC |OPENSSH )?PRIVATE ' + 'KEY')
    'Riferimento aziendale' = ('media' + 'set')
    'Email personale' = ('[A-Z0-9._%+-]+@gmail\.com')
}
$extensions = @('.ps1', '.psm1', '.js', '.json', '.md', '.cmd', '.yml', '.yaml', '.txt')
$violations = [System.Collections.Generic.List[string]]::new()

$trackedLogFiles = @(git -C $root ls-files -- 'DeviceLogs/*' | Where-Object { $_ -ne 'DeviceLogs/.gitkeep' })
foreach ($trackedLogFile in $trackedLogFiles) { $violations.Add("Log utente tracciato: $trackedLogFile") }

$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $_.FullName -ne $self -and
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.FullName -notmatch '[\\/]DeviceLogs[\\/]' -and
    $_.Extension -in $extensions
})
foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($entry in $patterns.GetEnumerator()) {
        $matches = [regex]::Matches($content, $entry.Value, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($match in $matches) {
            $line = 1 + ([regex]::Matches($content.Substring(0, $match.Index), "`n")).Count
            $relative = $file.FullName.Substring($root.Length + 1)
            $violations.Add("$($entry.Key): ${relative}:$line")
        }
    }
}

if ($IncludeHistory) {
    $commits = @(git -C $root rev-list --all)
    foreach ($commit in $commits) {
        $historicalLogs = @(git -C $root ls-tree -r --name-only $commit -- DeviceLogs | Where-Object { $_ -ne 'DeviceLogs/.gitkeep' })
        foreach ($historicalLog in $historicalLogs) {
            $violations.Add("Log utente storico: commit $($commit.Substring(0, 8)) $historicalLog")
        }
        foreach ($entry in $patterns.GetEnumerator()) {
            $historyHits = @(git -C $root grep -n -I -i -E $entry.Value $commit -- 2>$null)
            foreach ($historyHit in $historyHits) {
                if ($historyHit -match '^[^:]+:([^:]+):(\d+):') {
                    if ($Matches[1] -eq 'tests/Sensitive-Data-Smoke.ps1') { continue }
                    $violations.Add("$($entry.Key): commit $($commit.Substring(0, 8)) $($Matches[1]):$($Matches[2])")
                } else {
                    $violations.Add("$($entry.Key): commit $($commit.Substring(0, 8))")
                }
            }
        }
    }
}

if ($violations.Count) {
    Write-Host 'Controllo dati sensibili fallito. Valori redatti:' -ForegroundColor Red
    $violations | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw 'Rimuovere i dati segnalati prima di commit, push o release.'
}

$configuredEmail = (git -C $root config --local user.email 2>$null | Select-Object -First 1)
if ($configuredEmail -and $configuredEmail -notmatch '@users\.noreply\.github\.com$') {
    throw "L'identità Git locale deve usare un indirizzo GitHub noreply."
}

$historyText = if ($IncludeHistory) { "; $(@(git -C $root rev-list --all).Count) commit analizzati" } else { '' }
Write-Host "Sensitive-data smoke test: OK ($($files.Count) file analizzati$historyText)"
