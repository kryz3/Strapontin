#!/bin/bash
# Régénère Resources/AppIcon.png (1024 × 1024, fond transparent) depuis Resources/AppIcon.svg.
# bundle.sh en tire ensuite toutes les tailles macOS (16 à 1024, @1x et @2x).
# Rendu par Chrome sans fenêtre (Chrome, Chromium ou Edge installé).
set -euo pipefail
cd "$(dirname "$0")/.."
for b in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do [ -x "$b" ] && BROWSER="$b" && break; done
[ -n "${BROWSER:-}" ] || { echo "Il faut Chrome, Chromium ou Edge pour rendre le SVG." >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '<html><body style="margin:0;background:transparent"><img src="file://%s" width="1024" height="1024"></body></html>' \
  "$PWD/Resources/AppIcon.svg" > "$TMP/page.html"
"$BROWSER" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$TMP/profil" --allow-file-access-from-files \
  --default-background-color=00000000 --window-size=1024,1024 --force-device-scale-factor=1 \
  --screenshot="$TMP/icone.png" "file://$TMP/page.html" >/dev/null 2>&1
cp "$TMP/icone.png" Resources/AppIcon.png
sips -Z 256 Resources/AppIcon.png --out docs/images/icone.png >/dev/null
echo "Resources/AppIcon.png et docs/images/icone.png régénérés"
