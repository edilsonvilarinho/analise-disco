# disk-cleanup

Skill para o [opencode](https://opencode.ai) que faz análise completa de uso de
disco no Windows e executa a limpeza em etapas — com medição antes/depois e
aprovação explícita do usuário antes de qualquer remoção.

Construída a partir de uma execução real: 953 GB de volume, 814 GB ocupados,
**155 GB recuperados** (85,5% → 69,4% de ocupação).

---

## O que a skill faz

```
1. Survey        scripts/survey.ps1         somente leitura
2. Classificação references/catalog.md      4 tiers + lista de exclusões
3. Plano         tabela com GB/tier/risco → PERGUNTA e ESPERA
4. Execução      scripts/cleanup.ps1        um tier por vez, medindo
5. Relatório     references/report-template.md
```

**A skill nunca apaga nada sem aprovação.** O `-DryRun` é o padrão de todos os
scripts destrutivos.

## Instalação

### Como skill do projeto (já é o padrão deste repo)

O opencode descobre skills em `.opencode/skills/<nome>/SKILL.md`. Este repo já
está nesse formato — basta ter o repositório clonado e estar na pasta do
projeto.

Reinicie o opencode para o discovery de skills acontecer: config e skills são
carregados no startup, não são recarregados a quente.

### Como skill global (todos os projetos)

```powershell
git clone https://github.com/edilsonvilarinho/analise-disco.git `
  "$env:USERPROFILE\.config\opencode\skills\disk-cleanup"
```

Isso coloca `SKILL.md` em `~/.config/opencode/skills/disk-cleanup/SKILL.md`,
que é auto-descoberto.

### Alternativa: apontar para o clone

Se preferir manter o clone em outro lugar, registre o caminho em
`~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "skills": {
    "paths": ["C:/Users/edils/workspace/analise-disco/.opencode/skills"]
  }
}
```

## Uso

```
analisa meu disco e me diz o que dá pra liberar
libera espaço, quero tirar tudo que é cache
limpa o C: mas não toca nos meus jogos
```

A skill responde com o levantamento, monta o plano por tier e pergunta o que
executar. Depois executa em lotes, medindo cada um.

## Scripts

| Script | O que faz | Escreve? |
|---|---|---|
| `scripts/survey.ps1` | Mede o volume inteiro, corrige o tamanho de placeholder de nuvem, lista desinstaladores do registro, roda `DISM /AnalyzeComponentStore` | Não |
| `scripts/uninstall.ps1` | Roda o desinstalador certo (NSIS `/S`, MSI `/x {GUID} /qn`, NVIDIA `NVI2.DLL`, VS Installer com caminho entre aspas) | Sim |
| `scripts/cleanup.ps1` | Executa um tier de um plano JSON, mede antes/depois, loga | Sim, com `-Execute` |
| `scripts/reclaim-agent-db.ps1` | Diagnostica o bloat do `opencode.db` (snapshot por update na tabela de eventos) | Não (com `-Vacuum`, sim) |

```powershell
# survey
pwsh -NoProfile -File .opencode/skills/disk-cleanup/scripts/survey.ps1 -Depth 2 -OutJson out/survey.json

# plano (dry-run)
pwsh -NoProfile -File .opencode/skills/disk-cleanup/scripts/cleanup.ps1 -Plan out/plan.json -Tier A

# execução
pwsh -NoProfile -File .opencode/skills/disk-cleanup/scripts/cleanup.ps1 -Plan out/plan.json -Tier A -Execute

# desinstalação
pwsh -NoProfile -File .opencode/skills/disk-cleanup/scripts/uninstall.ps1 -DisplayName 'NVIDIA ChatRTX'
pwsh -NoProfile -File .opencode/skills/disk-cleanup/scripts/uninstall.ps1 -DisplayName 'NVIDIA ChatRTX' -Execute
```

## Os 4 tiers

| Tier | O que é | Exemplo |
|---|---|---|
| **A** | Cache regenerável | npm-cache, pip, DXCache, `LocalCache` de apps UWP |
| **B** | Ferramenta (desinstalar, nunca apagar pasta) | ChatRTX, Nsight, versão antiga do Android Studio |
| **C** | Diretório regenerável | `.gradle\caches`, `.m2\repository`, system-images do Android SDK |
| **D** | Sistema | `DISM /Online /Cleanup-Image /StartComponentCleanup` |

Exclusões fixas: `Windows\Installer`, `WinSxS` manual, `ProgramData\Package Cache`,
`Program Files\WindowsApps`, `Packages\*\LocalState`, `pagefile.sys`.

## As lições que viraram regras

`references/pitfalls.md` documenta dez erros que aconteceram na execução real.
Os mais caros:

- **Placeholder de nuvem distorce a medição em 160 GB.** `Get-ChildItem` devolve
  tamanho *lógico*; o que ocupa disco é o *real*.
- **Alias ganha de função no PowerShell.** Uma função chamada `Rm` nunca é
  chamada — `rm` (alias de `Remove-Item`) tem precedência.
- **`-ArgumentList` em array não aplica aspas.** `installPath: C:\Program` é o
  resultado; a linha inteira precisa ser uma string.
- **O atalho do menu Iniciar decide qual IDE sobrevive**, não a data de modificação.
- **Output grande de ferramenta vira bloat permanente no banco do agente**
  (8,24 GB medidos). Filtre no shell, nunca despeje o dump no modelo.

## Estrutura

```
.opencode/skills/disk-cleanup/
├── SKILL.md                    workflow e regras
├── scripts/
│   ├── survey.ps1
│   ├── uninstall.ps1
│   ├── cleanup.ps1
│   └── reclaim-agent-db.ps1
└── references/
    ├── catalog.md              catálogo de alvos com comando, tier e risco
    ├── pitfalls.md             os erros e como evitá-los
    └── report-template.md      formato do relatório final
```

## Requisitos

- Windows 10/11
- PowerShell 7+ (`pwsh`)
- Python 3 (só para `reclaim-agent-db.ps1`)
- Administrador, para tier B e tier D

## Licença

MIT — ver [LICENSE](LICENSE).
