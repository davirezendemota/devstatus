import Foundation

/// Tokens por dia (inicio do dia local -> total).
typealias DailyTokens = [Date: Int]
/// Custo diario em USD se o mesmo uso fosse cobrado pela API (precos de tabela).
typealias DailyCost = [Date: Double]

/// Precos da API em USD por 1M de tokens. Escrita de cache = 1,25x a entrada; leitura de cache = 0,1x
/// (exceto Opus 5.5 e Sonnet 5.5, que cobram US$ 0,20). Modelos desconhecidos usam o preco do Opus 5.5.
struct ModelPrice {
    let input: Double, output: Double, cacheRead: Double
    var cacheWrite: Double { input * 1.25 }

    static func forModel(_ m: String) -> ModelPrice {
        switch true {
        case m.contains("fable"), m.contains("mythos"): return .init(input: 10, output: 50, cacheRead: 1)
        case m.contains("opus-5-5"): return .init(input: 4, output: 20, cacheRead: 0.2)
        case m.contains("opus-4-1"), m.contains("opus-4-0"), m == "claude-opus-4": return .init(input: 15, output: 75, cacheRead: 1.5)
        case m.contains("opus"): return .init(input: 5, output: 25, cacheRead: 0.5)
        case m.contains("sonnet-5"): return .init(input: 2, output: 10, cacheRead: 0.2)
        case m.contains("sonnet"): return .init(input: 3, output: 15, cacheRead: 0.3)
        case m.contains("haiku-5"): return .init(input: 0.1, output: 0.5, cacheRead: 0.01)
        case m.contains("haiku-4"): return .init(input: 1, output: 5, cacheRead: 0.1)
        case m.contains("haiku"): return .init(input: 0.8, output: 4, cacheRead: 0.08)
        default: return .init(input: 4, output: 20, cacheRead: 0.2)
        }
    }
}

/// Le o uso de tokens dos logs locais do Claude Code (<configDir>/projects/**/*.jsonl).
/// Total = input + output + cache creation + cache read, como o ccusage.
/// So le arquivos; nada sai da maquina.
actor TokenScanner {
    static let shared = TokenScanner()
    static let days = 95

    /// `key` e um hash (FNV-1a) de mensagem + requisicao, so para deduplicar; `day` em segundos desde 1970.
    private struct Entry: Codable { let key: UInt64; let day: Date; let tokens: Int; let cost: Double }
    private struct Cached: Codable { let mtime: Date; let size: Int; let entries: [Entry] }
    private var cache: [String: Cached] = [:]
    private var loaded = false

    /// Cache em disco, compartilhado pelo app e pelo CLI (`devstatus ai`): so reprocessa logs novos ou alterados.
    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.devstatus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tokens-v1.json")
    }()
    private static let cacheVersion = 1

    private struct DiskCache: Codable { let version: Int; let files: [String: Cached] }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let disk = try? JSONDecoder().decode(DiskCache.self, from: data),
              disk.version == Self.cacheVersion else { return }
        cache = disk.files
    }

    private func saveCache(keeping used: Set<String>) {
        // Arquivos que sumiram ou sairam da janela de dias nao precisam ficar.
        cache = cache.filter { used.contains($0.key) }
        guard let data = try? JSONEncoder().encode(DiskCache(version: Self.cacheVersion, files: cache)) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// Devolve os tokens diarios por conta (chave = id da assinatura).
    func scan(_ accounts: [(id: String, dir: URL)]) -> (tokens: [String: DailyTokens], costs: [String: DailyCost]) {
        let since = Calendar.current.date(byAdding: .day, value: -Self.days, to: Calendar.current.startOfDay(for: Date()))!
        loadCache()
        let before = cache
        var usedFiles = Set<String>()
        var result: [String: DailyTokens] = [:]
        var costs: [String: DailyCost] = [:]
        for acc in accounts {
            var seen = Set<UInt64>()
            var daily = DailyTokens()
            var cost = DailyCost()
            for file in files(in: acc.dir.appendingPathComponent("projects"), since: since) {
                usedFiles.insert(file.path)
                for e in entries(file) where e.day >= since && seen.insert(e.key).inserted {
                    daily[e.day, default: 0] += e.tokens
                    cost[e.day, default: 0] += e.cost
                }
            }
            result[acc.id] = daily
            costs[acc.id] = cost
        }
        // So grava quando algo mudou (arquivo novo/alterado ou removido).
        let changed = usedFiles != Set(before.keys) || cache.contains { before[$0.key]?.mtime != $0.value.mtime || before[$0.key]?.size != $0.value.size }
        if changed { saveCache(keeping: usedFiles) }
        return (result, costs)
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
                let inp = u["input_tokens"] as? Int ?? 0, out = u["output_tokens"] as? Int ?? 0
                let cw = u["cache_creation_input_tokens"] as? Int ?? 0, cr = u["cache_read_input_tokens"] as? Int ?? 0
                let n = inp + out + cw + cr
                guard n > 0 else { continue }
                let p = ModelPrice.forModel(msg["model"] as? String ?? "")
                let cost = (Double(inp) * p.input + Double(out) * p.output
                            + Double(cw) * p.cacheWrite + Double(cr) * p.cacheRead) / 1e6
                // A mesma resposta aparece em varias linhas; deduplica por mensagem + requisicao.
                let key = Self.hash("\(msg["id"] as? String ?? "")|\(d["requestId"] as? String ?? d["uuid"] as? String ?? "")")
                list.append(Entry(key: key, day: cal.startOfDay(for: date), tokens: n, cost: cost))
            }
        }
        cache[url.path] = Cached(mtime: mtime, size: size, entries: list)
        return list
    }
}

enum Tokens {
    static func usd(_ v: Double) -> String {
        "US$ " + String(format: v >= 100 ? "%.0f" : "%.2f", v).replacingOccurrences(of: ".", with: ",")
    }
    static func cost(_ d: DailyCost, from start: Date) -> Double {
        d.reduce(0) { $1.key >= start ? $0 + $1.value : $0 }
    }
    static func mergeCost(_ all: [DailyCost]) -> DailyCost {
        all.reduce(into: DailyCost()) { acc, d in d.forEach { acc[$0.key, default: 0] += $0.value } }
    }
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
