#!/bin/bash
# Écrit build/appcast.xml pour une release : une seule entrée, archive signée EdDSA (Sparkle).
#   scripts/appcast.sh <archive.zip> <version> <build> <url de l'archive> <fichier de clé privée EdDSA>
# La clé privée n'est jamais dans le dépôt : en CI, elle vient du secret SPARKLE_PRIVATE_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."
ZIP="$1"; VERSION="$2"; BUILD="$3"; URL="$4"; KEY="$5"

SIGN_UPDATE="$(find .build/artifacts -path '*Sparkle/bin/sign_update' -type f | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update introuvable : lance d'abord swift build" >&2; exit 1; }
# sortie : sparkle:edSignature="…" length="…"
ATTRS="$("$SIGN_UPDATE" --ed-key-file "$KEY" "$ZIP")"
case "$ATTRS" in *edSignature=*length=*) ;; *) echo "signature impossible" >&2; exit 1 ;; esac

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Strapontin</title>
    <item>
      <title>Strapontin $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
$( [ -n "${GITHUB_REPOSITORY:-}" ] && echo "      <sparkle:fullReleaseNotesLink>https://github.com/$GITHUB_REPOSITORY/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>" )
      <enclosure url="$URL" $ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "build/appcast.xml : $VERSION ($BUILD)"
