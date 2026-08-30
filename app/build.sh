#!/bin/bash
# Assemble Unbury.app. SwiftPM only produces the executables; the bundle around
# them — Info.plist, the icon, the Sparkle framework that fetches updates, and
# the unburyctl the chat engines call — is here.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="build/Unbury.app"

# The version a plain build carries. It used to be the literal 0.1.0, which put
# an app built today on the shelf claiming to be the first release — and the
# updater compares exactly this number, so it would have offered an "update" to
# what was already installed. release.sh overwrites it with the version it is
# cutting; here the last tag is the closest true answer.
# The newest tag by version, not `git describe`: describe needs a tag that is an
# ancestor of HEAD, and tags made by `gh release create` land on the remote — so
# a clone that had not fetched them built 0.0.0, a version every published
# release looks newer than.
VERSION="$(git tag --list 'v*' --sort=-version:refname 2>/dev/null | head -1)"
VERSION="${VERSION#v}"
VERSION="${VERSION:-0.0.0}"

# Where installed copies look for the list of newer versions, and the public
# half of the EdDSA key those versions are signed with. The private half lives
# in the login keychain under the account `unbury` and is never in a file; see
# docs/RELEASING.md. Changing this key orphans every copy already installed.
FEED_URL="https://github.com/migsilva89/unbury/releases/latest/download/appcast.xml"
PUBLIC_ED_KEY="rWVB4Em3ZgPdN3JT8uEXa3jF1MXHgC7Ou9LSyYiIj1E="

swift build -c "$CONFIG" --product Unbury
swift build -c "$CONFIG" --product unburyctl
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Unbury" "$APP/Contents/MacOS/Unbury"
ln -s Unbury "$APP/Contents/MacOS/unburyctl"
cp Resources/Unbury.icns "$APP/Contents/Resources/Unbury.icns"

# Sparkle is a binary framework resolved by SwiftPM, so it exists only after the
# package declares it. Copying it with ditto rather than cp -R is what preserves
# the symlinked Versions layout that makes it a valid framework bundle.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$BIN/Sparkle.framework" ] || {
  echo "error: Sparkle.framework is not in $BIN — the app would launch without" >&2
  echo "       an updater, or not launch at all. Declare Sparkle in Package.swift" >&2
  echo "       and run: swift package resolve" >&2
  exit 1
}
ditto "$BIN/Sparkle.framework" "$SPARKLE"
# Unbury is not sandboxed. Sparkle's XPC services exist only to cross a sandbox
# boundary, so keeping them ships two executables and two signatures that can
# never be used — and every one of them is another way notarisation can fail.
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Unbury</string>
  <key>CFBundleDisplayName</key><string>Unbury</string>
  <key>CFBundleIdentifier</key><string>com.migsilva.unbury</string>
  <key>CFBundleExecutable</key><string>Unbury</string>
  <key>CFBundleIconFile</key><string>Unbury</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Miguel Silva</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$PUBLIC_ED_KEY</string>
  <!-- Refuse a feed that is not itself signed, not just a signed download.
       Without this, anybody who can serve the feed's address can rewrite the
       list of versions; it is also what makes generate_appcast sign the feed. -->
  <key>SURequireSignedFeed</key><true/>
  <!-- Sparkle refuses to start at all unless this is on beside the line above:
       a signed list of versions is worthless if the download it names is only
       checked after being unpacked. Leaving it out cost one release. -->
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <!-- Ask before installing, and never send a profile of the person's Mac. -->
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SUSendProfileInfo</key><false/>
</dict>
</plist>
PLIST

# Signing, and why it matters before there is any release to make: the Keychain
# grants access to a *signature*, not to a path. Ad-hoc signing produces a new
# identity on every build, so every build asks for the key again. Signing with
# the same Developer ID each time means the person is asked once, ever.
IDENTITY="${VAULT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}"

if [ -n "$IDENTITY" ]; then
  # A real identity gets Apple's secure timestamp: notarisation rejects any
  # signature without one, and nothing re-signs the framework later.
  TIMESTAMP="--timestamp"
else
  IDENTITY="-"
  TIMESTAMP="--timestamp=none"
fi

# Order is the whole trap. An embedded framework must be sealed before the app
# that contains it: sign the app first and its signature seals a Sparkle that is
# then modified, so notarisation fails with a message that never says "Sparkle".
# Inside out — the framework's own executables, the framework, then the app.
# `unburyctl` is sealed as a symlink by the app signature; signing it would
# follow the link and re-sign the app executable under the wrong identity.
for NESTED in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app"; do
  if [ -e "$NESTED" ]; then
    codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$NESTED"
  fi
done
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$SPARKLE"
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP"

if [ "$IDENTITY" = "-" ]; then
  echo "signed ad hoc — the Keychain will ask again after every build"
else
  echo "signed as: $IDENTITY"
fi
codesign --verify --deep --strict "$APP" && echo "signature ok"

echo "built $APP"
