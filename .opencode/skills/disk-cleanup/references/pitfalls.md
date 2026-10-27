# Armadilhas — erros que custaram tempo em uma execução real

Todos estes aconteceram em uma sessão de limpeza real (155 GB recuperados) ou
durante o teste dos scripts da própria skill. Cada um produziu um resultado
silenciosamente errado ou uma falha que só apareceu no log.

---

## 1. Função com nome de alias

```powershell
function Rm($p,$rot){ ... Remove-Item -LiteralPath $p ... }
Rm "$L\npm-cache\_npx" "npm staging"
```

**Erro:** `Remove-Item: Não foi possível encontrar um parâmetro posicional que
aceite o argumento 'npm staging'.`

**Por quê:** no PowerShell a precedência é **alias > função > cmdlet**. O alias
`rm` (=`Remove-Item`) ganha da função `Rm`, então a função nunca é chamada e o
segundo argumento vira lixo para o `Remove-Item`.

**Como evitar:** nomeie funções de verdade (`Del-Path`, `Invoke-DiskAction`) e
nunca com o nome de um alias (`rm`, `ls`, `cat`, `cp`, `mv`, `cd`, `echo`, `w`,
`which`).

---

## 2. `Start-Process -ArgumentList` em array não aplica aspas

```powershell
Start-Process setup.exe -ArgumentList "uninstall","--installPath","C:\Program Files (x86)\...\2019\BuildTools","--quiet"
```

**Erro:** o instalador sai com code 1 e o log mostra
`installPath: C:\Program` — o caminho foi truncado no primeiro espaço.

**Por quê:** `-ArgumentList` com array concatena os itens com espaço **sem**
aspas. O instalador recebeu um caminho de 5 palavras.

**Como evitar:** passe a linha inteira como uma string única:

```powershell
$args1 = 'uninstall --installPath "C:\Program Files (x86)\...\2019\BuildTools" --quiet --norestart'
Start-Process setup.exe -ArgumentList $args1
```

`scripts/uninstall.ps1` já faz isso para todos os tipos de instalador.

---

## 3. Tamanho lógico de pasta de nuvem

**Sintoma:** OneDrive "Informata GC" medido em 60 GB, mas o PC Manager
mostrava 9,1 GB. A soma "logística" do perfil dava 285 GB contra 226 GB reais.

**Por quê:** `Get-ChildItem` devolve `Length` = tamanho **lógico** do arquivo.
Arquivos com placeholder de nuvem (Google Drive streaming, OneDrive Files
On-Demand) reportam o tamanho completo mesmo ocupando 0 bytes.

**Como evitar:** meça o tamanho alocado com `GetCompressedFileSizeW`. Compare
`LogicoGB` vs `RealGB` e use o real. `scripts/survey.ps1` faz isso.

**Armadilha relacionada:** apresentar "161 GB no Google Drive" como se ocupasse
disco leva o usuário a planejar errado.

---

## 4. Qual instalação do IDE sobrevive

**Sintoma:** três instalações do Android Studio (`Android Studio` 2,88 GB,
`android-studio2` 3,01 GB, `Android Studio1` 1,54 GB) e a decisão inicial foi
manter a "mais nova" (a 2025.3).

**Realidade:** o atalho do menu Iniciar apontava para
`C:\Program Files\Android\Android Studio\bin\studio64.exe` (a **2024.3**). A
2025.3 era um build Canary (`studio64Panda3Canary1.exe`) que ninguém usa. A
decisão estava invertida.

**Como evitar:** antes de remover qualquer instalação duplicada, verifique:

```powershell
$sh = New-Object -ComObject WScript.Shell
Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu" -Recurse -Filter *.lnk |
  ForEach-Object { $sh.CreateShortcut($_.FullName).TargetPath } | Where-Object { $_ -match 'Android' }
```

E leia `product-info.json` de cada instalação para a versão real. "Modificado
mais recentemente" não significa "usada".

---

## 5. Ferramenta no `PATH` removida silenciosamente

**Sintoma:** CUDA Toolkit 11.8 (2,64 GB) estava na lista de tier B.

**Por quê:** `CUDA_PATH` estava definido no sistema e `...\CUDA\v11.8\bin`
estava no `PATH`. Remover quebra qualquer build de extensão CUDA.

**Como evitar:** antes de propor tier B, verifique `PATH` e variáveis de
ambiente que apontem para o alvo:

```powershell
$env:CUDA_PATH
($env:PATH -split ';') | Where-Object { $_ -match 'CUDA|Android|gradle' }
```

Se apontar, apresente o custo e deixe o usuário decidir. 2 GB não compensam
quebrar toolchain.

---

## 6. Resíduo em `ProgramData` após desinstalar

**Sintoma:** NVIDIA ChatRTX desinstalado com sucesso, `Program Files` limpo —
mas `C:\ProgramData\NVIDIA Corporation\ChatRTX` continuava com **11,15 GB** de
modelos (mistral-7b).

**Por quê:** o desinstalador NVIDIA limpa só a parte em `Program Files`. Dados
em `ProgramData` são de responsabilidade do app e ficam órfãos.

**Como evitar:** depois de cada tier B, meça de novo as pastas conhecidas do
app em `ProgramData` e remova o resíduo explicitamente. `uninstall.ps1` aceita
`-AlsoRemove` para isso.

---

## 7. `freelist_count = 0` no SQLite significa bloat real

**Sintoma:** `opencode.db` com 8,24 GB e `freelist_count = 0`. A intuição de
que "SQLite não devolve espaço" sugeria compactar.

**Realidade:** não há espaço livre. O bloat é **dado vivo**: a tabela `event`
guarda um snapshot completo de cada `message part` a cada update. 229.893
eventos = 7,94 GB, enquanto as tabelas `part` e `message` somavam 102 MB.

**Como evitar:** `VACUUM` sem `DELETE` não faz nada. O caminho é remover a
sessão culpada (`opencode session delete <id>`) e só então compactar.

**Armadilha maior:** a sessão culpada costuma ser a **atual**. Descobrir isso no
meio da análise e não poder corrigir é o motivo de medir cedo.

---

## 8. Output grande de ferramenta vira bloat permanente

**Sintoma:** a mesma análise de disco que produziu o diagnóstico acima consumiu
~8 GB de banco porque cada listagem grande foi re-snapshotada durante o
streaming.

**Por quê:** o opencode emite um evento `message.part.updated` por chunk de
stream, e cada evento carrega o payload **completo** da part. Payload de
50 MB re-emitido 100 vezes = 5 GB.

**Como evitar:**

- Filtre e agregue **no shell**, não no modelo:
  `Select-Object -First 40`, `Group-Object`, `Measure-Object`.
- Nunca peça "liste todos os arquivos de X" quando X tem centenas de milhares.
- Evite `Format-Table` em listagens sem `-First N`.
- Os scripts da skill já emitem tabelas condensadas por isso.

---

## 9. Desinstalador que abre janela e trava

**Sintoma:** `Start-Process ... -Wait` com o desinstalador NVIDIA devolveu
`exit=` vazio e nada foi removido. Na verdade o instalador **estava rodando**,
esperando confirmação numa janela, e a segunda tentativa falhou porque já
havia instância.

**Como evitar:**

- Confira `Get-Process | Where MainWindowTitle` antes de tentar de novo.
- O desinstalador NVIDIA (`RunDll32` + `NVI2.DLL`) abre UI: verifique se
  o processo persiste e espere, em vez de relançar.
- `uninstall.ps1` usa `-WindowStyle Hidden` e espera o PID original.

---

## 10. Volume mudou no meio da medição

**Sintoma:** a pasta `steamapps\downloading` media 82,44 GB na primeira
varredura e 0 GB na segunda, sem ninguém ter apagado nada.

**Realidade:** um download do Steam estava em andamento. O conteúdo foi movido
para `steamapps\common` durante a análise. A contagem de "82 GB de download
incompleto wasted" estava errada — o download simplesmente tinha terminado.

**Como evitar:** em diretórios que mudam sozinhos (downloads, `downloading`,
sync de nuvem), meça duas vezes com intervalo ou verifique `LastWriteTime`
recente antes de classificar como resíduo.

---

## 11. `param([string]$X)` restringe a variável nas atribuições seguintes

```powershell
param([string]$Plan)
$plan = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json
if (-not $plan.tiers.$Tier) { ... }   # => sempre true, $plan virou string
```

**Erro:** `Tier 'A' nao existe no plano. Disponiveis: ` (lista vazia).

**Por quê:** um parâmetro declarado com tipo cria uma variável **com restrição
de tipo**. Atribuir um `PSCustomObject` a ela coage o valor para `System.String`.
O `$plan` deixa de ser o objeto e vira a string `"@{volume=...; tiers=...}"`.
`$plan.tiers` é `$null`, e `$plan.PSObject.Properties.Name` devolve só
`Length`.

**Como evitar:** nunca reutilize o nome do parâmetro para guardar outro tipo.
Use `$planData`. E note que o erro aparece "vazio" — parece bug de lógica, mas
é coerção de tipo.

---

## 12. `"C:"` não é a raiz do volume

```powershell
Get-ChildItem -LiteralPath "C:" -Recurse -File   # => o diretório ATUAL na unidade C:
Get-ChildItem -LiteralPath "C:\" -Recurse -File  # => o volume inteiro
```

**Sintoma:** a varredura do volume retornou 0 GB em toda raiz, porque o
`Get-SizeMap` recebeu `"C:"` e listou só a pasta de trabalho.

**Como evitar:** normalize a raiz antes de usar. A skill faz isso em
`Normalize-Root`.

---

## 13. Atribuir array com um elemento a uma chave de hashtable descompacta

```powershell
$h = @{}
$h['x'] = @($obj)          # vira o próprio $obj, nao array
$h['x'][0]                 # => MetadataError: nao converte PSCustomObject para Int32
```

**Como evitar:** `$h['x'] = , @($obj)` — o operador vírgula preserva o array.

---

## 14. `$Args` é variável automática

```powershell
function f { param([string]$Exe, [string]$Args) ... }   # $Args nao amarra
```

**Sintoma:** o tipo do instalador era sempre `unknown`, mesmo para casos
óbvios.

**Por quê:** `$args` é a variável automática de argumentos não vinculados. Passar
`-Args` não funciona como se espera.

**Como evitar:** chame o parâmetro de `$Arguments`.

---

## 15. `Select-Object -First N` mata o pipeline a montante

```powershell
pwsh -File script.ps1 | Select-Object -First 60   # script pode morrer antes de terminar
```

**Sintoma:** o JSON de saída ficou com seções vazias porque o script foi
abortado no meio pelo `Select-Object`.

**Como evitar:** para ver só o começo de uma saída longa, redirecione para um
arquivo e leia o arquivo. Nunca encadeie `Select-Object -First` na frente de um
processo que precisa completar.

---

## 16. Reparse point não é sinônimo de nuvem

**Sintoma:** "Meus Documentos", "Menu Iniciar", "Ambiente de Rede" e
"Configurações Locais" apareceram como pastas de nuvem — são known folders do
Windows, com `Target` apontando para dentro do próprio perfil.

**Como evitar:** detecte nuvem **pelo nome** (`OneDrive*`, `*Google Drive*`,
`Dropbox`, `iCloud`, `Box`), nunca só por atributo de reparse point.

---

## 17. A varredura recursiva não desce em pastas de nuvem com placeholder

**Sintoma:** a varredura plana do perfil deu 209 GB, mas a pasta
`OneDrive - Informata GC` sozinha tem 60 GB lógicos — e a soma dos filhos
dava 285 GB.

**Por quê:** `Get-ChildItem -Recurse` não percorre o conteúdo de pastas de
nuvem com placeholder, então os totais por raiz são **conservadores**.

**Como evitar:** enumere as pastas de nuvem separadamente e reporte
`LogicoGB` vs `RealGB`. Deixe isso explícito no relatório, senão os números não
fecham com o que o usuário vê no PC Manager.
