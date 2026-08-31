#!/bin/bash
# Signs one finished disk image and writes the Sparkle feed published beside it.
# The private EdDSA key stays in the login keychain under the `unbury` account;
# only its public half is in the app's Info.plist, written there by build.sh.
#
#   Support/appcast.sh build/Unbury-0.1.0.dmg
#
# The feed is what an installed copy reads to learn a newer version exists. It
# is useless on this machine: it and both disk images have to be attached to the
# GitHub release for this version before anybody is offered the update.
#
# It points at a SECOND copy of the same image, published under the `-update`
# name. Same bytes, same signature, different GitHub asset — which is the only
# way to tell an update apart from a first install, because GitHub counts
# downloads per asset and nothing else. The plain name is what the site and any
# future Homebrew cask link; the `-update` name is only ever fetched by an app
# updating itself.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APP="$ROOT/build/Unbury.app"
DMG="${1:-}"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE="$TOOLS/generate_appcast"
KEYS="$TOOLS/generate_keys"
OUTPUT="$ROOT/build/appcast.xml"

# The feed has to name the address the disk image will actually live at, and a
# GitHub release puts it under its own tag. Read the version from the bundle
# rather than an argument: release.sh has already stamped it there, so the two
# can never disagree.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
	"$ROOT/build/Unbury.app/Contents/Info.plist")"
DOWNLOAD_PREFIX="https://github.com/migsilva89/unbury/releases/download/v$VERSION/"
UPDATE_DMG="$ROOT/build/Unbury-$VERSION-update.dmg"

[ -n "$DMG" ] || { echo "usage: Support/appcast.sh <path to .dmg>" >&2; exit 1; }
[ -f "$DMG" ] || { echo "error: no disk image at $DMG" >&2; exit 1; }
[ -f "$APP/Contents/Info.plist" ] || {
	echo "error: $APP is not built — the feed is written from what actually shipped" >&2
	exit 1
}
[ -x "$GENERATE" ] || {
	echo "error: Sparkle's release tools are missing — run: swift package resolve" >&2
	exit 1
}

# The two halves of the update key have to be the same key. If they are not,
# every installed copy rejects this release as forged — and it does so silently,
# months from now, with no way to fix it after the fact.
EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
ACTUAL="$("$KEYS" --account unbury -p)"
[ "$ACTUAL" = "$EXPECTED" ] || {
	echo "error: the Sparkle key in the keychain does not match the one in the app" >&2
	echo "       keychain: $ACTUAL" >&2
	echo "       app:      $EXPECTED" >&2
	exit 1
}

# generate_appcast reads a whole directory of disk images, so it gets one that
# holds exactly this release and nothing else left over from an earlier build.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# Under the update name, so that is the address the generated feed carries.
ditto "$DMG" "$STAGE/$(basename "$UPDATE_DMG")"

"$GENERATE" \
	--account unbury \
	--download-url-prefix "$DOWNLOAD_PREFIX" \
	--link "https://unbury.migsilva.dev" \
	--maximum-versions 1 \
	--maximum-deltas 0 \
	-o "$STAGE/appcast.xml" \
	"$STAGE"

# Checked in the staging directory, so a feed that fails any of these is never
# left in build/ where the next step would happily upload it.
xmllint --noout "$STAGE/appcast.xml"
grep -q 'sparkle:edSignature=' "$STAGE/appcast.xml" \
	|| { echo "error: the update in appcast.xml is not signed — does the app in" >&2
	     echo "       the disk image carry SUPublicEDKey?" >&2; exit 1; }
grep -q '<!-- sparkle-signatures:' "$STAGE/appcast.xml" \
	|| { echo "error: appcast.xml itself is not signed — the app needs" >&2
	     echo "       SURequireSignedFeed in its Info.plist" >&2; exit 1; }
# Publishing a feed that names the plain image would put every self-update back
# into the same counter as the first installs, silently and for that whole
# release. Cheaper to refuse here than to notice a month later.
grep -q "$(basename "$UPDATE_DMG")" "$STAGE/appcast.xml" \
	|| { echo "error: the feed does not point at the update copy" >&2; exit 1; }

cp "$STAGE/appcast.xml" "$OUTPUT"
cp "$DMG" "$UPDATE_DMG"

echo "update feed → $OUTPUT"
echo "update image → $UPDATE_DMG"
