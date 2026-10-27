<#
.SYNOPSIS
    Executa um desinstalador Windows de forma segura e verificavel.

.DESCRIPTION
    Localiza a entrada de desinstalacao no registro (ou aceita a string
    diretamente), identifica o TIPO do instalador e monta a linha de comando
    correta para modo silencioso. Depois executa, reporta o codigo de saida e
    mede o que sobrou.

    Tipos detectados:
      MSI          -> msiexec.exe /x {GUID} /qn /norestart
      NSIS         -> "<exe>" /S
      Inno Setup   -> "<exe>" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
      VS Installer -> setup.exe uninstall --installPath "<caminho>" --quiet --norestart
      NVIDIA core  -> RunDll32 + NVI2.DLL (executa a string do registro como esta)

    Dois erros que custaram tempo em uma execucao real estao corrigidos aqui:
      1. Start-Process com -ArgumentList em ARRAY nao aplica aspas: um caminho
         com espacos e truncado ("installPath: C:\Program") e o instalador
         falha. Aqui a linha inteira e passada como string unica.
      2. Remover a pasta do programa com Remove-Item deixa registro orfao e
         MSI quebrado. Aqui sempre se usa o desinstalador.

.EXAMPLE
    pwsh -NoProfile -File uninstall.ps1 -DisplayName 'NVIDIA ChatRTX'
    pwsh -NoProfile -File uninstall.ps1 -DisplayName 'NVIDIA ChatRTX' -Execute
#>
[CmdletBinding()]
param(
    [string]$DisplayName = '',
    [string]$UninstallString = '',
    [string[]]$AlsoRemove = @(),
    [switch]$Execute,
    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Continue'

function Split-CommandString {
    param([string]$CommandLine)
    $s = $CommandLine.Trim()
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -lt 0) { return [pscustomobject]@{ Exe = $s.Trim('"'); Args = '' } }
        return [pscustomobject]@{ Exe = $s.Substring(1, $end - 1); Args = $s.Substring($end + 1).Trim() }
    }
    $idx = $s.IndexOf(' ')
    if ($idx -lt 0) { return [pscustomobject]@{ Exe = $s; Args = '' } }
    return [pscustomobject]@{ Exe = $s.Substring(0, $idx); Args = $s.Substring($idx + 1).Trim() }
}

function Get-InstallerKind {
    # Nao usar $Args como nome de parametro: e uma variavel automatica do
    # PowerShell e o binding silenciosamente falha.
    param([string]$Exe, [string]$Arguments)
    if ($Arguments -match 'NVI2\.DLL') { return 'nvidia-core' }
    if ($Exe -match 'Microsoft Visual Studio\\Installer\\setup\.exe') { return 'vs-installer' }
    if ($Exe -match '(?i)msiexec\.exe$') { return 'msi' }
    if (Test-Path -LiteralPath $Exe) {
        try {
            $bytes = [IO.File]::ReadAllBytes($Exe)
            # A assinatura do Nullsoft costuma estar no fim do binario, entao
            # em arquivos pequenos le tudo; em grandes le o inicio e o fim.
            if ($bytes.Length -le 6291456) {
                $head = [Text.Encoding]::ASCII.GetString($bytes)
            }
            else {
                $head = [Text.Encoding]::ASCII.GetString($bytes, 0, 400000) +
                [Text.Encoding]::ASCII.GetString($bytes, ($bytes.Length - 400000), 400000)
            }
            if ($head -match 'Nullsoft') { return 'nsis' }
            if ($head -match 'Inno Setup|JR\.Inno') { return 'inno' }
        } catch { }
    }
    return 'unknown'
}

function Get-SizeGB {
    param([string]$Path)
    if (-not $Path) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and -not $item.PSIsContainer) { return [math]::Round($item.Length / 1GB, 3) }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    return [math]::Round(($sum) / 1GB, 3)
}

# --------------------------------------------------------------------------
# Localizar a entrada
# --------------------------------------------------------------------------

$entry = $null
if ($UninstallString) {
    $entry = [pscustomobject]@{ DisplayName = '(fornecida manualmente)'; DisplayVersion = ''; InstallLocation = ''; UninstallString = $UninstallString }
}
else {
    if (-not $DisplayName) { Write-Error "Informe -DisplayName (regex) ou -UninstallString."; exit 1 }
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $matches = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.UninstallString -and $_.DisplayName -match $DisplayName }
    if (-not $matches) { Write-Error "Nenhuma entrada de desinstalacao casou com '$DisplayName'."; exit 1 }
    if ($matches.Count -gt 1) {
        Write-Host "Entradas que casam:" -ForegroundColor Yellow
        $matches | ForEach-Object { Write-Host ("  - {0}  [{1}]" -f $_.DisplayName, $_.DisplayVersion) }
        Write-Error "Ambiguo: ajuste o regex para casar exatamente uma entrada."
        exit 1
    }
    $entry = $matches[0]
}

$parsed = Split-CommandString $entry.UninstallString
$kind = Get-InstallerKind -Exe $parsed.Exe -Arguments $parsed.Args

# --------------------------------------------------------------------------
# Montar a linha de comando
# --------------------------------------------------------------------------

$cmdLine = $null
switch ($kind) {
    'msi' {
        $guid = [regex]::Match($entry.UninstallString, '\{[0-9A-Fa-f\-]{36}\}').Value
        if (-not $guid) { Write-Error "Nao foi possivel extrair o GUID do MSI."; exit 1 }
        $cmdLine = "msiexec.exe /x $guid /qn /norestart"
    }
    'nsis' {
        $cmdLine = '"' + $parsed.Exe + '" /S'
    }
    'inno' {
        $cmdLine = '"' + $parsed.Exe + '" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    }
    'vs-installer' {
        # O caminho precisa ir entre aspas: sem isso o instalador ve "C:\Program".
        $ip = [regex]::Match($entry.UninstallString, '--installPath\s+"([^"]+)"').Groups[1].Value
        if (-not $ip) { Write-Error "Nao foi possivel extrair --installPath."; exit 1 }
        $cmdLine = '"' + $parsed.Exe + '" uninstall --installPath "' + $ip + '" --quiet --norestart'
    }
    'nvidia-core' {
        $cmdLine = $entry.UninstallString
    }
    default {
        $cmdLine = $entry.UninstallString
    }
}

# --------------------------------------------------------------------------
# Relatorio e execucao
# --------------------------------------------------------------------------

$loc = $entry.InstallLocation
$before = if ($loc) { Get-SizeGB $loc } else { 0 }

Write-Host ''
Write-Host '=== DESINSTALADOR ===' -ForegroundColor Cyan
Write-Host ("Aplicativo   : {0} {1}" -f $entry.DisplayName, $entry.DisplayVersion)
Write-Host ("Tipo         : {0}" -f $kind)
Write-Host ("Instalado em : {0}" -f $(if ($loc) { $loc } else { '(nao informado)' }))
Write-Host ("Tamanho      : {0} GB" -f $before)
Write-Host ("Comando      : {0}" -f $cmdLine)
Write-Host ''

if (-not $Execute) {
    Write-Host 'DRY-RUN. Nada foi executado.' -ForegroundColor DarkYellow
    Write-Host 'Use -Execute para rodar de verdade.' -ForegroundColor DarkYellow
    if ($AlsoRemove.Count -gt 0) {
        Write-Host ''
        Write-Host 'Residuos em ProgramData a remover apos a desinstalacao:'
        $AlsoRemove | ForEach-Object { Write-Host ("  - {0} ({1} GB)" -f $_, (Get-SizeGB $_)) }
    }
    exit 0
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $parsed.Exe -ArgumentList $cmdLine -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue

# Alguns desinstaladores relan themselves e o processo original sai na hora.
# Espera pelo PID original e depois da uma janela para o trabalho terminar.
$null = $proc.WaitForExit($TimeoutMinutes * 60 * 1000)
$exit = $proc.ExitCode
Start-Sleep -Seconds 10

Write-Host ("Concluido em {0}s | exit code = {1}" -f [math]::Round($sw.Elapsed.TotalSeconds, 1), $exit)

# Residuo em ProgramData: alguns desinstaladores so limpam Program Files.
if ($AlsoRemove.Count -gt 0) {
    foreach ($p in $AlsoRemove) {
        if (Test-Path -LiteralPath $p) {
            $sz = Get-SizeGB $p
            Write-Host ("Removendo residuo {0} ({1} GB)..." -f $p, $sz)
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $p) { Write-Host '  -> parcial (arquivo em uso)' -ForegroundColor DarkYellow }
            else { Write-Host '  -> removido' -ForegroundColor Green }
        }
    }
}

$after = if ($loc) { Get-SizeGB $loc } else { 0 }
Write-Host ''
Write-Host ("Tamanho em '{0}': {1} GB -> {2} GB" -f $(if ($loc) { $loc } else { '(desconhecido)' }), $before, $after)

$still = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq $entry.DisplayName }
if ($still) {
    Write-Host "Entrada de registro AINDA existe - desinstalacao parcial." -ForegroundColor Yellow
}
else {
    Write-Host 'Entrada de registro removida. OK.' -ForegroundColor Green
}

$left = if ($loc -and (Test-Path -LiteralPath $loc)) {
    Get-ChildItem -LiteralPath $loc -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 5 FullName
}
if ($left) {
    Write-Host ''
    Write-Host 'Arquivos remanescentes:' -ForegroundColor DarkYellow
    $left | ForEach-Object { Write-Host ("  - {0}" -f $_.FullName) }
}
