# Roadmap

- [ ] Docker: alerta quando o recuperável passar de X GB; prune por filtro de idade (`--filter until=`).
- [ ] Notificação quando uso passar de 80% / 90%.
- [x] Ícone com medidor em vez de texto (barras por assinatura).
- [ ] Lista manual de contas (`~/.config/devstatus/accounts.json`) para pastas fora do padrão `~/.claude-*`.
- [x] Item "Abrir no login" (SMAppService).
- [x] Mostrar tokens locais lendo `projects/*.jsonl` de cada pasta.
- [ ] Custo estimado dos tokens por modelo.
- [ ] Dock: janelas minimizadas.
- [ ] Dock: badges de notificação dos apps (via Acessibilidade).
- [ ] Dock: pastas em pilha.
- [ ] Dock: posição lateral e ocultar automaticamente.
- [ ] Herdr: clique abrir o agent específico (hoje só traz o Herdr para frente).

## Conhecido
- Token expirado só renova quando o Claude Code é usado na conta.
- Entradas de Keychain `Claude Code-credentials-<h>` de pastas fora do padrão `~/.claude-*` não são descobertas.
- O Claude Code apaga logs com mais de 30 dias (`cleanupPeriodDays`), então o mapa de tokens pode ter menos de 3 meses.
- Clicar no anel de uma assinatura abre o site com a conta logada no navegador, que pode não ser a do anel.
- Ao maximizar uma janela com o Dock próprio, ela ocupa a tela inteira por um instante antes de encolher.
- Fones Bluetooth que não informam bateria ao macOS não aparecem com % (o macOS também não mostra).
