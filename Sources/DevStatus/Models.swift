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

// MARK: Disponibilidade (devstatus agent)

/// Quanto da assinatura ainda pode ser usado, combinando a folga e a proximidade do reset.
struct Availability {
    let headroom: Double        // 0-100: o que sobra na metrica mais apertada
    let limiting: Metric        // metrica que limita (sessao, semana, plano...)
    let resetsAt: Date?         // reset dessa metrica
    let score: Double           // maior = melhor escolha agora

    var exhausted: Bool { headroom < 1 }
}

extension Subscription {
    /// Folga minima para a assinatura entrar na disputa principal: abaixo disso ela trava logo no meio do uso.
    static let minHeadroom = 10.0

    /// "Usa ou perde": a folga atual (100 - % usado da metrica mais apertada) dividida pelas horas ate o reset
    /// do limite longo (Claude: semana; Cursor: ciclo do plano). Quanto mais capacidade vai se perder por hora
    /// ate o reset, maior a pontuacao: 24% livres resetando em 1h30 ganham de 58% resetando em 3 dias.
    /// Folga abaixo de `minHeadroom` fica depois das demais (ordenada pela folga); esgotada (< 1% livre)
    /// fica abaixo de todas, e a que reseta antes vem primeiro.
    /// Metricas por modelo e on-demand nao entram (nao limitam o uso geral).
    var availability: Availability? {
        guard case .ok(let u) = state else { return nil }
        let candidates = u.metrics.filter { $0.percent != nil && $0.kind != .weekModel && $0.kind != .onDemand }
        guard let limiting = candidates.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }),
              let percent = limiting.percent else { return nil }
        let headroom = max(0, 100 - percent)
        // Metrica sem reset proprio (Cursor: Auto + Composer) segue o reset do ciclo do plano.
        let reset = limiting.resetsAt ?? u.metrics.first { $0.resetsAt != nil }?.resetsAt
        if headroom < 1 {
            let secs = reset.map { max(0, $0.timeIntervalSinceNow) }
            return Availability(headroom: headroom, limiting: limiting, resetsAt: reset,
                                score: -(secs ?? .greatestFiniteMagnitude) / 3600)
        }
        if headroom < Self.minHeadroom {
            return Availability(headroom: headroom, limiting: limiting, resetsAt: reset, score: headroom)
        }
        // Reset do limite longo: e nele que a folga que sobrar se perde.
        let budget = candidates.first { $0.kind == .week && $0.resetsAt != nil }
            ?? candidates.first { $0.kind == .plan && $0.resetsAt != nil }
        let budgetReset = budget?.resetsAt ?? reset
        let hours = budgetReset.map { max($0.timeIntervalSinceNow / 3600, 1) } ?? 30 * 24
        return Availability(headroom: headroom, limiting: limiting, resetsAt: reset, score: 1000 + headroom / hours)
    }
}
