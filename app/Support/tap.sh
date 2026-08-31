#!/bin/bash
# Points Homebrew at the release that was just published.
#
#   Support/tap.sh            the version in build/Unbury.app
#   Support/tap.sh 0.1.2      that one
#   Support/tap.sh --check    say what Homebrew is handing out, change nothing
#
# `brew install --cask migsilva89/unbury/unbury` reads one file in another
# repository — Casks/unbury.rb in migsilva89/homebrew-unbury — and that file
# names a version and the checksum of its disk image. Publishing a release on
# GitHub does not touch it, so until this runs Homebrew keeps installing the
# previous version while the site and the in-app updater offer the new one.
#
# The checksum is taken from the asset as GitHub serves it, never from the local
# build/ copy, because those are the bytes somebody's brew will download and
# compare. And it is the PLAIN image, never the `-update` one: that copy exists
# only so the update counter stays separate, and a cask pointing at it would put
# every brew install back into the updates column.

set -euo pipefail
cd "$(dirname "$0")/.."

TAP="migsilva89/homebrew-unbury"
CASK="Casks/unbury.rb"

step() { printf '\n\033[1;35m▸ %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

command -v gh >/dev/null || die "gh is not installed — brew install gh"

# Through the API rather than raw.githubusercontent, which serves a cached copy
# for a few minutes and would report the old version right after a push.
cask_text() { gh api "repos/$TAP/contents/$CASK" -H "Accept: application/vnd.github.raw"; }
cask_version() { cask_text | sed -n 's/^ *version "\(.*\)"/\1/p'; }

built_version() {
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
		build/Unbury.app/Contents/Info.plist 2>/dev/null
}

# ------------------------------------------------------------------- check

if [ "${1:-}" = "--check" ]; then
	HERE="$(built_version)" || die "nothing built — run ./build.sh first"
	THERE="$(cask_version)"
	if [ "$HERE" = "$THERE" ]; then
		echo "Homebrew installs $THERE, same as this tree"
	else
		printf '\033[1;33m! Homebrew installs %s; this tree is %s — run Support/tap.sh\033[0m\n' \
			"$THERE" "$HERE"
		exit 1
	fi
	exit 0
fi

VERSION="${1:-$(built_version)}"
[ -n "$VERSION" ] || die "no version given and nothing built — run ./build.sh first"
DMG="Unbury-$VERSION.dmg"

# --------------------------------------------------------------- the release

step "the release"
gh release view "v$VERSION" --json assets --jq '.assets[].name' 2>/dev/null \
	| grep -qx "$DMG" \
	|| die "v$VERSION has no $DMG attached — publish the release first, see docs/RELEASING.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/$DMG" \
	"https://github.com/migsilva89/unbury/releases/download/v$VERSION/$DMG"
SHA="$(shasum -a 256 "$TMP/$DMG" | cut -d' ' -f1)"
echo "$DMG · $(du -h "$TMP/$DMG" | cut -f1) · $SHA"

# ------------------------------------------------------------------ the cask

step "the cask"
git clone --quiet --depth 1 "https://github.com/$TAP.git" "$TMP/tap"

# Only the two lines that change every release. Everything else in the cask —
# what it depends on, what it links, what `brew zap` removes — is written once
# and left alone, so a mistake here cannot quietly drop any of it.
python3 - "$TMP/tap/$CASK" "$VERSION" "$SHA" <<'PY'
import re, sys
path, version, sha = sys.argv[1:4]
text = open(path).read()
for key, value in (("version", version), ("sha256", sha)):
	pattern = rf'^(  {key} ")[^"]*(")$'
	text, count = re.subn(pattern, rf'\g<1>{value}\g<2>', text, flags=re.M)
	assert count == 1, f"expected one {key} line in the cask, found {count}"
open(path, "w").write(text)
PY

if git -C "$TMP/tap" diff --quiet; then
	echo "already $VERSION — nothing to push"
	exit 0
fi

git -C "$TMP/tap" commit --quiet -am "unbury $VERSION"
git -C "$TMP/tap" push --quiet origin main
echo "pushed"

# ------------------------------------------------------------------- confirm

step "confirm"
[ "$(cask_version)" = "$VERSION" ] \
	|| die "pushed, but the tap still serves $(cask_version) — check $TAP by hand"

printf '\033[1;32m✓ brew install --cask migsilva89/unbury/unbury now gives %s\033[0m\n' "$VERSION"
echo "  try it: brew update && brew upgrade --cask unbury"
