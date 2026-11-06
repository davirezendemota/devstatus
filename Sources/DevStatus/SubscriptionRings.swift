import SwiftUI
import AppKit

/// Card de AI no Dock, no estilo do widget de baterias: um par de aneis por assinatura.
/// Anel externo: Claude = semana, Cursor = Auto + Composer. Anel interno: Claude = sessao de 5h,
/// Cursor = modelos de terceiros. No centro, o logo vai sendo preenchido de cima para baixo
/// conforme o tempo passa ate o proximo reset (Claude: 5h; Cursor: ciclo mensal).
struct AIRingsView: View {
    @ObservedObject var store: Store
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.14) {
            // Mais disponivel primeiro; o numero e o identificador fixo da assinatura.
            ForEach(store.subsByAvailability, id: \.sub.id) { item in
                SubscriptionRing(number: item.number, sub: item.sub, diameter: size * 0.9)
            }
        }
        .frame(height: size)
    }
}

struct SubscriptionRing: View {
    let number: Int
    let sub: Subscription
    let diameter: CGFloat

    private var line: CGFloat { max(3, diameter * 0.085) }
    private var gap: CGFloat { max(1.5, diameter * 0.03) }

    var body: some View {
        ZStack {
            ring(sub.outerRing?.percent, width: line)
                .frame(width: diameter - line, height: diameter - line)
            if sub.innerRing != nil {
                ring(sub.innerRing?.percent, width: line * 0.85)
                    .frame(width: diameter - line * 3 - gap * 2, height: diameter - line * 3 - gap * 2)
            }
            LogoFill(provider: sub.provider, progress: sub.resetProgress)
                .frame(width: diameter * 0.34, height: diameter * 0.34)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        // Clique abre a pagina de uso da IA no navegador (tem prioridade sobre o clique do widget).
        .onTapGesture { NSWorkspace.shared.open(sub.provider.usageURL) }
        .pointerCursor()
        .overlay(alignment: .topLeading) {
            Text("\(number)")
                .font(.system(size: max(7, diameter * 0.17), weight: .heavy).monospacedDigit())
                .padding(.horizontal, 2.5)
                .background(Capsule().fill(.black.opacity(0.55)))
                .foregroundStyle(.white)
                .offset(x: -2, y: -2)
        }
        .help(tooltip)
    }

    private func color(_ p: Double?) -> Color {
        guard let p else { return .gray }
        return p >= 90 ? .red : p >= 70 ? .orange : .green
    }

    private func ring(_ percent: Double?, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: width)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent ?? 0, 0), 100)) / 100)
                .stroke(color(percent), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    private var tooltip: String {
        var lines = ["\(number) · \(sub.title)", "Clique para abrir o uso em \(sub.provider.usageURL.host ?? "")"]
        func describe(_ m: Metric?, _ label: String) {
            guard let m else { return }
            var t = "\(label): \(m.percent.map { "\(Int($0.rounded()))%" } ?? "—")"
            if let r = m.resetsAt { t += " · reseta \(r.formatted(.relative(presentation: .named)))" }
            lines.append(t)
        }
        switch sub.provider {
        case .claude:
            describe(sub.outerRing, "Semana (anel externo)")
            describe(sub.innerRing, "Sessão 5h (anel interno)")
        case .cursor:
            describe(sub.outerRing, "Auto + Composer (anel externo)")
            describe(sub.innerRing, "Modelos de terceiros (anel interno)")
            if let r = sub.resetMetric?.resetsAt {
                lines.append("Ciclo mensal reseta \(r.formatted(.relative(presentation: .named)))")
            }
        }
        if case .ok = sub.state {} else { lines.append(stateText) }
        return lines.joined(separator: "\n")
    }

    private var stateText: String {
        switch sub.state {
        case .loading: return "carregando…"
        case .expired: return "token expirado"
        case .noCredentials: return "sem login"
        case .error(let m): return "erro: \(m)"
        case .ok: return ""
        }
    }
}

/// Logo estilo relogio: comeca cheio e vai esvaziando no sentido horario a partir das 12h,
/// conforme `progress` (0 = acabou de resetar, 1 = reseta agora).
struct LogoFill: View {
    let provider: Provider
    let progress: Double?

    var body: some View {
        ZStack {
            ProviderLogo(provider: provider).saturation(0).opacity(0.3)
            ProviderLogo(provider: provider)
                .mask { ClockSector(elapsed: progress ?? 0) }
        }
    }
}

/// Setor que sobra do relogio: do ponteiro (12h + fracao passada) ate as 12h, no sentido horario.
struct ClockSector: Shape {
    var elapsed: Double

    func path(in rect: CGRect) -> Path {
        let remaining = 1 - min(max(elapsed, 0), 1)
        var p = Path()
        guard remaining > 0 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = hypot(rect.width, rect.height)   // cobre o logo inteiro
        if remaining >= 1 { p.addRect(rect); return p }
        let start = Angle.degrees(-90 + 360 * (1 - remaining))
        p.move(to: c)
        // Em SwiftUI (y para baixo), clockwise: false desenha no sentido horario na tela.
        p.addArc(center: c, radius: r, startAngle: start, endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
