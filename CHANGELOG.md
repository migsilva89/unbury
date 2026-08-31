# Changelog

Notable changes, newest first. Versions follow [semantic versioning](https://semver.org),
with the caveat that 0.x means the settings, the store format and the command line may still
change between releases.

## 0.1.1 — 2026-08-31

A maintenance release. Nothing in the app itself changed — if you are already on
0.1.0 there is nothing here to gain, and nothing lost by skipping it.

- The README now says what the app actually runs on: macOS 14 or later **on Apple
  Silicon**. The published build is arm64 only and the update feed always said so,
  so an Intel Mac was never offered it — but nothing told anyone before they
  downloaded.
- When Unbury fetches one of your saved pages to describe it, it now identifies
  itself as `Unbury/1.0` with a link to the site. It had been saying
  `BookmarksVault/1.0`, a name the app stopped using in August, which is what
  every site owner saw in their logs.
- Each release now carries the disk image twice, under the plain name and an
  `-update` name that only the updater fetches. They are the same file. It exists
  so that first installs and self-updates can be counted apart, which GitHub
  cannot do for a single asset.

## 0.1.0 — 2026-08-30

First release.

Ask a question in plain language and get back the links you already saved, each with a line
saying what it is. It searches by meaning, so a page can be found without remembering what it
was called.

- **Import from your browser.** Brave, Chrome, Arc, Edge and Vivaldi. The import sheet says
  which profiles it found, how many links are new and roughly what describing them will cost,
  before it starts. Your browser is never written to.
- **Search by meaning, not by words.** A question is turned into a vector and ranked against
  your library on your own Mac. When nothing is a confident match it says so and offers the
  weak ones on request, rather than always returning something.
- **Ask Unbury.** A model runs the search itself and rephrases when the first attempt comes
  back weak. Every search it ran and everything that came back stays in the transcript, and
  the evidence panel separates what carries the answer from what was read and set aside.
  It answers through Claude Code, Codex, or a model on OpenRouter — whichever you have.
- **Library.** What the collection is made of: how it grew, where it came from, and what you
  collect. Every bar can be clicked to see what it holds.
- **Your vocabulary is the home screen.** Every tag is reachable without a paid search.
- **Everything is local.** Two files in `~/Library/Application Support/Unbury`. Browsing and
  filtering never leave the machine; the key lives in the macOS Keychain, never in a file.
- **`unburyctl`** does the same work from a terminal: `search`, `import`, `browsers`,
  `status`, `sync`.

Requires macOS 14 or later. Signed and notarised.
