import Foundation
import CryptoKit

/// Uma conta do Claude Code, identificada pela pasta de config (CLAUDE_CONFIG_DIR).
struct ClaudeAccount: Identifiable, Hashable {
    let configDir: URL
    var id: String { configDir.path }

    var isDefault: Bool { configDir.path == NSHomeDirectory() + "/.claude" }

    /// O Claude Code guarda as credenciais no Keychain com um sufixo derivado da pasta.
    var keychainService: String {
        if isDefault { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    /// Nome amigavel: e-mail da conta, se achar, senao o nome da pasta.
    var label: String {
        let file = isDefault
            ? URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
            : configDir.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let acc = json["oauthAccount"] as? [String: Any],
           let email = acc["emailAddress"] as? String { return email }
        return configDir.lastPathComponent
    }

    /// Descobre ~/.claude e qualquer ~/.claude-* que tenha credenciais.
    static func discover() -> [ClaudeAccount] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let dirs = names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .map { home.appendingPathComponent($0) }
            .filter { var isDir: ObjCBool = false
                      return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
            .sorted { $0.path < $1.path }
        return dirs.map { ClaudeAccount(configDir: $0) }
    }
}

enum ClaudeService {
    private struct Credentials { let token: String; let expiresAt: Date?; let plan: String? }

    static func fetch(_ account: ClaudeAccount) async -> UsageState {
        guard let creds = readCredentials(service: account.keychainService) else { return .noCredentials }
        if let exp = creds.expiresAt, exp < Date() { return .expired }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.0", forHTTPHeaderField: "User-Agent")
        return await run(req, plan: creds.plan)
    }

    /// Executa a requisicao de uso (mesmo formato no OAuth e no site) e monta as metricas.
    static func run(_ req: URLRequest, plan: String?) async -> UsageState {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .error("resposta invalida") }
            if http.statusCode == 401 || http.statusCode == 403 { return .expired }
            guard http.statusCode == 200 else { return .error("HTTP \(http.statusCode)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .error("JSON invalido") }
            let metrics = [
                metric("Sessão (5h)", json["five_hour"], .session),
                metric("Semana", json["seven_day"], .week),
                metric("Semana · Sonnet", json["seven_day_sonnet"], .weekModel),
                metric("Semana · Opus", json["seven_day_opus"], .weekModel),
            ].compactMap { $0 }
            if metrics.isEmpty { return .error("formato inesperado (campos: \(json.keys.sorted().prefix(8).joined(separator: ", ")))") }
            return .ok(Usage(plan: plan, metrics: metrics))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func metric(_ title: String, _ any: Any?, _ kind: MetricKind) -> Metric? {
        guard let d = any as? [String: Any], let u = Util.num(d["utilization"]) else { return nil }
        return Metric(title: title, percent: u, detail: nil, resetsAt: Util.date(d["resets_at"]), kind: kind)
    }

    /// Le o JSON de credenciais via /usr/bin/security (mesmo caminho que o Claude Code usa).
    private static func readCredentials(service: String) -> Credentials? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let exp = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(token: token, expiresAt: exp, plan: oauth["subscriptionType"] as? String)
    }
}
