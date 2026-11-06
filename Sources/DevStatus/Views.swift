import SwiftUI

enum AppTab: String, CaseIterable {
    case general = "Geral", ai = "AI", docker = "Docker", monitor = "Monitor", settings = "Ajustes"
    var icon: String {
        switch self {
        case .general: return "square.grid.2x2"
        case .ai: return "sparkles"
        case .docker: return "shippingbox"
        case .monitor: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var docker: DockerStore
    /// Aba que abre sempre que este icone e clicado (icones de Stats). nil = mantem a ultima aba.
    var focus: AppTab?
    @State private var tab: AppTab = .general
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(tab: $tab)
            Divider()
            Group {
                switch tab {
                case .general: GeneralView(tab: $tab)
                case .ai: AITab()
                case .docker: DockerView()
                case .monitor: MonitorView()
                case .settings: SettingsView()
                }
            }
            .frame(width: 500, height: 540)
        }
        .background(WindowReader(window: $window))
        .onAppear {
            if let focus { tab = focus } else if store.subs.isEmpty { tab = .ai }
        }
        .onReceive(NotificationCenter.default.publisher(for: .devStatusOpenTab)) { note in
            if focus == nil, let raw = note.userInfo?["tab"] as? String, let t = AppTab(rawValue: raw) { tab = t }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let focus, let w = note.object as? NSWindow, w === window { tab = focus }
        }
    }
}

/// Descobre a janela que hospeda a view (para saber quando o popover e reaberto).
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { window = v.window }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if v.window !== window { DispatchQueue.main.async { window = v.window } }
    }
}

struct TopBar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var docker: DockerStore
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(tab == t ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            Button { store.reload(); docker.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Atualizar tudo")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Sair")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

struct MetricView: View {
    let metric: Metric

    private var color: Color {
        guard let p = metric.percent else { return .green }
        return p >= 90 ? .red : p >= 70 ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(metric.title).font(.caption)
                Spacer()
                if let p = metric.percent { Text("\(Int(p.rounded()))%").font(.caption.monospacedDigit()) }
            }
            if let p = metric.percent {
                ProgressView(value: min(p, 100), total: 100).tint(color)
            }
            if let d = metric.detail { Text(d).font(.caption2).foregroundStyle(.secondary) }
            if let r = metric.resetsAt {
                Text("Reseta \(r.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

extension Notification.Name {
    /// Pede ao modal (RootView sem foco fixo) para mostrar uma aba.
    static let devStatusOpenTab = Notification.Name("devStatusOpenTab")
}
