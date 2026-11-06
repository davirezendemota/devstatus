import SwiftUI
import AppKit

/// Dispositivo com bateria conectado ao Mac (o proprio Mac e os acessorios).
struct ConnectedDevice: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let symbol: String
    var battery: Int?        // 0-100
    var charging = false
}

/// Baterias do Mac e dos acessorios, as mesmas do widget Baterias do macOS.
/// Fonte: `pmset -g accps` (o macOS ja le a bateria de fones, teclados e mouses Bluetooth).
/// O tipo de cada acessorio (icone) vem de `system_profiler SPBluetoothDataType -json`.
@MainActor
final class DevicesStore: ObservableObject {
    @Published private(set) var devices: [ConnectedDevice] = []
    private var timer: Timer?
    private var running = false
    private var types: [String: String] = [:]   // nome -> tipo Bluetooth (cache)

    func setPolling(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { devices = []; return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !running else { return }
        running = true
        let known = types
        Task.detached(priority: .utility) {
            let sources = Self.powerSources()
            // So consulta o tipo dos acessorios que ainda nao conhecemos.
            let needTypes = sources.contains { !$0.isInternal && known[$0.name] == nil }
            let fresh = needTypes ? Self.bluetoothTypes() : [:]
            await MainActor.run {
                self.running = false
                self.types.merge(fresh) { _, new in new }
                let list = sources.map { s in
                    ConnectedDevice(name: s.isInternal ? "Este Mac" : s.name,
                                    symbol: s.isInternal ? Self.sf("macbook", "laptopcomputer") : Self.symbol(name: s.name, type: self.types[s.name] ?? ""),
                                    battery: s.percent, charging: s.charging)
                }
                if list != self.devices { self.devices = list }
            }
        }
    }

    // MARK: pmset

    private struct Source { let name: String; let percent: Int?; let charging: Bool; let isInternal: Bool }

    /// Linhas como " -MX Master 4 (id=38212488)\t90%; " ou " -InternalBattery-0 (id=1)\t100%; charged; ...".
    nonisolated private static func powerSources() -> [Source] {
        guard let text = run("/usr/bin/pmset", ["-g", "accps"]) else { return [] }
        let regex = try! NSRegularExpression(pattern: #"^\s*-(.+?) \(id=\d+\)\s+(\d+)%;\s*(.*)$"#)
        return text.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let nameR = Range(m.range(at: 1), in: s), let pctR = Range(m.range(at: 2), in: s),
                  let restR = Range(m.range(at: 3), in: s) else { return nil }
            let name = String(s[nameR])
            let rest = s[restR].lowercased()
            let charging = rest.contains("charging") && !rest.contains("discharging") && !rest.contains("not charging")
            return Source(name: name, percent: Int(s[pctR]), charging: charging, isInternal: name.hasPrefix("InternalBattery"))
        }
        // Mac primeiro, depois os acessorios em ordem alfabetica.
        .sorted { ($0.isInternal ? 0 : 1, $0.name) < ($1.isInternal ? 0 : 1, $1.name) }
    }

    nonisolated private static func bluetoothTypes() -> [String: String] {
        guard let text = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let ctrls = json["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for ctrl in ctrls {
            for key in ["device_connected", "device_not_connected"] {
                for dev in ctrl[key] as? [[String: Any]] ?? [] {
                    for (name, value) in dev {
                        out[name] = (value as? [String: Any])?["device_minorType"] as? String ?? ""
                    }
                }
            }
        }
        return out
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    /// Simbolo preferido se existir nesta versao do macOS, senao a alternativa.
    nonisolated static func sf(_ preferred: String, _ fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : fallback
    }

    /// Mesmos icones (preenchidos) do widget Baterias do macOS.
    nonisolated private static func symbol(name: String, type: String) -> String {
        let n = name.lowercased(), t = type.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return sf("airpods.gen3", "airpods") }
        if n.contains("beats") { return sf("beats.headphones", "headphones") }
        if t.contains("keyboard") || n.contains("keys") || n.contains("keyboard") { return "keyboard" }
        if t.contains("mouse") || n.contains("mouse") || n.contains("master") { return "computermouse" }
        if t.contains("trackpad") || n.contains("trackpad") { return sf("rectangle.and.hand.point.up.left.fill", "rectangle.and.hand.point.up.left") }
        if t.contains("headset") || t.contains("headphone") || t.contains("audio") || n.contains("buds") { return "headphones" }
        if t.contains("gamepad") || t.contains("game") || n.contains("controller") { return "gamecontroller.fill" }
        if n.contains("pencil") { return "pencil.tip" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("ipad") { return "ipad" }
        if t.contains("phone") || n.contains("iphone") { return "iphone" }
        if t.contains("speaker") { return "hifispeaker.fill" }
        return "battery.75percent"
    }
}


/// Card do Dock no estilo do widget Baterias do macOS: um anel por dispositivo com o icone no centro.
struct DevicesView: View {
    @ObservedObject var devices: DevicesStore
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.14) {
            ForEach(devices.devices) { ring($0) }
        }
        .frame(height: size)
    }

    private func color(_ d: ConnectedDevice) -> Color {
        guard let b = d.battery else { return .gray }
        if d.charging { return .green }
        return b <= 20 ? .red : .green
    }

    private func ring(_ d: ConnectedDevice) -> some View {
        let diameter = size * 0.9, line = max(3.5, size * 0.1)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: line)
            Circle()
                .trim(from: 0, to: CGFloat(d.battery ?? 0) / 100)
                .stroke(color(d), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: d.symbol)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(.white)
            if d.charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: diameter * 0.2, weight: .bold)).foregroundStyle(.green)
                    .offset(y: diameter * 0.3)
            }
        }
        .padding(line / 2)
        .frame(width: diameter, height: diameter)
        .help("\(d.name)\(d.battery.map { " · \($0)%" } ?? "")\(d.charging ? " · carregando" : "")")
    }
}
