#!/bin/bash
# Publishes the version in Info.plist as a notarized GitHub release, with the update feed the app checks.
#
# Before running: bump CFBundleShortVersionString and CFBundleVersion in Info.plist and commit.
# Needs: a "Developer ID Application" certificate in the keychain, the asc CLI signed in (notarization),
# Dusk's Sparkle key in the login keychain (generate_keys --account Dusk), and gh signed in.
# Keep a backup of that Sparkle key (generate_keys --account Dusk -x <file>; restore with -f <file>):
# without it, installed copies can never be updated again.
set -euo pipefail
cd "$(dirname "$0")"

REPO=ahmadtawakol/Dusk
PLIST=/usr/libexec/PlistBuddy
VERSION=$($PLIST -c "Print CFBundleShortVersionString" Info.plist)
BUILD=$($PLIST -c "Print CFBundleVersion" Info.plist)
MIN_OS=$($PLIST -c "Print LSMinimumSystemVersion" Info.plist)
TAG="v$VERSION"

[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first."; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "$TAG already exists; bump the version in Info.plist."; exit 1; fi
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }

echo "Building Dusk $VERSION, signed with $IDENTITY"
SIGN_IDENTITY="$IDENTITY" ./build.sh

DIST=build/dist
rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="Dusk-$VERSION.zip"

# Notarize, staple the ticket to the app, then zip the stapled app for download and for updates.
ditto -c -k --keepParent build/Dusk.app "$DIST/to-notarize.zip"
echo "Notarizing (usually a few minutes)…"
RESULT=$(asc notarization submit --file "$DIST/to-notarize.zip" --wait --timeout 1h)
echo "$RESULT"
echo "$RESULT" | grep -q '"Accepted"' || { echo "Notarization was not accepted; see: asc notarization log --id <id>"; exit 1; }
asc notarization staple --file build/Dusk.app --confirm >/dev/null
rm "$DIST/to-notarize.zip"
ditto -c -k --keepParent build/Dusk.app "$DIST/$ZIP"
spctl --assess --type execute --verbose build/Dusk.app

# Update feed for this release, signed with Dusk's key from the login keychain.
SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account Dusk "$DIST/$ZIP") # sparkle:edSignature="…" length="…"
cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dusk</title>
    <item>
      <title>Dusk $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$ZIP" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$DIST/$ZIP" "$DIST/appcast.xml" --repo "$REPO" --title "Dusk $VERSION" --generate-notes
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
