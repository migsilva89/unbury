# Third-party software

Unbury is [MIT](LICENSE). It links, and in one case ships, the following. All of them are
permissive licences compatible with distributing this app under MIT — there is no copyleft
dependency in the tree, and adding one would change what Unbury itself may be released as.

## Shipped inside the app bundle

**[Sparkle](https://github.com/sparkle-project/Sparkle)** 2.9.6 — the updater. MIT, with
several BSD- and MIT-licensed components of its own (bsdiff, bspatch, and others) covered by
the "External licenses" section of its LICENSE file. `Sparkle.framework` is copied into
`Unbury.app/Contents/Frameworks`, so its licence travels with every build; the copy inside
the framework is the authoritative text.

Copyright (c) 2006–2013 Andy Matuschak, and the other holders named in its LICENSE.

## Linked at build time

| Package | Licence |
| --- | --- |
| [postgres-nio](https://github.com/vapor/postgres-nio) | MIT |
| [swift-nio](https://github.com/apple/swift-nio), swift-nio-ssl, swift-nio-transport-services | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections), swift-algorithms, swift-async-algorithms | Apache-2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics), swift-system, swift-log, swift-metrics, swift-asn1 | Apache-2.0 |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | Apache-2.0 |

The Apache-2.0 packages require their notice to be carried with a distribution; this file is
that notice, and each package's own LICENSE is in `app/.build/checkouts` after a build.

`postgres-nio` and everything under it are there for one thing only: `unburyctl sync`, which
pulls a library from a Postgres database on another machine. The app itself never opens a
database — it reads two files on your Mac. If that command is ever dropped, most of this
table goes with it.
