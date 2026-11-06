import SwiftUI
import ServiceManagement

/// Chaves das preferencias de icones extras na barra de menu.
enum StatKey {
    static let ai = "statAI"
    static let docker = "statDocker"
    static let monitor = "statMonitor"
}

/// Opcoes de cada icone de Stats: tempo de atualizacao e orientacao das barras.
enum Stat: String, CaseIterable {
    case ai = "AI", docker = "Docker", monitor = "Monitor"

    var intervalKey: String { "stat\(rawValue)Interval" }
    var verticalKey: String { "stat\(rawValue)Vertical" }
    var dockKey: String { "stat\(rawValue)Dock" }
    var inDock: Bool { UserDefaults.standard.bool(forKey: dockKey) }

    var tab: AppTab {
        switch self {
        case .ai: return .ai
        case .docker: return .docker
        case .monitor: return .monitor
        }
    }
    var icon: String {
        switch self {
        case .ai: return "sparkles"
        case .docker: return "shippingbox"
        case .monitor: return "waveform.path.ecg"
        }
    }

    /// AI consulta APIs da Anthropic/Cursor: minimo de 1 min para nao levar bloqueio por excesso de requisicoes.
    var intervals: [Double] {
        switch self {
        case .ai: return [60, 120, 300, 600, 900]
        case .docker: return [3, 5, 10, 30, 60, 300]
        case .monitor: return [1, 2, 3, 5, 10, 30]
        }
    }
    var defaultInterval: Double { self == .ai ? 300 : 3 }

    var interval: Double {
        let v = UserDefaults.standard.double(forKey: intervalKey)
        return v > 0 ? v : defaultInterval
    }
    var vertical: Bool { UserDefaults.standard.bool(forKey: verticalKey) }

    static func label(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }
}

struct SettingsView: View {
    @AppStorage(StatKey.ai) private var statAI = true
    @AppStorage(StatKey.docker) private var statDocker = true
    @AppStorage(StatKey.monitor) private var statMonitor = true
    @AppStorage(DockBar.enabledKey) private var dockReplace = false
    @AppStorage(DockBar.iconSizeKey) private var dockIconSize: Double = 52
    @State private var axTrusted = WindowGuard.isTrusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ajustes").font(.headline)

                group("Geral") {
                    row("Iniciar junto com o Mac", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    if let m = loginMessage {
                        HStack(spacing: 6) {
                            Text(m).font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            if SMAppService.mainApp.status == .requiresApproval {
                                Button("Abrir Itens de Início") { SMAppService.openSystemSettingsLoginItems() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Divider()

                group("Dock") {
                    row("Substituir o Dock do macOS", isOn: $dockReplace)
                    if dockReplace && !axTrusted {
                        HStack(spacing: 6) {
                            Text("Para as janelas não ficarem atrás da barra, permita o DevStatus em Acessibilidade.")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            Button("Abrir Acessibilidade") { WindowGuard.openAccessibilitySettings() }.controlSize(.small)
                        }
                    }
                    if dockReplace {
                        HStack {
                            Text("Tamanho dos ícones")
                            Slider(value: $dockIconSize, in: 36...80)
                            Text("\(Int(dockIconSize))").font(.caption.monospacedDigit()).frame(width: 24)
                        }
                    }
                    Text("A barra do DevStatus mostra Finder, apps fixos e abertos, os Stats marcados com \(Image(systemName: "dock.rectangle")) (com largura de 1 a 4 ícones), Lixo. O Dock do macOS fica oculto e volta ao desligar a opção ou sair do app. Arraste apps para fixar ou reordenar; clique direito para remover.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                group("Stats") {
                    Text("Cada opção ligada adiciona um ícone na barra de menu. Ao clicar, o app abre direto na aba correspondente. Escolha barras horizontais ou verticais e o tempo de atualização.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    StatRow(stat: .ai, icon: "sparkles", isOn: $statAI)
                    StatRow(stat: .docker, icon: "shippingbox", isOn: $statDocker)
                    StatRow(stat: .monitor, icon: "waveform.path.ecg", isOn: $statMonitor)
                    Text("O botão \(Image(systemName: "dock.rectangle")) coloca o Stats no Dock. Clique nele no Dock para abrir o app na aba.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !statAI && !statDocker && !statMonitor {
                        Text("Sem ícones na barra. Abra o DevStatus pelo Spotlight para ver o app.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Text("As assinaturas são configuradas em AI › Ajustes de AI.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(14)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            axTrusted = WindowGuard.isTrusted
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
            loginMessage = service.status == .requiresApproval
                ? "Aprove o DevStatus em Ajustes do Sistema › Itens de Início." : nil
        } catch {
            loginMessage = "Não consegui \(on ? "ativar" : "desativar"): \(error.localizedDescription)"
        }
        launchAtLogin = service.status == .enabled
    }

    /// Linha com o texto a esquerda e o toggle no canto direito.
    private func row(_ title: String, icon: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}

/// Linha de Stats: nome a esquerda; orientacao, tempo de atualizacao e toggle a direita.
struct StatRow: View {
    let stat: Stat
    let icon: String
    @Binding var isOn: Bool
    @AppStorage private var interval: Double
    @AppStorage private var vertical: Bool
    @AppStorage private var dock: Bool
    @AppStorage private var width: Int
    @AppStorage(DockBar.enabledKey) private var dockReplace = false

    init(stat: Stat, icon: String, isOn: Binding<Bool>) {
        self.stat = stat
        self.icon = icon
        _isOn = isOn
        _interval = AppStorage(wrappedValue: stat.defaultInterval, stat.intervalKey)
        _vertical = AppStorage(wrappedValue: false, stat.verticalKey)
        _dock = AppStorage(wrappedValue: false, stat.dockKey)
        _width = AppStorage(wrappedValue: 2, stat.widthKey)
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(stat.rawValue, systemImage: icon)
            Spacer()
            Picker("Orientação", selection: $vertical) {
                Image(systemName: "text.alignleft").help("Barras horizontais").tag(false)
                Image(systemName: "chart.bar.fill").help("Barras verticais").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Atualizar a cada", selection: $interval) {
                ForEach(stat.intervals, id: \.self) { Text(Stat.label($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Tempo de atualização")
            Toggle(isOn: $dock) { Image(systemName: "dock.rectangle") }
                .toggleStyle(.button)
                .help("Mostrar no Dock")
            if dock && dockReplace {
                Picker("Largura", selection: $width) {
                    ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("Largura no Dock, em ícones")
            }
            Toggle(stat.rawValue, isOn: $isOn).labelsHidden().help("Mostrar na barra de menu")
        }
    }
}
