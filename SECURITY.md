# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub's ["Report a vulnerability"](../../security/advisories/new)
button. Expect an acknowledgement within seven days. Once the issue is confirmed and fixed,
the release notes will credit the reporter, unless anonymity is preferred.

## What is worth reporting

Unbury holds your library in two files on your own Mac, and your API key in the macOS
Keychain. The parts most worth a second pair of eyes are:

- anything that could read a key out of the Keychain, or write one into a file
- anything that sends a URL, a title or a description somewhere it was not meant to go
- the update path: releases are signed with an EdDSA key and a build that is not the
  owner's should be refused rather than installed

## Supported versions

Only the latest release receives security fixes.
