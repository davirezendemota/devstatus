import Foundation

/// Esconde e restaura o Dock do macOS quando o DevStatus substitui o Dock.
/// Esconder = autohide ligado com atraso enorme (o Dock nunca aparece). Os valores originais
/// ficam salvos e voltam ao desligar a opcao ou sair do app.
/// Restaurar a mao: `defaults write com.apple.dock autohide -bool false;
/// defaults delete com.apple.dock autohide-delay; killall Dock`.
enum NativeDock {
    private static let domain = "com.apple.dock" as CFString
    private static let savedKey = "nativeDockSaved"

    static var isHiddenByUs: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    static func hide() {
        guard !isHiddenByUs else { return }
        var saved: [String: Any] = ["autohide": get("autohide") as? Bool ?? false]
        if let delay = get("autohide-delay") { saved["delay"] = delay }
        UserDefaults.standard.set(saved, forKey: savedKey)
        set("autohide", true as CFPropertyList)
        set("autohide-delay", 1000.0 as CFPropertyList)
        restartDock()
    }

    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        set("autohide", (saved["autohide"] as? Bool ?? false) as CFPropertyList)
        set("autohide-delay", saved["delay"] as CFPropertyList?)   // nil apaga a chave
        UserDefaults.standard.removeObject(forKey: savedKey)
        restartDock()
    }

    /// Caminhos dos apps fixos no Dock do macOS (para importar na primeira vez).
    static func pinnedAppPaths() -> [String] {
        guard let items = get("persistent-apps") as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let tile = item["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let s = file["_CFURLString"] as? String, let url = URL(string: s), url.isFileURL else { return nil }
            return url.standardizedFileURL.path
        }
    }

    private static func get(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static func set(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, domain)
        CFPreferencesAppSynchronize(domain)
    }

    private static func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}
