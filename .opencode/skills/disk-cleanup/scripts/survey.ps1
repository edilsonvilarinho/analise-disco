<#
.SYNOPSIS
    Survey read-only do uso de disco no Windows.

.DESCRIPTION
    Mede o volume inteiro em UMA varredura, agrupa por nivel, corrige o erro de
    tamanho de placeholder cloud (OneDrive/DriveFS reportam o tamanho logico
    do arquivo, nao o espaco realmente ocupado), lista as entradas de
    desinstalacao do registro e roda o DISM /AnalyzeComponentStore.

    Nao modifica nada. Leitura pura.

.EXAMPLE
    pwsh -NoProfile -File survey.ps1 -Depth 2 -OutJson out/survey.json
#>
[CmdletBinding()]
param(
    [string]$Volume = 'C:',
    [ValidateSet(1, 2)]
    [int]$Depth = 2,
    [string]$OutJson = '',
    [ValidateRange(5, 60)]
    [int]$Top = 15,
    [string]$UninstallRegex = '.+',
    [ValidateRange(10, 500)]
    [int]$UninstallLimit = 60,
    [switch]$LargeFiles,
    [double]$LargeFileGb = 1.5,
    [switch]$SkipDism
)

$ErrorActionPreference = 'Continue'
$sw = [Diagnostics.Stopwatch]::StartNew()

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

function Format-GB {
    param([double]$Bytes)
    if ($null -eq $Bytes) { return 0 }
    [math]::Round($Bytes / 1GB, 2)
}

# Tamanho real em disco (cluster allocation), diferente do tamanho logico.
# Para arquivos com placeholder de nuvem retorna ~0, que e o que importa.
if (-not ('DiskCleanup.RealSize' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RealSize {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetCompressedFileSizeW(string path, out uint high);
    public static long Of(string file) {
        uint high;
        uint low = GetCompressedFileSizeW(file, out high);
        if (low == 0xFFFFFFFF) {
            int err = Marshal.GetLastWin32Error();
            if (err != 0) return 0;
        }
        return ((long)high << 32) | low;
    }
}
'@
}

function Get-RealSizeOfFile {
    param([string]$Path)
    try { [DiskCleanup.RealSize]::Of($Path) } catch { 0 }
}

function Normalize-Root {
    <#
        "C:\" e a raiz do volume. "C:" e o diretorio ATUAL da unidade - e um
        erro classico do PowerShell que faz Get-ChildItem listar o cwd em vez
        do volume inteiro. Aqui o caminho e sempre normalizado.
    #>
    param([string]$Path)
    $p = $Path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { return ($p + '\') }
    return $p
}

<#
    Varre a arvore UMA vez e acumula o tamanho por prefixo de N segmentos.
    Uma varredura para todo o volume e muito mais rapido do que uma por
    diretorio filho (o bug classico de "Get-ChildItem -Recurse em loop").
#>
function Get-SizeMap {
    param(
        [string]$Root,
        [int]$Segments = 1
    )
    $map = @{}
    $base = Normalize-Root $Root
    $prefixLen = $base.Length
    if (-not $base.EndsWith('\')) { $prefixLen++ }

    Get-ChildItem -LiteralPath $base -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($prefixLen)
        if ($rel.Length -eq 0) { return }

        $idx = -1
        $pos = 0
        for ($i = 0; $i -lt $Segments; $i++) {
            $idx = $rel.IndexOf('\', $pos)
            if ($idx -lt 0) { break }
            $pos = $idx + 1
        }
        $key = if ($idx -lt 0) { $rel } else { $rel.Substring(0, $idx) }

        if ($map.ContainsKey($key)) { $map[$key] = $map[$key] + $_.Length }
        else { $map[$key] = $_.Length }
    }
    return $map
}

$CloudNamePattern = 'OneDrive|Google Drive|Dropbox|iCloud|Box Drive|Meu Drive|MeuDrive'

function Test-CloudRoot {
    <#
        So por NOME. Detectar por "e reparse point" e classico demais: os
        known folders do Windows (Meus Documentos, Menu Iniciar, Ambiente de
        Rede) tambem sao reparse points e nao tem nada a ver com nuvem.
    #>
    param([string]$Path)
    return ((Split-Path $Path -Leaf) -match $CloudNamePattern)
}

# --------------------------------------------------------------------------
# 1. Estado do volume
# --------------------------------------------------------------------------

$letter = ($Volume -replace '[:\\]', '')
$vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
if (-not $vol) { Write-Error "Volume '$Volume' nao encontrado."; exit 1 }

$volRoot = (Normalize-Root $Volume)

$report = [pscustomobject]@{
    generatedAt     = (Get-Date).ToString('o')
    computer        = $env:COMPUTERNAME
    user            = $env:USERNAME
    userProfile     = $env:USERPROFILE
    volume          = [pscustomobject]@{
        letter  = "$letter`:"
        totalGb = Format-GB $vol.Size
        usedGb  = Format-GB ($vol.Size - $vol.SizeRemaining)
        freeGb  = Format-GB $vol.SizeRemaining
        usedPct = [math]::Round((($vol.Size - $vol.SizeRemaining) / $vol.Size) * 100, 1)
    }
    roots           = @()
    children        = @{}
    profile         = @()
    cloudRoots      = @()
    largeFiles      = @()
    uninstall       = @()
    dism            = $null
    notes           = @()
    elapsedSeconds  = 0
}

Write-Host ''
Write-Host '=== SURVEY DE DISCO ===' -ForegroundColor Cyan
Write-Host ("Computador : {0}  ({1})" -f $env:COMPUTERNAME, $env:USERNAME)
Write-Host ("Volume     : {0}  total {1} GB | usado {2} GB | livre {3} GB ({4}%)" -f `
        $report.volume.letter, $report.volume.totalGb, $report.volume.usedGb, $report.volume.freeGb, $report.volume.usedPct)
Write-Host ''

# --------------------------------------------------------------------------
# 2. Varredura unica + agrupamento
# --------------------------------------------------------------------------

Write-Host '[1/5] Varrendo arvore do volume (1 passada)...' -ForegroundColor Yellow
$segments = if ($Depth -ge 2) { 2 } else { 1 }
$map = Get-SizeMap -Root $volRoot -Segments $segments

# Nivel 1: primeiro segmento da chave.
$rootTotals = @{}
foreach ($k in $map.Keys) {
    $r = $k.Split('\')[0]
    if (-not $rootTotals.ContainsKey($r)) { $rootTotals[$r] = 0L }
    $rootTotals[$r] += $map[$k]
}

$rootItems = Get-ChildItem -LiteralPath $volRoot -Force -Directory -ErrorAction SilentlyContinue
$rootList = foreach ($d in $rootItems) {
    $logical = if ($rootTotals.ContainsKey($d.Name)) { $rootTotals[$d.Name] } else { 0L }
    [pscustomobject]@{
        path      = $d.FullName
        logicalGb = Format-GB $logical
        modified  = $d.LastWriteTime.ToString('yyyy-MM-dd')
        cloud     = (Test-CloudRoot $d.FullName)
    }
}
# Arquivos soltos na raiz (pagefile.sys, hiberfil.sys...)
foreach ($k in $rootTotals.Keys) {
    if ($rootList | Where-Object { (Split-Path $_.path -Leaf) -eq $k }) { continue }
    $f = Get-Item -LiteralPath (Join-Path $volRoot $k) -Force -ErrorAction SilentlyContinue
    if ($f -and -not $f.PSIsContainer) {
        $rootList += [pscustomobject]@{
            path = $f.FullName; logicalGb = Format-GB $rootTotals[$k]
            modified = $f.LastWriteTime.ToString('yyyy-MM-dd'); cloud = $false
        }
    }
}
$report.roots = @($rootList | Sort-Object -Property logicalGb -Descending)

Write-Host ''
Write-Host '--- Por raiz do volume ---'
$report.roots | Select-Object -First $Top | Format-Table @{n='Caminho';e={Split-Path $_.path -Leaf}},
    @{n='GB';e={$_.logicalGb}}, @{n='Modificado';e={$_.modified}}, @{n='Cloud';e={if($_.cloud){'SIM'}else{''}}} -AutoSize

# --------------------------------------------------------------------------
# 3. Nivel 2
# --------------------------------------------------------------------------

if ($Depth -ge 2) {
    Write-Host ''
    Write-Host '[2/5] Detalhando nivel 2...' -ForegroundColor Yellow

    # As chaves do mapa JA sao de nivel 2 ("Pai\Filho"). Agrupa por pai.
    $byParent = @{}
    foreach ($k in $map.Keys) {
        $parts = $k.Split('\')
        if ($parts.Count -lt 2) { continue }
        $parent = $parts[0]
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = @() }
        $byParent[$parent] += [pscustomobject]@{ name = $parts[1]; size = $map[$k]; key = $k }
    }

    $children = @{}
    $cloudRoots = @($report.roots | Where-Object { $_.cloud } | ForEach-Object { $_.path })
    $parents = @($byParent.Keys | Sort-Object { ($byParent[$_] | Measure-Object -Property size -Sum).Sum } -Descending)

    $shown = 0
    foreach ($parent in $parents) {
        if ($shown -ge 12) { break }
        if ($cloudRoots | Where-Object { $parent -eq (Split-Path $_ -Leaf) }) { continue }
        $shown++

        $items = @($byParent[$parent] | Sort-Object -Property size -Descending)
        $children[$parent] = , $items

        $parentTotal = ($items | Measure-Object -Property size -Sum).Sum
        Write-Host ''
        Write-Host ("--- {0}  ({1} GB) ---" -f $parent, (Format-GB $parentTotal))
        $items | Select-Object -First 8 | ForEach-Object {
            $full = Join-Path (Join-Path $volRoot $parent) $_.name
            $it = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            Write-Host ("   {0,-44} {1,8} GB   {2}" -f $_.name, (Format-GB $_.size),
                $(if ($it) { $it.LastWriteTime.ToString('yyyy-MM-dd') } else { '' }))
        }
    }

    $report.children = $children
}

# --------------------------------------------------------------------------
# 2b. Perfil do usuario (onde vive a maior parte do lixo)
# --------------------------------------------------------------------------

Write-Host ''
Write-Host '[2b/5] Detalhando o perfil do usuario...' -ForegroundColor Yellow
$profileMap = Get-SizeMap -Root $env:USERPROFILE -Segments 1
$profileItems = foreach ($d in (Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Directory -ErrorAction SilentlyContinue)) {
    $logical = if ($profileMap.ContainsKey($d.Name)) { $profileMap[$d.Name] } else { 0L }
    [pscustomobject]@{
        path      = $d.FullName
        sizeGb    = Format-GB $logical
        modified  = $d.LastWriteTime.ToString('yyyy-MM-dd')
        cloud     = (Test-CloudRoot $d.FullName)
    }
}
$report.profile = @($profileItems | Sort-Object -Property sizeGb -Descending)
$report.profile | Select-Object -First $Top | Format-Table @{n='Pasta';e={Split-Path $_.path -Leaf}},
    @{n='GB';e={$_.sizeGb}}, @{n='Mod';e={$_.modified}}, @{n='Cloud';e={if($_.cloud){'SIM'}else{''}}} -AutoSize

# --------------------------------------------------------------------------
# 4. Pastas de nuvem: logico vs real
# --------------------------------------------------------------------------

Write-Host ''
Write-Host '[3/5] Medindo tamanho real das pastas de nuvem...' -ForegroundColor Yellow
$cloudList = @()
foreach ($d in (Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Directory -ErrorAction SilentlyContinue)) {
    if (-not (Test-CloudRoot $d.FullName)) { continue }
    $logical = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $real = 0L
    Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $real += (Get-RealSizeOfFile $_.FullName)
    }
    $cloudList += [pscustomobject]@{
        path          = $d.FullName
        logicalGb     = Format-GB $logical
        realGb        = Format-GB $real
        placeholderGb = Format-GB ($logical - $real)
    }
}
$report.cloudRoots = @($cloudList)

if ($cloudList.Count -gt 0) {
    $report.cloudRoots | Format-Table @{n='Pasta';e={Split-Path $_.path -Leaf}},
        @{n='LogicoGB';e={$_.logicalGb}}, @{n='RealGB';e={$_.realGb}}, @{n='PlaceholderGB';e={$_.placeholderGb}} -AutoSize
    $report.notes += 'Pastas de nuvem: use RealGB. LogicoGB conta arquivos que nao ocupam disco.'
    $report.notes += 'Os totais por raiz sao CONSERVADORES: a varredura recursiva do PowerShell nao desce nas pastas de nuvem com placeholder. A tabela acima traz o tamanho logico completo delas.'
}
else {
    Write-Host '(nenhuma pasta de nuvem detectada)'
}

# --------------------------------------------------------------------------
# 5. Arquivos grandes
# --------------------------------------------------------------------------

Write-Host ''
if ($LargeFiles) {
    Write-Host "[4/5] Localizando arquivos > $LargeFileGb GB..." -ForegroundColor Yellow
    $limit = $LargeFileGb * 1GB
    $big = Get-ChildItem -LiteralPath $volRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt $limit } |
        Sort-Object Length -Descending | Select-Object -First 40
    $report.largeFiles = @($big | ForEach-Object {
            [pscustomobject]@{ path = $_.FullName; sizeGb = Format-GB $_.Length; modified = $_.LastWriteTime.ToString('yyyy-MM-dd') }
        })
    $report.largeFiles | Format-Table @{n='Arquivo';e={$_.path}}, @{n='GB';e={$_.sizeGb}}, @{n='Mod';e={$_.modified}} -AutoSize
}
else {
    Write-Host '[4/5] Busca de arquivos grandes pulada (use -LargeFiles para ativar)' -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# 6. Entradas de desinstalacao
# --------------------------------------------------------------------------

Write-Host ''
Write-Host '[5/5] Lendo registro de desinstalacao...' -ForegroundColor Yellow
$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$uninst = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.UninstallString -and $_.DisplayName -match $UninstallRegex } |
    Sort-Object DisplayName -Unique

$report.uninstall = @($uninst | ForEach-Object {
        [pscustomobject]@{
            displayName     = $_.DisplayName
            version         = $_.DisplayVersion
            publisher       = $_.Publisher
            installLocation = $_.InstallLocation
            uninstallString = $_.UninstallString
        }
    })

Write-Host ("total de entradas com desinstalador: {0}" -f $report.uninstall.Count)
$report.uninstall | Select-Object -First $UninstallLimit |
    Format-Table @{n='Aplicativo';e={$_.displayName}}, @{n='Ver';e={$_.version}},
    @{n='UninstallString';e={if($_.uninstallString.Length -gt 70){$_.uninstallString.Substring(0,70)+'...'}else{$_.uninstallString}}} -AutoSize
if ($report.uninstall.Count -gt $UninstallLimit) {
    Write-Host ("... e mais {0} entradas (o JSON tem todas)" -f ($report.uninstall.Count - $UninstallLimit))
}

# --------------------------------------------------------------------------
# 7. DISM
# --------------------------------------------------------------------------

if (-not $SkipDism) {
    Write-Host ''
    Write-Host 'DISM /AnalyzeComponentStore ...' -ForegroundColor Yellow
    $dismOut = & dism /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String
    $report.dism = [pscustomobject]@{ available = $true; raw = $dismOut }
    $dismOut -split "`r?`n" | Where-Object { $_ -match 'Real Size|Size of Component|Backups|Cache and Temp|Recoverable|recommend' } |
        ForEach-Object { Write-Host ('   ' + $_.Trim()) }
}
else {
    $report.dism = [pscustomobject]@{ available = $false }
}

# --------------------------------------------------------------------------
# 8. Saida
# --------------------------------------------------------------------------

$report.elapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
Write-Host ''
Write-Host ("Concluido em {0}s" -f $report.elapsedSeconds)

if ($OutJson) {
    $outDir = Split-Path $OutJson -Parent
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    $report | ConvertTo-Json -Depth 8 | Out-File -FilePath $OutJson -Encoding utf8
    Write-Host "JSON gravado em: $OutJson" -ForegroundColor Green
}
