# DevStatus

App de barra de menu (macOS, Swift/SwiftUI) com 5 abas: **Geral**, **AI** (uso do Claude Code/Cursor por assinatura), **Docker** (armazenamento e prune), **Monitor** (CPU, RAM, discos, temperatura, rede, bateria) e **Ajustes**. Antes se chamava AIMonitor.

## Comandos
- `./build.sh` — compila (release), monta `DevStatus.app` e assina com o certificado de `.sign-identity` (hash SHA-1, arquivo local fora do git) ou `DEVSTATUS_SIGN_IDENTITY`; sem certificado, ad-hoc. Com certificado as permissões (Acessibilidade, Automação, Keychain) sobrevivem aos rebuilds.
- `open DevStatus.app` — executa. Para recarregar após build: `pkill DevStatus; open DevStatus.app`.
- `swift build` — só compila, sem empacotar.

## Estrutura
- `App.swift` — ícones opcionais de Stats (AI, Docker, Monitor) que abrem focados na aba; `AppDelegate` abre o modal (`NSPanel`) quando o app é aberto pelo Spotlight; `Migration` das preferências do nome antigo.
- `Views.swift` — `RootView` com barra de abas no topo (`AppTab`: Geral, AI, Docker, Monitor, Ajustes).
- `AIView.swift` — aba AI: cards (mapa de tokens com uma linha por mês e um quadrado por dia + card numerado por assinatura com atalho para o uso no site).
- `TokenStats.swift` — tokens diários dos logs locais do Claude Code.
- `MenuIcon.swift` — ícones da barra: AI (barra numerada por assinatura, cor da IA), Docker e Monitor (grade 2×2 de ícone + barra).
- `GeneralView.swift` — resumo de AI + Docker.
- `DockerView.swift` / `Docker.swift` — `docker system df`, totais e botões de prune com confirmação.
- `Monitor.swift` / `MonitorView.swift` — métricas do sistema (APIs locais; temperatura via API privada de sensores HID) e grade de cards.
- `DockBar.swift` / `NativeDock.swift` — Dock próprio que substitui o do macOS (apps, Lixo, widgets largos de Stats); esconde/restaura o Dock nativo.
- `NowPlaying.swift` — música do Spotify no grupo Mac do Dock (notificação distribuída + AppleScript).
- `WindowGuard.swift` — Acessibilidade: impede janelas de ficarem atrás da barra do Dock.
- `YouTubePlayer.swift` — player do Dock: YouTube (link colado → WKWebView com só o vídeo, controles pela API do player), vídeos locais ("Abrir com › DevStatus"), fila e janela flutuante própria e `MediaCardView` (card único Spotify/YouTube com seletor à esquerda).
- `ProcessCPU.swift` — CPU por app (processo + descendentes) para a cor da barrinha no Dock.
- `Herdr.swift` — fila de agents do Herdr no Dock (status working/blocked/done/idle).
- `Devices.swift` — baterias do Mac e dos acessórios no Dock (`pmset -g accps`, igual ao widget Baterias), em anéis.
- `SubscriptionRings.swift` — widget de AI no Dock: anéis por assinatura (externo/interno) e logo preenchido até o reset.
- `DockTiles.swift` — Stats no Dock como janelas minimizadas com tile próprio.
- `SettingsView.swift` — Ajustes: iniciar com o Mac (`SMAppService`), Dock (substituir, tamanho dos ícones, aviso de Acessibilidade) e Stats (por ícone: orientação, intervalo, botão do Dock, largura no Dock e toggle; enum `Stat`).
- `AISettingsView.swift` — Ajustes de AI (na aba AI): cola cookie do site, assinaturas (com ordem/número ▲▼), contas identificadas.
- `Relogin.swift` — botão "Relogar" (card e cabeçalho da aba AI): abre o Terminal rodando `claude`, `CLAUDE_CONFIG_DIR=… claude` e `agent login` das assinaturas deslogadas.
- `Logos.swift` — logos oficiais Claude/Cursor via path SVG + parser `SVGPath`.
- `Models.swift` — `Provider`, `Subscription`, `Usage`, `Metric` (+ `MetricKind`), `UsageState`; escolha dos anéis e progresso do reset.
- `Store.swift` — junta contas do Claude Code, Cursor e cookies na ordem de `subscriptionOrder` (define o número fixo); `subsByAvailability`; refresh no intervalo de Stats › AI (mín. 1 min).
- `CursorAgentService.swift` — Cursor identificado pelo cursor-agent (config + Keychain).
- `ClaudeService.swift` — contas do Claude Code, Keychain, API OAuth.
- `WebServices.swift` — uso via cookie: claude.ai e cursor.com.
- `CookieStore.swift` — cookies no Keychain (`local.devstatus.cookies`), metadados no UserDefaults.
- `Assets/AppIcon.svg` / `AppIcon.icns` — ícone do app (o mesmo do site); o `build.sh` copia o `.icns` para `Contents/Resources`.
- `README.md` — visão geral. `docs/architecture.md` (fontes, APIs, decisões), `docs/development.md` (build, assinatura, testes), `docs/roadmap.md`.

## Regras e cuidados
- Swift tools 5.9, alvo macOS 13+. Sem dependências externas; sem Xcode project (só SwiftPM + `build.sh`).
- **Nunca logar, imprimir ou persistir tokens.** O token é lido do Keychain, usado na requisição e descartado.
- **Não renovar tokens OAuth.** O refresh rotaciona o refresh token e pode deslogar o Claude Code. Se expirou, o app só avisa.
- Rede: só `api.anthropic.com`, `claude.ai`, `cursor.com` e `i.scdn.co` (capa da música do Spotify no Dock). Exceção: o WKWebView do player do YouTube acessa o YouTube (e as CDNs que a página usa), só com o link que o usuário colou. Login do YouTube só pela janela de login do Google no próprio WebKit do app; nunca ler cookies do Safari/Chrome nem ler ou exibir os cookies da sessão. Docker: só o CLI local.
- Herdr: só leitura via CLI local `herdr-core events --json` (primeira linha, a cada 3 s com o Dock ligado; `ls --json` não traz `herdr.seen`). Nunca enviar comandos, prompts ou teclas para agents.
- Apple Events (AppleScript): só para o Spotify (estado, capa, play/pausa/faixa). Chave `NSAppleEventsUsageDescription` no `build.sh`.
- **Dock nativo**: só esconder via `NativeDock` (salva e restaura os valores originais). Nunca apagar `persistent-apps` nem outras chaves do `com.apple.dock`.
- **Prune sempre com confirmação (NSAlert)**. Nunca oferecer prune de volumes (podem ter dados). Sem telemetria nem analytics.
- Cookies colados nunca são logados nem exibidos; ficam só no Keychain.
- Credenciais do Claude Code vêm do Keychain via `/usr/bin/security`, como o próprio Claude Code faz.
- APIs privadas (sensores HID, `SetsCursorInBackground`) só para leitura/aparência; listar novas em `docs/architecture.md` › APIs privadas.
- Acessibilidade: só para manter janelas acima do Dock próprio (`WindowGuard`); não ler conteúdo de janelas.
- Se mudar o formato do Keychain/API, atualizar `docs/architecture.md`.
