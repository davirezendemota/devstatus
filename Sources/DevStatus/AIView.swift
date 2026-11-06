import SwiftUI

/// Aba AI: lista de cards (mapa de tokens + um card por assinatura, numerados).
struct AITab: View {
    @EnvironmentObject var store: Store
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if showSettings {
                    Button { showSettings = false } label: { Label("Assinaturas", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                } else {
                    Text("Assinaturas").font(.subheadline.weight(.semibold))
                    if let t = store.lastUpdate {
                        Text("· atualizado \(t.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !showSettings {
                    Button { showSettings = true } label: { Label("Ajustes de AI", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            if showSettings {
                AISettingsView()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ApiCostCard()
                        HeatmapCard(daily: Tokens.merge(Array(store.tokens.values)))
                        ForEach(Array(store.subs.enumerated()), id: \.element.id) { i, sub in
                            SubscriptionCard(number: i + 1, sub: sub, daily: store.tokens[sub.id])
                        }
                        if store.subs.isEmpty {
                            Button("Adicionar assinatura") { showSettings = true }.controlSize(.small)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear { if store.subs.isEmpty { showSettings = true } }
    }
}

/// Fundo comum dos cards.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

struct NumberBadge: View {
    let number: Int
    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .frame(width: 16, height: 16)
            .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: Custo equivalente na API

struct ApiCostCard: View {
    @EnvironmentObject var store: Store

    private struct Row: Identifiable {
        let id: String, number: Int, sub: Subscription
        let month: Double?, week: Double?, total: Double?
        let cycle: Bool   // Cursor: so existe o valor do ciclo
    }

    private var rows: [Row] {
        let cal = Calendar.current
        let m = cal.dateInterval(of: .month, for: Date())!.start
        let w = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        return store.subs.enumerated().compactMap { i, sub in
            if let c = store.costs[sub.id] {
                return Row(id: sub.id, number: i + 1, sub: sub, month: Tokens.cost(c, from: m),
                           week: Tokens.cost(c, from: w), total: c.values.reduce(0, +), cycle: false)
            }
            if case .ok(let u) = sub.state, let v = u.apiCostUSD {
                return Row(id: sub.id, number: i + 1, sub: sub, month: v, week: nil, total: nil, cycle: true)
            }
            return nil
        }
    }

    var body: some View {
        let rows = rows
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Custo se fosse via API").font(.caption.weight(.semibold))
                Spacer()
                head("mês"); head("semana"); head("3 meses")
            }
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    NumberBadge(number: r.number)
                    ProviderLogo(provider: r.sub.provider).frame(width: 12, height: 12)
                    Text(r.sub.title).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    cell(r.month, note: r.cycle ? "ciclo" : nil); cell(r.week); cell(r.total)
                }
            }
            HStack {
                Text("Total").font(.caption.weight(.semibold))
                Spacer()
                cell(rows.compactMap(\.month).reduce(0, +), bold: true)
                cell(rows.compactMap(\.week).reduce(0, +), bold: true)
                cell(rows.compactMap(\.total).reduce(0, +), bold: true)
            }
            Text("Claude Code: logs locais com preços de tabela da API. Cursor: gasto do ciclo atual informado pelo site.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func head(_ t: String) -> some View {
        Text(t).font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
    }

    private func cell(_ v: Double?, note: String? = nil, bold: Bool = false) -> some View {
        Group {
            if let v {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Tokens.usd(v)).font(.caption.monospacedDigit().weight(bold ? .semibold : .regular))
                    if let note { Text(note).font(.system(size: 8)).foregroundStyle(.secondary) }
                }
            } else { Text("–").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(width: 64, alignment: .trailing)
    }
}

// MARK: Mapa de tokens (estilo contribuicoes do GitHub), ultimos 3 meses

struct HeatmapCard: View {
    let daily: DailyTokens
    private let gap: CGFloat = 2, labelWidth: CGFloat = 24
    @State private var gridWidth: CGFloat = 330

    /// Ultimos 3 meses (o atual por ultimo). Cada mes: 31 posicoes, nil onde o dia nao existe.
    private var months: [(label: String, days: [Date?])] {
        let cal = Calendar.current
        let thisMonth = cal.dateInterval(of: .month, for: Date())!.start
        return (0..<3).reversed().map { back in
            let start = cal.date(byAdding: .month, value: -back, to: thisMonth)!
            let count = cal.range(of: .day, in: .month, for: start)!.count
            let days: [Date?] = (0..<31).map { i in i < count ? cal.date(byAdding: .day, value: i, to: start) : nil }
            return (start.formatted(.dateTime.month(.abbreviated)), days)
        }
    }

    private var maxDay: Int { daily.values.max() ?? 0 }

    private func color(_ day: Date) -> Color {
        if day > Date() { return Color.primary.opacity(0.03) }
        let t = daily[day] ?? 0
        guard t > 0, maxDay > 0 else { return Color.primary.opacity(0.08) }
        // Raiz suaviza dias muito maiores que a media.
        let level = min(4, 1 + Int(3.999 * (Double(t) / Double(maxDay)).squareRoot()))
        return Color.green.opacity([0, 0.3, 0.5, 0.75, 1][level])
    }

    var body: some View {
        Card {
            // Cabecalho com os totais na mesma linha (economiza altura).
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Tokens por dia").font(.caption.weight(.semibold))
                Spacer()
                total("mês", Tokens.month(daily))
                total("semana", Tokens.week(daily))
                total("3 meses", daily.values.reduce(0, +))
            }
            // Uma linha por mes, um quadrado por dia (1 a 31); o tamanho vem da largura disponivel.
            let cell = max(4, (gridWidth - labelWidth - gap * 31) / 31)
            VStack(alignment: .leading, spacing: gap) {
                ForEach(months, id: \.label) { month in
                    HStack(spacing: gap) {
                        Text(month.label).font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        ForEach(0..<31, id: \.self) { i in
                            if let day = month.days[i] {
                                RoundedRectangle(cornerRadius: 2).fill(color(day))
                                    .frame(width: cell, height: cell)
                                    .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(Tokens.format(daily[day] ?? 0)) tokens")
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.onAppear { gridWidth = g.size.width }
                    .onChange(of: g.size.width) { gridWidth = $0 }
            })
            HStack(spacing: 3) {
                Text("Claude Code, logs locais. Cursor não informa tokens.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("menos").font(.system(size: 8)).foregroundStyle(.secondary)
                ForEach([0.08, 0.3, 0.5, 0.75, 1], id: \.self) { o in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(o == 0.08 ? Color.primary.opacity(o) : Color.green.opacity(o))
                        .frame(width: 8, height: 8)
                }
                Text("mais").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
    }

    private func total(_ title: String, _ n: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(Tokens.format(n)).font(.caption.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: Card de assinatura

struct SubscriptionCard: View {
    @EnvironmentObject var store: Store
    let number: Int
    let sub: Subscription
    let daily: DailyTokens?

    var body: some View {
        Card {
            HStack(spacing: 8) {
                NumberBadge(number: number)
                ProviderLogo(provider: sub.provider).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(sub.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(sub.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if case .ok(let u) = sub.state, let plan = u.plan {
                    Text(plan.capitalized).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Button { NSWorkspace.shared.open(sub.provider.usageURL) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Abrir o uso no site (\(sub.provider.usageURL.host ?? ""))")
                Menu {
                    Button("Ver uso no site") { NSWorkspace.shared.open(sub.provider.usageURL) }
                    Button("Remover assinatura", role: .destructive) { store.remove(sub) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }

            switch sub.state {
            case .loading: ProgressView().controlSize(.small)
            case .ok(let u): ForEach(u.metrics) { MetricView(metric: $0) }
            case .expired: note(expiredText, .orange)
            case .noCredentials: note(missingText, .secondary)
            case .error(let msg): note(msg, .red)
            }

            if let d = daily {
                Divider()
                HStack(spacing: 16) {
                    tokenStat("Tokens no mês", Tokens.month(d))
                    tokenStat("Tokens na semana", Tokens.week(d))
                    Spacer()
                }
            }
        }
    }

    private func tokenStat(_ title: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tokens.format(n)).font(.caption.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var expiredText: String {
        switch sub.source {
        case .cookie: return "Cookie expirado. Entre no site, copie o cookie de novo e cole em Ajustes de AI."
        case .cursorAgent: return "Token expirado. Abra o cursor-agent para renovar."
        case .claudeCode: return "Token expirado. Abra o Claude Code nessa conta para renovar."
        }
    }
    private var missingText: String {
        switch sub.source {
        case .cookie: return "Cookie não encontrado no Keychain. Cole de novo em Ajustes de AI."
        case .cursorAgent: return "Sem credenciais. Rode `cursor-agent login`."
        case .claudeCode: return "Sem credenciais no Keychain. Faça /login nessa conta."
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
