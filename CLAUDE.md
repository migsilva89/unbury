# unbury — context for agents

Unbury is a Mac app. You ask it a question in plain language and it answers with the
links you saved, each with a line saying what it is. It searches by meaning, so you
find a link without remembering what it was called.

Everything below was decided deliberately, and every number in it was measured
rather than assumed. **Read this before changing anything.** A decision recorded
here can be overturned — but knowing what it cost to reach is cheaper than
rediscovering it.

## The three questions it must answer

If a change does not help one of these, it is out of scope.

1. **Topic + time** — "what did I save this month about AI agents?"
2. **A concrete need** — "that 3D-printed part for the Pavo 20", when you remember
   what a link *was* but not what it was *called*.
3. **Similar to this** — "did I already have something like this?"

A fourth was cut: "what have I not opened yet". A browser's bookmarks file has no
visit history, so there is no data for it. **Do not add an "unopened" feature.**

## Where things live now

**Everything is local.** The vault is two files in
`~/Library/Application Support/Unbury`: `vault.json`, which a person could read, and
`vectors.bin`, a flat block of 32-bit floats. Around 3 MB for 624 links. Settings
live beside them; the OpenRouter key and any password live in the Keychain.

**The app was called Vault until 2026-08-27.** The rename went end to end: bundle
`com.migsilva.unbury`, executable and command `unburyctl`, data directory, Keychain
service `com.migsilva.unbury`. Two pieces of code carry people across from the old
name — `UnburyStore.defaultDirectory`, which moves a `Vault` data folder to `Unbury`
on first launch, and `Keychain.swift`, which reads the old service when the new one is
empty. **Do not delete either migration.**

This is a change from the first day, and the reason matters. The vault began as
Postgres with pgvector on a Raspberry Pi, so that a chat agent could write to it.
That made every screen harder: somebody installing the app has no Pi, and buttons
about pulling from one meant nothing to them. **The Pi is gone from the app.** It
survives only as `unburyctl sync` on the command line, for anyone who runs one.

Search needs no index at any size worth having. Comparing a question against 623
vectors takes **1.3 ms** in a release build; ten thousand would still be milliseconds.
The wait a person feels is the second or so spent asking OpenRouter for the
question's vector, never the ranking.

## Two rules that are easy to get wrong

**Vectors are 1024 dimensions.** `qwen/qwen3-embedding-8b` produces 4096 natively;
we ask for 1024 through the `dimensions` parameter. Changing this means re-importing
everything, because numbers made at one size cannot be compared with another's.

**Search queries carry an instruction prefix; stored records do not.** Qwen embedding
models expect `Instruct: <task>\nQuery: <question>` on the query side. Without it the
scores bunch together — measured, the wrong link won at 0.59 against 0.46. With it,
the right link scores 0.60 and the runner-up drops to 0.37. `embedQuery` handles
this, `embed` is the bare one. **Do not merge them.**

## The shape of the store

Everything the interface asks of the vault goes through these, and they are the reason
no screen has to hold the whole library in memory:

- `search(vector:within tags: [String] = [], limit:)` — tag narrowing is an ARRAY, and
  it is AND: a record must carry all of them. Never a single optional tag again.
- `recent(limit:tagged tags: [String] = [])`
- `page(tagged:offset:limit:) -> Page { bookmarks, offset, total, hasMore }` — the only
  correct way to show a list. Anything unbounded is a hang waiting to happen.
- `bookmark(url:)` and `bookmarks(urls:)` — identity by address. This is how Ask Unbury points
  at the records it cited; re-running a search to find a link you already have is what
  made "show in results" find nothing.
- `reconcileBrowser(profiles:urls:noticedOn:) -> BrowserSweep { gone, returned, claimed }`

## The models, and the money

- **Vectors**: `qwen/qwen3-embedding-8b`, $0.01/M tokens. Picked over OpenAI's
  `text-embedding-3-small` because questions here get asked in one language about
  links titled in another, and Qwen is genuinely multilingual. Half the price too.
- **Descriptions and tags**: `moonshotai/kimi-k2`, in English. English for tags first
  (no `ia`/`ai` splitting one drawer in two) and then for descriptions, to keep one
  language. He still asks in Portuguese; Qwen bridges it.

**Never change a paid model without asking the owner.** The first 461 links were
described with `claude-sonnet-5`, inherited unquestioned from another project, and
cost $1.60 of a $15 balance. The replacement was chosen by running
the same four bookmarks through four models and reading the output beside the measured
cost — `compare_models.py` still does this. All 623 cost $0.42 with Kimi against $2.30
with Sonnet.

Rejected, with reasons worth keeping: `google/gemini-3.7-flash` returned malformed
JSON on one bookmark in four; `google/gemini-2.5-flash-lite` is cheaper again but
opens every description with "This page is…", and identical boilerplate across 623
vectors makes records look more alike than they are.

His key has had a spending cap on it twice, which reads as a broken app rather than a
setting. `VaultError.explain` turns OpenRouter's statuses into sentences that name the
fix; keep it that way and never show raw JSON.

## How links get in

The browser is an inbox, not the list. You save a link while browsing, then import
by hand — **no watcher, no scheduler, decided deliberately.**

`Importer` does it natively: fetch the page, have Kimi say what it is, embed that,
store it. It saves in batches of ten so stopping halfway never throws away work
already paid for. The browser is never written to.

The import sheet shows what it will do *before* it does it: which profiles exist,
which links are new, and roughly what they cost. The first version started the moment
it opened, which spends someone's money on their behalf.

Around a third of links have no preview picture and never will — some sites serve a
JavaScript shell with no preview tags. **That is a designed state, not a failure.**
YouTube is a special case: its thumbnail address is derived from the video id.

**Deleting a bookmark in the browser does not delete it here.** The record stays,
flagged as no longer present, and still appears in searches carrying a quiet grey note.
Losing something because a browser tidied up is worse than keeping a stale row.
`Importer.sweep(profiles:into:)` runs after an import and only ever judges the profiles
it actually read — widening it to the whole vault would flag every link from every other
profile as missing. `Bookmark.isGoneFromBrowser` is what the interface reads.

## Tags reuse an existing name before inventing one

The first library drifted badly: 1048 tags for 624 links, 688 of them used exactly
once, with `drone`/`drones` and `tailwind`/`tailwind-css`/`tailwindcss` splitting one
drawer into three. The cause was that every link was tagged blind — the model was
never shown what it had already used.

Two defences now, and the pair is what works:

**The vocabulary rides along.** `describe` takes a `known:` list — the tags already in
the vault, most used first, capped at 200 — and is told to reuse one verbatim before
coining a variant. The cap exists because that list is paid for in every request; 200
costs roughly $0.15 across 600 links.

**A local snap catches the rest, for nothing.** `Importer.settle` reduces a tag to its
bare shape (letters and digits, no trailing plural) and, when that shape already exists
in the vault, uses the stored spelling instead. It compares against the whole
vocabulary, not just the 200 that were sent.

Measured on the re-import: **423 tags for 627 links, 219 used once** — against 1048 and
688 before. **Re-analysing links already stored costs real money and needs the
owner's explicit go-ahead every time.**

## The interface

Four tabs — Ask Unbury, Search, Library, Settings — implemented from a Claude Design project
kept in `design/Unbury.dc.html`. The mark in the header is `UnburyMark`, drawn in code
(an octagon minus an aperture minus four slits) — a camera iris, teal on near-black,
matching the app icon. It is no longer a bookmark ribbon.

**The first screen is the vocabulary, not a list of links** (`Vocabulary.swift`). Tags
sized by how many links they hold, alphabetical, outlined only on hover and when chosen;
a "find a tag" field that filters the whole vocabulary locally; and a line offering five
of the tags that hold a single link. Every tag must be reachable without a paid search —
browsing your own collection cannot be something you pay for. The old "recently saved"
list is gone.

**Choosing tags narrows, and several at once.** `AppModel.scope` is a set, AND across
them, shown as removable chips beside the field with "clear all", and the cloud collapses
to the tags still reachable from where you are. A tag with 500 links must never print
500 rows.

**Search does not run while you type, and the screen never lies about what it shows.**
There was a 380 ms debounce; half a sentence is a different question in a search by
meaning, so it runs only on Return or the round button — **do not put the debounce back.**
The subtler half: when the field no longer matches the results beneath it, the match
count and score disappear, the list dims and is labelled with the question it actually
answers. A screen that says "12 matches · 0.68" over text nobody asked reads as a search
that fired on its own.

**It admits defeat.** A right answer scores about 0.60 here; unrelated records cluster at
0.44–0.47. That gap is narrow, so an absolute cut-off alone waves seventeen near-misses
through behind one good hit. The rule is *relative*: keep only results within 12% of the
best, and only if the best clears 0.45. When nothing clears it, the screen says what the
best score was and offers three weak matches on request. **A search tool that always
returns something cannot be trusted.**

**Ask Unbury is not one of the tabs.** It was called Ask, briefly Dig — rejected as too
short and too quiet — and is now "Ask Unbury", standing OUTSIDE the tab group as its own
outlined button carrying `UnburyMark`, while Search and Library stay a quiet pair in
their box. Accent outline, never a filled plate: filled accent belongs to the single
primary action of whatever screen you are on, and spending it on navigation would leave
every screen carrying two. The enum case is `.ask` and its `rawValue` stays a lowercase
identifier for the test channel; `Tab.label` is the only thing a person reads, because
"Ask Unbury" has a space and could never be a raw value. The types are `AskView` and
`AskEngine` and stay that way — nobody sees a type name, and a half-done rename across
five files is worse than none. The channel accepts `ask`, and still `dig`.

**Ask Unbury holds the search, and is watched doing it.** The model is never handed results; it
calls the search itself and rephrases when the first attempt is weak. Every search and
everything that came back stays in the transcript, and the evidence panel separates what
carries the answer from what was read and not used. Conversations are kept — an index
appended a line at a time, one file per conversation, beside the vault and never inside
it — with a sidebar, "new conversation", and delete. Read-only means Ask Unbury never changes a
link; it does not mean it forgets.

**Every panel that opens closes by a worded control.** `DetailDrawer(closeLabel:onClose:)`
is shared by Search and Ask Unbury. `esc` stays as a second route and calls the same `goBack()`
the buttons do, so the key and the buttons can never disagree. An earlier Ask screen was
rejected outright for having four competing navigation systems and no exit but a bare
"esc" hint.

**Time phrases are stripped before embedding.** "last month" is a filter, not meaning.

**Settings is a full page of panels**, three columns wide, two on a laptop, one when
narrow — not a form floating in a black window. It owns the choice of engine; the browser
picker was deliberately removed and must not come back.

**Type is 15% larger everywhere**, from one number: `Theme.typeScale`.

**Accent colour has one hierarchy**: filled accent for the single primary action of a
screen, accent as text or outline for a strong match and for what is selected, grey for
everything else. Never the same colour meaning two things on one screen.

**Two things that look like bugs and are the system.** macOS 26's scroll edge effect is
switched off with `.noScrollEdge()`, and the focus ring with `.focusEffectDisabled()` on
the root view. **Do not restore either.** The keys strip appears only under Search, where
those keys are true.

## Why lists are capped, and how it was measured

A hang report showed the main thread frozen 14 seconds inside SwiftUI's lazy stack
layout. Four separate causes were found by measuring, not by reading:

- **Work inside `body`.** Every tag chip re-sorted the whole 423-tag vocabulary to decide
  its own size, and hover lived on the parent — one pointer move re-sorted fifty times and
  re-laid the entire cloud. Sizes are computed once; hover belongs to each chip.
- **Previews decoded at full size on the main thread.** A 1200×630 image drawn at 48pt.
  ImageIO now decodes straight to thumbnail size, off the main thread: 4159 ms → 788 ms.
- **A `Task` per row, made and cancelled on every realisation.** 77 s against 47 s over
  200 rows. Rows that already have their picture, or are known to have none, start nothing.
- **Image fetches on `URLSession.shared`**, the same session as the question — a dozen slow
  sites queued ahead of the search, which then appeared to hang forever. Pictures have
  their own session.

And the structural one: **a `LazyVStack` realises rows as you pass and never releases
them**, so cost grows with everything scrolled past, not with what is on screen. Measured
knee: 120 rows is a full traversal with 0 of 537 frames over budget; 160 rows drops 180 of
672; 627 does not finish in ten minutes. Hence `pageSize` 40 and a **ceiling of 120**, with
a line saying a list that long is not how you find anything. **Do not raise the ceiling
without re-measuring.**

## Who answers in Ask Unbury

`Preferences.chatEngine` is one of `claude-code`, `codex`, `openrouter`, with
`Preferences.chatModel` mattering only for the last. `ChatEngines.available()` lists the
engines actually installed on this machine — never offer one that is not there. Codex
needed real fixing to answer at all: it inherited the app's stdin and waited forever for
a line that never came, and it ran from `/`.

**The word "free" appears nowhere in this app, deliberately.** It is a lie in both
directions: Claude Code and Codex are not free, they spend a subscription somebody
already pays for. Say what is true instead — browsing and filtering never leave the Mac; pressing
Return sends the question to OpenRouter to be vectorised, real but thousandths of a cent;
asking and importing are the costly ones, and both say what they will cost first.

## Testing without clicking

The app watches for a file at `~/Library/Application Support/Unbury/snapshot-please`
and writes its answer beside it. Commands: `ask <question>`, `search <text>`,
`type <text>` (fills the field WITHOUT searching, which is what typing does),
`tab ask|search|landscape|settings`, `size <w>x<h>`, `tag <name>`, `findtag <text>`,
`select <n>`, `more`, `scroll <points>`, `scrollat <percent>`, `import`, `settings`,
`close`, or a `.png` path, which makes the app photograph its own window. It exists because screen capture from
outside needs a permission that belongs to the person, not to an agent.

`unburyctl` is the same engine on the command line — `search`, `import`, `browsers`,
`status`, `sync`. When the app misbehaves, this tells you whether the engine or the
interface is at fault. The chat engines also use it: Claude Code and Codex already
know how to run a command, so the search tool is a command rather than a protocol.

## Building and releasing

`./build.sh` assembles and signs `Unbury.app`. **Signing matters before any release:**
the Keychain grants access to a signature, and ad-hoc signing makes a new one every
build, so the person is asked for their key again every time.

`./release.sh <version>` builds, signs, makes the DMG, notarises and staples it.
Signing alone is not enough — without notarisation macOS says the app "is damaged",
which reads as a broken download rather than a missing stamp.

## Working on this

- **Never commit without being asked.** Signing, releasing and publishing are the
  owner's calls, not an agent's.
- **Everything written into this repository is in English** — commit messages, branch
  names, comments, documentation and the app's own words. Conversation about it may
  happen in another language; the record does not.
- **UI work is done by several agents at once**, each owning a disjoint list of files
  and building with its own `swift build --scratch-path .build-<name> --product Unbury`.
  One shared `.build` directory and two agents editing one file both end badly.
- The window minimum is 720x520, low enough that the layouts which adapt below 820pt
  can actually be reached.
