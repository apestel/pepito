#!/bin/sh
# Publie une version de Pépito. Voir .claude/skills/release/SKILL.md pour la procédure complète.
#
#     ./release.sh 0.5.0        (ou 0.5.0-rc.1 pour une répétition en pre-release)
#
# Ce script tient les portes qui demandent la machine de l'auteur : tests, QA manuelle sur la
# build release, cohérence version/changelog. Le tag poussé déclenche .github/workflows/release.yml
# qui construit le DMG et publie la release GitHub.
set -e

V="$1"
case "$V" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "usage: ./release.sh <version>   ex. 0.5.0 ou 0.5.0-rc.1" >&2; exit 1 ;;
esac
BASE="${V%%-*}"   # version sans le suffixe -rc.N : c'est elle qui va dans l'Info.plist

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "❌ pas sur main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "❌ arbre git sale" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$V" >/dev/null && { echo "❌ tag v$V déjà existant" >&2; exit 1; }

echo "▸ Tests"
swift test

echo "▸ Changelog"
grep -q "^## \[$BASE\]" CHANGELOG.md || {
    echo "❌ pas de section '## [$BASE] - $(date +%F)' dans CHANGELOG.md." >&2
    echo "   Renomme [Unreleased] et répartis les entrées en ### Fonctionnel / ### Technique." >&2
    exit 1
}

echo "▸ Version → $BASE"
PB=/usr/libexec/PlistBuddy
BUILD=$(( $($PB -c "Print :CFBundleVersion" Packaging/Info.plist) + 1 ))
$PB -c "Set :CFBundleShortVersionString $BASE" -c "Set :CFBundleVersion $BUILD" Packaging/Info.plist

echo "▸ Build release + QA"
./build-app.sh release
open .build/Pepito.app
echo
sed -n '/^## /,$p' Packaging/QA-CHECKLIST.md
echo
printf "L'app est lancée. QA passée et validée ? [oui/non] "
read -r ANSWER
[ "$ANSWER" = "oui" ] || { git checkout Packaging/Info.plist; echo "Abandon (version restaurée)."; exit 1; }

echo "▸ Tag et push"
git commit -am "release: v$V"
git tag -a "v$V" -m "Pépito v$V"
git push --follow-tags
echo "✅ v$V poussé. La release GitHub (DMG + notes) est construite par le workflow Release."
