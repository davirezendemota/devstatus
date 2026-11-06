import SwiftUI

/// Ajustes da aba AI: cookie do site, assinaturas e contas identificadas.
struct AISettingsView: View {
    @EnvironmentObject var store: Store
    @State private var cookie = ""
    @State private var name = ""
    @State private var message: (text: String, ok: Bool)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ajustes de AI").font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Adicionar assinatura").font(.subheadline.weight(.semibold))
                    Text("Cole o cookie de claude.ai ou cursor.com. O app identifica o provider pelo conteúdo.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $cookie)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    TextField("Nome (opcional)", text: $name).textFieldStyle(.roundedBorder).controlSize(.small)
                    HStack {
                        Button("Detectar e adicionar") { add() }
                            .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let m = message {
                            Text(m.text).font(.caption).foregroundStyle(m.ok ? .green : .red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !store.subs.isEmpty {
                    Divider()
                    Text("Assinaturas").font(.subheadline.weight(.semibold))
                    ForEach(Array(store.subs.enumerated()), id: \.element.id) { i, sub in
                        HStack(spacing: 8) {
                            NumberBadge(number: i + 1)
                            ProviderLogo(provider: sub.provider).frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(sub.title).font(.caption)
                                Text(sub.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Ordem = numero fixo da assinatura (cards, menu bar e Dock).
                            Button { store.move(sub, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(i == 0).help("Subir (muda o número)")
                            Button { store.move(sub, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(i == store.subs.count - 1).help("Descer (muda o número)")
                            Button(action: { store.remove(sub) }) { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Remover assinatura")
                        }
                    }
                }

                let detected = store.detectedClaudeAccounts
                let cursorEmail = store.detectedCursorEmail
                if !detected.isEmpty || cursorEmail != nil {
                    Divider()
                    Text("Identificadas nesta máquina").font(.subheadline.weight(.semibold))
                    if let email = cursorEmail {
                        HStack(spacing: 8) {
                            ProviderLogo(provider: .cursor).frame(width: 16, height: 16)
                            Text("Cursor · \(email)").font(.caption)
                            Spacer()
                            Button("Adicionar") { store.addCursorAgent() }.controlSize(.small)
                        }
                    }
                    ForEach(detected) { acc in
                        HStack(spacing: 8) {
                            ProviderLogo(provider: .claude).frame(width: 16, height: 16)
                            Text("Claude Code · \(acc.label)").font(.caption)
                            Spacer()
                            Button("Adicionar") { store.addClaudeAccount(acc) }.controlSize(.small)
                        }
                    }
                }

                Text("Os cookies ficam no Keychain deste Mac e só são enviados a claude.ai e cursor.com.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    private func add() {
        switch store.addCookie(cookie, name: name) {
        case .success(let p):
            message = ("\(p.name) adicionado.", true)
            cookie = ""; name = ""
        case .failure(let err):
            message = (err.message, false)
        }
    }
}
