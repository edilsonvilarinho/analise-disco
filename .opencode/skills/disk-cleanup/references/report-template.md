# Modelo de relatório

Estrutura do relatório final de uma sessão de limpeza. O objetivo é que quem lê
saiba **o que mudou, o que não mudou e por quê** — não só os números.

---

## 1. Resultado

| | Inicial | Final | Δ |
|---|---|---|---|
| Livre | X GB | Y GB | +Z GB |
| Usado | X GB | Y GB | −Z GB |
| Ocupação | X% | Y% | −N p.p. |

## 2. Por etapa

| Etapa | Liberado | Conteúdo |
|---|---|---|
| A — caches regeneráveis | +X GB | npm, pip, DXCache, Temp, LocalCache… |
| B — desinstalações | +X GB | ChatRTX, Nsight, IDE antiga… |
| C — diretórios regeneráveis | +X GB | .gradle, .m2, SDK antigo… |
| D — sistema | +X GB | DISM /StartComponentCleanup |

## 3. Decisões que divergiram do plano

> Lista explícita. É o que diferencia um relatório útil de um log.
> Formato: **item → decisão → motivo**.

- *CUDA Toolkit 11.8 (2,64 GB)* → **mantido** — `CUDA_PATH` aponta para ele;
  remover quebra build de extensões CUDA.
- *Android Studio 2025.3 (3,01 GB)* → **removido** — build Canary; o atalho do
  menu Iniciar aponta para a 2024.3.

## 4. Pendências

- Itens que falharam (arquivo em uso por processo ativo) com o resíduo em MB.
- Itens opcionais não executados e o motivo.
- Resíduos de registro órfãos.

## 5. Não tocado (deliberado)

Lista com o motivo de cada exclusão. Especialmente: `Windows\Installer`,
`pagefile.sys`, `WinSxS` manual, `ProgramData\Package Cache`, `WindowsApps`,
dados do usuário, jogos.

## 6. Verificação de integridade

- Aplicativos que deveriam ter sobrevivido: caminho existe?
- Entradas de registro de desinstalação: sobrou alguma órfã?
- Ambiente de desenvolvimento ainda funcional (node, python, java, git, adb)?

## 7. Espaço para o agente

Se o próprio agente inflar o banco de sessão durante a análise, reportar:

- Caminho do `.db` e tamanho
- Tabela com o volume por tipo de evento
- Sessão culpada e o comando exato para recuperar

Não apagar a sessão se ela for a atual — isso destrói a conversa em andamento.
Entregar o comando para o usuário rodar depois de fechar o agente.
