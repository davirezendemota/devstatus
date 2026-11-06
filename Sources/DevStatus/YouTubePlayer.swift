import SwiftUI
import AppKit
import WebKit

/// Player do YouTube no Dock: o link colado abre num WKWebView (motor do Safari) dentro do card.
/// O CSS injetado deixa so o video na pagina; estado e controles pela API do proprio player
/// (`#movie_player`: getVideoData, getCurrentTime, seekTo, nextVideo...).
@MainActor
final class YouTubePlayer: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var title = ""
    @Published private(set) var channel = ""
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isAd = false
    /// Video na janela flutuante (picture-in-picture proprio, com linha do tempo clicavel).
    @Published private(set) var floating = false
    private(set) var floatPanel: NSPanel?
    @Published private(set) var tint = YouTubePlayer.defaultTint

    static let defaultTint = Color(red: 0.32, green: 0.05, blue: 0.05)

    /// Item da fila: cada link colado. O atual toca; ao terminar, sai da fila e o proximo comeca.
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var title = ""
        var isPlaylist: Bool { url.query?.contains("list=") == true }
        /// Video do Mac aberto com "Abrir com › DevStatus".
        var isLocal: Bool { url.isFileURL }
    }
    @Published private(set) var queue: [Item] = []
    @Published private(set) var currentID: UUID?
    private var endedHandled = ""
    private var currentIndex: Int? { queue.firstIndex { $0.id == currentID } }

    override init() {
        super.init()
        checkLogin()
    }

    private(set) var webView: WKWebView?
    private var poll: Timer?
    @Published private(set) var loggedIn = false
    private var loginWindow: NSWindow?
    private var loginView: WKWebView?
    private static let userAgentSuffix = "Version/18.0 Safari/605.1.15"
    private var videoID = ""

    var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }

    // MARK: Abrir

    /// Pede o link (o da area de transferencia ja vem preenchido, se for do YouTube).
    func ask() {
        let adding = active
        let a = NSAlert()
        a.messageText = adding ? "Adicionar à fila do YouTube" : "Tocar vídeo do YouTube"
        a.informativeText = "Cole o link do vídeo ou da playlist."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://www.youtube.com/watch?v=…"
        if let clip = NSPasteboard.general.string(forType: .string), Self.watchURL(clip) != nil { field.stringValue = clip }
        a.accessoryView = field
        if adding {
            a.addButton(withTitle: "Adicionar à fila")
            a.addButton(withTitle: "Tocar agora")
        } else {
            a.addButton(withTitle: "Tocar")
        }
        a.addButton(withTitle: "Cancelar")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let resp = a.runModal()
        let playNow: Bool
        switch resp {
        case .alertFirstButtonReturn: playNow = !adding
        case .alertSecondButtonReturn where adding: playNow = true
        default: return
        }
        guard let url = Self.watchURL(field.stringValue) else {
            let e = NSAlert()
            e.messageText = "Link do YouTube inválido."
            e.runModal()
            return
        }
        enqueue(url, playNow: playNow)
    }

    // MARK: Fila

    func enqueue(_ url: URL, playNow: Bool) {
        let item = Item(url: url)
        if playNow {
            queue.insert(item, at: currentIndex.map { $0 + 1 } ?? queue.count)
            play(item)
        } else {
            queue.append(item)
        }
        fetchTitle(item)
    }

    /// Toca um item da fila (o atual continua na fila).
    func select(_ item: Item) {
        if item.id != currentID { play(item) }
    }

    /// Fecha so o video atual: sai da fila e toca o proximo (sem proximo, fecha o player).
    func closeCurrent() {
        if let i = currentIndex { remove(queue[i]) } else { close() }
    }

    func remove(_ item: Item) {
        if item.id == currentID { advance() } else { queue.removeAll { $0.id == item.id } }
    }

    /// Tira o atual da fila e toca o seguinte; sem mais itens, fecha o player.
    private func advance() {
        guard let i = currentIndex else { return }
        queue.remove(at: i)
        if queue.isEmpty { close() } else { play(queue[min(i, queue.count - 1)]) }
    }

    private func play(_ item: Item) {
        currentID = item.id
        load(item.url)
    }

    /// Titulo do item pelo oEmbed do YouTube (para a dica dos icones da fila).
    private func fetchTitle(_ item: Item) {
        if item.isLocal {
            if let i = queue.firstIndex(where: { $0.id == item.id }) { queue[i].title = item.url.deletingPathExtension().lastPathComponent }
            return
        }
        guard var c = URLComponents(string: "https://www.youtube.com/oembed") else { return }
        c.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "url", value: item.url.absoluteString)]
        guard let url = c.url else { return }
        Task {
            let title: String
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = o["title"] as? String {
                title = t
            } else {
                title = item.isPlaylist ? "Playlist" : "YouTube"
            }
            if let i = queue.firstIndex(where: { $0.id == item.id }) { queue[i].title = title }
        }
    }

    private func load(_ url: URL) {
        let wv = webView ?? makeWebView()
        webView = wv
        if url.isFileURL {
            // Acesso de leitura so ao arquivo: o "Abrir com" libera o arquivo, nao a pasta
            // (Mesa, Documentos e Downloads sao protegidas pelo macOS).
            wv.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            wv.load(URLRequest(url: url))
        }
        title = "Carregando…"; channel = url.isFileURL ? "Vídeo local" : "YouTube"
        position = 0; duration = 0; playing = false; videoID = ""; tint = Self.defaultTint
        active = true
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func close() {
        poll?.invalidate(); poll = nil
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
        endFloating()
        active = false; playing = false; title = ""; channel = ""; videoID = ""
        queue = []; currentID = nil
    }

    /// Continua no Safari a partir do ponto atual (e pausa aqui).
    var isLocal: Bool { currentIndex.map { queue[$0].isLocal } ?? false }

    /// Videos abertos pelo Finder ("Abrir com › DevStatus"): o primeiro toca, os outros vao para a fila.
    /// Sem o Dock proprio ligado, o video abre na janela flutuante.
    func openFiles(_ urls: [URL], floating: Bool) {
        let files = urls.filter(\.isFileURL)
        guard let first = files.first else { return }
        enqueue(first, playNow: true)
        files.dropFirst().forEach { enqueue($0, playNow: false) }
        if floating { startFloating() }
    }

    func revealInFinder() {
        guard let i = currentIndex, queue[i].isLocal else { return }
        NSWorkspace.shared.activateFileViewerSelecting([queue[i].url])
    }

    func openInSafari() {
        guard !videoID.isEmpty, var c = URLComponents(string: "https://www.youtube.com/watch") else { return }
        c.queryItems = [URLQueryItem(name: "v", value: videoID), URLQueryItem(name: "t", value: "\(Int(position))s")]
        guard let url = c.url else { return }
        if playing { togglePlay() }
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Controles

    func togglePlay() {
        js("var p=document.getElementById('movie_player');var v=document.querySelector('video');"
           + "if(v){v.paused?(p&&p.playVideo?p.playVideo():v.play()):(p&&p.pauseVideo?p.pauseVideo():v.pause())}")
        playing.toggle()
    }

    /// Pula `delta` segundos (janela flutuante).
    func skip(_ delta: Double) { seek(to: min(max(position + delta, 0), max(duration, 0))) }

    // MARK: Janela flutuante

    /// Picture-in-picture proprio: o PiP nativo do macOS nao deixa pular pela linha do tempo
    /// quando o video vem de um WKWebView. O web view muda do card para esta janela e volta.
    func togglePiP() { floating ? endFloating() : startFloating() }

    private func startFloating() {
        guard webView != nil else { return }
        if floatPanel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentAspectRatio = NSSize(width: 16, height: 9)
            p.minSize = NSSize(width: 240, height: 135)
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.backgroundColor = .black
            p.contentView = NSHostingView(rootView: FloatingPlayerView(youtube: self))
            if !p.setFrameUsingName("DevStatusYouTubeFloat"), let vf = NSScreen.screens.first?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: vf.maxX - 480 - 20, y: vf.minY + 120))
            }
            p.setFrameAutosaveName("DevStatusYouTubeFloat")
            p.delegate = self
            floatPanel = p
        }
        floating = true
        floatPanel?.orderFrontRegardless()
    }

    /// Ao mudar o video de janela (card <-> flutuante) ou redimensionar, a camada do video pode
    /// ficar preta: forca novo layout e recarrega o quadro com um seek no mesmo ponto.
    func repaint() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let wv = self?.webView, let sv = wv.superview else { return }
            wv.frame = sv.bounds.insetBy(dx: 0, dy: 0.5)
            wv.frame = sv.bounds
            self?.js("var v=document.querySelector('video');if(v){v.style.visibility='hidden';"
                     + "requestAnimationFrame(function(){v.style.visibility=''})}")
        }
        // Ao trocar de janela o WebKit descarta a camada do video e so volta a desenhar
        // depois de um seek (mesmo tocando). Recua um pouco para o seek nao ser ignorado.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.js("var v=document.querySelector('video');if(v&&v.readyState>0){var t=Math.max(0,v.currentTime-0.05);"
                     + "var p=document.getElementById('movie_player');"
                     + "if(p&&p.seekTo&&!(p.classList&&p.classList.contains('ad-showing')))p.seekTo(t,true);else v.currentTime=t}")
        }
    }

    func endFloating() {
        floating = false
        // Esconde a janela so depois que o video ja voltou para o card (nunca fica numa janela oculta).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.floating else { return }
            self.floatPanel?.orderOut(nil)
        }
    }

    /// Proximo da fila; numa playlist (ou sem fila) o proximo do proprio YouTube.
    func next() {
        if queue.count > 1, let i = currentIndex, !queue[i].isPlaylist { advance(); return }
        js("var p=document.getElementById('movie_player');if(p&&p.nextVideo)p.nextVideo()")
    }

    /// Volta ao inicio; se ja estiver no comeco, video anterior (playlist) ou pagina anterior.
    func previous() {
        if position > 3 || isLocal { seek(to: 0); return }
        js("var p=document.getElementById('movie_player');var pl=p&&p.getPlaylist&&p.getPlaylist();"
           + "if(pl&&pl.length&&p.getPlaylistIndex()>0)p.previousVideo();else history.back()")
    }

    func seek(fraction: Double) { seek(to: duration * min(max(fraction, 0), 1)) }

    private func seek(to t: Double) {
        js("var p=document.getElementById('movie_player');var v=document.querySelector('video');"
           + "if(p&&p.seekTo)p.seekTo(\(t),true);else if(v)v.currentTime=\(t)")
        position = t
    }

    private func js(_ source: String) {
        webView?.evaluateJavaScript("(function(){\(source)})();void 0", completionHandler: nil)
    }

    // MARK: Estado

    /// Registra seekto/seekforward/seekbackward e a posicao no Media Session, que a linha do tempo
    /// do picture-in-picture usa para pular (o YouTube nao registra todos).
    /// Tambem desliga legendas: o modulo do YouTube e as trilhas de texto do <video>, que o
    /// picture-in-picture do macOS desenha por conta propria (o CSS nao alcanca).
    private func refresh() {
        let src = """
        (function(){var p=document.getElementById('movie_player');var v=document.querySelector('video');
        if(p&&p.isSubtitlesOn&&p.isSubtitlesOn()&&p.unloadModule)p.unloadModule('captions');
        if(v&&v.textTracks)for(var i=0;i<v.textTracks.length;i++)if(v.textTracks[i].mode!=='disabled')v.textTracks[i].mode='disabled';
        try{var ms=navigator.mediaSession;if(ms&&v){var sk=function(t){if(p&&p.seekTo)p.seekTo(t,true);else v.currentTime=t};
        ms.setActionHandler('seekto',function(e){sk(e.seekTime)});
        ms.setActionHandler('seekforward',function(e){sk(v.currentTime+(e.seekOffset||10))});
        ms.setActionHandler('seekbackward',function(e){sk(Math.max(0,v.currentTime-(e.seekOffset||10)))});
        if(isFinite(v.duration)&&v.duration>0)ms.setPositionState({duration:v.duration,playbackRate:v.playbackRate||1,position:Math.min(v.currentTime,v.duration)});}}catch(_){}
        var d=p&&p.getVideoData?p.getVideoData():{};
        return JSON.stringify({t:v?v.currentTime:0,d:v&&isFinite(v.duration)?v.duration:0,p:v?!v.paused:false,
        id:d.video_id||'',title:d.title||document.title.replace(/^\\(\\d+\\)\\s*/,'').replace(/ - YouTube$/,''),
        ch:d.author||'',e:v?v.ended:false,ad:!!(p&&p.classList.contains('ad-showing'))});})()
        """
        webView?.evaluateJavaScript(src) { [weak self] result, _ in
            guard let s = result as? String, let data = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            MainActor.assumeIsolated { self?.apply(o) }
        }
    }

    private func apply(_ o: [String: Any]) {
        guard active else { return }
        position = Util.num(o["t"]) ?? 0
        duration = Util.num(o["d"]) ?? 0
        playing = o["p"] as? Bool ?? false
        isAd = o["ad"] as? Bool ?? false
        if let i = currentIndex, queue[i].isLocal {
            title = queue[i].url.deletingPathExtension().lastPathComponent
            channel = "Vídeo local"
        } else {
            if let t = o["title"] as? String, !t.isEmpty { title = t }
            if let c = o["ch"] as? String, !c.isEmpty { channel = c }
        }
        let id = o["id"] as? String ?? ""
        if !id.isEmpty, id != videoID {
            videoID = id
            // Cor do fundo pelo quadro do video, depois de comecar a tocar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.updateTint(for: id) }
        }
        // Video terminou: passa para o proximo da fila (playlists seguem pelo proprio YouTube).
        if o["e"] as? Bool == true, !isAd, endedHandled != videoID {
            endedHandled = videoID
            if queue.count > 1, let i = currentIndex, !queue[i].isPlaylist { advance() }
        }
    }

    private func updateTint(for id: String) {
        guard id == videoID, let wv = webView else { return }
        wv.takeSnapshot(with: nil) { [weak self] img, _ in
            guard let img, let self, id == self.videoID else { return }
            let c = NowPlaying.averageColor(img, fallback: nil)
            if let c { self.tint = c }
        }
    }

    // MARK: Sessao

    /// O WKWebView tem cookies proprios (nao le os do Safari). O login e feito numa janela com o
    /// mesmo armazenamento do player; a sessao fica salva no WebKit do app, como num navegador.
    func login() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = loginWindow { w.makeKeyAndOrderFront(nil); return }
        let cfg = WKWebViewConfiguration()
        cfg.applicationNameForUserAgent = Self.userAgentSuffix
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 680), configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!))
        let w = NSWindow(contentRect: wv.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Entrar no YouTube"
        w.contentView = wv
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        loginWindow = w
        loginView = wv
    }

    /// Apaga cookies e dados do Google/YouTube do WebKit do app.
    func logout() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { [weak self] records in
            let mine = records.filter { r in ["youtube", "google"].contains { r.displayName.contains($0) } }
            store.removeData(ofTypes: types, for: mine) { [weak self] in
                MainActor.assumeIsolated { self?.loggedIn = false; self?.reloadKeepingPosition() }
            }
        }
    }

    /// Ha sessao do YouTube no WebKit do app (cookie LOGIN_INFO ou SAPISID).
    func checkLogin(_ done: (() -> Void)? = nil) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let ok = cookies.contains { c in
                c.domain.hasSuffix("youtube.com") && ["LOGIN_INFO", "SAPISID", "__Secure-3PAPISID"].contains(c.name)
            }
            MainActor.assumeIsolated {
                self?.loggedIn = ok
                done?()
            }
        }
    }

    private func reloadKeepingPosition() {
        guard active, !videoID.isEmpty, var c = URLComponents(string: "https://www.youtube.com/watch") else { return }
        c.queryItems = [URLQueryItem(name: "v", value: videoID), URLQueryItem(name: "t", value: "\(Int(position))s")]
        if let url = c.url { load(url) }
    }

    private func finishLogin() {
        loginWindow?.delegate = nil
        loginWindow?.close()
        loginWindow = nil
        loginView = nil
        reloadKeepingPosition()
    }

    // MARK: WebView

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.applicationNameForUserAgent = Self.userAgentSuffix
        let script = "(function(){var s=document.createElement('style');s.textContent=`\(Self.css)`;"
            + "(document.head||document.documentElement).appendChild(s);})();"
        cfg.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: Self.localScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: Self.alwaysVisible, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 160, height: 90), configuration: cfg)
        wv.underPageBackgroundColor = .black
        wv.pageZoom = 0.5   // layout como se fosse maior: o YouTube nao entra no modo "player minusculo"
        return wv
    }

    /// A pagina sempre se ve visivel. Com a pagina "oculta" (web view fora da janela ao trocar
    /// card <-> flutuante, ou com o Spotify no card), o YouTube Premium passa para so audio
    /// (reproducao em segundo plano) e o video fica preto ao voltar.
    private static let alwaysVisible = """
    (function(){try{
    Object.defineProperty(document,'hidden',{configurable:true,get:function(){return false}});
    Object.defineProperty(document,'visibilityState',{configurable:true,get:function(){return 'visible'}});
    Object.defineProperty(document,'webkitVisibilityState',{configurable:true,get:function(){return 'visible'}});
    }catch(e){}
    var stop=function(e){e.stopImmediatePropagation()};
    document.addEventListener('visibilitychange',stop,true);
    document.addEventListener('webkitvisibilitychange',stop,true);
    window.addEventListener('visibilitychange',stop,true);})();
    """

    /// Video local: o documento de midia padrao do WebKit nao deixa o video ocupar o quadro, entao
    /// troca o conteudo por um <video> proprio (mesmo arquivo, mesma permissao de leitura).
    private static let localScript = """
    (function(){if(location.protocol!=='file:')return;
    var old=document.querySelector('video');if(old){old.pause();old.removeAttribute('src');
    Array.prototype.forEach.call(old.querySelectorAll('source'),function(s){s.remove()});old.load();old.remove();}
    if(document.head)document.head.innerHTML='';
    var st=document.createElement('style');
    st.textContent='html,body{margin:0;background:#000;overflow:hidden}video{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain}';
    (document.head||document.documentElement).appendChild(st);
    document.body.innerHTML='';
    var v=document.createElement('video');v.src=location.href;v.autoplay=true;v.playsInline=true;
    document.body.appendChild(v);v.play().catch(function(){});})();
    """

    /// So o video, ocupando a pagina inteira; esconde controles, cards e o resto do site.
    private static let css = """
    html,body{overflow:hidden!important;background:#000!important}
    #masthead-container,#secondary,#below,#chat,ytd-popup-container,tp-yt-iron-overlay-backdrop{display:none!important}
    #movie_player,.html5-video-player{position:fixed!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;z-index:2147483647!important;background:#000!important}
    .html5-video-container,video.html5-main-video{left:0!important;top:0!important;width:100vw!important;height:100vh!important;object-fit:contain!important}
    .ytp-chrome-top,.ytp-chrome-bottom,.ytp-gradient-top,.ytp-gradient-bottom,.ytp-ce-element,.ytp-pause-overlay,.ytp-cards-teaser,.ytp-watermark,.iv-branding,.ytp-paid-content-overlay,.ytp-autonav-endscreen-countdown-overlay,.ytp-spinner,.ytp-bezel,.ytp-tooltip,.ytp-iv-player-content,.ytp-caption-window-container{display:none!important}
    """

    // MARK: Links

    /// Normaliza youtu.be, /watch, /shorts, /live, /embed e /playlist para um link /watch.
    static func watchURL(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let c = URLComponents(string: raw), let host = c.host?.lowercased() else { return nil }
        let q = { (name: String) in c.queryItems?.first { $0.name == name }?.value }
        let parts = c.path.split(separator: "/").map(String.init)
        var id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            if parts.first == "watch" { id = q("v") }
            else if parts.count > 1, ["shorts", "live", "embed", "v"].contains(parts[0]) { id = parts[1] }
            else if parts.first != "playlist" { return nil }
        } else {
            return nil
        }
        let valid = { (s: String) in s.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil }
        var out = URLComponents(string: "https://www.youtube.com/watch")!
        var items: [URLQueryItem] = []
        if let id, valid(id) { items.append(URLQueryItem(name: "v", value: id)) }
        if let list = q("list"), list.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            items.append(URLQueryItem(name: "list", value: list))
        }
        guard !items.isEmpty, items.contains(where: { $0.name == "v" }) || parts.first == "playlist" else { return nil }
        if let t = q("t"), t.range(of: "^[0-9hms]+$", options: .regularExpression) != nil { items.append(URLQueryItem(name: "t", value: t)) }
        out.queryItems = items
        return out.url
    }
}

extension YouTubePlayer: WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// Login concluido quando a janela volta para o YouTube com a sessao criada.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === loginView, webView.url?.host?.hasSuffix("youtube.com") == true else { return }
        checkLogin { [weak self] in if self?.loggedIn == true { self?.finishLogin() } }
    }

    /// Links que abririam nova janela (comuns no login do Google) abrem na mesma.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if (notification.object as? NSWindow) === floatPanel { repaint() }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === loginWindow else { return }
        loginWindow = nil
        loginView = nil
        checkLogin { [weak self] in if self?.loggedIn == true { self?.reloadKeepingPosition() } }
    }
}

// MARK: Views

/// Card de midia do Dock: Spotify e YouTube no mesmo card. A esquerda, icones para trocar o
/// player: Spotify e um por item da fila, numa coluna com rolagem.
struct MediaCardView: View {
    enum Source { case spotify, youtube }
    enum Entry: Hashable { case spotify, video(UUID) }
    @ObservedObject var player: NowPlaying
    @ObservedObject var youtube: YouTubePlayer
    let size: CGFloat
    @State private var picked: Source = .spotify

    private var source: Source {
        if !youtube.active { return .spotify }
        if !player.hasTrack { return .youtube }
        return picked
    }

    private var entries: [Entry] {
        (player.hasTrack ? [.spotify] : []) + youtube.queue.map { .video($0.id) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            let list = entries
            if list.count >= 2 {
                // Coluna unica com rolagem (barra invisivel) na altura do card; centrada se couber.
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(list, id: \.self) { entryButton($0).id($0) }
                        }
                        .frame(minHeight: size)
                    }
                    .frame(width: size * 0.34, height: size)
                    .onChange(of: youtube.currentID) { id in
                        if let id { withAnimation { proxy.scrollTo(Entry.video(id), anchor: .center) } }
                    }
                }
            }
            if source == .spotify {
                NowPlayingView(player: player, size: size)
            } else {
                YouTubePlayerView(youtube: youtube, size: size)
            }
        }
        .onChange(of: youtube.active) { if $0 { picked = .youtube } }
        .animation(.easeInOut(duration: 0.2), value: source)
        .animation(.easeInOut(duration: 0.2), value: youtube.queue.count)
    }

    @ViewBuilder private func entryButton(_ e: Entry) -> some View {
        switch e {
        case .spotify:
            pickButton(selected: source == .spotify, help: "Spotify", action: { picked = .spotify }) {
                if let icon = NowPlaying.appIcon { Image(nsImage: icon).resizable().interpolation(.high) }
            }
        case .video(let id):
            if let item = youtube.queue.first(where: { $0.id == id }) {
                pickButton(selected: source == .youtube && youtube.currentID == id,
                           help: item.title.isEmpty ? "YouTube" : item.title,
                           action: { picked = .youtube; youtube.select(item) }) {
                    if item.isLocal { YouTubeGlyph(fill: Color(white: 0.88), mark: .black) } else { YouTubeGlyph() }
                }
                    .contextMenu { Button("Remover da fila") { youtube.remove(item) } }
            }
        }
    }

    private func pickButton<I: View>(selected: Bool, help: String, action: @escaping () -> Void,
                                     @ViewBuilder _ icon: () -> I) -> some View {
        let side = size * 0.34
        return Button(action: action) {
            icon()
                .frame(width: side, height: side)
                .opacity(selected ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }
}

/// Logo do YouTube desenhado (retangulo vermelho com o triangulo branco).
/// Com outras cores, o mesmo formato serve de icone para video local.
struct YouTubeGlyph: View {
    var fill = Color(red: 1, green: 0, blue: 0)
    var mark = Color.white

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = w * 0.7
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.28, style: .continuous).fill(fill)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.4, y: h * 0.3))
                    p.addLine(to: CGPoint(x: w * 0.4, y: h * 0.7))
                    p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.5))
                    p.closeSubpath()
                }
                .fill(mark)
            }
            .frame(width: w, height: h)
            .frame(maxHeight: .infinity)
        }
    }
}

/// Player do YouTube no mesmo formato do Spotify: video ao vivo no lugar da capa.
struct YouTubePlayerView: View {
    @ObservedObject var youtube: YouTubePlayer
    let size: CGFloat
    @State private var hover = false

    private var art: CGFloat { size - 12 }
    private var videoWidth: CGFloat { art * 16 / 9 }

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if youtube.floating {
                    Image(systemName: "pip").font(.system(size: size * 0.26)).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.35))
                } else if let wv = youtube.webView {
                    WebViewHost(webView: wv, owns: { [youtube] in !youtube.floating }, onAttach: youtube.repaint)
                } else {
                    Color.black
                }
            }
            .frame(width: videoWidth, height: art)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                // No hover: abrir no Safari, picture-in-picture e fechar, sem fundo.
                HStack(spacing: size * 0.12) {
                    if hover {
                        if youtube.isLocal {
                            videoButton("folder", "Mostrar no Finder") { youtube.revealInFinder() }
                        } else {
                            videoButton("safari", "Abrir no Safari") { youtube.openInSafari() }
                        }
                        videoButton(youtube.floating ? "pip.exit" : "pip.enter",
                                    youtube.floating ? "Voltar para o Dock" : "Janela flutuante") { youtube.togglePiP() }
                        videoButton("xmark", "Fechar este vídeo") { youtube.closeCurrent() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
            }
            .animation(.easeInOut(duration: 0.15), value: hover)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(youtube.isAd ? "Anúncio" : youtube.title)
                            .font(.system(size: max(10, size * 0.21), weight: .bold)).lineLimit(1)
                        if youtube.isAd && !youtube.loggedIn {
                            // Sem login no player nao ha Premium (a sessao do Safari nao vale aqui).
                            Button { youtube.login() } label: {
                                Text("Entrar para usar o Premium").underline()
                                    .font(.system(size: max(9, size * 0.17))).lineLimit(1)
                            }
                            .buttonStyle(.plain).pointerCursor()
                        } else {
                            Text(youtube.channel).font(.system(size: max(9, size * 0.17))).opacity(0.75).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    control("backward.end.fill", "Anterior") { youtube.previous() }
                    control(youtube.playing ? "pause.fill" : "play.fill", "Play/pausa") { youtube.togglePlay() }
                    control("forward.end.fill", "Próximo") { youtube.next() }
                }
                SeekBar(youtube: youtube, thickness: 3)
            }
            .foregroundStyle(.white)
        }
        .padding(6)
        .frame(width: size * 3.4 + (videoWidth - art), height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [youtube.tint.opacity(0.95), youtube.tint.opacity(0.65)],
                                     startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(.white.opacity(0.15)))
        .animation(.easeInOut(duration: 0.3), value: youtube.tint)
        .contextMenu {
            Button("Abrir no Safari") { youtube.openInSafari() }
            Button("Adicionar à fila…") { youtube.ask() }
            if youtube.loggedIn {
                Button("Sair do YouTube") { youtube.logout() }
            } else {
                Button("Entrar no YouTube…") { youtube.login() }
            }
            Divider()
            Button("Fechar este vídeo") { youtube.closeCurrent() }
            if youtube.queue.count > 1 { Button("Fechar todos") { youtube.close() } }
        }
    }

    private func control(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: max(10, size * 0.2), weight: .semibold))
                .frame(width: size * 0.32, height: size * 0.32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }

    private func videoButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: max(11, size * 0.26), weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
        .transition(.opacity)
    }
}

/// Barra de progresso; clicar ou arrastar pula para o ponto.
struct SeekBar: View {
    @ObservedObject var youtube: YouTubePlayer
    let thickness: CGFloat
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { g in
            let f = dragging ?? youtube.progress
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(youtube.isAd ? Color.yellow : .white.opacity(0.9)).frame(width: g.size.width * f)
            }
            .frame(height: dragging == nil ? thickness : thickness * 1.6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = min(max(v.location.x / max(g.size.width, 1), 0), 1) }
                .onEnded { v in
                    youtube.seek(fraction: v.location.x / max(g.size.width, 1))
                    dragging = nil
                })
        }
        .frame(height: thickness * 3)
        .pointerCursor()
    }
}

/// Conteudo da janela flutuante: video e, no hover, controles (voltar ao Dock, fechar,
/// -10 s, play/pausa, +10 s e linha do tempo). Arrastar o video move a janela.
struct FloatingPlayerView: View {
    @ObservedObject var youtube: YouTubePlayer
    @State private var hover = false
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    var body: some View {
        ZStack {
            if youtube.floating, let wv = youtube.webView { WebViewHost(webView: wv, owns: { [youtube] in youtube.floating }, onAttach: youtube.repaint) } else { Color.black }
            Color.black.opacity(hover ? 0.3 : 0.001)
                .contentShape(Rectangle())
                .onTapGesture { youtube.togglePlay() }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        guard let w = youtube.floatPanel else { return }
                        let m = NSEvent.mouseLocation
                        if dragStart == nil { dragStart = (m, w.frame.origin) }
                        if let s = dragStart { w.setFrameOrigin(NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y)) }
                    }
                    .onEnded { _ in dragStart = nil })
            if hover { controls.transition(.opacity) }
        }
        .ignoresSafeArea()
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.15), value: hover)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Spacer()
                button("pip.exit", 15, "Voltar para o Dock") { youtube.endFloating() }
                button("xmark", 15, "Fechar este vídeo") { youtube.closeCurrent() }
            }
            Spacer()
            HStack(spacing: 34) {
                button("gobackward.10", 22, "Voltar 10 s") { youtube.skip(-10) }
                button(youtube.playing ? "pause.fill" : "play.fill", 32, "Play/pausa") { youtube.togglePlay() }
                button("goforward.10", 22, "Avançar 10 s") { youtube.skip(10) }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text(youtube.isAd ? "Anúncio" : youtube.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(Self.time(youtube.position))
                    SeekBar(youtube: youtube, thickness: 4)
                    Text(Self.time(youtube.duration))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 3)
        .padding(12)
    }

    private func button(_ symbol: String, _ pt: CGFloat, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: pt, weight: .semibold)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }

    static func time(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Hospeda o WKWebView do player sem deixar ele receber cliques (os controles sao do card).
/// Card e janela flutuante tem cada um o seu host; so adota o web view o host que e o dono
/// atual (`owns`) e ja esta numa janela. Sem isso, ao trocar, o host que esta saindo podia
/// pegar o web view de volta e ser descartado com ele dentro: o video ficava fora de qualquer
/// janela e preto nos dois lugares.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let owns: () -> Bool
    var onAttach: () -> Void = {}

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ v: Container, context: Context) {
        v.webView = webView
        v.owns = owns
        v.onAttach = onAttach
        v.adopt()
    }

    final class Container: NSView {
        var webView: WKWebView?
        var owns: () -> Bool = { false }
        var onAttach: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            adopt()
        }

        func adopt() {
            guard let wv = webView, window != nil, owns(), wv.superview !== self else { return }
            wv.removeFromSuperview()
            wv.frame = bounds
            wv.autoresizingMask = [.width, .height]
            addSubview(wv)
            onAttach()
        }
    }
}
