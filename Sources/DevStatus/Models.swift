import Foundation

enum Provider: String, Codable {
    case claude, cursor
    var name: String { self == .claude ? "Claude" : "Cursor" }
    /// Pagina de uso no site (abre no navegador padrao).
    var usageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .cursor: return URL(string: "https://cursor.com/dashboard?tab=usage")!
        }
    }
}

/// Tipo da metrica, para escolher os aneis sem depender do titulo.
enum MetricKind {
    case session        // Claude: janela de 5 horas
    case week           // Claude: limite semanal
    case weekModel      // Claude: semanal por modelo (Sonnet/Opus)
    case plan           // Cursor: total do plano (ciclo mensal)
    case composer       // Cursor: Auto + Composer
    case thirdParty     // Cursor: modelos de terceiros (API)
    case onDemand       // Cursor: on-demand
    case other
}

struct Metric: Identifiable {
    let id = UUID()
    let title: String
    let percent: Double?     // 0-100, nil se so houver texto
    let detail: String?
    let resetsAt: Date?
    var kind: MetricKind = .other
    var periodStart: Date? = nil   // inicio do ciclo, quando a API informa
}

struct Usage {
    let plan: String?
    let metrics: [Metric]
    var apiCostUSD: Double? = nil   // Cursor: gasto do ciclo a precos de API
}

enum UsageState {
    case loading
    case ok(Usage)
    case expired            // token/cookie expirou
    case noCredentials
    case error(String)
}

/// Assinatura cadastrada pelo usuario via cookie do site.
struct WebEntry: Codable, Identifiable, Hashable {
    let id: String
    let provider: Provider
    var name: String
}

enum Source {
    case claudeCode(ClaudeAccount)   // descoberta automatica (Keychain do Claude Code)
    case cursorAgent(email: String)  // identificado pelo cursor-agent (Keychain)
    case cookie(WebEntry)            // colada em Ajustes
}

struct Subscription: Identifiable {
    let id: String
    let provider: Provider
    let title: String        // texto curto da aba
    let subtitle: String     // e-mail / origem
    let source: Source
    var state: UsageState = .loading

    /// Maior % entre as metricas, usado no icone da barra.
    var worstPercent: Double? {
        guard case .ok(let u) = state else { return nil }
        return u.metrics.compactMap(\.percent).max()
    }
    /// % da primeira metrica (sessao/plano), usado na aba.
    var headlinePercent: Double? {
        guard case .ok(let u) = state else { return nil }
        return u.metrics.first?.percent
    }
}

enum Util {
    static func num(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

// MARK: Aneis da assinatura (Dock)

extension Subscription {
    private var metrics: [Metric] {
        if case .ok(let u) = state { return u.metrics }
        return []
    }
    private func metric(_ kind: MetricKind) -> Metric? { metrics.first { $0.kind == kind } }

    /// Anel externo: Claude = sessao de 5h (senao a semana); Cursor = modelos de terceiros (senao Auto + Composer).
    var outerRing: Metric? {
        switch provider {
        case .claude: return metric(.session) ?? metric(.week) ?? metrics.first
        case .cursor: return metric(.thirdParty) ?? metric(.composer) ?? metric(.plan) ?? metrics.first
        }
    }

    /// Anel interno: Claude = limite semanal; Cursor = Auto + Composer. So existe junto com o externo.
    var innerRing: Metric? {
        switch provider {
        case .claude: return metric(.session) != nil ? metric(.week) : nil
        case .cursor: return metric(.thirdParty) != nil ? (metric(.composer) ?? metric(.plan)) : nil
        }
    }

    /// Metrica que define o "proximo reset" usado no preenchimento do logo.
    var resetMetric: Metric? {
        switch provider {
        case .claude: return metric(.session) ?? metric(.week)
        case .cursor: return metric(.plan)
        }
    }

    /// Fracao do periodo atual ja passada (0 = acabou de resetar, 1 = vai resetar agora).
    /// Claude: janela de 5h (ou 7 dias). Cursor: ciclo mensal (inicio informado ou um mes antes do fim).
    var resetProgress: Double? {
        guard let m = resetMetric, let end = m.resetsAt else { return nil }
        let start: Date
        if let s = m.periodStart {
            start = s
        } else {
            switch m.kind {
            case .session: start = end.addingTimeInterval(-5 * 3600)
            case .week, .weekModel: start = end.addingTimeInterval(-7 * 86400)
            default: start = Calendar.current.date(byAdding: .month, value: -1, to: end) ?? end.addingTimeInterval(-30 * 86400)
            }
        }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return nil }
        return min(max(Date().timeIntervalSince(start) / total, 0), 1)
    }
}
