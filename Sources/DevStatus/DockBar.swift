import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: Preferencias

enum DockBar {
    static let enabledKey = "dockReplace"
    static let iconSizeKey = "dockIconSize"
    static let pinnedKey = "dockPinned"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static let finderPath = "/System/Library/CoreServices/Finder.app"
    static let settingsPath = "/System/Applications/System Settings.app"
    /// Apps do sistema que ficam no grupo Mac (junto do Lixo), fora da lista de apps.
    static let systemPaths = [finderPath]
}

extension Stat {
    var widthKey: String { "stat\(rawValue)DockWidth" }
    /// Largura do widget na barra, em "icones" (1 a 4).
    var dockWidth: Int {
        let v = UserDefaults.standard.integer(forKey: widthKey)
        return v > 0 ? v : 2
    }
}

// MARK: Modelo dos apps

struct DockApp: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    var running: NSRunningApplication?
    var url: URL { URL(fileURLWithPath: path) }
    var isRunning: Bool { running != nil }
    static func == (a: DockApp, b: DockApp) -> Bool { a.path == b.path && a.running?.processIdentifier == b.running?.processIdentifier }
}

@MainActor
final class DockModel: ObservableObject {
    @Published private(set) var pinned: [DockApp] = []
    @Published private(set) var others: [DockApp] = []   // abertos e nao fixos
    @Published private(set) var system: [DockApp] = []   // Finder e Ajustes do Sistema
    /// % de CPU por app (caminho do .app), 100 = um nucleo.
    @Published private(set) var cpu: [String: Double] = [:]
    private let cpuMeter = ProcessCPU()
    private var cpuTimer: Timer?
    private var icons: [String: NSImage] = [:]
    private var bag: [NSObjectProtocol] = []

    private var pinnedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: DockBar.pinnedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: DockBar.pinnedKey) }
    }

    init() {
        // Primeira vez: importa os apps fixos do Dock do macOS.
        if UserDefaults.standard.object(forKey: DockBar.pinnedKey) == nil {
            pinnedPaths = NativeDock.pinnedAppPaths().filter { $0 != DockBar.finderPath }
        }
        // Ajustes do Sistema nao fica fixo (aparece so quando aberto).
        if !UserDefaults.standard.bool(forKey: "dockSettingsUnpinned") {
            UserDefaults.standard.set(true, forKey: "dockSettingsUnpinned")
            pinnedPaths.removeAll { $0 == DockBar.settingsPath }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            bag.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuild() }
            })
        }
        rebuild()
    }

    /// Mede a CPU dos apps abertos a cada 3 s enquanto a barra esta visivel.
    func setSampling(_ on: Bool) {
        cpuTimer?.invalidate(); cpuTimer = nil
        guard on else { cpu = [:]; return }
        sampleCPU()
        cpuTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCPU() }
        }
    }

    private func sampleCPU() {
        let apps = (pinned + others + system).compactMap { app in app.running.map { ($0.processIdentifier, app.path) } }
        let byPid = Dictionary(apps, uniquingKeysWith: { a, _ in a })
        let meter = cpuMeter
        Task.detached(priority: .utility) {
            let usage = meter.sample(roots: Set(byPid.keys))
            await MainActor.run {
                var out: [String: Double] = [:]
                for (pid, v) in usage { if let path = byPid[pid] { out[path] = v } }
                self.cpu = out
            }
        }
    }

    func icon(_ path: String) -> NSImage {
        if let i = icons[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        icons[path] = i
        return i
    }

    func rebuild() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        func runningApp(_ path: String) -> NSRunningApplication? {
            running.first { $0.bundleURL?.standardizedFileURL.path == path }
        }
        let paths = pinnedPaths.filter { FileManager.default.fileExists(atPath: $0) && !DockBar.systemPaths.contains($0) }
        pinned = paths.map { DockApp(path: $0, name: Self.name($0), running: runningApp($0)) }
        system = DockBar.systemPaths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { DockApp(path: $0, name: Self.name($0), running: runningApp($0)) }
        let pinnedSet = Set(paths + DockBar.systemPaths)
        others = running.compactMap { app in
            guard let p = app.bundleURL?.standardizedFileURL.path, !pinnedSet.contains(p) else { return nil }
            return DockApp(path: p, name: app.localizedName ?? Self.name(p), running: app)
        }
    }

    private static func name(_ path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Acoes

    /// Igual ao Dock: abre ou traz para frente (o "reopen" cria janela se o app nao tiver nenhuma).
    func open(_ app: DockApp) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: cfg)
    }

    func open(files: [URL], with app: DockApp) {
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(files, withApplicationAt: app.url, configuration: cfg)
    }

    func isPinned(_ app: DockApp) -> Bool { DockBar.systemPaths.contains(app.path) || pinnedPaths.contains(app.path) }

    func pin(_ path: String, at index: Int? = nil) {
        guard !DockBar.systemPaths.contains(path) else { return }
        var list = pinnedPaths.filter { $0 != path }
        let i = min(max(index ?? list.count, 0), list.count)
        list.insert(path, at: i)
        pinnedPaths = list
        rebuild()
    }

    func unpin(_ app: DockApp) {
        pinnedPaths.removeAll { $0 == app.path }
        rebuild()
    }

    func hide(_ app: DockApp) { app.running?.hide() }
    func quit(_ app: DockApp) { app.running?.terminate() }
    func showInFinder(_ app: DockApp) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
}

// MARK: Janela da barra

@MainActor
final class DockBarController {
    private let model = DockModel()
    private lazy var player = NowPlaying()
    private let herdr = HerdrStore()
    private let devices = DevicesStore()
    let windowGuard = WindowGuard()
    private let store: Store
    private let docker: DockerStore
    private let monitor: MonitorStore
    private let openTab: (AppTab) -> Void
    private var panel: NSPanel?
    private var observer: NSObjectProtocol?

    init(store: Store, docker: DockerStore, monitor: MonitorStore, openTab: @escaping (AppTab) -> Void) {
        self.store = store
        self.docker = docker
        self.monitor = monitor
        self.openTab = openTab
        windowGuard.barTop = { [weak self] in self?.barTopAX }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
    }

    func sync() {
        if DockBar.enabled {
            show()
            NativeDock.hide()
            windowGuard.start()
            model.setSampling(true)
            herdr.setPolling(true)
            devices.setPolling(true)
        } else {
            panel?.orderOut(nil)
            windowGuard.stop()
            model.setSampling(false)
            herdr.setPolling(false)
            devices.setPolling(false)
            NativeDock.restore()
        }
    }

    private func show() {
        BackgroundCursor.enable()
        if panel == nil {
            let view = DockBarView(model: model, store: store, docker: docker, monitor: monitor,
                                   player: player, herdr: herdr, devices: devices, openTab: openTab)
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // O NSHostingView ajusta o tamanho da janela ao conteudo; a cada mudanca recentralizamos.
            p.contentView = NSHostingView(rootView: view)
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p,
                                                                    queue: .main) { [weak self] _ in
                Task { @MainActor in self?.place() }
            }
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            panel = p
        }
        place()
        panel?.orderFrontRegardless()
    }

    private var resizeObserver: NSObjectProtocol?

    /// Centraliza na base da tela principal (a da barra de menu), mantendo o tamanho atual da janela.
    private func place() {
        guard let p = panel, let screen = NSScreen.screens.first else { return }
        let f = screen.frame
        if let fit = p.contentView?.fittingSize, fit.width > 0, fit != p.frame.size {
            p.setContentSize(fit)   // dispara didResize, que chama place() de novo
            return
        }
        let origin = NSPoint(x: (f.midX - p.frame.width / 2).rounded(), y: f.minY + 10)
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
        if p.frame.height != lastHeight { lastHeight = p.frame.height; windowGuard.clampAll() }
    }

    private var lastHeight: CGFloat = 0

    /// Topo visivel da barra (sem a folga do zoom) em coordenadas de Acessibilidade.
    var barTopAX: CGFloat? {
        guard let p = panel, p.isVisible, let screen = NSScreen.screens.first else { return nil }
        let zoomRoom = CGFloat(UserDefaults.standard.object(forKey: DockBar.iconSizeKey) as? Double ?? 52) * 0.3
        return screen.frame.height - (p.frame.maxY - zoomRoom)
    }
}

// MARK: Views

struct DockBarView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var store: Store
    @ObservedObject var docker: DockerStore
    @ObservedObject var monitor: MonitorStore
    @ObservedObject var player: NowPlaying
    @ObservedObject var herdr: HerdrStore
    @ObservedObject var devices: DevicesStore
    let openTab: (AppTab) -> Void
    @AppStorage(DockBar.iconSizeKey) private var iconSize: Double = 52
    // Recarrega quando os toggles/larguras dos Stats mudam.
    @AppStorage(Stat.ai.dockKey) private var aiOn = false
    @AppStorage(Stat.docker.dockKey) private var dockerOn = false
    @AppStorage(Stat.monitor.dockKey) private var monitorOn = false
    @AppStorage(Stat.ai.widthKey) private var aiW = 2
    @AppStorage(Stat.docker.widthKey) private var dockerW = 2
    @AppStorage(Stat.monitor.widthKey) private var monitorW = 2
    @AppStorage(Stat.ai.verticalKey) private var aiV = false
    @AppStorage(Stat.docker.verticalKey) private var dockerV = false
    @AppStorage(Stat.monitor.verticalKey) private var monitorV = false

    private var s: CGFloat { CGFloat(iconSize) }
    private var widgets: [Stat] {
        [(Stat.ai, aiOn), (.docker, dockerOn), (.monitor, monitorOn)].filter(\.1).map(\.0)
    }

    var body: some View {
        // Tres grupos com fundo proprio; entre eles, transparente.
        HStack(alignment: .bottom, spacing: 10) {
            group {
                ForEach(model.pinned) { AppIconView(app: $0, model: model, size: s) }
                ForEach(model.others) { AppIconView(app: $0, model: model, size: s) }
            }
            group {
                ForEach(model.system) { AppIconView(app: $0, model: model, size: s) }
                TrashIconView(size: s)
            }
            if !herdr.agents.isEmpty {
                group { HerdrQueueView(herdr: herdr, size: s) }
            }
            if !widgets.isEmpty {
                group {
                    ForEach(widgets, id: \.self) { stat in
                        Group {
                            if stat == .ai {
                                AIRingsView(store: store, size: s)   // aneis por assinatura
                            } else {
                                WidgetTileView(rows: StatRows.rows(stat, store: store, docker: docker, monitor: monitor),
                                               icon: stat.icon, vertical: stat.vertical, units: stat.dockWidth, size: s)
                            }
                        }
                            .onTapGesture { openTab(stat.tab) }
                            .pointerCursor()
                            .help("DevStatus · \(stat.rawValue)")
                    }
                }
            }
            if player.hasTrack {
                group { NowPlayingView(player: player, size: s) }
            }
            if !devices.devices.isEmpty {
                group { DevicesView(devices: devices, size: s) }
            }
        }
        .padding(.top, s * 0.3)   // espaco para o zoom ao passar o mouse
        .fixedSize()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Soltar um .app na barra fixa no fim.
            loadURLs(providers) { urls in urls.filter { $0.pathExtension == "app" }.forEach { model.pin($0.standardizedFileURL.path) } }
            return true
        }
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .bottom, spacing: 8) { content() }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.15)))
            )
    }

}

/// Le URLs de arquivos soltos (drag and drop).
func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { done(urls) } }
}

struct AppIconView: View {
    let app: DockApp
    @ObservedObject var model: DockModel
    let size: CGFloat
    @State private var hover = false
    @State private var dropTarget = false

    /// Barrinha de app aberto: amarela com 70%+ de CPU, vermelha com 90%+.
    private var runningColor: Color {
        let c = model.cpu[app.path] ?? 0
        if c >= 90 { return .red }
        if c >= 70 { return .yellow }
        return .primary.opacity(0.85)
    }

    var body: some View {
        Image(nsImage: model.icon(app.path))
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .scaleEffect(hover ? 1.25 : 1, anchor: .bottom)
            .brightness(dropTarget ? 0.15 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            // App aberto: barrinha horizontal embaixo, sobre a margem do grupo (nao ocupa altura).
            .overlay(alignment: .bottom) {
                if app.isRunning {
                    Capsule().fill(runningColor)
                        .frame(width: size * 0.3, height: 3)
                        .offset(y: 4)
                }
            }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { model.open(app) }
        .help(model.cpu[app.path].map { "\(app.name) · CPU \(Int($0.rounded()))%" } ?? app.name)
        .onDrag { NSItemProvider(object: app.url as NSURL) }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            loadURLs(providers) { urls in
                let apps = urls.filter { $0.pathExtension == "app" }
                if !apps.isEmpty, model.isPinned(app), let i = model.pinned.firstIndex(of: app) {
                    // Arrastar um app sobre outro fixo: reordena (ou fixa) nessa posicao.
                    apps.forEach { model.pin($0.standardizedFileURL.path, at: i) }
                } else if apps.isEmpty {
                    model.open(files: urls, with: app)   // arquivos: abre com este app
                }
            }
            return true
        }
        .contextMenu {
            if !DockBar.systemPaths.contains(app.path) {
                if model.isPinned(app) {
                    Button("Remover do Dock") { model.unpin(app) }
                } else {
                    Button("Manter no Dock") { model.pin(app.path) }
                }
            }
            Button("Mostrar no Finder") { model.showInFinder(app) }
            if app.isRunning {
                Divider()
                Button("Ocultar") { model.hide(app) }
                if app.path != DockBar.finderPath { Button("Encerrar") { model.quit(app) } }
            } else {
                Button("Abrir") { model.open(app) }
            }
        }
    }
}

struct TrashIconView: View {
    let size: CGFloat
    @State private var hover = false
    @State private var target = false
    private var trash: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.Trash") }

    var body: some View {
        Image(nsImage: NSImage(named: NSImage.trashEmptyName) ?? NSImage()).resizable()
            .frame(width: size, height: size)
            .scaleEffect(hover || target ? 1.25 : 1, anchor: .bottom)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover || target)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture { NSWorkspace.shared.open(trash) }
        .help("Lixo")
        .onDrop(of: [.fileURL], isTargeted: $target) { providers in
            loadURLs(providers) { urls in
                for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
            }
            return true
        }
    }
}

/// Widget de Stats na barra: largura de 1 a 4 icones.
struct WidgetTileView: View {
    let rows: [TileRow]
    let icon: String
    let vertical: Bool
    let units: Int
    let size: CGFloat

    private var width: CGFloat { CGFloat(units) * size + CGFloat(units - 1) * 6 }

    var body: some View {
        Group {
            if units == 1 {
                DockTileView(title: "", icon: icon, rows: rows, vertical: vertical)
                    .scaleEffect(size / 128)
                    .frame(width: size, height: size)
            } else {
                content
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(width: width, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(.white.opacity(0.14)))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            Label("sem dados", systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vertical {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(rows.indices, id: \.self) { i in column(rows[i]) }
            }
        } else {
            // Ate um item por "icone" de largura numa linha; se passar disso, quebra em duas linhas.
            let perLine = rows.count > units ? Int((Double(rows.count) / 2).rounded(.up)) : rows.count
            VStack(spacing: 4) {
                ForEach(Array(stride(from: 0, to: rows.count, by: max(perLine, 1))), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(start..<min(start + perLine, rows.count), id: \.self) { i in item(rows[i]) }
                    }
                }
            }
        }
    }

    private var font: CGFloat { max(9, size * 0.2) }

    @ViewBuilder private func label(_ r: TileRow) -> some View {
        if r.symbol {
            Image(systemName: r.label).font(.system(size: font * 0.9, weight: .semibold))
        } else {
            Text(r.label).font(.system(size: font, weight: .heavy).monospacedDigit())
        }
    }

    private func item(_ r: TileRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                label(r).foregroundStyle(.white.opacity(0.85))
                Text(r.value).font(.system(size: font, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(r.color).frame(width: max(5, g.size.width * min(max(r.fraction, 0), 1)))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }

    private func column(_ r: TileRow) -> some View {
        VStack(spacing: 2) {
            Text(r.value).font(.system(size: font * 0.85, weight: .bold).monospacedDigit())
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.18))
                    RoundedRectangle(cornerRadius: 3).fill(r.color)
                        .frame(height: max(5, g.size.height * min(max(r.fraction, 0), 1)))
                }
            }
            .frame(maxWidth: 12)
            label(r).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Permite trocar o cursor com o app em segundo plano (a barra nunca fica ativa).
/// Propriedade privada do WindowServer "SetsCursorInBackground", a mesma usada por apps de mouse/Dock.
@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

enum BackgroundCursor {
    private static var done = false
    static func enable() {
        guard !done else { return }
        done = true
        let cid = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

extension View {
    /// Cursor de mao ao passar o mouse (a barra nao fica ativa, entao o cursor e trocado na mao).
    func pointerCursor() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}
