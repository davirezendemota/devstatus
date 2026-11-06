import SwiftUI
import AppKit

struct DockerRow: Identifiable {
    var id: String { type }
    let type: String
    let count: Int
    let active: Int
    let sizeBytes: Double
    let reclaimableBytes: Double
}

enum DockerState {
    case loading
    case unavailable(String)
    case ok([DockerRow])
}

enum PruneKind: CaseIterable {
    case buildCache, images, system

    var title: String {
        switch self {
        case .buildCache: return "Limpar build cache"
        case .images: return "Remover imagens sem uso"
        case .system: return "Prune do sistema"
        }
    }
    var args: [String] {
        switch self {
        case .buildCache: return ["builder", "prune", "-a", "-f"]
        case .images: return ["image", "prune", "-a", "-f"]
        case .system: return ["system", "prune", "-f"]
        }
    }
    var warning: String {
        switch self {
        case .buildCache: return "Remove todo o build cache que não está em uso. Os próximos builds ficam mais lentos até o cache ser recriado."
        case .images: return "Remove todas as imagens que nenhum container usa (docker image prune -a). Elas serão baixadas de novo quando precisar."
        case .system: return "Remove containers parados, redes sem uso, imagens dangling e build cache dangling. Volumes não são tocados."
        }
    }
    var command: String { "docker " + args.joined(separator: " ") }
}

@MainActor
final class DockerStore: ObservableObject {
    @Published var state: DockerState = .loading
    @Published var busy: String?
    @Published var result: String?
    @Published var lastUpdate: Date?
    private var timer: Timer?

    private var interval: Double = 0
    private var refreshing = false

    init() {
        refresh()
        setInterval(Stat.docker.interval)
    }

    func setInterval(_ seconds: Double) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var totals: (size: Double, reclaimable: Double)? {
        guard case .ok(let rows) = state else { return nil }
        return (rows.reduce(0) { $0 + $1.sizeBytes }, rows.reduce(0) { $0 + $1.reclaimableBytes })
    }

    func refresh() {
        // `docker system df` pode demorar; nao empilha execucoes.
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            let r = await DockerCLI.run(["system", "df", "--format", "{{json .}}"], timeout: 30)
            guard r.code == 0 else {
                state = .unavailable(DockerCLI.friendly(r))
                return
            }
            let rows: [DockerRow] = r.out.split(separator: "\n").compactMap { line in
                guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                      let type = d["Type"] else { return nil }
                return DockerRow(type: type,
                                 count: Int(d["TotalCount"] ?? "") ?? 0,
                                 active: Int(d["Active"] ?? "") ?? 0,
                                 sizeBytes: DockerCLI.bytes(d["Size"]),
                                 reclaimableBytes: DockerCLI.bytes(d["Reclaimable"]))
            }
            state = .ok(rows)
            lastUpdate = Date()
        }
    }

    /// Pede confirmacao e executa o prune.
    func prune(_ kind: PruneKind) {
        let alert = NSAlert()
        alert.messageText = kind.title + "?"
        alert.informativeText = kind.warning + "\n\n" + kind.command
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Executar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        busy = kind.title
        result = nil
        Task {
            let r = await DockerCLI.run(kind.args, timeout: 600)
            busy = nil
            if r.code == 0 {
                let line = r.out.split(separator: "\n").last { $0.contains("reclaimed") }
                result = line.map(String.init) ?? "Concluído."
            } else {
                result = "Erro: " + DockerCLI.friendly(r)
            }
            refresh()
        }
    }
}

enum DockerCLI {
    struct Output { let code: Int32; let out: String; let err: String }

    /// O app de barra de menu nao herda o PATH do shell, entao procura o binario.
    static let path: String? = [
        "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
        "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ args: [String], timeout: TimeInterval) async -> Output {
        guard let path else { return Output(code: 127, out: "", err: "docker não encontrado") }
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return Output(code: 126, out: "", err: error.localizedDescription) }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            // Le stderr em paralelo para nao travar o pipe.
            var errData = Data()
            let g = DispatchGroup()
            g.enter()
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            g.wait()
            killer.cancel()
            return Output(code: p.terminationStatus,
                          out: String(data: outData, encoding: .utf8) ?? "",
                          err: String(data: errData, encoding: .utf8) ?? "")
        }.value
    }

    static func friendly(_ r: Output) -> String {
        let e = r.err.lowercased()
        if r.code == 127 { return "Docker não encontrado nesta máquina." }
        if e.contains("cannot connect") || e.contains("is the docker daemon running") || e.contains("connection refused") {
            return "Docker não está rodando. Abra o OrbStack/Docker Desktop."
        }
        let first = r.err.split(separator: "\n").first.map(String.init) ?? "falha (código \(r.code))"
        return first
    }

    /// "6.226GB (40%)" -> bytes (decimal, como o docker imprime).
    static func bytes(_ s: String?) -> Double {
        guard let s, let m = s.range(of: #"([0-9.]+)\s*([kKMGT]?B)"#, options: .regularExpression) else { return 0 }
        let part = String(s[m])
        let num = Double(part.prefix { "0123456789.".contains($0) }) ?? 0
        let unit = part.drop { "0123456789. ".contains($0) }.uppercased()
        let mult: Double = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][unit] ?? 1
        return num * mult
    }

    static func format(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .decimal)
    }
}
