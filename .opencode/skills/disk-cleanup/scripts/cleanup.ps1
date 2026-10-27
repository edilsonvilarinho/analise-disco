<#
.SYNOPSIS
    Executa um tier de um plano de limpeza, medindo o espaco antes e depois.

.DESCRIPTION
    Le um plano JSON (ver SKILL.md para o formato), executa os itens de um tier
    e reporta o delta real de espaco livre. Cada item e independente: se um
    falhar (arquivo travado por processo ativo e o caso mais comum), o script
    registra e segue para o proximo.

    -DryRun e o default. Sem -Execute nada e removido.

.EXAMPLE
    pwsh -NoProfile -File cleanup.ps1 -Plan out/plan.json -Tier A
    pwsh -NoProfile -File cleanup.ps1 -Plan out/plan.json -Tier A -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Plan,
    [Parameter(Mandatory)]
    [ValidateSet('A', 'B', 'C', 'D')]
    [string]$Tier,
    [string]$LogPath = '',
    [switch]$Execute
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $Plan)) { Write-Error "Plano nao encontrado: $Plan"; exit 1 }
$planData = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json

if (-not $planData.tiers.$Tier) {
    Write-Error "Tier '$Tier' nao existe no plano. Disponiveis: $(($planData.tiers.PSObject.Properties.Name) -join ', ')"
    exit 1
}
$items = @($planData.tiers.$Tier)

if (-not $LogPath) {
    $logDir = Join-Path (Split-Path $Plan -Parent) 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $LogPath = Join-Path $logDir ("cleanup-{0}-{1}.log" -f $Tier, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$log = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    $log.Add($line)
    Write-Host $line
}

function Get-FreeGB {
    $letter = ($planData.volume -replace '[:\\]', '')
    $v = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if ($v) { return [math]::Round($v.SizeRemaining / 1GB, 3) }
    return 0
}

function Get-SizeGB {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and -not $item.PSIsContainer) { return [math]::Round($item.Length / 1GB, 3) }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [math]::Round($sum / 1GB, 3)
}

Write-Host ''
Write-Host ("=== CLEANUP TIER {0} ===" -f $Tier) -ForegroundColor Cyan
Write-Log "Tier $Tier | itens: $($items.Count) | execute=$Execute"
$freeBefore = Get-FreeGB
Write-Log ("Espaco livre antes: {0} GB" -f $freeBefore)

if (-not $Execute) {
    Write-Host ''
    Write-Host '--- DRY-RUN: o que seria feito ---' -ForegroundColor DarkYellow
    foreach ($it in $items) {
        $kind = $it.kind
        switch ($kind) {
            'path' { Write-Host ("  [path]      {0}  ->  remover {1} ({2} GB)" -f $it.label, $it.path, (Get-SizeGB $it.path)) }
            'command' { Write-Host ("  [command]   {0}  ->  {1}" -f $it.label, $it.command) }
            'uninstall' { Write-Host ("  [uninstall] {0}  ->  desinstalar '{1}'" -f $it.label, $it.displayName) }
            default { Write-Host ("  [???]       {0}  (kind desconhecido: {1})" -f $it.label, $kind) -ForegroundColor Red }
        }
    }
    Write-Host ''
    Write-Host 'Nada foi alterado. Use -Execute para executar.' -ForegroundColor DarkYellow
    Write-Log 'Dry-run encerrado.'
    $log | Out-File -FilePath $LogPath -Encoding utf8
    Write-Host "Log: $LogPath"
    exit 0
}

# --------------------------------------------------------------------------
# Execucao
# --------------------------------------------------------------------------

$scriptDir = Split-Path $MyInvocation.MyCommand.Path
$uninstallScript = Join-Path $scriptDir 'uninstall.ps1'

$results = @()

foreach ($it in $items) {
    $label = if ($it.label) { $it.label } else { $it.id }
    $freeStart = Get-FreeGB
    $status = 'ok'
    $detail = ''

    try {
        switch ($it.kind) {
            'path' {
                if (-not (Test-Path -LiteralPath $it.path)) {
                    $status = 'skip'; $detail = 'caminho inexistente'
                }
                else {
                    $sz = Get-SizeGB $it.path
                    Remove-Item -LiteralPath $it.path -Recurse -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $it.path) {
                        $left = Get-SizeGB $it.path
                        $status = 'parcial'
                        $detail = "restou {0} GB (arquivo em uso)" -f $left
                    }
                    else {
                        $detail = "{0} GB removidos" -f $sz
                    }
                }
            }
            'command' {
                $out = cmd /c $it.command 2>&1 | Out-String
                $code = $LASTEXITCODE
                if ($code -ne 0) { $status = 'parcial'; $detail = "exit=$code :: " + ($out -replace '\s+', ' ').Substring(0, [Math]::Min(160, ($out -replace '\s+', ' ').Length)) }
                else { $detail = 'ok' }
            }
            'uninstall' {
                if (-not (Test-Path -LiteralPath $uninstallScript)) {
                    $status = 'erro'; $detail = 'uninstall.ps1 nao encontrado'
                }
                else {
                    $argsList = @('-NoProfile', '-File', $uninstallScript, '-DisplayName', $it.displayName, '-Execute')
                    if ($it.alsoRemove) { $argsList += @('-AlsoRemove') + @($it.alsoRemove) }
                    $out = & pwsh @argsList 2>&1 | Out-String
                    if ($out -match 'Entrada de registro AINDA existe') { $status = 'parcial'; $detail = 'registro orfao' }
                    elseif ($out -match 'Erro|Exception') { $status = 'parcial'; $detail = 'ver log' }
                    else { $detail = 'desinstalado' }
                }
            }
            default {
                $status = 'erro'; $detail = "kind invalido: $($it.kind)"
            }
        }
    }
    catch {
        $status = 'erro'; $detail = $_.Exception.Message
    }

    $freeEnd = Get-FreeGB
    $delta = [math]::Round($freeEnd - $freeStart, 2)
    Write-Log ("{0,-10} {1,-40} {2,8} GB | {3}" -f $status, $label, $delta, $detail)
    $results += [pscustomobject]@{ id = $it.id; label = $label; status = $status; deltaGb = $delta; detail = $detail }
}

$freeAfter = Get-FreeGB
$total = [math]::Round($freeAfter - $freeBefore, 2)

Write-Host ''
Write-Host '--- Resultado do tier ---' -ForegroundColor Cyan
$results | Format-Table @{n='Status';e={$_.status}}, @{n='Item';e={$_.label}}, @{n='DeltaGB';e={$_.deltaGb}}, @{n='Detalhe';e={$_.detail}} -AutoSize
Write-Host ''
Write-Host ("Espaco livre: {0} GB -> {1} GB   (delta do tier: {2} GB)" -f $freeBefore, $freeAfter, $total)

if ($results | Where-Object { $_.status -eq 'parcial' -or $_.status -eq 'erro' }) {
    Write-Host ''
    Write-Host 'Itens com pendencia (normalmente arquivo em uso por processo ativo):' -ForegroundColor DarkYellow
    $results | Where-Object { $_.status -in 'parcial', 'erro' } | ForEach-Object { Write-Host ("  - {0}: {1}" -f $_.label, $_.detail) }
}

$log | Out-File -FilePath $LogPath -Encoding utf8
Write-Host ''
Write-Host "Log: $LogPath"
