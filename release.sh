#!/bin/bash
# Cut a notarized Mac release: archive + export (Developer ID, re-signs Sparkle's XPC services), notarize, publish the zip to
# GitHub Releases, write site/appcast.xml, deploy site/ to the VPS, install to /Applications.
#   ./release.sh "release notes"
# Bump CFBundleShortVersionString + CFBundleVersion in project.yml (all three targets) and commit first.
set -euo pipefail
cd "$(dirname "$0")"

V=$(sed -n 's/.*CFBundleShortVersionString: *"\(.*\)".*/\1/p' project.yml | head -1)
B=$(sed -n 's/.*CFBundleVersion: *"\(.*\)".*/\1/p' project.yml | head -1)
NOTES=${1:-$(git log -1 --pretty=%s)}
REPO=cheewee2000/fork-calendar
VPS=cwandt@vps52023.dreamhostps.com:experiments.cwandt.com/forkcalendar/
ZIP="$PWD/dist/Fork-Calendar-$V.zip"
APP="build/export/Fork Calendar.app"
git diff --quiet || { echo "working tree dirty — commit first"; exit 1; }
gh release view "v$V" >/dev/null 2>&1 && { echo "v$V already released"; exit 1; }

echo "── building $V ($B)"
mkdir -p dist
xcodegen generate
rm -rf build/ForkCalendar.xcarchive build/export
xcodebuild archive -project ForkCalendar.xcodeproj -scheme ForkCalendar -configuration Release \
  -archivePath build/ForkCalendar.xcarchive -derivedDataPath build \
  -allowProvisioningUpdates -skipPackagePluginValidation -quiet
xcodebuild -exportArchive -archivePath build/ForkCalendar.xcarchive \
  -exportOptionsPlist Support/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates -quiet

echo "── notarizing"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile notary --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the ticket ships with it

echo "── appcast"
SIG=$(build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update "$ZIP")  # sparkle:edSignature="…" length="…"
cat > site/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Fork Calendar</title>
    <link>https://www.experiments.cwandt.com/forkcalendar/</link>
    <description>Updates for Fork Calendar</description>
    <language>en</language>
    <item>
      <title>Fork Calendar $V</title>
      <link>https://github.com/$REPO/releases/tag/v$V</link>
      <sparkle:version>$B</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES</p>]]></description>
      <enclosure
        url="https://github.com/$REPO/releases/download/v$V/Fork-Calendar-$V.zip"
        type="application/octet-stream"
        $SIG/>
    </item>
  </channel>
</rss>
XML
sed -i '' "s/(v[0-9.]*, macOS/(v$V, macOS/" site/index.html

echo "── publishing"
gh release create "v$V" "$ZIP" --title "Fork Calendar $V" --notes "$NOTES"
rsync -az site/ "$VPS"
git add site && git commit -q -m "release: v$V appcast + site" && git push -q

echo "── installing"
osascript -e 'quit app "Fork Calendar"' 2>/dev/null || true
sleep 2; pkill -x "Fork Calendar" || true   # a hung build ignores the quit event
rm -rf "/Applications/Fork Calendar.app"
ditto "$APP" "/Applications/Fork Calendar.app"
open "/Applications/Fork Calendar.app"
echo "done — v$V live at https://github.com/$REPO/releases/tag/v$V"
