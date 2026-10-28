#!/bin/zsh
# Build, notarize, package as dmg, and publish a GitHub release.
# Usage: ./release.sh 0.1.0 [notes.md]
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?version, e.g. 0.1.0}"
NOTES_FILE="${2:-}"

./build.sh

# Notarize when the app carries a Developer ID signature and notary
# credentials are stored (one-time: `xcrun notarytool store-credentials
# blitztree-notary --key <AuthKey.p8> --key-id <id> --issuer <uuid>`).
# The app is stapled before packaging so it opens offline once copied out
# of the dmg; the dmg is then signed, notarized and stapled itself.
# (-dvv: plain -dv never prints the Authority lines.)
NOTARIZE=0
DEVID=$(codesign -dvv build/DisktreeX.app 2>&1 | awk -F= '/^Authority=Developer ID Application/ && !n++ {print $2}')
if [[ -n "$DEVID" ]]; then
    NOTARIZE=1
    echo "==> Notarizing app"
    ZIP=$(mktemp -d)/DisktreeX.zip
    ditto -c -k --keepParent build/DisktreeX.app "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile blitztree-notary --wait
    xcrun stapler staple build/DisktreeX.app
    rm -f "$ZIP"
fi

STAGE=$(mktemp -d)
cp -R build/DisktreeX.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "DisktreeX.dmg"
hdiutil create -volname DisktreeX -srcfolder "$STAGE" -ov -format UDZO -quiet DisktreeX.dmg
rm -rf "$STAGE"

if (( NOTARIZE )); then
    echo "==> Notarizing dmg"
    codesign --force --timestamp --sign "$DEVID" DisktreeX.dmg
    xcrun notarytool submit DisktreeX.dmg --keychain-profile blitztree-notary --wait
    xcrun stapler staple DisktreeX.dmg
    spctl --assess --type open --context context:primary-signature -v DisktreeX.dmg
    NOTES="Download DisktreeX.dmg and drag it to Applications, then grant Full Disk Access when asked and relaunch."
else
    NOTES="Download DisktreeX.dmg, drag to Applications. First launch: System Settings → Privacy & Security → Open Anyway (unnotarized build), then grant Full Disk Access and relaunch."
fi
[[ -n "$NOTES_FILE" ]] && NOTES=$(<"$NOTES_FILE")

# Sparkle appcast: installed apps read it from the latest release
# (SUFeedURL in build.sh). The dmg is EdDSA-signed with the key from
# `generate_keys --account blitztree` (backed up in ~/.config/blitztree-signing).
SPARKLE_KEY="$HOME/.config/blitztree-signing/sparkle-ed25519.key"
if [[ -f "$SPARKLE_KEY" ]]; then
    ED=$(.cache/sparkle-*/bin/sign_update --ed-key-file "$SPARKLE_KEY" DisktreeX.dmg)
else
    ED=$(.cache/sparkle-*/bin/sign_update --account blitztree DisktreeX.dmg)
fi
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" build/DisktreeX.app/Contents/Info.plist)
# The update window shows the notes above the install section, as HTML.
CHANGES_HTML=$(gh api markdown -f text="${NOTES%%'### Install'*}")
cat > appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>DisktreeX</title>
<item>
    <title>DisktreeX $V</title>
    <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
    <sparkle:version>$V</sparkle:version>
    <sparkle:shortVersionString>$V</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>$MIN_OS.0</sparkle:minimumSystemVersion>
    <sparkle:fullReleaseNotesLink>https://github.com/ahmedkhaleel2004/blitztree/releases/tag/v$V</sparkle:fullReleaseNotesLink>
    <description><![CDATA[$CHANGES_HTML]]></description>
    <enclosure url="https://github.com/ahmedkhaleel2004/blitztree/releases/download/v$V/DisktreeX.dmg" $ED type="application/octet-stream"/>
</item>
</channel>
</rss>
EOF
xmllint --noout appcast.xml

shasum -a 256 DisktreeX.dmg > SHA256SUMS.txt
if gh release view "v$V" >/dev/null 2>&1; then
    # Re-running over an existing (e.g. draft) release replaces its files.
    gh release upload "v$V" DisktreeX.dmg SHA256SUMS.txt appcast.xml --clobber
    gh release edit "v$V" --title "DisktreeX $V" --notes "$NOTES" --draft=false --latest
else
    gh release create "v$V" DisktreeX.dmg SHA256SUMS.txt appcast.xml \
        --title "DisktreeX $V" \
        --notes "$NOTES"
fi
rm -f SHA256SUMS.txt appcast.xml
echo "==> released v$V"
