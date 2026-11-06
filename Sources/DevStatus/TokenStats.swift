import Foundation

/// Tokens por dia (inicio do dia local -> total).
typealias DailyTokens = [Date: Int]

/// Le o uso de tokens dos logs locais do Claude Code (<configDir>/projects/**/*.jsonl).
/// Total = input + output + cache creation + cache read, como o ccusage.
/// So le arquivos; nada sai da maquina.
actor TokenScanner {
    static let shared = TokenScanner()
    static let days = 95

    private struct Entry { let key: String; let day: Date; let tokens: Int }
    private struct Cached { let mtime: Date; let size: Int; let entries: [Entry] }
    private var cache: [String: Cached] = [:]

    /// Devolve os tokens diarios por conta (chave = id da assinatura).
    func scan(_ accounts: [(id: String, dir: URL)]) -> [String: DailyTokens] {
        let since = Calendar.current.date(byAdding: .day, value: -Self.days, to: Calendar.current.startOfDay(for: Date()))!
        var result: [String: DailyTokens] = [:]
        for acc in accounts {
            var seen = Set<String>()
            var daily = DailyTokens()
            for file in files(in: acc.dir.appendingPathComponent("projects"), since: since) {
                for e in entries(file) where e.day >= since && seen.insert(e.key).inserted {
                    daily[e.day, default: 0] += e.tokens
                }
            }
            result[acc.id] = daily
        }
        return result
    }

    private func files(in dir: URL, since: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if let m = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, m >= since { out.append(url) }
        }
        return out
    }

    private func entries(_ url: URL) -> [Entry] {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = vals?.contentModificationDate ?? .distantPast, size = vals?.fileSize ?? 0
        if let c = cache[url.path], c.mtime == mtime, c.size == size { return c.entries }

        var list: [Entry] = []
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let marker = Data("\"usage\"".utf8)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cal = Calendar.current
            for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
                guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      d["type"] as? String == "assistant",
                      let msg = d["message"] as? [String: Any],
                      let u = msg["usage"] as? [String: Any],
                      let ts = d["timestamp"] as? String,
                      let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else { continue }
                let n = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + (u[$1] as? Int ?? 0) }
                guard n > 0 else { continue }
                // A mesma resposta aparece em varias linhas; deduplica por mensagem + requisicao.
                let key = "\(msg["id"] as? String ?? "")|\(d["requestId"] as? String ?? d["uuid"] as? String ?? "")"
                list.append(Entry(key: key, day: cal.startOfDay(for: date), tokens: n))
            }
        }
        cache[url.path] = Cached(mtime: mtime, size: size, entries: list)
        return list
    }
}

enum Tokens {
    static func sum(_ d: DailyTokens, from start: Date) -> Int {
        d.reduce(0) { $1.key >= start ? $0 + $1.value : $0 }
    }
    static func month(_ d: DailyTokens) -> Int {
        let cal = Calendar.current
        return sum(d, from: cal.dateInterval(of: .month, for: Date())!.start)
    }
    static func week(_ d: DailyTokens) -> Int {
        let cal = Calendar.current
        return sum(d, from: cal.dateInterval(of: .weekOfYear, for: Date())!.start)
    }
    static func merge(_ all: [DailyTokens]) -> DailyTokens {
        all.reduce(into: DailyTokens()) { acc, d in d.forEach { acc[$0.key, default: 0] += $0.value } }
    }
    /// 1234 -> "1,2 mil"; 3_400_000 -> "3,4 mi"; 2_100_000_000 -> "2,1 bi".
    static func format(_ n: Int) -> String {
        let v = Double(n)
        func f(_ x: Double, _ s: String) -> String {
            (x >= 100 ? String(format: "%.0f", x) : String(format: "%.1f", x)).replacingOccurrences(of: ".", with: ",") + " " + s
        }
        if v >= 1e9 { return f(v / 1e9, "bi") }
        if v >= 1e6 { return f(v / 1e6, "mi") }
        if v >= 1e3 { return f(v / 1e3, "mil") }
        return "\(n)"
    }
}
