# Releasing Unbury

How a `.dmg` somebody else can open gets made, and how an installed copy learns
that a newer one exists. Everything happens on one Mac — there is no CI, and no
signing key ever enters this repository.

## Once, on the machine that builds

```bash
cd app && swift package resolve
```

That fetches Sparkle, the framework that checks for updates, and with it the
command-line tools this release uses — they live in
`app/.build/artifacts/sparkle/Sparkle/bin` and are not in the repository.

## Once, for Apple

A Developer ID certificate in the login keychain. Confirm it is there:

```bash
security find-identity -v -p codesigning
```

Use the line that starts `Developer ID Application:` — that is your own signing
identity, and the ten-character code in brackets at the end of it is your team id.
The scripts find this line themselves, so it is never written down here.

Then store the notary credentials under a profile name. This is an Apple ID, a
team id, and an **app-specific password** — not the account password. Generate
one at appleid.apple.com › Sign-In and Security › App-Specific Passwords.

```bash
xcrun notarytool store-credentials imark \
  --apple-id you@example.com --team-id <your-team-id> --password <app-specific-password>
```

`imark` is the profile name this Mac already uses across the owner's apps, and it
is what `release.sh` reaches for by default. On a machine where it is called
something else, set `UNBURY_NOTARY_PROFILE`.

## Once, for updates

Sparkle has a second key, unrelated to Apple's. Apple's proves who built the
app; this EdDSA key proves the downloaded disk image and its feed are the exact
files published for Unbury. Its private half is already in the login keychain
under the account `unbury` and must never be written to a file. Only its public
half is in the app, as `SUPublicEDKey` in `app/build.sh`.

Confirm the two still agree:

```bash
cd app && .build/artifacts/sparkle/Sparkle/bin/generate_keys --account unbury -p
```

That must print the same string as `PUBLIC_ED_KEY` in `app/build.sh`.

**Never generate a replacement because the key looks missing.** A new, unrelated
key makes every copy already installed reject every future update, silently and
permanently. Restore the private key, or follow Sparkle's key-rotation
procedure.

## Every release

```bash
cd app && ./release.sh 0.2.0
```

That builds, stamps the version, signs with the Developer ID, makes the disk
image, sends it to Apple, waits for the verdict, staples the ticket into the
image, and then writes the update feed. Notarisation is Apple looking at the
binary and takes a few minutes.

It leaves two files in `app/build/`:

- `Unbury-<version>.dmg` — signed, notarised and stapled
- `appcast.xml` — the signed feed, listing that one version

The signing order inside `build.sh` is not cosmetic. Sparkle is sealed first,
then `unburyctl`, then the app. Sign the app before the framework it contains
and the outer signature seals an inner one that then changes, and notarisation
fails with a message that never mentions Sparkle.

## Check it before it goes anywhere

```bash
spctl -a -vvv -t install app/build/Unbury-<version>.dmg
xcrun stapler validate app/build/Unbury-<version>.dmg
codesign --verify --deep --strict --verbose=2 app/build/Unbury.app
```

`spctl` should say `accepted` and `source=Notarized Developer ID`. Anything
else — `Unnotarized Developer ID` in particular — means it is not ready.

The last check is not a command: mount the image on a Mac that has never built
this app, drag it across, open it. Gatekeeper is only really tested elsewhere.

## Publishing

Nothing reaches anybody until both files are attached to one GitHub release:

```
gh release create v<version> \
  app/build/Unbury-<version>.dmg app/build/appcast.xml \
  --title "Unbury <version>" --notes "..."
```

The app reads the feed at
`https://github.com/migsilva89/unbury/releases/latest/download/appcast.xml`,
and the feed names the disk image by the address that tag gives it. Publishing
one file without the other offers people an update that cannot be downloaded.
`release.sh` prints the whole command at the end for this reason.

GitHub counts every download of the disk image, whether a person clicked it or
Sparkle fetched it on somebody's behalf. That count is the only measure of
whether a release reached anyone.
