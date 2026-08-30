# Contributing

Thanks for taking an interest — this document exists so that time spent on a contribution
is not wasted.

## What this project is, and is not

Unbury answers three questions about the links you have already saved: what did I keep
about a topic in a period, what was that thing I remember but cannot name, and do I already
have something like this. A change that does not help one of those three is out of scope,
however well written.

Some things are deliberately absent and will stay absent. There is no watcher or scheduler
that imports on its own, because spending someone's money without them pressing anything is
not a feature. There is no "links I have not opened yet", because a browser's bookmarks file
records no visit history and the number would be invented. Nothing here writes to your
browser, ever.

`CLAUDE.md` in the root is the long version: what every decision cost to reach, and which
numbers were measured rather than guessed. Read it before proposing anything structural — it
will tell you whether an idea has already been tried and why it was dropped.

## Reporting a bug

Open an issue with:

- what happened, and what you expected instead
- the steps to reproduce it
- the version (Unbury → About Unbury, or the number at the top of Settings) and your macOS
  version

If the app misbehaves, `unburyctl status` and `unburyctl search "something"` in a terminal
say whether the fault is in the engine or in the interface. That answer saves a round trip.

## Suggesting a feature

Open an issue describing the problem before writing code. A feature that does not fit the
scope above will be declined however good the implementation, and that is a waste of an
evening.

## Setting up

You need macOS 14 or later and a Swift 6 toolchain (Xcode 16 or the Swift toolchain alone).

```bash
git clone https://github.com/migsilva89/unbury.git
cd unbury/app
swift build --product Unbury      # or ./build.sh to assemble Unbury.app
```

`./build.sh` produces a signed `build/Unbury.app`. Without a Developer ID it signs ad-hoc,
which works on your own machine and nowhere else — that is expected, not a bug.

Running the app for real needs an API key from [OpenRouter](https://openrouter.ai/keys),
entered in Settings. It goes into the macOS Keychain and never into a file.

## Pull requests

- One change per pull request.
- Explain the why in the description; the what is in the diff.
- Match the surrounding style rather than introducing a new one. The comments in this
  codebase say *why* a thing is the way it is, not what the line does — please keep that up.
- Anything that changes a measured number (list sizes, thresholds, dimensions) needs a new
  measurement in the description, not an assertion.

## Is this production-ready?

It is a personal tool that other people are welcome to use. It is signed, notarised and
works, but it is version 0.x: settings, the store format and the command line may still
change between releases. Contributions are accepted and read; response times are whenever
there is an evening free.
