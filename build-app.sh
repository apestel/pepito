#!/bin/sh
# Assemble un vrai bundle Pepito.app (nécessaire pour un comportement macOS correct :
# fenêtres, activation, réglages, permissions). Voir CLAUDE.md.
set -e

mkdir -p .build
LOCK=".build/pepito-bundle.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "Une construction de Pépito est déjà en cours. Réessayez après sa fin." >&2
    exit 1
fi
STAGE=""
cleanup() {
    if [ -n "$STAGE" ]; then
        if [ -d "$STAGE/previous.app" ] && [ ! -e .build/Pepito.app ]; then
            mv "$STAGE/previous.app" .build/Pepito.app
        fi
        rm -rf "$STAGE"
    fi
    rmdir "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

CONFIG="${1:-debug}"
python3 Packaging/prepare-agent-runtime.py
if [ "$CONFIG" = "release" ]; then
    swift build -c release
    BIN=".build/release/Pepito"
else
    swift build
    BIN=".build/debug/Pepito"
fi

STAGE=$(mktemp -d .build/pepito-bundle.XXXXXX)
APP="$STAGE/Pepito.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pepito"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/Pepito.icns "$APP/Contents/Resources/Pepito.icns"
mkdir -p "$APP/Contents/Resources/AgentRuntime"
cp Runtime/python-runner.mjs Runtime/bridge.mjs Runtime/script-runner.mjs Runtime/fetch.mjs Runtime/package.json Runtime/package-lock.json "$APP/Contents/Resources/AgentRuntime/"
cp -R Runtime/node_modules "$APP/Contents/Resources/AgentRuntime/"
cp .build/agent-assets/node .build/agent-assets/NODE-LICENSE "$APP/Contents/Resources/AgentRuntime/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signature. L'ad-hoc (-) change de hash à chaque build : TCC (Enregistrement d'écran,
# requis par ScreenCaptureKit) réinvalide alors l'autorisation à chaque reconstruction.
# Pour une autorisation STABLE, crée une fois un certificat de signature de code auto-signé
# (Trousseau › Assistant de certification › « Signature de code ») nommé p.ex. « Pepito Dev »,
# puis exporte PEPITO_SIGN_IDENTITY="Pepito Dev". TCC lie alors l'autorisation à l'identité.
SIGN_IDENTITY="${PEPITO_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/AgentRuntime/node"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
# Vérifie aussi les imports du moteur embarqué, sans mission ni connexion à un fournisseur IA.
"$APP/Contents/Resources/AgentRuntime/node" "$APP/Contents/Resources/AgentRuntime/bridge.mjs" < /dev/null
if [ -e .build/Pepito.app ]; then
    mv .build/Pepito.app "$STAGE/previous.app"
fi
mv "$APP" .build/Pepito.app
APP=".build/Pepito.app"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "⚠️  Signé ad-hoc : la permission Enregistrement d'écran devra être réaccordée après ce build."
    echo "    (Pour la rendre persistante, voir PEPITO_SIGN_IDENTITY dans build-app.sh.)"
fi

echo "Construit : $APP"
echo "Lancer :   open $APP"
