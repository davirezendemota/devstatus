# Arquitetura

## Fluxo
1. `Store.reload()` monta as assinaturas: contas do Claude Code (`~/.claude`, `~/.claude-*`, via Keychain), o Cursor do `cursor-agent` e as entradas de cookie criadas em Ajustes de AI, na ordem salva em `subscriptionOrder` (ver "Ordem e número das assinaturas").
2. `Store.refresh()` consulta cada uma (`ClaudeService.fetch` ou `WebServices.fetch`) e grava um `UsageState`.
3. UI: sem ícone principal. Três ícones opcionais na barra (Ajustes › Stats: AI, Docker e Monitor; o de AI desenha uma barra por assinatura, numerada, na cor da IA (Claude laranja, Cursor azul), ordenada da mais disponível para a menos (`Store.subsByAvailability`; o número é fixo, igual ao card da aba AI). O widget de AI no Dock usa a mesma ordem; o de Docker é uma grade 2×2 de ícone + barra (imagens, build cache, containers, volumes) com a fatia de cada tipo no total; o de Monitor é a mesma grade (`GridBarsIcon`) com CPU, RAM, disco do sistema e temperatura da CPU (0–100 °C), vermelho a partir de 90%; todos em `MenuIcon.swift`, `@AppStorage` `statAI`/`statDocker`/`statMonitor`, padrão ligados, via `MenuBarExtra(isInserted:)`); clicar abre o app focado na aba dele (`RootView(focus:)`, reaplicado a cada `didBecomeKey`). Abrir o app pelo Spotlight/Finder (`applicationDidFinishLaunching` e `applicationShouldHandleReopen`) mostra o modal: um `NSPanel` flutuante com o `RootView`, que some ao perder o foco. Ao iniciar como item de login, o modal não abre. Abas: **Geral**, **AI** (lista de cards: mapa de tokens dos últimos 3 meses — uma linha por mês, um quadrado por dia, totais de mês/semana/3 meses no cabeçalho — + um card numerado por assinatura com uso, tokens no mês/semana e atalho para a página de uso no site; botão "Ajustes de AI" com cookie, ordem das assinaturas e contas identificadas), **Docker**, **Monitor** (grade de cards do sistema), **Ajustes** (iniciar com o Mac via `SMAppService.mainApp`, Dock e Stats).
4. Refresh automático no intervalo de cada Stats (Ajustes › Stats, seletor à esquerda do toggle; enum `Stat`, chaves `stat<Nome>Interval`) e no botão Atualizar. AI: 1–15 min (padrão 5 min), porque consulta APIs externas e intervalos curtos levariam a bloqueio. Docker: 3 s–5 min (padrão 3 s; não empilha `docker system df`). Monitor: 1–30 s (padrão 3 s). O `AppDelegate` reaplica os intervalos quando o UserDefaults muda.
5. Cada ícone de Stats pode ter barras horizontais ou verticais (`stat<Nome>Vertical`); na vertical, as barras ficam lado a lado com o número/ícone embaixo.

## Cursor identificado pelo cursor-agent
- E-mail e `authId` em `~/.cursor/cli-config.json` (`authInfo`); token em `Keychain › cursor-access-token`.
- Cookie montado em memória: `WorkosCursorSessionToken=<userId>%3A%3A<accessToken>`, onde `userId` é a parte do `authId` depois do `|`. Verificado: `GET cursor.com/api/usage-summary` responde 200.
- Token expirado (claim `exp` do JWT) → "abra o cursor-agent para renovar". O app não renova.
- Opt-in: aparece em AI › Ajustes de AI › "Identificadas nesta máquina" e só entra na lista ao clicar Adicionar.

## Cookies do site (AI › Ajustes de AI)
- O usuário cola o cookie; `CookieDetector` identifica o provider: `WorkosCursorSessionToken` → Cursor; `sessionKey`/`lastActiveOrg` → Claude. Aceita também só o valor (`sk-ant-sid…`, `user_…::…`).
- Cookie vai para o Keychain (`local.devstatus.cookies`, conta = id). Nome e provider ficam no UserDefaults (`webEntries`).
- Claude: `GET claude.ai/api/organizations` → `GET claude.ai/api/organizations/<uuid>/usage` (mesmo formato do endpoint OAuth).
- Cursor: `GET cursor.com/api/usage-summary` → `individualUsage.plan/onDemand` (valores em centavos), `billingCycleStart`/`billingCycleEnd` (ciclo mensal, usado no relógio do logo), `membershipType`.
- Cursor: `plan.totalPercentUsed` inclui bônus; `autoPercentUsed` e `apiPercentUsed` são as faixas separadas. Formato verificado com o token do cursor-agent.
- Claude pelo site **não foi verificado** com cookie real: se o formato divergir, o app mostra "formato inesperado" com os nomes dos campos.

## Credenciais (Keychain)
O Claude Code guarda um item genérico por pasta de config:
- Conta padrão (`~/.claude`): serviço `Claude Code-credentials`.
- Outras: `Claude Code-credentials-<h>`, onde `<h>` = 8 primeiros hex de `SHA256(caminho absoluto da pasta)`.
  Ex.: `/Users/you/.claude-work` → `f7aef36f`.
- Conta (`-a`): `NSUserName()`. O valor é JSON: `claudeAiOauth.{accessToken, refreshToken, expiresAt (ms), subscriptionType}`.
- Leitura: `/usr/bin/security find-generic-password -s <serviço> -a <usuário> -w`.

## API de uso
`GET https://api.anthropic.com/api/oauth/usage`
Headers: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/2.0`.
Resposta (campos usados): `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`, cada um com `utilization` (0–100) e `resets_at` (ISO 8601).
Endpoint não documentado oficialmente; pode mudar sem aviso.

## Ordem e número das assinaturas
O número de cada assinatura (cards, ícone da barra de menu, Dock) é a posição em `subscriptionOrder` (UserDefaults, lista de ids: pasta do Claude Code, `cursor-agent` ou id do cookie). Novas assinaturas entram no fim. Ajustes de AI tem botões de subir/descer. A ordem por disponibilidade nos ícones só muda a posição, nunca o número.

## Estados (`UsageState`)
| Estado | Causa | Na UI |
|---|---|---|
| `ok` | HTTP 200 | barras de uso |
| `expired` | `expiresAt` no passado ou HTTP 401 | pede para abrir o Claude Code na conta |
| `noCredentials` | item ausente no Keychain | pede `/login` |
| `error` | rede ou HTTP diferente de 200/401 | mensagem de erro |

## Decisões
- **Sem renovação de token**: o refresh rotaciona o refresh token; fazer isso fora do Claude Code arrisca invalidar a sessão dele.
- **`security` em vez de `SecItemCopyMatching`**: o item pertence ao Claude Code; ler direto exigiria permissão do Keychain para o DevStatus (e de novo a cada build ad-hoc). O `security` já tem acesso ao item, como o próprio Claude Code faz.
- **`MenuBarExtra` (`.window`)** com abas dentro; ícones extras só por opção do usuário (Stats). A tentativa anterior, um `NSStatusItem` por conta, foi descartada por ficar ruim visualmente. `LSUIElement` esconde o Dock.
- **Assinatura**: com `.sign-identity` (certificado Apple Development) a identidade do app é estável e as permissões do macOS persistem; sem ele, ad-hoc, e o macOS pode pedir permissões de novo a cada rebuild.
- **SwiftPM + `build.sh`**: evita depender de um projeto Xcode.

## Comando de terminal (`devstatus`)
- Mesmo binário do app: `main.swift` roda o `CLI` quando o primeiro argumento é um subcomando (`status`, `ai`, `docker`, `agent`, `install`, `uninstall`, `help`, `version`); sem argumento (Finder, Spotlight) abre o app.
- `CLIInstaller` grava `~/.local/bin/devstatus` (Ajustes › Terminal ou `DevStatus.app/Contents/MacOS/DevStatus install`): um script `sh` que chama o binário dentro do `.app` (caminho atual, `/Applications`, `~/Applications`), para o macOS tratar a execução como o DevStatus. Sem sudo.
- Lê só o que o app já lê (Keychain, logs locais, APIs de uso, `docker` CLI); nada novo sai da máquina. Cores ANSI só com TTY e sem `NO_COLOR`.
- `devstatus ai` usa o mesmo cache de tokens do app (`~/Library/Caches/local.devstatus/tokens-v1.json`).

### `devstatus agent`
- Escolha por `Subscription.availability` (Models.swift). Entra o limite mais apertado entre as métricas com percentual, exceto `weekModel` e `onDemand`; `headroom = 100 − %`. Métrica sem reset próprio (Cursor: Auto + Composer) usa o reset do ciclo.
- `score = headroom + bônus`, com bônus de até 15 pontos proporcional à proximidade do reset dentro da janela da métrica (sessão 5 h, semana 7 d, demais 30 d). Assinatura no limite (`headroom < 1`) fica com score negativo pelas horas até o reset, então a que reseta antes vem primeiro.
- Imprime o ranking (com o número fixo da assinatura) e faz `execv` do CLI da melhor que tem CLI: `claude` com `CLAUDE_CONFIG_DIR` da conta (removido na conta padrão `~/.claude`) ou `agent`/`cursor-agent` no Cursor. Cookies não têm CLI e só aparecem no ranking. Busca o binário no `PATH` + `~/.local/bin`.
- `--dry` só mostra o ranking; o resto dos argumentos vai para o CLI (`devstatus agent -c`). Todas no limite: sai com erro dizendo qual reseta antes.

## Docker
- `DockerCLI` procura o binário (`/usr/local/bin`, Homebrew, OrbStack, Docker Desktop), porque o app não herda o PATH do shell.
- Uso: `docker system df --format '{{json .}}'` → linhas `Type/TotalCount/Active/Size/Reclaimable` (Images, Containers, Local Volumes, Build Cache). Tamanhos em texto decimal ("6.226GB (40%)") são convertidos para bytes.
- Prune (sempre com confirmação): build cache `builder prune -a -f`; imagens sem uso `image prune -a -f`; sistema `system prune -f` (sem `-a` e sem volumes).
- Volumes aparecem no total mas não têm prune.
- Docker parado → "Docker não está rodando".

## Renomeação
Projeto renomeado de AIMonitor para DevStatus (bundle `local.devstatus`). `Migration` copia as preferências do domínio `local.aimonitor` na primeira execução.

## Logos
`Logos.swift` desenha os logos oficiais de Claude e Cursor a partir dos paths SVG (simple-icons, viewBox 24×24) com um parser mínimo de path SVG (`SVGPath`, inclui arcos). Claude em #D97757; Cursor na cor do texto.

## Tokens (Claude Code)
- `TokenScanner` lê `<configDir>/projects/**/*.jsonl` modificados nos últimos 95 dias. Linhas `type: assistant` com `message.usage`.
- Total = `input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens` (mesmo critério do ccusage). Deduplica por `message.id` + `requestId`.
- Cache por arquivo (mtime + tamanho): primeira leitura ~5 s, as seguintes ~50 ms.
- O Claude Code apaga logs antigos (`cleanupPeriodDays`, padrão 30 dias), então o mapa pode ter menos de 3 meses de histórico.
- Cursor e assinaturas via cookie não têm tokens.

## Monitor
- `MonitorStore` lê no intervalo de Stats › Monitor (1–30 s, padrão 3 s) enquanto a aba está aberta (`start`/`stop`) ou enquanto o ícone, o tile ou o widget de Monitor estiver ligado (`setBackground`, sincronizado pelo `AppDelegate` quando o UserDefaults muda).
- CPU: `host_statistics(HOST_CPU_LOAD_INFO)` (diferença de ticks) + `getloadavg`.
- Memória: `host_statistics64(HOST_VM_INFO64)`; usada = (internal − purgeable) + wired + comprimida, como o Monitor de Atividade. Swap via `vm.swapusage`.
- Discos: `mountedVolumeURLs`, só `/` e `/Volumes/*` (ignora discos virtuais como o do OrbStack). Livre = `volumeAvailableCapacityForImportantUsage`.
- Temperatura: sensores HID (`IOHIDEventSystemClient`, API **privada** do IOKit, via `@_silgen_name`, só leitura). CPU = média dos `PMU tdie*`; SSD = `NAND*`; bateria = `gas gauge battery`. Estado térmico via `ProcessInfo.thermalState` (também é o fallback se os sensores falharem).
- Rede: `sysctl NET_RT_IFLIST2` (contadores de 64 bits), soma das interfaces exceto loopback; IP da primeira `en*` com IPv4.
- Bateria: `IOPSCopyPowerSourcesInfo`; ciclos e saúde (`NominalChargeCapacity / DesignCapacity`, dentro de `BatteryData`) em `AppleSmartBattery`.

## Stats no Dock
- Botão `dock.rectangle` em cada linha de Stats (chave `stat<Nome>Dock`). `DockTiles` cria uma `NSWindow` por Stats ligado, com o `RootView` focado na aba, e minimiza na hora (alpha 0 para não aparecer). O tile do Dock é `window.dockTile.contentView` (`NSImageView` com o `DockTileView` renderizado por `ImageRenderer`: quadrado, sem título, valores grandes; o Dock não permite tiles mais largos), redesenhado quando os stores mudam (debounce 300 ms).
- Clicar no tile restaura a janela (o app aberto na aba); ao perder o foco ela volta a minimizar, exceto durante alertas (`NSApp.modalWindow`) ou sheets.
- Só a janela é minimizável: sem botão de fechar nem zoom. Desligar o toggle fecha a janela e o tile some.
- Funciona com "Minimize windows into application icon" ligado ou desligado: como o app não tem ícone no Dock (`LSUIElement`), o Dock mostra a janela minimizada ao lado do Lixo (verificado com a opção ligada).
- Tiles ficam no lado direito do Dock, junto das janelas minimizadas.

## Dock próprio (substitui o Dock do macOS)
- Ajustes › Dock › "Substituir o Dock do macOS" (`dockReplace`) e tamanho dos ícones (`dockIconSize`, 36–80, padrão 52).
- `NativeDock` esconde o Dock do macOS com `autohide = true` + `autohide-delay = 1000` (CFPreferences no domínio `com.apple.dock` + `killall Dock`). Os valores originais ficam em `nativeDockSaved` e voltam ao desligar a opção ou sair do app (`applicationWillTerminate`). Se o app fechar de forma inesperada, o Dock continua oculto até o DevStatus abrir de novo com a opção desligada, ou a mão: `defaults write com.apple.dock autohide -bool false; defaults delete com.apple.dock autohide-delay; killall Dock`.
- `DockBarController`: `NSPanel` sem borda, não ativante, nível `.dockWindow`, em todos os Spaces (não aparece em apps em tela cheia), centralizado na base da tela da barra de menu, 10 pt acima da borda. O `NSHostingView` ajusta o tamanho da janela ao conteúdo; a cada `NSWindow.didResizeNotification` (e mudança de tela) o `place()` recentraliza.
- `DockModel`: apps fixos (`dockPinned`, importados de `persistent-apps` na primeira vez; Ajustes do Sistema foi tirado dos fixos) + apps abertos não fixos (`NSWorkspace.runningApplications`, `activationPolicy == .regular`) + `system` (Finder, sempre presente, no grupo Mac), atualizado por notificações do `NSWorkspace`. Clique = `openApplication` (abre ou traz para frente, como o Dock). Sem linhas divisórias. Cursor de mão nos itens (`NSCursor.set` no hover; como o app fica em segundo plano, liga a propriedade privada do WindowServer `SetsCursorInBackground` via `CGSSetConnectionProperty`). App aberto: barrinha horizontal embaixo do ícone, sobre a margem do grupo (não ocupa altura). Cor pela CPU do app (`ProcessCPU`, a cada 3 s com a barra visível): amarela com 70%+, vermelha com 90%+, onde 100% = um núcleo (como o Monitor de Atividade). Soma o processo do app e os descendentes (`proc_listallpids` + `proc_pidinfo`); o tooltip mostra o %. Arrastar `.app` fixa/reordena; arquivos soltos num app abrem com ele; arquivos no Lixo vão para o Lixo. Menu de contexto: manter/remover, mostrar no Finder, ocultar, encerrar.
- Widget de AI no Dock (`AIRingsView`): um par de anéis por assinatura, no estilo do widget de baterias, ordenados por disponibilidade e com o número fixo no canto. Anel externo: Claude = sessão de 5h (`five_hour`), Cursor = modelos de terceiros (`apiPercentUsed`). Anel interno: Claude = semana (`seven_day`), Cursor = Auto + Composer (`autoPercentUsed`). Cor: verde, laranja com 70%+, vermelho com 90%+. No centro, o logo da IA em estilo relógio: começa cheio e esvazia no sentido horário a partir das 12h (`ClockSector`) conforme passa o período até o próximo reset (Claude: janela de 5h; Cursor: ciclo mensal `billingCycleStart`→`billingCycleEnd`, ou um mês antes do fim). As métricas têm `MetricKind` para os anéis não dependerem do título. Clique num anel abre a página de uso da IA no navegador (`Provider.usageURL`: `claude.ai/settings/usage`, `cursor.com/dashboard?tab=usage`); o card da aba AI tem o mesmo atalho. O site abre com a conta logada no navegador, não necessariamente a do anel.
- Widgets de Stats na barra: os Stats com o botão do Dock ligado. Docker e Monitor têm largura de 1 a 4 ícones (`stat<Nome>DockWidth`, padrão 2); o de AI são os anéis acima e cresce com o número de assinaturas. Clique abre o modal na aba (`Notification.Name.devStatusOpenTab`). Com o Dock substituído, os tiles de janela minimizada (`DockTiles`) não são criados.
- Layout: fundo transparente com grupos (cada um com fundo de material), da esquerda para a direita: **apps** (fixos e abertos, sem espaço entre eles), **Mac** (Finder e Lixo), **Herdr** (fila de agents), **Stats** (widgets), **mídia** (card único: Spotify e/ou YouTube; com os dois ativos, uma coluna de ícones à esquerda troca o player, e abrir um vídeo já seleciona o YouTube) e **dispositivos** (baterias). Grupos vazios não aparecem.
- Spotify (`NowPlaying`): estado pela notificação distribuída `com.spotify.client.PlaybackStateChanged` (Name, Artist, Duration em ms, Playback Position em s, Player State, Track ID), sem permissão. Ao abrir, se o Spotify estiver rodando, consulta o estado via AppleScript. Capa: `artwork url of current track` (AppleScript) e download de `i.scdn.co`; o fundo do player usa a cor média da capa. Controles: AppleScript `playpause`, `next track`, `previous track`. O macOS pede permissão de Automação na primeira vez (com assinatura ad-hoc, pode pedir de novo após rebuild). Some quando o Spotify para ou fecha.
- YouTube (`YouTubePlayer`): botão direito na barra (fora dos ícones de app) › "Tocar vídeo do YouTube…" pede o link (`NSAlert` com campo; usa a área de transferência se for do YouTube). `watchURL` normaliza youtu.be, /watch, /shorts, /live, /embed e /playlist para `youtube.com/watch` (mantém `list` e `t`). Toca num `WKWebView` (motor do Safari; user agent com `Safari`, autoplay liberado, `pageZoom` 0,5) hospedado no card, sem receber cliques. Um CSS injetado no início da página deixa só o `#movie_player` ocupando a página e esconde controles, cards e legendas. Legendas também são desligadas a cada 1 s (`unloadModule('captions')` se ligadas e `textTracks[i].mode = 'disabled'`), porque o YouTube cria trilhas `forced` que o macOS desenha por conta própria (ex.: no Agora Tocando). No mesmo ciclo registra no Media Session `seekto`, `seekforward` e `seekbackward` (±10 s) e `setPositionState`. Estado a cada 1 s pela API do player da página (`getVideoData` → título, canal e id; `video.currentTime`/`duration`/`paused`; classe `ad-showing` → "Anúncio" e barra amarela). Controles: `playVideo`/`pauseVideo`, `nextVideo`, `previousVideo` (playlist; fora dela volta ao início ou `history.back`), `seekTo` ao clicar na barra. Fila: com o player ativo, colar outro link pergunta "Adicionar à fila" ou "Tocar agora" (entra logo depois do atual). Cada item vira um ícone do YouTube no seletor à esquerda do card (coluna única com rolagem e barra invisível na altura do card, junto com o Spotify; rola até o item que está tocando; título pelo oEmbed `youtube.com/oembed` na dica). Clicar toca o item; botão direito remove. Quando um vídeo termina (`video.ended`, fora de anúncio), ele sai da fila e o próximo começa; o "próximo" do card também avança a fila. Playlists seguem pelo próprio YouTube. Durante anúncio sem login, o subtítulo vira "Entrar para usar o Premium". No hover do vídeo, três ícones sem fundo: fechar este vídeo (sai da fila e toca o próximo; "Fechar todos" no menu do card), abrir no Safari no mesmo ponto (`&t=`, pausa aqui) e janela flutuante. A janela flutuante é um picture-in-picture próprio (`NSPanel` não ativador, nível `.floating`, em todas as mesas, 16:9, redimensionável, posição salva): o web view sai do card e vai para ela. No hover, voltar ao Dock, fechar este vídeo, −10 s, play/pausa, +10 s e linha do tempo clicável; clique no vídeo = play/pausa, arrastar move a janela. Vídeo preto ao trocar de janela: com a página oculta (web view fora de uma janela visível), o YouTube Premium passa para só áudio (reprodução em segundo plano) e não volta. Por isso um script no início da página fixa `document.hidden`/`visibilityState` como visível e barra `visibilitychange`; a janela flutuante só é escondida depois que o vídeo voltou ao card; card e janela flutuante têm cada um o seu host (`WebViewHost`), e só adota o web view o host que é o dono atual (card sem flutuar, janela flutuando) e já está numa janela (sem isso, o host que estava saindo pegava o web view de volta e era descartado com ele dentro: vídeo fora de qualquer janela, preto no Dock e no PiP); e ao trocar de janela ou terminar de redimensionar, `repaint()` força novo layout e sempre faz um seek 0,05 s antes do ponto atual (`seekTo`, ou `currentTime` em anúncio e vídeo local): ao trocar de janela o WebKit descarta a camada do vídeo, e ela só volta a ser desenhada depois de um seek, mesmo com o vídeo tocando. O PiP nativo do macOS (processo do sistema) não foi usado porque, vindo de um WKWebView, a linha do tempo dele não deixa pular. Fundo: cor média de um `takeSnapshot` 3 s após trocar de vídeo. O vídeo continua tocando quando o card mostra o Spotify (o web view sai da janela, mas o WebKit não pausa). Sessão: o WKWebView tem cookies próprios (não lê os do Safari). "Entrar no YouTube…" (menu da barra e do card) abre uma janela com o login do Google no mesmo `WKWebsiteDataStore.default()`; quando volta para youtube.com com cookie `LOGIN_INFO`/`SAPISID`, fecha e recarrega o player no mesmo ponto. A sessão fica salva no WebKit do app, como num navegador. "Sair do YouTube" apaga os registros de Google/YouTube desse armazenamento.
- Vídeos locais ("Abrir com › DevStatus"): o `build.sh` declara `CFBundleDocumentTypes` (MP4, MOV, M4V e WebM, que o WebKit toca; `LSHandlerRank` Alternate, então não vira o app padrão sozinho). `application(_:open:)` manda os arquivos para o mesmo player: o primeiro toca e os outros vão para a fila (ícone no formato do YouTube, em cinza claro, no seletor). Sem o Dock próprio ligado, abre na janela flutuante. Aberto assim, o app não mostra o modal. Carrega com `loadFileURL(arquivo, allowingReadAccessTo: arquivo)`: leitura só do arquivo, que é o que o "Abrir com" libera (dar acesso à pasta falha na Mesa/Documentos/Downloads, protegidas pelo macOS). Como o documento de mídia padrão do WebKit não deixa o vídeo ocupar o quadro, um script no fim do carregamento troca o conteúdo por um `<video>` próprio do mesmo arquivo. No hover, "Mostrar no Finder" no lugar do Safari; título = nome do arquivo.
- Espaço da barra (`WindowGuard`): com o Dock nativo oculto, o macOS não reserva espaço. Com permissão de **Acessibilidade**, o app observa (`AXObserver`) janelas criadas, movidas e redimensionadas de todos os apps e encurta (ou sobe) as que invadem a barra na tela principal. Ignora tela cheia e janelas não padrão. Sem a permissão, Ajustes › Dock mostra um aviso com botão para abrir Acessibilidade. Com assinatura ad-hoc, cada rebuild muda a identidade do app e a permissão precisa ser concedida de novo; por isso o `build.sh` assina com um certificado fixo quando há `.sign-identity`. Se a permissão ficar presa a uma assinatura antiga (aparece ligada mas não funciona), `tccutil reset Accessibility local.devstatus` e ligar de novo.
- Herdr (`HerdrStore`): a cada 3 s lê a primeira linha de `~/.local/bin/herdr-core events --json` (lista completa; só leitura, sem rede; inclui máquinas remotas) e encerra o processo (timeout 3 s). Não usa `ls --json` porque ele não traz o rótulo `herdr.seen`: `done` com `herdr.seen >= turn` significa que você já viu no Herdr e vira `idle` (é o que o app Herdr mostra). Terminais com `status.app` diferente de shell viram chips (tooltip inclui `status.msg`, a atividade atual): logo (Claude/Cursor, senão ícone de terminal), cor do status (`blocked` laranja, `done` verde, `working` azul, `idle` cinza) e o workspace (`where` antes de " / "). Ordem: blocked, done, working, idle. Mostra até 6 (+N). Clique traz o Herdr para frente. O card some sem agents ou sem `herdr-core`.
- Dispositivos (`DevicesStore`, a cada 60 s): `pmset -g accps` traz a bateria do Mac e de todos os acessórios que o macOS conhece (inclusive fones e periféricos de terceiros, como Logitech MX e QCY), os mesmos do widget Baterias. O tipo (ícone) vem de `system_profiler SPBluetoothDataType -json`, consultado só para nomes novos. Visual: um anel por dispositivo (verde; vermelho com 20% ou menos; raio quando carregando), com os mesmos ícones do widget Baterias (`macbook`, `keyboard`, `computermouse`, `headphones`, AirPods...; alternativa automática se o símbolo não existir na versão do macOS).
- Ainda não tem: ver `docs/roadmap.md`.

## APIs privadas e não documentadas
Usadas só para leitura ou aparência, e podem quebrar em atualizações do macOS ou dos serviços:
- Sensores de temperatura HID (`IOHIDEventSystemClient*`, via `@_silgen_name`).
- `SetsCursorInBackground` (`CGSSetConnectionProperty`) para o cursor de mão no Dock.
- Endpoints de uso: `api.anthropic.com/api/oauth/usage`, `claude.ai/api/organizations/<uuid>/usage`, `cursor.com/api/usage-summary`.
- Saída do `herdr-core events --json` e do `pmset -g accps`.
