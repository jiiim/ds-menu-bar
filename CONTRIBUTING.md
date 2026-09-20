# Contributing to DS Menu Bar

Thanks for your interest. This is a small, single-maintainer project, and what
follows is simply what makes a pull request mergeable without a round trip.

DS Menu Bar is MIT licensed and will stay MIT. There is no CLA and no sign-off
to add: opening a pull request is taken as offering your contribution under
that license.

## Before opening a pull request

All of these must pass, and CI runs them too:

```sh
swift test
reuse lint
./scripts/check-copyright.sh
./scripts/check-commit-attribution.sh main..HEAD
```

The last two enforce the rules below, so you can see a problem before review
rather than after. Keep your branch rebased on `main` rather than merging
`main` into it.

## Commits

- Conventional Commits: `type(scope): imperative summary`, scope optional
- Subject 72 characters or less, no trailing period
- Wrap the body at 72 characters
- Explain why, not what — the diff already says what

### No AI or agent attribution

A commit must not attribute any part of itself to an AI tool, model, or
vendor, whether in the subject, the body, or a trailer. CI rejects
`Co-authored-by:`, `Assisted-by:`, `Generated-by:`, `Written-by:`,
`Created-by:`, the phrase "Generated with", and the 🤖 emoji that assistants
add to generated messages.

Using an assistant to write code is fine and needs no disclosure. The commit
record names the people accountable for a change, and a tool is not one of
them.

A pull request whose commits carry such a line cannot be merged as it stands,
and the line cannot be removed for you without rewriting your commit. Drop it
with `git commit --amend` or an interactive rebase, then force-push to your
branch — the pull request updates in place.

## New files

Every file needs licensing information. Source files carry the header
verbatim:

```swift
// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT
```

Use the same two lines with `#` comments in shell scripts and YAML. A file
that cannot carry comments goes in the `path` list in `REUSE.toml` instead.

Copy that notice unchanged; do not substitute your own name. The tree uses one
notice throughout so that no file reads as an exception, and the About window
credits contributors by linking to the contributors graph, which stays current
without anyone editing a file to claim it.

## How pull requests are merged

Rebase merge. Your commits keep you as author, the maintainer is recorded as
committer, and `main` stays linear.

If this is your first contribution, CI will not start until the maintainer
approves the workflow run. That is a GitHub default for pull requests from
forks, not a comment on your patch.
