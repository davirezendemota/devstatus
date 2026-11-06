import AppKit

extension Provider {
    /// Cor da marca, usada nas barras do icone de AI.
    var nsColor: NSColor {
        switch self {
        case .claude: return NSColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        case .cursor: return .systemBlue
        }
    }
}

/// Icone de AI: uma barra por assinatura (cor da IA), com o numero fixo dela; a ordem vem de quem chama.
enum UsageBarsIcon {
    static func make(_ rows: [(number: Int, percent: Double?, color: NSColor)], vertical: Bool = false) -> NSImage {
        vertical ? makeVertical(Array(rows.prefix(6))) : makeHorizontal(Array(rows.prefix(4)))
    }

    /// Colunas lado a lado: barra em pe e o numero embaixo.
    private static func makeVertical(_ rows: [(number: Int, percent: Double?, color: NSColor)]) -> NSImage {
        let colW: CGFloat = 7, gap: CGFloat = 3
        let width = CGFloat(rows.count) * colW + CGFloat(max(rows.count - 1, 0)) * gap
        let img = NSImage(size: NSSize(width: max(width, 7), height: 18), flipped: true) { _ in
            let font = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .bold)
            for (i, row) in rows.enumerated() {
                let x = CGFloat(i) * (colW + gap)
                Bars.draw(NSRect(x: x + 1.5, y: 1, width: 4, height: 9), fraction: (row.percent ?? 0) / 100,
                          color: row.color, vertical: true)
                let label = NSAttributedString(string: "\(row.number)", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                let ls = label.size()
                label.draw(at: NSPoint(x: x + (colW - ls.width) / 2, y: 18 - ls.height))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func makeHorizontal(_ rows: [(number: Int, percent: Double?, color: NSColor)]) -> NSImage {
        let img = NSImage(size: NSSize(width: 34, height: 18), flipped: true) { rect in
            let rowH = rect.height / CGFloat(rows.count)
            let barH = min(5, rowH * 0.6)
            let numW: CGFloat = 7, barX = numW + 2
            let font = NSFont.monospacedDigitSystemFont(ofSize: min(9, rowH + 1), weight: .bold)
            for (i, row) in rows.enumerated() {
                let midY = rowH * (CGFloat(i) + 0.5)
                let label = NSAttributedString(string: "\(row.number)", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                let ls = label.size()
                label.draw(at: NSPoint(x: (numW - ls.width) / 2, y: midY - ls.height / 2))
                Bars.draw(NSRect(x: barX, y: midY - barH / 2, width: rect.width - barX, height: barH),
                          fraction: (row.percent ?? 0) / 100, color: row.color)
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// Grade 2x2 de icone + barra, usada pelos icones de Docker e Monitor.
enum GridBarsIcon {
    struct Item { let symbol: String; let fraction: Double; let color: NSColor }

    static func make(_ items: [Item], vertical: Bool = false) -> NSImage {
        vertical ? makeVertical(Array(items.prefix(4))) : makeHorizontal(items)
    }

    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
        .applying(.init(paletteColors: [.labelColor]))

    private static func drawSymbol(_ name: String, in box: NSRect) {
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) else { return }
        let s = sym.size, scale = min(box.width / s.width, box.height / s.height)
        let w = s.width * scale, h = s.height * scale
        sym.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
    }

    /// Colunas lado a lado: barra em pe e o icone embaixo.
    private static func makeVertical(_ items: [Item]) -> NSImage {
        let colW: CGFloat = 9, gap: CGFloat = 3
        let width = CGFloat(items.count) * colW + CGFloat(max(items.count - 1, 0)) * gap
        let img = NSImage(size: NSSize(width: width, height: 18), flipped: true) { _ in
            for (i, item) in items.enumerated() {
                let x = CGFloat(i) * (colW + gap)
                Bars.draw(NSRect(x: x + 2.5, y: 1, width: 4, height: 9), fraction: item.fraction, color: item.color, vertical: true)
                drawSymbol(item.symbol, in: NSRect(x: x, y: 11, width: colW, height: 7))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func makeHorizontal(_ items: [Item]) -> NSImage {
        let img = NSImage(size: NSSize(width: 60, height: 18), flipped: true) { rect in
            let cellW = (rect.width - 4) / 2, cellH = rect.height / 2
            let iconSize: CGFloat = 8, barH: CGFloat = 4
            for (i, item) in items.prefix(4).enumerated() {
                let x = CGFloat(i % 2) * (cellW + 4), midY = cellH * (CGFloat(i / 2) + 0.5)
                drawSymbol(item.symbol, in: NSRect(x: x, y: midY - iconSize / 2, width: iconSize, height: iconSize))
                let barX = x + iconSize + 2
                Bars.draw(NSRect(x: barX, y: midY - barH / 2, width: x + cellW - barX, height: barH),
                          fraction: item.fraction, color: item.color)
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// Icone de Docker: imagens, build cache, containers e volumes; barra = fatia de cada tipo no total.
enum DockerBarsIcon {
    static let kinds: [(type: String, symbol: String, color: NSColor)] = [
        ("Images", "square.stack.3d.up.fill", .systemBlue),
        ("Build Cache", "hammer.fill", .systemOrange),
        ("Containers", "cube.fill", .systemGreen),
        ("Local Volumes", "externaldrive.fill", .systemPurple),
    ]

    static func make(_ rows: [DockerRow], vertical: Bool = false) -> NSImage {
        let total = max(rows.reduce(0) { $0 + $1.sizeBytes }, 1)
        return GridBarsIcon.make(kinds.map { k in
            .init(symbol: k.symbol, fraction: (rows.first { $0.type == k.type }?.sizeBytes ?? 0) / total, color: k.color)
        }, vertical: vertical)
    }
}

/// Icone de Monitor: CPU, memoria, disco do sistema e temperatura da CPU (0-100 °C). Vermelho a partir de 90%.
enum MonitorBarsIcon {
    static func make(cpu: Double, memory: Double, disk: Double, temperature: Double?, vertical: Bool = false) -> NSImage {
        func item(_ symbol: String, _ f: Double, _ color: NSColor) -> GridBarsIcon.Item {
            .init(symbol: symbol, fraction: f, color: f >= 0.9 ? .systemRed : color)
        }
        return GridBarsIcon.make([
            item("cpu", cpu, .systemBlue),
            item("memorychip", memory, .systemPurple),
            item("internaldrive.fill", disk, .systemTeal),
            item("thermometer.medium", (temperature ?? 0) / 100, .systemOrange),
        ], vertical: vertical)
    }
}

enum Bars {
    /// Trilho cinza + preenchimento colorido arredondado.
    static func draw(_ track: NSRect, fraction: Double, color: NSColor, vertical: Bool = false) {
        let r = min(track.width, track.height) / 2
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
        guard fraction > 0 else { return }
        var fill = track
        let f = CGFloat(min(fraction, 1))
        if vertical {
            // Cresce de baixo para cima (contexto invertido: y maior = mais embaixo).
            fill.size.height = max(track.width, track.height * f)
            fill.origin.y = track.maxY - fill.size.height
        } else {
            fill.size.width = max(track.height, track.width * f)
        }
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}
