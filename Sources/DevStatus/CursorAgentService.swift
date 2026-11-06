import Foundation

/// Conta do Cursor identificada nesta maquina pelo `cursor-agent` (CLI), sem colar cookie.
/// - e-mail e authId: ~/.cursor/cli-config.json (authInfo)
/// - token de acesso: Keychain, servico `cursor-access-token`
/// O dashboard do Cursor aceita o cookie WorkosCursorSessionToken = "<user_id>::<access token>".
enum CursorAgent {
    struct Info { let email: String; let userID: String }

    static func info() -> Info? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.cursor/cli-config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["authInfo"] as? [String: Any],
              let authId = auth["authId"] as? String else { return nil }
        // authId vem como "google-oauth2|user_01..."; o cookie usa so a parte depois do "|".
        let uid = authId.split(separator: "|").last.map(String.init) ?? authId
        return Info(email: (auth["email"] as? String) ?? "cursor-agent", userID: uid)
    }

    static func fetch() async -> UsageState {
        guard let info = info(), let token = readToken() else { return .noCredentials }
        if let exp = jwtExpiry(token), exp < Date() { return .expired }
        return await WebServices.cursor("WorkosCursorSessionToken=\(info.userID)%3A%3A\(token)")
    }

    private static func readToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "cursor-access-token", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    private static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = Util.num(json["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
