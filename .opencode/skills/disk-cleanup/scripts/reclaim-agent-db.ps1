<#
.SYNOPSIS
    Diagnostica (e opcionalmente recupera) espaco em bancos de dados de agentes.

.DESCRIPTION
    O opencode guarda um snapshot COMPLETO de cada parte de mensagem a cada
    update, em uma tabela de eventos. Uma sessao com outputs grandes infla o
    opencode.db em gigabytes mesmo que o conteudo util seja megabytes: as
    tabelas 'part' e 'message' ficam pequenas e a tabela 'event' carrega quase
    tudo.

    Este script mostra a relacao entre as tabelas, isola a sessao responsavel
    e imprime os comandos exatos para recuperar o espaco.

    Diagnostico e somente leitura. -Vacuum escreve: so use com o agente fechado.

.EXAMPLE
    pwsh -NoProfile -File reclaim-agent-db.ps1
    pwsh -NoProfile -File reclaim-agent-db.ps1 -Vacuum
#>
[CmdletBinding()]
param(
    [string]$DbPath = '',
    [switch]$Vacuum
)

$ErrorActionPreference = 'Continue'

function Find-AgentDb {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.local\share\opencode\opencode.db'),
        (Join-Path $env:USERPROFILE '.opencode\opencode.db'),
        (Join-Path $env:APPDATA 'opencode\opencode.db')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    # Fallback: procura qualquer opencode.db conhecido
    $found = Get-ChildItem -LiteralPath $env:USERPROFILE -Recurse -Depth 5 -Filter 'opencode.db' -File -Force -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

if (-not $DbPath) { $DbPath = Find-AgentDb }

if (-not $DbPath -or -not (Test-Path -LiteralPath $DbPath)) {
    Write-Host 'Nenhum opencode.db encontrado.' -ForegroundColor Yellow
    exit 0
}

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Write-Error 'Python nao encontrado no PATH (necessario para ler SQLite).'; exit 1 }

$dbSizeGB = [math]::Round((Get-Item -LiteralPath $DbPath).Length / 1GB, 2)
Write-Host ''
Write-Host '=== BANCO DO AGENTE ===' -ForegroundColor Cyan
Write-Host ("Arquivo : {0}" -f $DbPath)
Write-Host ("Tamanho : {0} GB" -f $dbSizeGB)

$analysis = @'
import sqlite3, os, sys, datetime
db = sys.argv[1]
con = sqlite3.connect("file:%s?mode=ro" % db.replace("\\", "/"), uri=True)
c = con.cursor()
pr = c.execute("pragma page_size").fetchone()[0]
pc = c.execute("pragma page_count").fetchone()[0]
fl = c.execute("pragma freelist_count").fetchone()[0]
print("PAGES      page_size=%d page_count=%d freelist=%d" % (pr, pc, fl))
print("TOTAL      %.2f GB   livre=%.2f GB" % (pr*pc/1024**3, pr*fl/1024**3))
print("")
tables = [r[0] for r in c.execute("select name from sqlite_master where type='table'")]
print("TABELAS")
for t in sorted(tables):
    try:
        n = c.execute('select count(*) from "%s"' % t).fetchone()[0]
        s = c.execute('select sum(length(coalesce(data,""))) from "%s"' % t).fetchone()[0]
    except Exception:
        n, s = 0, 0
    print("  %-22s linhas=%-9d dados=%8.1f MB" % (t, n, (s or 0)/1024/1024))
print("")
if "event" in tables:
    titles = {}
    try:
        for r in c.execute("select id, title, directory, time_updated from session"):
            titles[r[0]] = (r[1], r[2], r[3])
    except Exception:
        pass
    rows = list(c.execute("""
        select aggregate_id, count(*) n, sum(length(coalesce(data,''))) sz
        from event group by aggregate_id order by sz desc limit 8"""))
    print("TOP SESSOES POR VOLUME DE EVENTO")
    for sid, n, sz in rows:
        t, d, up = titles.get(sid, ("(sem sessao)", "", 0))
        when = datetime.datetime.fromtimestamp(up/1000).strftime("%Y-%m-%d %H:%M") if up else "?"
        print("  %-26s %9.1f MB  eventos=%-8d %s" % (sid[:26], (sz or 0)/1024/1024, n, when))
        print("      %s | %s" % (str(t)[:70], str(d)[:60]))
con.close()
'@

Write-Host ''
$analysis | python - $DbPath

if ($Vacuum) {
    Write-Host ''
    Write-Host 'VACUUM: so e seguro com o agente FECHADO.' -ForegroundColor Yellow
    $vac = @'
import sqlite3, os, sys
db = sys.argv[1]
before = os.path.getsize(db)
con = sqlite3.connect(db)
con.execute("VACUUM")
con.close()
after = os.path.getsize(db)
print("VACUUM  %.2f GB -> %.2f GB  (recuperado %.2f GB)" % (before/1024**3, after/1024**3, (before-after)/1024**3))
'@
    $vac | python - $DbPath
}
else {
    Write-Host ''
    Write-Host '--- Como recuperar ---' -ForegroundColor Cyan
    Write-Host '1) Feche o opencode.'
    Write-Host '2) Apague as sessoes indicadas acima:'
    Write-Host '     opencode session delete <sessionID>'
    Write-Host '3) Compacte o banco (com o opencode fechado):'
    Write-Host ('     python -c "import sqlite3,os; p=r''{0}''; c=sqlite3.connect(p); c.execute(''VACUUM''); c.close()"' -f $DbPath)
    Write-Host ''
    Write-Host 'Ou rode este script com -Vacuum depois de fechar o opencode.'
    Write-Host ''
    Write-Host 'PREVENCAO: saidas grandes de ferramenta viram event rows gigantes.'
    Write-Host 'Filtre e agregue no shell (Select-Object -First N, Group-Object) em vez de'
    Write-Host 'pedir a listagem completa - o modelo nao precisa do dump inteiro.'
}
