import SwiftUI

struct AddError: Error { let message: String }

@MainActor
final class Store: ObservableObject {
    @Published var subs: [Subscription] = []
    @Published var lastUpdate: Date?
    /// Tokens diarios por assinatura (so contas do Claude Code, via logs locais).
    @Published var tokens: [String: DailyTokens] = [:]
    private var timer: Timer?

    private var interval: Double = 0

    init() {
        reload()
        setInterval(Stat.ai.interval)
    }

    func setInterval(_ seconds: Double) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Redescobre as assinaturas (Claude Code automatico + cookies de Ajustes) e atualiza.
    private let addedKey = "claudeCodePaths"

    private var addedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: addedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: addedKey) }
    }

    /// Contas do Claude Code encontradas na maquina que ainda nao foram adicionadas.
    var detectedClaudeAccounts: [ClaudeAccount] {
        ClaudeAccount.discover().filter { !addedPaths.contains($0.id) }
    }

    private let cursorKey = "cursorAgentAdded"
    private var cursorAdded: Bool {
        get { UserDefaults.standard.bool(forKey: cursorKey) }
        set { UserDefaults.standard.set(newValue, forKey: cursorKey) }
    }

    /// Cursor identificado nesta maquina (cursor-agent logado) e ainda nao adicionado.
    var detectedCursorEmail: String? { cursorAdded ? nil : CursorAgent.info()?.email }

    func addCursorAgent() { cursorAdded = true; reload() }

    func addClaudeAccount(_ acc: ClaudeAccount) {
        if !addedPaths.contains(acc.id) { addedPaths.append(acc.id) }
        reload()
    }

    /// Remove qualquer assinatura da lista. Cookie: apaga do Keychain. Claude Code: so tira da lista.
    func remove(_ sub: Subscription) {
        switch sub.source {
        case .cookie(let e): removeCookie(e.id)
        case .claudeCode(let acc):
            addedPaths.removeAll { $0 == acc.id }
            reload()
        case .cursorAgent:
            cursorAdded = false
            reload()
        }
    }

    func reload() {
        let added = Set(addedPaths)
        let auto = ClaudeAccount.discover().filter { added.contains($0.id) }.map { acc -> Subscription in
            let dir = acc.configDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return Subscription(id: acc.id, provider: .claude, title: "Claude (\(acc.label))",
                                subtitle: "Claude Code · \(dir)", source: .claudeCode(acc))
        }
        var cursor: [Subscription] = []
        if cursorAdded, let info = CursorAgent.info() {
            cursor = [Subscription(id: "cursor-agent", provider: .cursor, title: "Cursor (\(info.email))",
                                   subtitle: "cursor-agent", source: .cursorAgent(email: info.email))]
        }
        let web = CookieStore.entries().map { e in
            // Nome dado pelo usuario entre parenteses; sem nome, so o provider.
            Subscription(id: e.id, provider: e.provider,
                         title: e.name == e.provider.name ? e.provider.name : "\(e.provider.name) (\(e.name))",
                         subtitle: "via cookie do site", source: .cookie(e))
        }
        subs = Self.applyOrder(auto + cursor + web)
        refresh()
    }

    func refresh() {
        refreshTokens()
        for sub in subs {
            Task {
                let state: UsageState
                switch sub.source {
                case .claudeCode(let acc): state = await ClaudeService.fetch(acc)
                case .cursorAgent: state = await CursorAgent.fetch()
                case .cookie(let entry): state = await WebServices.fetch(entry)
                }
                if let i = subs.firstIndex(where: { $0.id == sub.id }) { subs[i].state = state }
                lastUpdate = Date()
            }
        }
    }

    private func refreshTokens() {
        let accounts = subs.compactMap { sub -> (id: String, dir: URL)? in
            if case .claudeCode(let acc) = sub.source { return (sub.id, acc.configDir) }
            return nil
        }
        Task {
            let result = await TokenScanner.shared.scan(accounts)
            tokens = result
        }
    }

    /// Adiciona uma assinatura a partir do cookie colado. Devolve o provider detectado ou o erro.
    func addCookie(_ raw: String, name: String) -> Result<Provider, AddError> {
        guard let found = CookieDetector.detect(raw) else {
            return .failure(AddError(message: "Não reconheci o site. Cole o cookie de claude.ai (sessionKey) ou de cursor.com (WorkosCursorSessionToken)."))
        }
        let id = UUID().uuidString
        guard CookieStore.setCookie(found.header, for: id) else { return .failure(AddError(message: "Não consegui gravar no Keychain.")) }
        let n = name.trimmingCharacters(in: .whitespaces)
        var list = CookieStore.entries()
        list.append(WebEntry(id: id, provider: found.provider, name: n.isEmpty ? found.provider.name : n))
        CookieStore.saveEntries(list)
        reload()
        return .success(found.provider)
    }

    func removeCookie(_ id: String) {
        CookieStore.deleteCookie(for: id)
        CookieStore.saveEntries(CookieStore.entries().filter { $0.id != id })
        reload()
    }

    /// Texto da barra de menu: maior % entre todas as assinaturas.
    var menuTitle: String {
        guard let worst = subs.compactMap(\.worstPercent).max() else { return "" }
        return "\(Int(worst.rounded()))%"
    }
}

extension Store {
    /// Ordem escolhida pelo usuario (ids). Define o numero fixo de cada assinatura.
    private static let orderKey = "subscriptionOrder"

    static func applyOrder(_ list: [Subscription]) -> [Subscription] {
        let order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        // Ordenadas pela posicao salva; as novas vao para o fim, na ordem de descoberta.
        let sorted = list.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.id) ?? Int.max
            let ib = order.firstIndex(of: b.element.id) ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
        UserDefaults.standard.set(sorted.map(\.id), forKey: orderKey)
        return sorted
    }

    /// Move a assinatura uma posicao (-1 sobe, +1 desce) e renumera.
    func move(_ sub: Subscription, by delta: Int) {
        guard let i = subs.firstIndex(where: { $0.id == sub.id }) else { return }
        let j = i + delta
        guard subs.indices.contains(j) else { return }
        subs.swapAt(i, j)
        UserDefaults.standard.set(subs.map(\.id), forKey: Self.orderKey)
    }

    /// Assinaturas da mais disponivel para a menos (menor % de uso primeiro; sem dado por ultimo).
    /// `number` e o identificador fixo (posicao na lista, igual aos cards da aba AI) e nao muda com a ordem.
    var subsByAvailability: [(number: Int, sub: Subscription)] {
        subs.enumerated().map { (number: $0.offset + 1, sub: $0.element) }
            .sorted { a, b in
                switch (a.sub.worstPercent, b.sub.worstPercent) {
                case let (x?, y?): return x != y ? x < y : a.number < b.number
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.number < b.number
                }
            }
    }
}
