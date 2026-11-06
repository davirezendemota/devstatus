import SwiftUI

struct DockerView: View {
    @EnvironmentObject var docker: DockerStore

    private func label(_ type: String) -> String {
        switch type {
        case "Images": return "Imagens"
        case "Containers": return "Containers"
        case "Local Volumes": return "Volumes"
        case "Build Cache": return "Build cache"
        default: return type
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch docker.state {
            case .loading:
                ProgressView().controlSize(.small)
            case .unavailable(let msg):
                Text(msg).font(.callout).foregroundStyle(.orange)
            case .ok(let rows):
                if let t = docker.totals {
                    HStack(alignment: .firstTextBaseline) {
                        Text(DockerCLI.format(t.size)).font(.system(size: 26, weight: .semibold))
                        Text("em uso total").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(DockerCLI.format(t.reclaimable)).font(.callout.weight(.semibold)).foregroundStyle(.orange)
                            Text("recuperável").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(label(r.type)).font(.caption)
                            Text("\(r.active)/\(r.count) ativos").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(DockerCLI.format(r.sizeBytes)).font(.caption.monospacedDigit())
                            Text("(\(DockerCLI.format(r.reclaimableBytes)) livres)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        ProgressView(value: r.sizeBytes > 0 ? (r.sizeBytes - r.reclaimableBytes) : 0,
                                     total: max(r.sizeBytes, 1)).tint(.blue)
                    }
                }
            }

            Divider()
            Text("Prune").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(PruneKind.allCases, id: \.title) { k in
                    Button(k.title) { docker.prune(k) }
                        .controlSize(.small)
                        .disabled(docker.busy != nil || { if case .ok = docker.state { return false } else { return true } }())
                }
            }
            if let b = docker.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("\(b)…").font(.caption) }
            }
            if let r = docker.result { Text(r).font(.caption).foregroundStyle(.secondary) }
            Text("Volumes não têm prune aqui: podem guardar dados de bancos.")
                .font(.caption2).foregroundStyle(.secondary)

            Spacer(minLength: 0)
            HStack {
                if let t = docker.lastUpdate {
                    Text("Atualizado \(t.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Atualizar") { docker.refresh() }.controlSize(.small)
            }
        }
        .padding(14)
        .onAppear { docker.refresh() }
    }
}
