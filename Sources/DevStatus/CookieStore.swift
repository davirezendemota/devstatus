import Foundation
import Security

/// Cookies colados pelo usuario ficam no Keychain; so os metadados (nome/provider) vao no UserDefaults.
enum CookieStore {
    private static let service = "local.devstatus.cookies"
    private static let defaultsKey = "webEntries"

    static func entries() -> [WebEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([WebEntry].self, from: data) else { return [] }
        return list
    }

    static func saveEntries(_ list: [WebEntry]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    static func cookie(for id: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setCookie(_ value: String, for id: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: id]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteCookie(for id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: id] as CFDictionary)
    }
}

/// Identifica a IA pelo conteudo do cookie colado.
enum CookieDetector {
    struct Result { let provider: Provider; let header: String }

    static func detect(_ raw: String) -> Result? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("cookie:") { s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        s = s.replacingOccurrences(of: "\n", with: "; ").replacingOccurrences(of: "\r", with: "")
        guard !s.isEmpty else { return nil }

        if s.contains("WorkosCursorSessionToken") { return Result(provider: .cursor, header: s) }
        if s.contains("sessionKey=") || s.contains("lastActiveOrg=") { return Result(provider: .claude, header: s) }
        // So o valor do token, sem o nome do cookie.
        if s.hasPrefix("sk-ant-sid") { return Result(provider: .claude, header: "sessionKey=\(s)") }
        if !s.contains("="), s.hasPrefix("user_"), (s.contains("%3A%3A") || s.contains("::")) {
            return Result(provider: .cursor, header: "WorkosCursorSessionToken=\(s)")
        }
        return nil
    }
}
