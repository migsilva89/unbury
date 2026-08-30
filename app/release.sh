#!/bin/bash
# Cut a release of Unbury that opens on somebody else's Mac.
#
# Signing alone is not enough: without notarisation, macOS tells the person the
# app "is damaged and can't be opened", which reads like a broken download
# rather than a missing Apple stamp. The stapling at the end is what makes it
# work on a machine that is offline the first time it runs.
#
#   ./release.sh 0.1.0
#
# Needs a notarytool keychain profile once. `imark` is the profile Miguel's Mac
# already has, shared across his apps; UNBURY_NOTARY_PROFILE names a different
# one on a machine where it is called something else.
#   xcrun notarytool store-credentials imark \
#     --apple-id you@example.com --team-id <your-team-id> --password <app-specific>
# Your team id is the code in brackets on your own signing identity:
#     security find-identity -v -p codesigning   # the "Developer ID Application:" line
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>}
PROFILE=${UNBURY_NOTARY_PROFILE:-imark}
APP="build/Unbury.app"
DMG="build/Unbury-$VERSION.dmg"
APPCAST="build/appcast.xml"
STAGE="build/dmg"

# --- preflight, so a failure happens before a five-minute upload ------------
IDENTITY="${VAULT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}"
[ -n "$IDENTITY" ] || { echo "no Developer ID Application identity found"; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
  echo "notarytool profile '$PROFILE' not set up — see the header of this script"; exit 1; }

# --- build and stamp the version -------------------------------------------
./build.sh release
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Signing again after editing the plist: any change to the bundle breaks the
# seal, and a broken seal fails notarisation with a message that does not
# mention the plist at all. `unburyctl` is a sealed symlink to the app executable,
# not another binary to sign.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- the disk image --------------------------------------------------------
rm -rf "$STAGE" "$DMG"
rm -f "$APPCAST"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Unbury" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" "$DMG"

# --- notarise and staple ---------------------------------------------------
echo "uploading for notarisation — this usually takes a few minutes"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# --- the update feed -------------------------------------------------------
# Only now, and only here: a feed that points at an image which is not signed,
# not notarised or not stapled offers people an update that will not open.
Support/appcast.sh "$DMG"

echo
echo "$DMG"
echo "Gatekeeper says: $(spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | tail -1)"

# The one thing this script cannot do for itself. Until both files are attached
# to the release, nobody is offered this version — installed copies read the
# feed, and the feed is the only thing that tells them a new Unbury exists.
cat <<EOF

to publish:
  gh release create v$VERSION "$DMG" "$APPCAST" --title "Unbury $VERSION" --notes "…"

Both files, in one release. The feed names the disk image by the address that
tag gives it, so publishing one without the other offers an update that cannot
be downloaded.
EOF
