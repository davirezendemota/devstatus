import SwiftUI
import AppKit
import Combine

/// Stats no Dock: cada Stats ligado vira uma janela minimizada com o tile desenhado por nos.
/// Clicar no tile restaura a janela (o app focado na aba); ao perder o foco ela volta para o Dock.
/// Funciona mesmo com "Minimize windows into application icon" ligado: o app nao tem icone no Dock
/// (LSUIElement), entao o Dock mostra a janela minimizada ao lado do Lixo.
@MainActor
final class DockTiles: NSObject, NSWindowDelegate {
    private let store: Store
    private let docker: DockerStore
    private let monitor: MonitorStore
    private let makeRoot: (AppTab) -> AnyView
    private var windows: [Stat: NSWindow] = [:]
    private var images: [Stat: NSImageView] = [:]
    private var bag: Set<AnyCancellable> = []

    init(store: Store, docker: DockerStore, monitor: MonitorStore, makeRoot: @escaping (AppTab) -> AnyView) {
        self.store = store
        self.docker = docker
        self.monitor = monitor
        self.makeRoot = makeRoot
        super.init()
        // Redesenha quando qualquer dado muda (agrupado para nao redesenhar em rajada).
        Publishers.Merge3(store.objectWillChange, docker.objectWillChange, monitor.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &bag)
    }

    /// Cria ou remove os tiles conforme os toggles de Ajustes › Stats.
    func sync() {
        for stat in Stat.allCases {
            if stat.inDock && !DockBar.enabled {
                if windows[stat] == nil { create(stat) }
            } else if let w = windows.removeValue(forKey: stat) {
                images[stat] = nil
                w.delegate = nil
                w.close()
            }
        }
        redraw()
    }

    private func create(_ stat: Stat) {
        let host = NSHostingController(rootView: makeRoot(stat.tab))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .miniaturizable, .fullSizeContentView]
        w.title = "DevStatus · \(stat.rawValue)"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self
        if let screen = NSScreen.main {
            let f = screen.visibleFrame, size = w.frame.size
            w.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - f.height * 0.1))
        }
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        w.dockTile.contentView = iv
        windows[stat] = w
        images[stat] = iv
        // Vai direto para o Dock sem aparecer na tela.
        w.alphaValue = 0
        w.orderFront(nil)
        w.miniaturize(nil)
    }

    private func stat(of window: NSWindow) -> Stat? { windows.first { $0.value === window }?.key }

    func windowDidMiniaturize(_ n: Notification) {
        (n.object as? NSWindow)?.alphaValue = 1
        redraw()
    }

    func windowDidDeminiaturize(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Volta para o Dock ao perder o foco (menos durante alertas, como a confirmacao de prune).
    func windowDidResignKey(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !w.isKeyWindow, !w.isMiniaturized, NSApp.modalWindow == nil, w.attachedSheet == nil,
                  self.stat(of: w) != nil else { return }
            w.miniaturize(nil)
        }
    }

    // MARK: Desenho

    private func redraw() {
        for (stat, w) in windows {
            let view = DockTileView(title: stat.rawValue, icon: stat.icon, rows: rows(stat), vertical: stat.vertical)
                .frame(width: 128, height: 128)
            let r = ImageRenderer(content: view)
            r.scale = 2
            images[stat]?.image = r.nsImage
            w.dockTile.display()
        }
    }

    private func rows(_ stat: Stat) -> [TileRow] { StatRows.rows(stat, store: store, docker: docker, monitor: monitor) }
}

struct TileRow {
    let label: String
    let symbol: Bool
    let fraction: Double
    let color: Color
    let value: String
}

/// Tile do Dock (128x128 pt, sempre quadrado): sem titulo, fundo no tile inteiro, textos e barras grandes.
struct DockTileView: View {
    let title: String
    let icon: String
    let rows: [TileRow]
    let vertical: Bool

    var body: some View {
        Group {
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 40, weight: .semibold))
                    Text("sem dados").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vertical {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(rows.indices, id: \.self) { i in column(rows[i]) }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        line(rows[i]).frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(width: 124, height: 124)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .frame(width: 128, height: 128)
    }

    @ViewBuilder private func label(_ r: TileRow, size: CGFloat) -> some View {
        if r.symbol {
            Image(systemName: r.label).font(.system(size: size, weight: .semibold))
        } else {
            Text(r.label).font(.system(size: size + 2, weight: .heavy).monospacedDigit())
        }
    }

    /// Icone a esquerda; valor grande em cima da barra.
    private func line(_ r: TileRow) -> some View {
        HStack(spacing: 6) {
            label(r, size: 16).frame(width: 20).foregroundStyle(.white.opacity(0.9))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.value).font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(r.color).frame(width: max(7, g.size.width * min(max(r.fraction, 0), 1)))
                    }
                }
                .frame(height: 7)
            }
        }
    }

    /// Valor em cima, barra larga em pe, icone embaixo.
    private func column(_ r: TileRow) -> some View {
        VStack(spacing: 4) {
            Text(r.value).font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.18))
                    RoundedRectangle(cornerRadius: 5).fill(r.color)
                        .frame(height: max(8, g.size.height * min(max(r.fraction, 0), 1)))
                }
            }
            .frame(maxWidth: 20)
            label(r, size: 15).foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Linhas (rotulo, barra, valor) de cada Stats, usadas pelos tiles e pela barra do Dock.
@MainActor
enum StatRows {
    static func rows(_ stat: Stat, store: Store, docker: DockerStore, monitor: MonitorStore) -> [TileRow] {
        switch stat {
        case .ai:
            // Mais disponivel primeiro; o numero continua o da assinatura.
            return store.subsByAvailability.prefix(4).map { number, sub in
                let p = sub.worstPercent
                return TileRow(label: "\(number)", symbol: false, fraction: (p ?? 0) / 100,
                               color: Color(nsColor: sub.provider.nsColor), value: p.map { "\(Int($0.rounded()))%" } ?? "—")
            }
        case .docker:
            guard case .ok(let list) = docker.state else { return [] }
            let total = max(list.reduce(0) { $0 + $1.sizeBytes }, 1)
            return DockerBarsIcon.kinds.map { k in
                let size = list.first { $0.type == k.type }?.sizeBytes ?? 0
                return TileRow(label: k.symbol, symbol: true, fraction: size / total, color: Color(nsColor: k.color),
                               value: DockerCLI.format(size))
            }
        case .monitor:
            let m = monitor.memory
            let mem = m.total > 0 ? m.used / m.total : 0
            let disk = monitor.disks.first { $0.path == "/" }.map { $0.total > 0 ? $0.used / $0.total : 0 } ?? 0
            let temp = monitor.temperature.cpu
            func row(_ s: String, _ f: Double, _ c: NSColor, _ v: String) -> TileRow {
                TileRow(label: s, symbol: true, fraction: f, color: Color(nsColor: f >= 0.9 ? .systemRed : c), value: v)
            }
            return [
                row("cpu", monitor.cpu.usage, .systemBlue, "\(Int((monitor.cpu.usage * 100).rounded()))%"),
                row("memorychip", mem, .systemPurple, "\(Int((mem * 100).rounded()))%"),
                row("internaldrive.fill", disk, .systemTeal, "\(Int((disk * 100).rounded()))%"),
                row("thermometer.medium", (temp ?? 0) / 100, .systemOrange, temp.map { "\(Int($0.rounded()))°" } ?? "—"),
            ]
        }
    }
}
