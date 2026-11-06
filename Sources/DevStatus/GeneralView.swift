import SwiftUI

struct GeneralView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var docker: DockerStore
    @Binding var tab: AppTab

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("AI", icon: "sparkles", target: .ai) {
                if store.subs.isEmpty {
                    Text("Nenhuma assinatura. Adicione em AI › Ajustes de AI.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.subs) { sub in
                    HStack(spacing: 8) {
                        ProviderLogo(provider: sub.provider).frame(width: 16, height: 16)
                        Text(sub.title).font(.caption).frame(width: 190, alignment: .leading).lineLimit(1).truncationMode(.middle)
                        if let p = sub.headlinePercent {
                            ProgressView(value: min(p, 100), total: 100)
                                .tint(p >= 90 ? .red : p >= 70 ? .orange : .green)
                            Text("\(Int(p.rounded()))%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                        } else {
                            Text(stateText(sub)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            Divider()
            section("Docker", icon: "shippingbox", target: .docker) {
                switch docker.state {
                case .loading: ProgressView().controlSize(.small)
                case .unavailable(let m): Text(m).font(.caption).foregroundStyle(.orange)
                case .ok(let rows):
                    if let t = docker.totals {
                        HStack {
                            Text(DockerCLI.format(t.size)).font(.title3.weight(.semibold))
                            Text("em uso · ").font(.caption).foregroundStyle(.secondary)
                            Text("\(DockerCLI.format(t.reclaimable)) recuperável").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    ForEach(rows.filter { $0.type == "Images" || $0.type == "Build Cache" }) { r in
                        HStack {
                            Text(r.type == "Images" ? "Imagens" : "Build cache").font(.caption)
                            Spacer()
                            Text(DockerCLI.format(r.sizeBytes)).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func stateText(_ s: Subscription) -> String {
        switch s.state {
        case .loading: return "carregando…"
        case .expired: return "token expirado"
        case .noCredentials: return "sem login"
        case .error: return "erro"
        case .ok: return ""
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, icon: String, target: AppTab,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { tab = target } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            content()
        }
    }
}
