#!/bin/sh
# Assemble un vrai bundle Pepito.app (nécessaire pour un comportement macOS correct :
# fenêtres, activation, réglages, permissions). Voir CLAUDE.md.
set -e

CONFIG="${1:-debug}"
if [ "$CONFIG" = "release" ]; then
    swift build -c release
    BIN=".build/release/Pepito"
else
    swift build
    BIN=".build/debug/Pepito"
fi

APP=".build/Pepito.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pepito"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/Pepito.icns "$APP/Contents/Resources/Pepito.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signature. L'ad-hoc (-) change de hash à chaque build : TCC (Enregistrement d'écran,
# requis par ScreenCaptureKit) réinvalide alors l'autorisation à chaque reconstruction.
# Pour une autorisation STABLE, crée une fois un certificat de signature de code auto-signé
# (Trousseau › Assistant de certification › « Signature de code ») nommé p.ex. « Pepito Dev »,
# puis exporte PEPITO_SIGN_IDENTITY="Pepito Dev". TCC lie alors l'autorisation à l'identité.
SIGN_IDENTITY="${PEPITO_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 || true
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "⚠️  Signé ad-hoc : la permission Enregistrement d'écran devra être réaccordée après ce build."
    echo "    (Pour la rendre persistante, voir PEPITO_SIGN_IDENTITY dans build-app.sh.)"
fi

echo "Construit : $APP"
echo "Lancer :   open $APP"
