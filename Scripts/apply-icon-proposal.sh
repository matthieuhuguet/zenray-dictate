#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CHOICE="${1:-1}"

case "$CHOICE" in
    1)
        NAME="proposition-1-gemini-spectrum"
        LABEL="Gemini Spectrum Studio (Fond clair · Spectre continu)"
        ;;
    2)
        NAME="proposition-2-antigravity-dark"
        LABEL="Antigravity Dark Glow (Dark mode · Néon cosmique)"
        ;;
    3)
        NAME="proposition-3-gemini-spark"
        LABEL="Gemini Spark Signature (Fond clair · Micro PBR + Étoile Gemini)"
        ;;
    *)
        echo "Usage: $0 [1|2|3]"
        exit 1
        ;;
esac

SVG_SRC="docs/icons-proposals/${NAME}.svg"

if [[ ! -f "$SVG_SRC" ]]; then
    echo "Fichier source introuvable : $SVG_SRC"
    exit 1
fi

echo "==> Application de la proposition $CHOICE : $LABEL"
cp "$SVG_SRC" AppIcon.svg
./Scripts/generate-icns.sh AppIcon.svg AppIcon.icns

if [[ -d ZenRayDictate.app/Contents/Resources ]]; then
    echo "==> Mise à jour de ZenRayDictate.app/Contents/Resources/AppIcon.icns"
    cp AppIcon.icns ZenRayDictate.app/Contents/Resources/AppIcon.icns
    touch ZenRayDictate.app
fi

echo "==> Icône mise à jour avec succès !"
