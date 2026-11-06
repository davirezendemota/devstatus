import AppKit

/// Abre um terminal rodando o CLI de cada assinatura deslogada (claude, claude com CLAUDE_CONFIG_DIR, agent)
/// para o usuario relogar. Nao toca em tokens: so executa os CLIs.
enum Relogin {
    /// Comando de shell que abre o CLI da assinatura; nil para cookies (nao ha CLI).
    static func command(for sub: Subscription) -> String? {
        switch sub.source {
        case .cookie: return nil
        case .cursorAgent: return "agent login"
        case .claudeCode(let acc):
            return acc.isDefault ? "claude" : "CLAUDE_CONFIG_DIR=\(quote(acc.configDir.path)) claude"
        }
    }

    static func needsLogin(_ sub: Subscription) -> Bool {
        switch sub.state {
        case .expired, .noCredentials: return command(for: sub) != nil
        default: return false
        }
    }

    /// Roda os comandos em sequencia num unico Terminal (um .command temporario).
    static func run(_ subs: [Subscription]) {
        let cmds = subs.compactMap(command(for:))
        guard !cmds.isEmpty else { return }
        var script = "#!/bin/zsh -l\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
        for c in cmds {
            script += "echo; echo \"▶ \(c)\"\n\(c)\n"
        }
        script += "echo; echo \"Pronto. Pode fechar esta janela.\"\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devstatus-relogin-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: cfg)
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
