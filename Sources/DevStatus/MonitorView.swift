import SwiftUI

/// Aba Monitor: grade de cards com CPU, RAM, discos, temperatura, rede e bateria.
struct MonitorView: View {
    @EnvironmentObject var monitor: MonitorStore
    var scrolls = true

    private var cards: [AnyView] {
        [AnyView(cpuCard), AnyView(memoryCard)]
            + monitor.disks.map { AnyView(diskCard($0)) }
            + [AnyView(temperatureCard), AnyView(networkCard), AnyView(batteryCard)]
    }

    private var grid: some View {
        let all = cards
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: all.count, by: 2)), id: \.self) { i in
                GridRow {
                    all[i]
                    if i + 1 < all.count { all[i + 1] } else { Color.clear }
                }
            }
        }
        .padding(12)
    }

    var body: some View {
        Group {
            if scrolls { ScrollView { grid } } else { grid }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    // MARK: Cards

    private var cpuCard: some View {
        let c = monitor.cpu
        return MonitorCard(title: "CPU", icon: "cpu") {
            BigValue(text: pct(c.usage * 100), color: level(c.usage * 100))
            Sparkline(values: monitor.cpuHistory, maxValue: 1).stroke(Color.accentColor, lineWidth: 1.5).frame(height: 26)
            Detail("Usuário \(pct(c.user * 100)) · Sistema \(pct(c.system * 100))")
            Detail("Carga \(String(format: "%.2f %.2f %.2f", c.load.0, c.load.1, c.load.2)) · \(c.cores) núcleos")
        }
    }

    private var memoryCard: some View {
        let m = monitor.memory
        let p = m.total > 0 ? m.used / m.total * 100 : 0
        return MonitorCard(title: "Memória", icon: "memorychip") {
            BigValue(text: "\(mem(m.used)) / \(mem(m.total))", color: level(p))
            MeterBar(percent: p, color: barColor(p))
            Detail("Fixa \(mem(m.wired)) · Comprimida \(mem(m.compressed))")
            Detail("Swap \(mem(m.swapUsed))")
        }
    }

    private func diskCard(_ d: DiskInfo) -> some View {
        let p = d.total > 0 ? d.used / d.total * 100 : 0
        return MonitorCard(title: d.name, icon: d.isInternal ? "internaldrive" : "externaldrive") {
            BigValue(text: "\(disk(d.free)) livres", color: level(p))
            MeterBar(percent: p, color: barColor(p))
            Detail("\(disk(d.used)) de \(disk(d.total)) · \(pct(p)) usado")
            Detail(d.path == "/" ? "Disco do sistema" : d.path).lineLimit(1).truncationMode(.middle)
        }
    }

    private var temperatureCard: some View {
        let t = monitor.temperature
        return MonitorCard(title: "Temperatura", icon: "thermometer.medium") {
            if let cpu = t.cpu {
                BigValue(text: temp(cpu), color: cpu >= 90 ? .red : cpu >= 75 ? .orange : .primary)
            } else {
                BigValue(text: thermalText(t.thermalState), color: thermalColor(t.thermalState))
            }
            if t.cpu != nil { Detail("CPU (média dos núcleos)") }
            Detail([t.ssd.map { "SSD \(temp($0))" }, t.battery.map { "Bateria \(temp($0))" }]
                .compactMap { $0 }.joined(separator: " · "))
            Text("Estado térmico: \(thermalText(t.thermalState))").font(.caption2).foregroundStyle(thermalColor(t.thermalState))
        }
    }

    private var networkCard: some View {
        let n = monitor.network
        let peak = max(monitor.downHistory.max() ?? 0, monitor.upHistory.max() ?? 0, 1)
        return MonitorCard(title: "Rede", icon: "network") {
            HStack(spacing: 10) {
                Label(rate(n.down), systemImage: "arrow.down").foregroundStyle(.blue)
                Label(rate(n.up), systemImage: "arrow.up").foregroundStyle(.green)
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            ZStack {
                Sparkline(values: monitor.downHistory, maxValue: peak).stroke(Color.blue, lineWidth: 1.5)
                Sparkline(values: monitor.upHistory, maxValue: peak).stroke(Color.green, lineWidth: 1.5)
            }
            .frame(height: 26)
            if let i = n.interface { Detail("\(i)\(n.ip.map { " · \($0)" } ?? "")") }
            Detail("Desde o boot: ↓ \(disk(n.totalDown)) ↑ \(disk(n.totalUp))")
        }
    }

    private var batteryCard: some View {
        MonitorCard(title: "Bateria", icon: batteryIcon) {
            if let b = monitor.battery {
                BigValue(text: pct(b.percent), color: b.percent <= 10 ? .red : b.percent <= 20 ? .orange : .primary)
                MeterBar(percent: b.percent, color: b.charging ? .green : b.percent <= 20 ? .orange : .accentColor)
                Detail(batteryStatus(b))
                Detail([b.cycles.map { "\($0) ciclos" }, b.health.map { "saúde \(pct($0))" }]
                    .compactMap { $0 }.joined(separator: " · "))
            } else {
                BigValue(text: "—", color: .secondary)
                Detail("Sem bateria neste Mac.")
            }
        }
    }

    private var batteryIcon: String {
        guard let b = monitor.battery else { return "battery.0" }
        if b.charging { return "battery.100.bolt" }
        return b.percent > 75 ? "battery.100" : b.percent > 50 ? "battery.75" : b.percent > 25 ? "battery.50" : "battery.25"
    }

    private func batteryStatus(_ b: BatteryInfo) -> String {
        let time = b.minutesLeft.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        if b.charging { return "Carregando" + (time.map { " · cheia em \($0)" } ?? "") }
        if b.onAC { return "Na tomada" }
        return "Na bateria" + (time.map { " · \($0) restantes" } ?? "")
    }

    // MARK: Formatos

    private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    private func temp(_ v: Double) -> String { "\(Int(v.rounded())) °C" }
    private static let memFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .memory; f.allowsNonnumericFormatting = false; return f
    }()
    private static let fileFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false; return f
    }()
    private func mem(_ b: Double) -> String { Self.memFormatter.string(fromByteCount: Int64(b)) }
    private func disk(_ b: Double) -> String { Self.fileFormatter.string(fromByteCount: Int64(b)) }
    private func rate(_ b: Double) -> String { disk(b) + "/s" }
    private func barColor(_ p: Double) -> Color { p >= 90 ? .red : p >= 75 ? .orange : .accentColor }
    private func level(_ p: Double) -> Color { p >= 90 ? .red : p >= 75 ? .orange : .primary }

    private func thermalText(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "Normal"
        case .fair: return "Morno"
        case .serious: return "Quente"
        case .critical: return "Crítico"
        @unknown default: return "—"
        }
    }
    private func thermalColor(_ s: ProcessInfo.ThermalState) -> Color {
        switch s {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        default: return .red
        }
    }
}

// MARK: Componentes

struct MonitorCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            content
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

private struct BigValue: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Detail: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption2).foregroundStyle(.secondary) }
}

/// Barra de uso arredondada.
struct MeterBar: View {
    let percent: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: max(6, g.size.width * CGFloat(min(max(percent, 0), 100)) / 100))
            }
        }
        .frame(height: 6)
    }
}

/// Linha simples com o historico recente.
struct Sparkline: Shape {
    let values: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1, maxValue > 0 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: CGFloat(i) * step, y: rect.maxY - rect.height * CGFloat(min(v / maxValue, 1)))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}
