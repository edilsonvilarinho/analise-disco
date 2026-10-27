# Catálogo de alvos de limpeza (Windows)

Candidatos **verificados** antes de agir. A presença do caminho no disco não
significa que o usuário não usa aquilo — um `.gradle` de 6 GB pode ser o build
cache de um projeto ativo. Para cada entrada: como medir, como limpar
corretamente, em que tier cai e qual o sinal de obsolescência.

Todos os caminhos usam `%VAR%` para funcionar em qualquer máquina.

---

## Como medir o tamanho real

```powershell
# logico (errado para nuvem)
(Get-ChildItem $p -Recurse -File -Force | Measure-Object Length -Sum).Sum

# real em disco, correto para placeholder de nuvem
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class RS{[DllImport("kernel32.dll",CharSet=CharSet.Unicode)]public static extern uint GetCompressedFileSizeW(string p,out uint h);}'
# ... ver scripts/survey.ps1, que ja faz isso
```

`scripts/survey.ps1` faz a medição real das pastas de nuvem e mostra
`LogicoGB` vs `RealGB`. Em OneDrive/DriveFS a diferença pode ser de 160 GB
lógicos contra menos de 1 GB real.

---

## Tier A — Cache regenerável

Cache se reconstrói sozinho na próxima execução. Remover é seguro; o custo é
tempo de re-download na próxima vez.

| Alvo | Caminho | Como limpar |
|---|---|---|
| npm | `%LOCALAPPDATA%\npm-cache` | `npm cache clean --force` (não apague a pasta inteira: o npm recria, mas o comando oficial é melhor) |
| npm npx | `%LOCALAPPDATA%\npm-cache\_npx` | remover pasta — só contém versões descartadas de pacotes |
| pip | `%LOCALAPPDATA%\pip\cache` | `pip cache purge` |
| yarn | `%LOCALAPPDATA%\Yarn\Cache` | `yarn cache clean` |
| pnpm | `%LOCALAPPDATA%\pnpm\store` | `pnpm store prune` |
| NuGet | `%USERPROFILE%\.nuget\packages` | `dotnet nuget locals all --clear` |
| Chocolatey | `%PROGRAMDATA%\chocolatey\lib-bad` / `cache` | `choco cache clean` |
| Cargo | `%USERPROFILE%\.cargo\registry\cache` | remover subpastas `cache` |
| Playwright | `%LOCALAPPDATA%\ms-playwright` | remover só as versões antigas; a atual é re-downloadada pelo `playwright install` |
| Electron builder | `%LOCALAPPDATA%\electron-builder\Cache` | remover pasta |
| Electron | `%LOCALAPPDATA%\electron\Cache` | remover pasta |
| VS Code caches | `%APPDATA%\Code\{CachedExtensionVSIXs,Crashpad,CachedData,Cache}` | remover — `CachedExtensionVSIXs` guarda .vsix já instalados |
| Cursor / Windsurf | `%APPDATA%\{Cursor,Windsurf,Antigravity IDE}\` | mesma lista de caches do VS Code |
| Chrome | `%LOCALAPPDATA%\Google\Chrome\User Data\{OptGuideOnDeviceModel,component_crx_cache,Safe Browsing,GrShaderCache,ShaderCache}` | remover — o modelo on-device é re-baixado pela Chrome |
| NVIDIA shader cache | `%LOCALAPPDATA%\NVIDIA\{DXCache,GLCache}` | remover — se falhar, é o driver com o arquivo aberto (resíduo de MB é aceitável) |
| Windows Temp | `%LOCALAPPDATA%\Temp` | remover só o que tiver `LastWriteTime` antigo (>3 dias) |
| Windows Temp global | `C:\Windows\Temp` | idem, raramente relevante |
| Windows Update | `C:\Windows\SoftwareDistribution\Download` | remover com o serviço `wuauserv` parado |
| Delivery Optimization | `C:\Windows\SoftwareDistribution\DeliveryOptimization` | remover pasta |
| Prefetch | `C:\Windows\Prefetch` | não vale o risco, é gerenciado pelo Windows |
| Crash dumps | `%LOCALAPPDATA%\CrashDumps`, `C:\ProgramData\Microsoft\Windows\WER`, `%LOCALAPPDATA%\Microsoft\Windows\WER` | remover — só interessam se você for depurar um crash |
| Teams / Spotify / Codex | `%LOCALAPPDATA%\Packages\*\LocalCache` | remover `LocalCache` de apps UWP. **NUNCA** `LocalState` (é dado do app) |
| Ollama updates | `%LOCALAPPDATA%\Ollama\updates_v2` | remover — binários de update antigos |
| LM Studio | `%LOCALAPPDATA%\LM-Studio` cache | remover cache; `models` é do usuário |
| Discord | `%APPDATA%\discord\{Cache,Code Cache,GPUCache}` | remover |
| Postman | `%LOCALAPPDATA%\Postman-Agent` | remover cache de runtime |
| Recycle Bin | `C:\$Recycle.Bin` | `Clear-RecycleBin -Force` |
| Steam | `steamapps\downloading`, `steamapps\shadercache`, `steamapps\depotcache`, `appcache` | `downloading` é resíduo de download abortado — confirm que não há download ativo |
| OneDrive temp | `C:\OneDriveTemp` | remover |

### Sinais de obsolescência

- `LastWriteTime` de meses atrás numa pasta que deveria ser ativa.
- Cache de app que você não abre há mais de 6 meses.
- Versões antigas de runtime (Playwright, Electron, SDKs) coexistindo com uma atual.

---

## Tier B — Ferramentas: desinstalar, nunca apagar pasta

Remove com o desinstalador. `Remove-Item` em pasta de programa deixa entrada
de registro órfã, chave de MSI quebrada e estado corrompido do Windows
Installer.

| Alvo | Como |
|---|---|
| NVIDIA ChatRTX | `scripts/uninstall.ps1 -DisplayName 'NVIDIA ChatRTX' -Execute` — **depois remover o resíduo em `C:\ProgramData\NVIDIA Corporation\ChatRTX`** (o desinstalador não limpa) |
| NVIDIA Nsight Compute / Systems / VS Edition | `scripts/uninstall.ps1 -DisplayName 'NVIDIA Nsight' -Execute` (são MSI) |
| NVIDIA Broadcast | `scripts/uninstall.ps1 -DisplayName 'NVIDIA Broadcast'` — só se não usa microfone/câmera virtual |
| Android Studio (versões antigas) | `uninstall.exe /S` (NSIS). Verificar antes qual versão o atalho do menu Iniciar aponta |
| Android SDK components | `sdkmanager --uninstall "system-images;android-19;google_apis;x86"` — usar o sdkmanager, não apagar a pasta (o `packages.xml` fica inconsistente) |
| Emuladores Android (MEmu, LDPlayer, BlueStacks) | desinstalador do fabricante; as VMs em `image/` somem com ele |
| Visual Studio BuildTools antigos | `setup.exe uninstall --installPath "<caminho>" --quiet --norestart` (instância mais nova é a que fica) |
| Windows SDK duplicado | `winsdksetup.exe /uninstall /quiet /norestart` no `Package Cache` — só o mais antigo quando há duas versões |
| CUDA Toolkit antigo | `scripts/uninstall.ps1 -DisplayName 'NVIDIA CUDA Development'` — **só se `CUDA_PATH` não apontar para ele** |
| JetBrains IDEs | desinstalador em `bin\Uninstall.exe` (NSIS) |
| Ren'Py SDK | desinstalador em `C:\Program Files\renpy-*` |
| Ferramentas em `Program Files` sem entrada no registro | perguntar antes; sem desinstalador a remoção é manual e o usuário precisa saber |

### Antes de remover uma instalação duplicada

```powershell
# Qual versão o menu Iniciar aponta?
$sh = New-Object -ComObject WScript.Shell
Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu" -Recurse -Filter *.lnk |
  Where-Object Name -match 'Android Studio' | ForEach-Object {
    $sh.CreateShortcut($_.FullName).TargetPath }

# Quais versoes existem de verdade?
Get-ChildItem 'C:\Program Files\Android' -Directory | ForEach-Object {
  $v = (Get-Content "$($_.FullName)\product-info.json" -Raw | ConvertFrom-Json).version
  "$($_.Name) -> $v" }
```

O atalho do menu Iniciar é o arbítrimo real. Uma instalação "mais nova" pode
ser um build Canary que ninguém usa.

---

## Tier C — Diretórios regeneráveis

Custo: re-download no próximo uso. Não apague se o projeto está em uso e o
re-download for caro (vários GB).

| Alvo | Caminho | Observação |
|---|---|---|
| Gradle | `%USERPROFILE%\.gradle\caches`, `.gradle\wrapper` | `gradle --stop` antes; o daemon segura arquivos |
| Maven | `%USERPROFILE%\.m2\repository` | re-baixado no próximo `mvn`; apague por grupo (`br\com\empresa`) para preservar o resto |
| Android NDK | `%LOCALAPPDATA%\Android\Sdk\ndk` | via sdkmanager; cada versão tem 2+ GB |
| Android build-tools | `%LOCALAPPDATA%\Android\Sdk\build-tools` | manter a versão usada pelo Gradle |
| Flutter SDK | `%USERPROFILE%\develop\flutter` | SDK completo, ~3 GB |
| NVIDIA NGX | `C:\ProgramData\NVIDIA\NGX\models` | modelo DLSS/Streamline; re-baixado pela NVIDIA App |
| NVIDIA App cache | `C:\ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework` | payloads de driver antigos |
| HuggingFace | `%USERPROFILE%\.cache\huggingface` | modelos re-baixados |
| LM Studio extensions | `%USERPROFILE%\.lmstudio\extensions` | só se não usa o LM Studio |
| JetBrains caches | `%LOCALAPPDATA%\JetBrains\<Id>\caches` | índices do IDE |
| VS Code extensions | `%USERPROFILE%\.vscode\extensions` | versões antigas do mesmo extension |
| Cache de jogo | `%LOCALAPPDATA%\<Jogo>\{Pipelines,Shaders,Cache}` | regerado pelo jogo |
| node_modules órfão | `<projeto>\node_modules` em projetos que você não abre mais | `npm prune` não resolve; apague a pasta |

---

## Tier D — Sistema

| Operação | Comando | Observação |
|---|---|---|
| Component store | `DISM /Online /Cleanup-Image /StartComponentCleanup` | seguro. Ganho típico 2–5 GB. `AnalyzeComponentStore` antes para saber |
| Component store agressivo | `DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase` | **irreversível** para atualizações já instaladas. Não fazer sem o usuário pedir explicitamente |
| Windows Update | `cleanmgr /sagerun` ou Configurações > Armazenamento | |
| Shadow copies | `vssadmin list shadowstorage` | espaço usado por pontos de restauração. Ajustar com `vssadmin resize shadowstorage` |
| Compact OS | `compact /compactos:always` | reduz o Windows, custa CPU |
| Reserved storage | `DISM /Online /Set-ReservedStorageState /State:disabled` | libera ~7 GB, desativa atualizações automáticas |
| pagefile | `SystemPropertiesAdvanced` | mexer só com medição de RAM/commit |

---

## Exclusões — nunca propor

```
C:\Windows\Installer                   cache do MSI; sem ele a desinstalacao quebra
C:\Windows\WinSxS                      so via DISM
C:\ProgramData\Package Cache           instaladores usados para desinstalar
C:\Program Files\WindowsApps           so a Store gerencia
%LOCALAPPDATA%\Packages\*\LocalState   dado do app, nao cache
C:\ProgramData\Microsoft\Search        indice do Windows
C:\Windows\System32\DriverStore        driver store
```

Também não tocar, sem o usuário pedir:

- `~/.codex/sessions`, `~/.claude/projects` — histórico de conversa.
- `OneDrive*` e `*Google Drive*` — use o "livre espaço" do cliente, nunca `Remove-Item`.
- `*.vhdx` de WSL/Hyper-V — encolha com `Optimize-VHD`, não apague.

---

## Ordem recomendada

1. **A** — cache puro. Maior ganho, risco zero, nenhum uninstaller envolvido.
2. **B** — desinstalar ferramentas não usadas. Exige verificar atalhos e `PATH`.
3. **C** — diretórios regeneráveis. Confirme que o re-download é aceitável.
4. **D** — sistema. Última etapa, DISM pode levar 10+ minutos.

Meça o espaço livre antes e depois de cada tier. Se um tier liberar menos do
que o previsto, investigue antes de seguir — quase sempre significa item
travado por processo ativo (item que falha de novo depois de fechar o app
relacionado precisa ser tratado).
