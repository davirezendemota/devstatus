import SwiftUI
import AppKit

/// Agent rodando num terminal do Herdr (lido de `herdr-core ls --json`).
struct HerdrAgent: Identifiable, Equatable {
    let id: String          // endereco, ex.: t36 ou server/t3
    let kind: String        // claude-code, cursor-agent, codex...
    let status: String      // working, blocked, done, idle, unknown
    let place: String       // workspace, ex.: my-app
    let machine: String?    // nil = esta maquina
    var activity: String? = nil   // o que o agent esta fazendo agora (msg do Herdr)

    /// Ordem da fila: quem precisa de voce primeiro.
    var priority: Int {
        switch status {
        case "blocked": return 0
        case "done": return 1
        case "working": return 2
        case "idle": return 3
        default: return 4
        }
    }

    var color: Color {
        switch status {
        case "blocked": return .orange
        case "done": return .green
        case "working": return .blue
        default: return .gray
        }
    }

    var statusText: String {
        switch status {
        case "blocked": return "esperando você"
        case "done": return "terminou"
        case "working": return "trabalhando"
        case "idle": return "parado"
        default: return status
        }
    }

    var provider: Provider? {
        if kind.hasPrefix("claude") { return .claude }
        if kind.hasPrefix("cursor") { return .cursor }
        return nil
    }
}

/// Fila de agents do Herdr. So le o CLI local (`herdr-core events --json`, primeira linha); nao controla nada.
@MainActor
final class HerdrStore: ObservableObject {
    @Published private(set) var agents: [HerdrAgent] = []
    private var timer: Timer?
    private var running = false

    nonisolated static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "pwsh", "dash", "tcsh", "ksh"]

    static var binary: String? {
        let candidates = [NSHomeDirectory() + "/.local/bin/herdr-core", "/opt/homebrew/bin/herdr-core", "/usr/local/bin/herdr-core"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func setPolling(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on, Self.binary != nil else { agents = []; return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !running, let bin = Self.binary else { return }
        running = true
        Task.detached(priority: .utility) {
            let list = Self.read(bin)
            await MainActor.run {
                self.running = false
                if let list, list != self.agents { self.agents = list }
            }
        }
    }

    /// Traz o Herdr para frente.
    func openHerdr() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.herdr.app") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Le a lista completa (primeira linha de `herdr-core events --json`), que traz o rotulo `herdr.seen`.
    /// `ls --json` nao traz esse rotulo, e sem ele um agent ja visto continuaria "done".
    nonisolated private static func read(_ bin: String) -> [HerdrAgent]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["events", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        defer { if p.isRunning { p.terminate() } }
        // Se o herdr-core nao responder, encerra (fecha o pipe e destrava a leitura).
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }   // processo terminou
            buffer.append(chunk)
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }
        guard let line = buffer.split(separator: UInt8(ascii: "\n")).first,
              let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let terms = json["terminals"] as? [[String: Any]] else { return nil }
        return terms.compactMap { t in
            guard let address = t["address"] as? String, (t["state"] as? String ?? "live") == "live",
                  let status = t["status"] as? [String: Any], let kind = status["app"] as? String,
                  !shells.contains(kind) else { return nil }
            let labels = t["labels"] as? [String: String] ?? [:]
            var state = status["state"] as? String ?? "unknown"
            // Terminou e voce ja viu no Herdr: nao precisa mais de atencao.
            let turn = t["turn"] as? Int ?? 0
            if state == "done", let seen = Int(labels["herdr.seen"] ?? ""), seen >= turn { state = "idle" }
            let whereText = labels["where"] ?? ""
            let place = whereText.components(separatedBy: " / ").first ?? ""
            let machine = address.contains("/") ? address.components(separatedBy: "/").first : nil
            let msg = (status["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return HerdrAgent(id: address, kind: kind, status: state, place: place.isEmpty ? address : place,
                              machine: machine, activity: msg)
        }
        .sorted { ($0.priority, $0.place) < ($1.priority, $1.place) }
    }
}

/// Card da fila no Dock: um chip por agent (logo + cor do status + workspace), quem precisa de voce primeiro.
struct HerdrQueueView: View {
    @ObservedObject var herdr: HerdrStore
    let size: CGFloat
    private let maxShown = 6

    var body: some View {
        HStack(spacing: 6) {
            ForEach(herdr.agents.prefix(maxShown)) { chip($0) }
            if herdr.agents.count > maxShown {
                Text("+\(herdr.agents.count - maxShown)")
                    .font(.system(size: size * 0.22, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .frame(height: size)
        .contentShape(Rectangle())
        .onTapGesture { herdr.openHerdr() }
        .pointerCursor()
    }

    private func chip(_ a: HerdrAgent) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let p = a.provider {
                        ProviderLogo(provider: p).padding(size * 0.1)
                    } else {
                        Image(systemName: "terminal").font(.system(size: size * 0.3, weight: .semibold))
                    }
                }
                .frame(width: size * 0.62, height: size * 0.62)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                    .stroke(a.color.opacity(a.status == "idle" ? 0.3 : 0.9), lineWidth: 1.5))
                Circle().fill(a.color).frame(width: size * 0.18, height: size * 0.18)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .offset(x: 3, y: 3)
            }
            Text(a.place).font(.system(size: max(8, size * 0.17), weight: .medium))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: size * 0.95)
        }
        .help("\(a.place) · \(a.kind) · \(a.statusText)\(a.machine.map { " · \($0)" } ?? "")\(a.activity.map { "\n\($0)" } ?? "")")
    }
}
