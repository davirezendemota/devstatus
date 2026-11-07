import Foundation
import Darwin

/// Modo terminal do DevStatus: o mesmo binario do app, sem abrir interface.
/// `devstatus` (Geral), `devstatus ai`, `devstatus docker`, `devstatus agent`, `devstatus install`.
/// So le o que o app ja le (Keychain, logs locais, APIs de uso, docker CLI); nada novo sai da maquina.
enum CLI {
    private static let commands: Set<String> = ["status", "ai", "docker", "agent", "install", "uninstall", "help", "version"]
    private static let flags: Set<String> = ["-h", "--help", "-v", "--version"]

    /// O app aberto pelo Finder/Spotlight nao recebe subcomando; so o terminal recebe.
    static func wants(_ args: [String]) -> Bool {
        guard let first = args.dropFirst().first else { return false }
        return commands.contains(first) || flags.contains(first)
    }

    static func main() -> Never {
        let args = Array(CommandLine.arguments.dropFirst())
        Task {
            let code = await run(args)
            exit(code)
        }
        dispatchMain()
    }

    private static func run(_ args: [String]) async -> Int32 {
        let rest = Array(args.dropFirst())
        switch args.first ?? "status" {
        case "status": return await status()
        case "ai": return await ai()
        case "docker": return await docker()
        case "agent": return await agent(rest)
        case "install": return CLIInstaller.report(CLIInstaller.install())
        case "uninstall": return CLIInstaller.report(CLIInstaller.uninstall())
        case "version", "-v", "--version":
            print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            return 0
        default: return help()
        }
    }

    private static func help() -> Int32 {
        print("""
        \(T.bold("devstatus")) — status do DevStatus no terminal

          devstatus            resumo (AI + Docker), igual à aba Geral
          devstatus ai         uso de cada assinatura: limites, resets e tokens
          devstatus docker     armazenamento do Docker
          devstatus agent      abre o Claude Code/Cursor na assinatura com mais folga
              --dry            só mostra o ranking, sem abrir
              (o resto vai para o CLI; ex.: devstatus agent -c)
          devstatus install    instala o comando `devstatus` em ~/.local/bin
          devstatus uninstall  remove o comando
        """)
        return 0
    }

    // MARK: Geral

    private static func status() async -> Int32 {
        async let subs = loadSubscriptions()
        async let docker = DockerCLI.usage()
        let list = await subs

        print(T.bold("AI"))
        if list.isEmpty { print(T.dim("  Nenhuma assinatura. Adicione no app, em AI › Ajustes de AI.")) }
        for (i, sub) in list.enumerated() {
            let title = pad(sub.title, 38)
            if let p = sub.headlinePercent {
                print("  \(i + 1)  \(title) \(T.bar(p, width: 20)) \(T.pct(p))")
            } else {
                print("  \(i + 1)  \(title) \(T.dim(stateText(sub.state)))")
            }
        }

        print("\n" + T.bold("Docker"))
        switch await docker {
        case .loading: break
        case .unavailable(let m): print("  " + T.yellow(m))
        case .ok(let rows):
            let size = rows.reduce(0) { $0 + $1.sizeBytes }, rec = rows.reduce(0) { $0 + $1.reclaimableBytes }
            print("  \(T.bold(DockerCLI.format(size))) em uso · \(T.yellow(DockerCLI.format(rec))) recuperável")
            for r in rows where r.type == "Images" || r.type == "Build Cache" {
                print("  \(pad(r.type == "Images" ? "Imagens" : "Build cache", 14)) \(DockerCLI.format(r.sizeBytes))")
            }
        }
        print("\n" + T.dim("devstatus ai · devstatus agent · devstatus help"))
        return 0
    }

    // MARK: AI

    private static func ai() async -> Int32 {
        // Descoberta e local; consulta de uso (rede) e leitura dos logs andam juntas.
        let discovered = SubscriptionLoader.discover()
        let accounts = discovered.compactMap { sub -> (id: String, dir: URL)? in
            if case .claudeCode(let acc) = sub.source { return (sub.id, acc.configDir) }
            return nil
        }
        async let scanTask = TokenScanner.shared.scan(accounts)
        let list = await fetchAll(discovered)
        let scan = await scanTask
        if list.isEmpty {
            print("Nenhuma assinatura. Adicione no app, em AI › Ajustes de AI.")
            return 0
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let monthStart = cal.dateInterval(of: .month, for: Date())!.start

        for (i, sub) in list.enumerated() {
            var head = "\(T.bold("\(i + 1)  \(sub.title)"))"
            if case .ok(let u) = sub.state, let plan = u.plan { head += T.dim("  · \(plan)") }
            print(head)
            switch sub.state {
            case .ok(let u):
                for m in u.metrics {
                    let label = pad(m.title, 24)
                    if let p = m.percent {
                        print("   \(label) \(T.bar(p, width: 24)) \(T.pct(p))  \(T.dim(resetText(m.resetsAt)))")
                    } else {
                        print("   \(label) \(m.detail ?? "—")  \(T.dim(resetText(m.resetsAt)))")
                    }
                }
                if let c = u.apiCostUSD { print("   \(pad("Custo da API", 24)) \(Tokens.usd(c)) no ciclo") }
            default:
                print("   " + T.yellow(stateText(sub.state)) + (Relogin.needsLogin(sub) ? T.dim("  — relogue com: \(Relogin.command(for: sub) ?? "")") : ""))
            }
            if let daily = scan.tokens[sub.id], let cost = scan.costs[sub.id] {
                print("   " + T.dim("Tokens: hoje \(Tokens.format(Tokens.sum(daily, from: today))) · semana \(Tokens.format(Tokens.week(daily))) · mês \(Tokens.format(Tokens.month(daily))) (≈ \(Tokens.usd(Tokens.cost(cost, from: monthStart))) a preços de API)"))
            }
            print("")
        }
        return 0
    }

    // MARK: Docker

    private static func docker() async -> Int32 {
        switch await DockerCLI.usage() {
        case .loading: return 0
        case .unavailable(let m):
            print(T.yellow(m))
            return 1
        case .ok(let rows):
            for r in rows {
                print("\(pad(r.type, 14)) \(pad("\(r.active)/\(r.count)", 8)) \(pad(DockerCLI.format(r.sizeBytes), 10)) \(T.dim("recuperável " + DockerCLI.format(r.reclaimableBytes)))")
            }
            return 0
        }
    }

    // MARK: Agent

    /// Escolhe a assinatura com mais folga (ver `Subscription.availability`) e abre o CLI dela.
    private static func agent(_ args: [String]) async -> Int32 {
        let dry = args.contains("--dry")
        let forward = args.filter { $0 != "--dry" }
        let list = await loadSubscriptions()

        struct Candidate { let number: Int; let sub: Subscription; let avail: Availability? }
        let all = list.enumerated().map { Candidate(number: $0.offset + 1, sub: $0.element, avail: $0.element.availability) }
        // Quem tem CLI para abrir e dado de uso, da melhor para a pior.
        let ranked = all.filter { $0.avail != nil }.sorted { $0.avail!.score > $1.avail!.score }

        if all.isEmpty {
            err("Nenhuma assinatura. Adicione no app, em AI › Ajustes de AI.")
            return 1
        }
        for c in ranked {
            let a = c.avail!
            let launch = Launcher(for: c.sub) == nil ? T.dim("  (sem CLI: só cookie)") : ""
            print("  \(c.number)  \(pad(c.sub.title, 38)) \(T.bar(100 - a.headroom, width: 16)) \(pad(String(format: "%.0f%% livre", a.headroom), 10)) \(T.dim(resetText(a.resetsAt)))\(launch)")
        }
        for c in all where c.avail == nil {
            print("  \(c.number)  \(pad(c.sub.title, 38)) \(T.dim(stateText(c.sub.state)))")
        }

        guard let best = ranked.first(where: { Launcher(for: $0.sub) != nil }), let launcher = Launcher(for: best.sub) else {
            err("\nNenhuma assinatura disponível com CLI para abrir.")
            return 1
        }
        let a = best.avail!
        if a.exhausted {
            err("\n" + T.yellow("Todas as assinaturas estão no limite.") + " A que reseta antes: \(best.sub.title) \(resetText(a.resetsAt)).")
            return 1
        }
        print("\n→ \(T.bold(best.sub.title)): \(Int(a.headroom.rounded()))% livre, \(resetText(a.resetsAt))")
        if dry { return 0 }
        return launcher.exec(forward)
    }

    /// Como abrir o CLI da assinatura (cookies nao tem CLI).
    private struct Launcher {
        let binaries: [String]
        let configDir: String?   // CLAUDE_CONFIG_DIR; nil = conta padrao (variavel removida)
        let isClaude: Bool

        init?(for sub: Subscription) {
            switch sub.source {
            case .cookie: return nil
            case .cursorAgent: binaries = ["agent", "cursor-agent"]; configDir = nil; isClaude = false
            case .claudeCode(let acc): binaries = ["claude"]; configDir = acc.isDefault ? nil : acc.configDir.path; isClaude = true
            }
        }

        /// Troca este processo pelo CLI (como `exec`), mantendo o terminal e o diretorio atuais.
        func exec(_ args: [String]) -> Int32 {
            var path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            path.append(NSHomeDirectory() + "/.local/bin")
            guard let bin = binaries.lazy.compactMap({ name in
                path.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
            }).first else {
                CLI.err("\(binaries[0]) não encontrado no PATH.")
                return 127
            }
            if isClaude {
                if let configDir { setenv("CLAUDE_CONFIG_DIR", configDir, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
            }
            let argv = ([bin] + args).map { strdup($0) } + [nil]
            execv(bin, argv)
            CLI.err("Não consegui abrir \(bin): \(String(cString: strerror(errno)))")
            return 126
        }
    }

    // MARK: Utilidades

    private static func loadSubscriptions() async -> [Subscription] {
        await fetchAll(SubscriptionLoader.discover())
    }

    private static func fetchAll(_ found: [Subscription]) async -> [Subscription] {
        var subs = found
        await withTaskGroup(of: (Int, UsageState).self) { group in
            for (i, sub) in subs.enumerated() {
                group.addTask { (i, await SubscriptionLoader.fetch(sub)) }
            }
            for await (i, state) in group { subs[i].state = state }
        }
        return subs
    }

    private static func stateText(_ s: UsageState) -> String {
        switch s {
        case .loading: return "carregando…"
        case .expired: return "token expirado"
        case .noCredentials: return "sem login"
        case .error(let m): return "erro: \(m)"
        case .ok: return ""
        }
    }

    /// "reseta em 2h13", "reseta em 3d 4h".
    static func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "reseta agora" }
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return "reseta em \(d)d \(h)h" }
        if h > 0 { return "reseta em \(h)h\(String(format: "%02d", m))" }
        return "reseta em \(m)min"
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - s.count)
    }

    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}

/// Cores ANSI so quando a saida e um terminal (e NO_COLOR nao esta definido).
enum T {
    static let color = isatty(1) == 1 && getenv("NO_COLOR") == nil
    private static func wrap(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { wrap("1", s) }
    static func dim(_ s: String) -> String { wrap("2", s) }
    static func yellow(_ s: String) -> String { wrap("33", s) }

    static func tint(_ p: Double, _ s: String) -> String { wrap(p >= 90 ? "31" : p >= 70 ? "33" : "32", s) }
    static func pct(_ p: Double) -> String { tint(p, String(format: "%3d%%", Int(p.rounded()))) }
    static func bar(_ p: Double, width: Int) -> String {
        let filled = Int((min(max(p, 0), 100) / 100 * Double(width)).rounded())
        return tint(p, String(repeating: "█", count: filled)) + wrap("2", String(repeating: "░", count: width - filled))
    }
}

/// Instala/remove o comando `devstatus` em ~/.local/bin (sem sudo). E um script que chama o binario do app,
/// para o macOS tratar a execucao como o DevStatus (e nao como um link solto).
enum CLIInstaller {
    static var target: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/devstatus") }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: target.path) }

    static func install() -> Result<String, AddError> {
        let app = Bundle.main.bundlePath
        guard app.hasSuffix(".app") else { return .failure(AddError(message: "Rode de dentro do DevStatus.app (DevStatus.app/Contents/MacOS/DevStatus install).")) }
        let quoted = "'" + app.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        # Gerado pelo DevStatus (devstatus install). Chama o app em modo terminal.
        for app in \(quoted) "/Applications/DevStatus.app" "$HOME/Applications/DevStatus.app"; do
          bin="$app/Contents/MacOS/DevStatus"
          if [ -x "$bin" ]; then
            [ $# -eq 0 ] && set -- status
            exec "$bin" "$@"
          fi
        done
        echo "DevStatus.app não encontrado. Rode 'devstatus install' de dentro do app de novo." >&2
        exit 127

        """
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        } catch {
            return .failure(AddError(message: "Não consegui gravar \(target.path): \(error.localizedDescription)"))
        }
        let dir = target.deletingLastPathComponent().path
        let inPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { String($0) == dir }
        return .success("Instalado em \(target.path)." + (inPath ? "" : " Adicione ~/.local/bin ao PATH (export PATH=\"$HOME/.local/bin:$PATH\")."))
    }

    static func uninstall() -> Result<String, AddError> {
        guard isInstalled else { return .success("O comando não estava instalado.") }
        do { try FileManager.default.removeItem(at: target) } catch {
            return .failure(AddError(message: "Não consegui remover \(target.path): \(error.localizedDescription)"))
        }
        return .success("Removido \(target.path).")
    }

    static func report(_ r: Result<String, AddError>) -> Int32 {
        switch r {
        case .success(let m): print(m); return 0
        case .failure(let e): CLI.err(e.message); return 1
        }
    }
}
