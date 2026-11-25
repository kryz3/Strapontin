#!/bin/bash
# Construit build/Strapontin.app (libmpv, Transmission et Sparkle embarqués), build/Strapontin.dmg et build/Strapontin.zip.
# À lancer sur un Mac avec : brew install mpv dylibbundler pkg-config transmission-cli molten-vk
#
# Réglages lus dans .env (facultatif, jamais versionné, voir .env.example) ou dans l'environnement :
#   TMDB_API_KEY       clé TMDb fournie avec l'app (sinon chacun saisit la sienne dans les réglages)
#   STRAPONTIN_VERSION    version affichée (ex. 0.2.0)       STRAPONTIN_BUILD  numéro de build, croissant
#   STRAPONTIN_FEED_URL   appcast Sparkle (sinon déduit de GITHUB_REPOSITORY ; vide = mises à jour intégrées éteintes)
#   INDEXER_URL        indexeur Torznab : adresse de base, INDEXER_API_PATH le chemin de l'API (ex. /api), et
#                      INDEXER_API_KEY sa clé. Pour une copie
#                      PERSONNELLE seulement. L'app les recopie dans ses réglages au premier lancement (les réglages
#                      gardent la main). Jamais pris en compte en CI : une release publique ne contient aucune clé.
set -euo pipefail
cd "$(dirname "$0")/.."

# .env : lu ligne à ligne (pas exécuté), seulement les clés connues, sans écraser l'environnement
if [ -f .env ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      TMDB_API_KEY|OPENSUBTITLES_API_KEY|STRAPONTIN_VERSION|STRAPONTIN_BUILD|STRAPONTIN_FEED_URL|GITHUB_REPOSITORY|INDEXER_URL|INDEXER_API_PATH|INDEXER_API_KEY)
        v="${v%\"}"; v="${v#\"}"
        [ -z "${!k:-}" ] && export "$k=$v" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' .env)
fi
# copie compilée sur sa machine : le dépôt GitHub d'origine (git remote origin), pour qu'elle reçoive aussi les mises à jour
if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
  case "$ORIGIN" in
    *github.com[:/]*) GITHUB_REPOSITORY="$(echo "$ORIGIN" | sed -E 's#.*github\.com[:/]##; s#\.git$##')" ;;
  esac
fi
if [ -z "${STRAPONTIN_FEED_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  STRAPONTIN_FEED_URL="https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml"
fi

swift build -c release
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/Strapontin"
APP=build/Strapontin.app
# seulement ce que ce script produit : le reste de build/ (captures, etc.) est laissé tel quel
rm -rf "$APP" build/AppIcon.iconset build/dmg build/Strapontin.dmg build/Strapontin.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Strapontin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST" >/dev/null; }
[ -n "${STRAPONTIN_VERSION:-}" ] && pb "Set :CFBundleShortVersionString $STRAPONTIN_VERSION"
[ -n "${STRAPONTIN_BUILD:-}" ] && pb "Set :CFBundleVersion $STRAPONTIN_BUILD"
[ -n "${TMDB_API_KEY:-}" ] && pb "Add :StrapontinTMDbKey string $TMDB_API_KEY"
[ -n "${OPENSUBTITLES_API_KEY:-}" ] && pb "Add :StrapontinOpenSubtitlesKey string $OPENSUBTITLES_API_KEY"
[ -n "${STRAPONTIN_FEED_URL:-}" ] && pb "Add :SUFeedURL string $STRAPONTIN_FEED_URL"
if [ -n "${CI:-}${GITHUB_ACTIONS:-}" ]; then
  [ -n "${INDEXER_URL:-}${INDEXER_API_PATH:-}${INDEXER_API_KEY:-}" ] && echo "INDEXER_* ignorés en CI : une release publique ne contient pas d'indexeur" >&2
else
  [ -n "${INDEXER_URL:-}" ] && pb "Add :StrapontinIndexerURL string $INDEXER_URL"
  [ -n "${INDEXER_API_PATH:-}" ] && pb "Add :StrapontinIndexerPath string $INDEXER_API_PATH"
  [ -n "${INDEXER_API_KEY:-}" ] && pb "Add :StrapontinIndexerKey string $INDEXER_API_KEY"
fi
echo "Version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")), \
clé TMDb : $([ -n "${TMDB_API_KEY:-}" ] && echo fournie || echo non), \
indexeur : $(/usr/libexec/PlistBuddy -c 'Print :StrapontinIndexerURL' "$PLIST" >/dev/null 2>&1 && echo "fourni (copie personnelle)" || echo non), \
mises à jour : ${STRAPONTIN_FEED_URL:-éteintes}"

# Sparkle : framework complet (outil d'installation, services XPC), gardé avec sa propre signature
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# icône
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# libmpv + ffmpeg, libplacebo… copiés dans l'app : pas besoin de Homebrew pour la lancer
BREW="$(brew --prefix)"
# (Sparkle, chargé par @rpath, est ignoré : il est déjà copié en entier ci-dessus)
dylibbundler -of -b -cd -x "$APP/Contents/MacOS/Strapontin" -d "$APP/Contents/Frameworks" \
  -p @executable_path/../Frameworks/ -s "$BREW/lib" -i "$BINDIR" >/dev/null
# trouver Sparkle.framework dans Contents/Frameworks
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Strapontin" 2>/dev/null || true

# moteur de téléchargement intégré : transmission-daemon (sans fenêtre), lancé par Strapontin depuis Contents/MacOS
cp "$BREW/bin/transmission-daemon" "$APP/Contents/MacOS/transmission-daemon"
chmod u+w "$APP/Contents/MacOS/transmission-daemon"
# -of et pas -od : -od viderait Frameworks, donc libmpv & co copiés juste avant
dylibbundler -of -b -x "$APP/Contents/MacOS/transmission-daemon" -d "$APP/Contents/Frameworks" \
  -p @executable_path/../Frameworks/ -s "$BREW/lib" >/dev/null

# dylibbundler peut ajouter plusieurs fois le même LC_RPATH : dyld récent refuse alors de charger
# (« duplicate LC_RPATH »). On ne garde qu'une occurrence de chaque rpath.
dedupe_rpaths() {
  local f="$1"
  otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | sort | uniq -d | while read -r rp; do
    while [ "$(otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -cxF "$rp")" -gt 1 ]; do
      install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null
    done
  done
}
for f in "$APP/Contents/MacOS/Strapontin" "$APP/Contents/MacOS/transmission-daemon" "$APP"/Contents/Frameworks/*.dylib; do
  dedupe_rpaths "$f"
done

# pilote Vulkan MoltenVK pour le rendu gpu-next (libplacebo) : chargé à l'exécution par libvulkan via son
# fichier ICD, donc invisible pour dylibbundler. L'app pointe VK_DRIVER_FILES sur ce fichier au lancement.
MVK="$(brew --prefix molten-vk)/lib/libMoltenVK.dylib"
cp "$MVK" "$APP/Contents/Frameworks/libMoltenVK.dylib"
chmod u+w "$APP/Contents/Frameworks/libMoltenVK.dylib"
install_name_tool -id @executable_path/../Frameworks/libMoltenVK.dylib "$APP/Contents/Frameworks/libMoltenVK.dylib"
mkdir -p "$APP/Contents/Resources/vulkan/icd.d"
cat > "$APP/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json" <<'JSON'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "../../../Frameworks/libMoltenVK.dylib",
        "api_version": "1.4.0",
        "is_portability_driver": true
    }
}
JSON

# symboles de débogage retirés : ils contiennent les chemins de la machine qui a compilé
strip -S -x "$APP/Contents/MacOS/Strapontin"

# signature locale (ad hoc) : obligatoire sur Apple Silicon après modification des bibliothèques
find "$APP/Contents/Frameworks" -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP/Contents/MacOS/transmission-daemon"
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" build/Strapontin.zip

# image disque : Strapontin.app + raccourci Applications, à glisser-déposer
DMG_DIR=build/dmg
mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "Strapontin" -srcfolder "$DMG_DIR" -ov -format UDZO build/Strapontin.dmg >/dev/null
codesign --force --sign - build/Strapontin.dmg
echo "OK : $APP"
