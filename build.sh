#!/usr/bin/env bash
# Compila e empacota DevStatus.app (app de barra de menu, sem Dock).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=DevStatus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DevStatus "$APP/Contents/MacOS/DevStatus"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DevStatus</string>
  <key>CFBundleIdentifier</key><string>local.devstatus</string>
  <key>CFBundleExecutable</key><string>DevStatus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Mostrar a música do Spotify no Dock do DevStatus e controlar play, pausa e faixa.</string>
</dict></plist>
P
# Assinatura: certificado de .sign-identity (hash SHA-1, arquivo local fora do git) ou
# DEVSTATUS_SIGN_IDENTITY; sem isso, ad-hoc. Com certificado fixo o macOS mantem as permissoes
# (Acessibilidade, Automacao, Keychain) entre builds.
IDENTITY="${DEVSTATUS_SIGN_IDENTITY:-}"
[ -z "$IDENTITY" ] && [ -f .sign-identity ] && IDENTITY="$(tr -d '[:space:]' < .sign-identity)"
if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null
  echo "Assinado com certificado."
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Assinado ad-hoc."
fi
echo "OK: $(pwd)/$APP"
