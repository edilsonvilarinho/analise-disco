---
name: disk-cleanup
description: Analisa e libera espaço em disco no Windows - faz levantamento completo do uso de disco, classifica o que é cache regenerável, o que é ferramenta desinstalável e o que é dado do usuário, monta um plano por níveis e só executa após aprovação explícita. Use sempre que o usuário falar em "C: cheio", "libera espaço", "análise de disco", "limpeza de disco", "arquivos que não uso mais", "cache ocupando tudo", "disk full", "free up disk space", "disk usage analysis", "storage cleanup", ou mostrar print do PC Manager / Storage Sense com barra de armazenamento cheia.
compatibility: Windows 10/11, PowerShell 7+ (pwsh). Requer privilégios de administrador para desinstalação e DISM.
---

# Análise e limpeza de disco (Windows)

Skill para transformar "meu disco está cheio" em um plano verificável e executado com
medição. O principio central: **nada é apagado sem medição antes/depois e sem
aprovação do usuário**.

Este workflow foi construído a partir de uma execução real que recuperou 155 GB
num volume de 953 GB. Os erros cometidos naquela execução estão registrados em
`references/pitfalls.md` — leia antes de executar qualquer coisa.

## Fluxo obrigatório

```
1. SURVEY        -> scripts/survey.ps1        (somente leitura)
2. CLASSIFICA    -> references/catalog.md      (4 tiers + exclusoes)
3. PLANO         -> presenta tabela, PERGUNTA e ESPERA aprovacao
4. EXECUCAO      -> scripts/cleanup.ps1        (um tier por vez, medindo)
5. RELATORIO     -> references/report-template.md
```

Nao pule a etapa 3. O usuario precisa ver o que vai ser removido, quanto vale
cada item e qual o risco, antes de qualquer `Remove-Item`. Deletar cache e
irreversivel do mesmo jeito que deletar documento: o fato de ser "cache" reduz o
risco, nao zera.

## Etapa 1 - Survey (somente leitura)

```powershell
pwsh -NoProfile -File .opencode/skills/disk-cleanup/scripts/survey.ps1 -Depth 2 -OutJson out/survey.json
```

Devolve: estado do volume, tamanho por raiz do volume, detalhamento de nível 2,
**perfil do usuário** (onde vive a maior parte do lixo), entradas de
desinstalação do registro, `DISM /AnalyzeComponentStore` e uma **correção de
placeholder cloud** (ver pitfalls #3 e #17).

Dois avisos sobre os números:

- **Os totais por raiz são conservadores.** A varredura recursiva do PowerShell
  não desce nas pastas de nuvem com placeholder, então `Users` aparece menor do
  que a soma dos filhos. A seção de nuvem traz o tamanho lógico completo delas.
  Use `RealGB` para ocupar disco.
- **Rode com `-Depth 2`.** Com `-Depth 1` o perfil do usuário não é detalhado e
  você perde a visibilidade de `AppData`, `.gradle`, `.m2` etc.

A varredura completa leva 3–5 minutos em volume de 1 TB. Rode uma vez, guarde o
JSON e trabalhe a partir dele — não repita a varredura a cada decisão.

O script e read-only por construcao. Se ele falhar por falta de permissao em
`Program Files`, rode o PowerShell como administrador.

**Nao despeje a listagem de arquivos no contexto.** O survey ja resume; pedir
"liste todos os arquivos" de um diretorio com 600k arquivos infla o banco de
sessoes do opencode em gigabytes (pitfalls #8). Filtre e agregue sempre no
shell, nunca no modelo.

## Etapa 2 - Classificacao em 4 tiers

O catalogo completo esta em `references/catalog.md`. Cada entrada tem caminho,
comando correto, tier, risco e sinal de obsolencia. Use como **candidatos a
verificar**, nao como lista de execucao: a presenca do caminho no disco nao
significa que o usuario nao usa aquilo.

| Tier | Significado | Exemplos | Risco |
|---|---|---|---|
| **A** | Cache regeneravel | npm-cache, pip, DXCache, Temp, LocalCache de apps | Nenhum (re-baixado) |
| **B** | Ferramenta via desinstalador | ChatRTX, Nsight, Android Studio antigo, MEmu | Baixo (reversivel so re-instalando) |
| **C** | Diretorio regeneravel | .gradle, .m2, Android SDK antigo, NGX models | Custo de re-download |
| **D** | Sistema | DISM /StartComponentCleanup | Baixo, operacao longa |

**Exclusoes obrigatorias** (nunca propor, mesmo que o usuario peça "limpar tudo"):

```
C:\Windows\Installer          C:\Windows\WinSxS  (so via DISM)
C:\pagefile.sys               C:\ProgramData\Package Cache
C:\Program Files\WindowsApps  %LOCALAPPDATA%\Packages\*\LocalState
```

Justificativas: `Windows\Installer` e o cache do MSI - sem ele, desinstalar
programa quebra. `Package Cache` guarda os instaladores que o Windows Installer
precisa para desinstalar. `WindowsApps` so a Store gerencia. `LocalState` e
dado de app, nao cache.

## Etapa 3 - Plano e aprovacao

Monte uma tabela com: item | caminho | GB | tier | acao | risco. Depois **pergunte
explicitamente** o que executar. Respostas tipicas: "A + D", "tudo menos os
jogos", "so o cache".

Decisoes que precisam ser consultadas antes de propor tier B:

- **Qual versao da ferramenta sobrevive?** Se houver varias instalacoes (varias
  versoes de Android Studio, VS, Node), verifique o atalho do menu Iniciar e
  o registro `UninstallString` para descobrir qual esta em uso. Remover a
  errada deixa o usuario sem IDE (pitfalls #4).
- **A ferramenta esta no PATH?** Se `CUDA_PATH` ou o `PATH` aponta para o
  diretorio, remover quebra build scripts. Apresente o custo explicitamente e
  deixe o usuario decidir.
- **E jogo?** Pergunte. "Manter todos" e uma resposta valida e frequente.

Monte o JSON de plano para o `cleanup.ps1`:

```json
{
  "volume": "C:",
  "tiers": {
    "A": [
      { "id": "npm-cache", "kind": "path", "label": "npm cache",
        "path": "C:\\Users\\edils\\AppData\\Local\\npm-cache", "action": "remove" }
    ],
    "B": [
      { "id": "chatrtx", "kind": "uninstall", "label": "NVIDIA ChatRTX",
        "displayName": "NVIDIA ChatRTX 0.5" }
    ],
    "D": [
      { "id": "dism", "kind": "command", "label": "Limpeza do WinSxS",
        "command": "DISM /Online /Cleanup-Image /StartComponentCleanup" }
    ]
  }
}
```

Kinds aceitos: `path` (remove diretorio/arquivo), `command` (executa comando),
`uninstall` (localiza e roda o desinstalador correto via `uninstall.ps1`).

## Etapa 4 - Execucao

```powershell
# dry-run primeiro (default do script)
pwsh -NoProfile -File .opencode/skills/disk-cleanup/scripts/cleanup.ps1 -Plan out/plan.json -Tier A

# aprovado? execute de verdade
pwsh -NoProfile -File .opencode/skills/disk-cleanup/scripts/cleanup.ps1 -Plan out/plan.json -Tier A -Execute
```

Regras de execucao:

- **Um tier por vez.** Meça o espaco livre antes e depois de cada tier e reporte
  o delta. Se um tier liberar muito menos que o previsto, investigue antes de
  seguir - normalmente significa item travado por processo ativo.
- **Item travado nao aborta o batch.** Arquivo em uso por processo ativo e
  normal (DXCache pelo driver NVIDIA, LocalCache por app aberto). O script
  registra e segue. Residuo de poucos MB e aceitavel.
- **Tier B usa `uninstall.ps1`**, nao `Remove-Item`. Pastas de programa nao se
  removem por `Remove-Item`: sobra registro orfao, chave de desinstalacao e
  estado corrompido no Windows Installer.
- **Depois de desinstalar, verifique residuo em `ProgramData`.** Alguns
  desinstaladores (NVIDIA ChatRTX) deixam o payload em `ProgramData` - 11 GB
  no caso real. Remova o residuo explicitamente.
- **Nao reinicie o sistema** sem perguntar. Alguns desinstaladores pedem
  reboot no final.

## Etapa 5 - Relatorio

Use `references/report-template.md`. O relatorio precisa de:

1. Antes/depois em GB e % de ocupacao
2. Delta por tier
3. **Decisoes que divergiram do plano** e por que (ex: "mantive a CUDA porque
   `CUDA_PATH` aponta para ela")
4. Pendencias nao resolvidas (residuos travados, itens opcionais nao executados)
5. Verificacao de integridade: os aplicativos preservados continuam no disco e
   o registro de desinstalacao ficou limpo

O ponto 3 e o que diferencia um relatorio util de um log. Quem leu vai querer
saber o que voce deixou de fazer e por que.

## Achados que valem checar sempre

- **Bloat do proprio agente.** `~/.local/share/opencode/opencode.db` guarda um
  snapshot completo de cada `part` em cada update. Uma sessao com outputs
  grandes infla o banco em GB. `scripts/reclaim-agent-db.ps1` diagnostica e
  orienta a limpeza. Vale rodar no survey.
- **Instalacoes multiplas da mesma tool.** Varie versoes de IDE, SDK e runtime
  ocupam gigabytes e quase sempre uma so esta em uso.
- **Cache de driver.** `ProgramData\NVIDIA Corporation\<app>\UpdateFramework` e
  `ProgramData\NVIDIA\NGX\models` guardam GB de payloads que reaparecem
  sozinhos na proxima atualizacao.
- **Game engines.** Steam/Epic guardam downloads incompletos em
  `steamapps/downloading` que sao resíduo de download abortado.

## Scripts

| Script | Funcao | Escrita? |
|---|---|---|
| `scripts/survey.ps1` | Mede tudo, corrige placeholder cloud | Nao |
| `scripts/uninstall.ps1` | Roda o desinstalador certo (NSIS/MSI/NVIDIA/VS) | Sim (desinstalacao) |
| `scripts/cleanup.ps1` | Executa um tier de um plano JSON, mede antes/depois | Sim, conforme tier |
| `scripts/reclaim-agent-db.ps1` | Diagnostica bloat do opencode.db | Nao (diagnostico) |

Todos aceitam `-DryRun`. `cleanup.ps1` tem `-DryRun` default `true` - so
executa de verdade com `-Execute`.
