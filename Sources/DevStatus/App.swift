import SwiftUI

@main
struct DevStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    @AppStorage(StatKey.ai) private var statAI = true
    @AppStorage(StatKey.docker) private var statDocker = true
    @AppStorage(StatKey.monitor) private var statMonitor = true

    init() { Migration.fromAIMonitor() }

    var body: some Scene {
        // Stats: IA (opcional)
        MenuBarExtra(isInserted: $statAI) {
            app.root(focus: .ai)
        } label: {
            AILabel(store: app.store)
        }
        .menuBarExtraStyle(.window)

        // Stats: Docker (opcional)
        MenuBarExtra(isInserted: $statDocker) {
            app.root(focus: .docker)
        } label: {
            DockerLabel(docker: app.docker)
        }
        .menuBarExtraStyle(.window)

        // Stats: Monitor (opcional)
        MenuBarExtra(isInserted: $statMonitor) {
            app.root(focus: .monitor)
        } label: {
            MonitorLabel(monitor: app.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct AILabel: View {
    @ObservedObject var store: Store
    @AppStorage(Stat.ai.verticalKey) private var vertical = false
    var body: some View {
        if store.subs.isEmpty {
            Image(systemName: "sparkles")
        } else {
            Image(nsImage: UsageBarsIcon.make(store.subsByAvailability.map { ($0.number, $0.sub.worstPercent, $0.sub.provider.nsColor) }, vertical: vertical))
        }
    }
}

struct DockerLabel: View {
    @ObservedObject var docker: DockerStore
    @AppStorage(Stat.docker.verticalKey) private var vertical = false
    var body: some View {
        if case .ok(let rows) = docker.state {
            Image(nsImage: DockerBarsIcon.make(rows, vertical: vertical))
        } else {
            Image(systemName: "shippingbox")
        }
    }
}

struct MonitorLabel: View {
    @ObservedObject var monitor: MonitorStore
    @AppStorage(Stat.monitor.verticalKey) private var vertical = false
    var body: some View {
        let m = monitor.memory
        let root = monitor.disks.first { $0.path == "/" }
        Image(nsImage: MonitorBarsIcon.make(
            cpu: monitor.cpu.usage,
            memory: m.total > 0 ? m.used / m.total : 0,
            disk: root.map { $0.total > 0 ? $0.used / $0.total : 0 } ?? 0,
            temperature: monitor.temperature.cpu,
            vertical: vertical))
    }
}

/// Abre o modal quando o app e aberto pelo Spotlight/Finder (inclusive se ja estiver rodando).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    let docker = DockerStore()
    let monitor = MonitorStore()
    private var panel: NSPanel?
    private lazy var dockBar = DockBarController(store: store, docker: docker, monitor: monitor) { [unowned self] tab in
        self.showModal(tab: tab)
    }
    private lazy var dockTiles = DockTiles(store: store, docker: docker, monitor: monitor) { [unowned self] tab in
        AnyView(self.root(focus: tab))
    }

    func root(focus: AppTab?) -> some View {
        RootView(focus: focus).environmentObject(store).environmentObject(docker).environmentObject(monitor)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // O icone de Monitor precisa de leituras mesmo com a aba fechada.
        syncMonitor()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncMonitor() }
        }

        // Ao iniciar junto com o Mac, fica so nos icones da barra.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginItem = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Aberto com um video ("Abrir com"): vai direto para o player, sem o modal.
        let isOpenFiles = event?.eventID == kAEOpenDocuments
        if !isLoginItem && !isOpenFiles { showModal() }
    }

    /// "Abrir com › DevStatus" em videos do Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        dockBar.openFiles(urls)
    }

    /// Aplica as preferencias de Stats (ligado/desligado e intervalos) quando mudam.
    private func syncMonitor() {
        let on = UserDefaults.standard.object(forKey: StatKey.monitor) as? Bool ?? true
        monitor.setInterval(Stat.monitor.interval)
        monitor.setBackground(on || Stat.monitor.inDock)
        dockTiles.sync()
        dockBar.sync()
        store.setInterval(Stat.ai.interval)
        docker.setInterval(Stat.docker.interval)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showModal()
        return false
    }

    /// Ao sair, o Dock do macOS volta.
    func applicationWillTerminate(_ notification: Notification) {
        NativeDock.restore()
    }

    func showModal(tab: AppTab? = nil) {
        if panel == nil {
            let host = NSHostingController(rootView: root(focus: nil))
            let p = NSPanel(contentViewController: host)
            p.styleMask = [.titled, .closable, .fullSizeContentView]
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.delegate = self
            panel = p
        }
        guard let p = panel else { return }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame, size = p.frame.size
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - f.height * 0.15))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        if let tab { NotificationCenter.default.post(name: .devStatusOpenTab, object: nil, userInfo: ["tab": tab.rawValue]) }
    }

    /// Fecha ao perder o foco, como o popover da barra.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let p = self?.panel, !p.isKeyWindow, NSApp.modalWindow == nil, p.attachedSheet == nil else { return }
            p.orderOut(nil)
        }
    }
}

/// Copia as preferencias do nome antigo do app (AIMonitor) na primeira execucao.
enum Migration {
    static func fromAIMonitor() {
        let d = UserDefaults.standard
        guard d.object(forKey: "migratedFromAIMonitor") == nil else { return }
        d.set(true, forKey: "migratedFromAIMonitor")
        guard let old = d.persistentDomain(forName: "local.aimonitor") else { return }
        for k in ["webEntries", "claudeCodePaths", "cursorAgentAdded"] where d.object(forKey: k) == nil {
            if let v = old[k] { d.set(v, forKey: k) }
        }
    }
}
