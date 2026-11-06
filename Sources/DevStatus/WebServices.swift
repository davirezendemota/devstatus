import Foundation

/// Consulta de uso pelos sites (claude.ai e cursor.com) usando o cookie colado em Ajustes.
/// Endpoints nao documentados; o formato pode mudar.
enum WebServices {
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static func request(_ url: String, cookie: String, referer: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.timeoutInterval = 15
        r.httpShouldHandleCookies = false   // senao o URLSession pode ignorar/sobrescrever o header Cookie
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(referer, forHTTPHeaderField: "Referer")
        return r
    }

    /// Sessao sem armazenamento de cookies, para o header Cookie manual valer como esta.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    /// Diagnostico sem expor valores: nomes dos cookies enviados e tamanho de cada um.
    private static func rejected(_ code: Int, _ cookie: String) -> UsageState {
        let parts = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let sent = parts.map { p -> String in
            let kv = p.split(separator: "=", maxSplits: 1)
            return "\(kv.first ?? "?") (\(kv.count > 1 ? kv[1].count : 0) car.)"
        }.joined(separator: ", ")
        return .error("O site recusou o cookie (HTTP \(code)). Enviados: \(sent). Copie de novo, logado no site.")
    }

    static func fetch(_ entry: WebEntry) async -> UsageState {
        guard let cookie = CookieStore.cookie(for: entry.id) else { return .noCredentials }
        switch entry.provider {
        case .claude: return await claude(cookie)
        case .cursor: return await cursor(cookie)
        }
    }

    // MARK: Claude (claude.ai)
    private static func claude(_ cookie: String) async -> UsageState {
        do {
            let (data, resp) = try await session.data(
                for: request("https://claude.ai/api/organizations", cookie: cookie, referer: "https://claude.ai/"))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return rejected(code, cookie) }
            guard code == 200, let orgs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !orgs.isEmpty else { return .error("HTTP \(code) ao listar organizações") }
            let org = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? orgs[0]
            guard let uuid = org["uuid"] as? String else { return .error("organização sem uuid") }
            let req = request("https://claude.ai/api/organizations/\(uuid)/usage", cookie: cookie, referer: "https://claude.ai/settings/usage")
            return await ClaudeService.run(req, plan: nil)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: Cursor (cursor.com)
    static func cursor(_ cookie: String) async -> UsageState {
        do {
            let (data, resp) = try await session.data(
                for: request("https://cursor.com/api/usage-summary", cookie: cookie, referer: "https://cursor.com/dashboard"))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return rejected(code, cookie) }
            guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .error("HTTP \(code)") }

            let individual = json["individualUsage"] as? [String: Any]
            var metrics: [Metric] = []
            var cents: Double?
            let reset = Util.date(json["billingCycleEnd"])
            let cycleStart = Util.date(json["billingCycleStart"])

            if let plan = individual?["plan"] as? [String: Any] {
                let used = Util.num(plan["used"]), limit = Util.num(plan["limit"])
                let total = Util.num(plan["totalPercentUsed"])
                var pct = total
                if pct == nil, let u = used, let l = limit, l > 0 { pct = u / l * 100 }
                var detail: String?
                cents = Util.num((plan["breakdown"] as? [String: Any])?["total"]) ?? used
                if let b = plan["breakdown"] as? [String: Any], let inc = Util.num(b["included"]), let t = Util.num(b["total"]) {
                    detail = "\(usd(inc)) do plano + \(usd(max(t - inc, 0))) de bônus"
                } else if let u = used, let l = limit {
                    detail = "\(usd(u)) de \(usd(l))"
                }
                metrics.append(Metric(title: "Plano (total)", percent: pct, detail: detail, resetsAt: reset,
                                      kind: .plan, periodStart: cycleStart))
                if let auto = Util.num(plan["autoPercentUsed"]) {
                    metrics.append(Metric(title: "Auto + Composer", percent: auto, detail: nil, resetsAt: nil,
                                          kind: .composer))
                }
                if let api = Util.num(plan["apiPercentUsed"]) {
                    metrics.append(Metric(title: "Modelos nomeados (API)", percent: api, detail: nil, resetsAt: nil,
                                          kind: .thirdParty))
                }
            }
            if let od = individual?["onDemand"] as? [String: Any], let used = Util.num(od["used"]) {
                let limit = Util.num(od["limit"])
                cents = (cents ?? 0) + used
                let pct = (limit ?? 0) > 0 ? used / limit! * 100 : nil
                let detail = limit.map { "\(usd(used)) de \(usd($0))" } ?? "\(usd(used)) (sem limite)"
                metrics.append(Metric(title: "On-demand", percent: pct, detail: detail, resetsAt: nil, kind: .onDemand))
            }
            if metrics.isEmpty {
                return .error("formato inesperado (campos: \(json.keys.sorted().prefix(8).joined(separator: ", ")))")
            }
            return .ok(Usage(plan: json["membershipType"] as? String, metrics: metrics, apiCostUSD: cents.map { $0 / 100 }))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// A API devolve centavos.
    private static func usd(_ cents: Double) -> String { String(format: "$%.2f", cents / 100) }
}
