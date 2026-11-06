# Desenvolvimento

## Build e execução
```
./build.sh
pkill DevStatus; open DevStatus.app
```
Requisitos: Swift 5.9+ (testado com 6.4), macOS 13+. Sem projeto Xcode e sem dependências.

Abra sempre com `open` (ou Spotlight). Rodar o binário direto (`DevStatus.app/Contents/MacOS/DevStatus`) faz o macOS checar as permissões do terminal, não as do DevStatus.

## CI e release
`.github/workflows/build.yml` roda em `macos-15`: compila em todo push/PR na `main` (artefato `.zip` por 7 dias) e, quando uma release é publicada, gera o app universal com `DEVSTATUS_UNIVERSAL=1 ./build.sh`, confere as arquiteturas com `lipo` e anexa `DevStatus-<tag>-macos-universal.zip` e o `.sha256` à release. Para uma release já existente: Actions › Build › Run workflow, com a tag. Fora de PR, o CI assina com o certificado autoassinado das releases (abaixo) e falha se a assinatura não sair com ele; em PR (sem secrets) assina ad-hoc. O app não é notarizado: o `install.sh` do site baixa com `curl`, que não põe quarentena (ver README).

### Certificado das releases
- `DevStatus Release Signing`, autoassinado, RSA 3072, só Code Signing, válido até 2036. SHA-1 `D34B81470098E31DC94CFDEB255C4F5454430384`.
- Requisito designado resultante: `identifier "local.devstatus" and certificate root = H"d34b81…"`. Igual em todas as versões, então o macOS mantém as permissões nas atualizações.
- GitHub: secrets `DEVSTATUS_SIGNING_P12` (base64 do `.p12`) e `DEVSTATUS_SIGNING_P12_PASSWORD`, variável `DEVSTATUS_SIGN_IDENTITY` (SHA-1). O workflow importa num keychain temporário e o apaga no fim.
- Backup: `.p12` em `~/.config/devstatus-signing/` (fora do git) e a senha no Keychain (`security find-generic-password -s devstatus-release-signing-p12 -w`). Perder o certificado obriga todos os usuários a liberar as permissões de novo; vazar a chave permite assinar um app que herda essas permissões. Nunca comitar.
- `security find-identity -v` não lista certificado autoassinado (não confiável); por isso o `build.sh` busca sem `-v`. `DEVSTATUS_REQUIRE_SIGN=1` faz o build falhar em vez de cair em ad-hoc.

## Assinatura (permissões que sobrevivem ao rebuild)
O `build.sh` assina com o certificado indicado em `.sign-identity` (hash SHA-1, fora do git) ou em `DEVSTATUS_SIGN_IDENTITY`; sem isso, ad-hoc.
```
security find-identity -v -p codesigning
echo "<SHA-1>" > .sign-identity
```
Com ad-hoc, cada build é um "app novo" para o macOS: Acessibilidade, Automação (Spotify) e Keychain precisam ser concedidos de novo.

Se a Acessibilidade aparecer ligada mas não funcionar (presa a uma assinatura antiga):
```
tccutil reset Accessibility local.devstatus
```
e ligue de novo em System Settings › Privacy & Security › Accessibility.

## Dock do macOS ficou oculto
Com "Substituir o Dock" ligado, `pkill` não restaura o Dock (só sair pelo app ou desligar a opção). Para restaurar à mão:
```
defaults write com.apple.dock autohide -bool false
defaults delete com.apple.dock autohide-delay
killall Dock
```

## Testar a API sem o app
```
T=$(security find-generic-password -s "Claude Code-credentials" -a "$USER" -w | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
curl -s https://api.anthropic.com/api/oauth/usage -H "Authorization: Bearer $T" -H "anthropic-beta: oauth-2025-04-20"
```
Não cole nem registre o token.

## Ver uma view sem abrir o app
Compile os fontes sem o `App.swift` (que tem o `@main`) junto com um `main.swift` de teste e renderize com `ImageRenderer`:
```swift
import SwiftUI
@main struct M { @MainActor static func main() async {
    let v = DevicesView(devices: DevicesStore(), size: 52).padding(10)
    let r = ImageRenderer(content: v); r.scale = 2
    try! NSBitmapImageRep(cgImage: r.cgImage!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "out.png"))
}}
```
```
swiftc -parse-as-library -o t $(ls Sources/DevStatus/*.swift | grep -v App.swift) main.swift && ./t
```
O `ImageRenderer` não desenha `ScrollView`, `LazyVGrid`, materiais nem controles nativos (aparecem vazios ou amarelos). As preferências do binário de teste são outras: copie as chaves de `local.devstatus` se a view depender delas.

## Adicionar um provider de IA
1. Caso em `Provider` (`Models.swift`): `name`, `usageURL`; cor em `MenuIcon.swift` (`nsColor`); logo em `Logos.swift`.
2. `XService.swift` com `fetch(...) async -> UsageState`, marcando cada `Metric` com um `MetricKind`.
3. Montar as assinaturas em `Store.reload()` e mapear os anéis em `Subscription.outerRing`/`innerRing`/`resetMetric`.
4. Documentar credenciais, API e domínios em `architecture.md` e na regra de rede do `CLAUDE.md`.
