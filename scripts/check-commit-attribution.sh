#!/bin/bash
# SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
# SPDX-License-Identifier: MIT

# Commit messages must not attribute any part of a change to an AI tool,
# model, or vendor. People are the responsible parties.
#
# Assistants add these lines on their own, so a contributor can send one
# without ever deciding to. Catching it in CI is kinder than catching it at
# review, because the line cannot be removed on merge without rewriting the
# contributor's commit — it has to be fixed before the pull request lands.

set -euo pipefail

range="${1:?usage: check-commit-attribution.sh <git-range>}"

# The trailers and phrases tooling emits. This does not try to enumerate model
# names: the wrapper lines are what gets added automatically, and naming
# vendors would age badly and misfire on ordinary prose.
pattern='(co-authored-by|assisted-by|generated-by|written-by|created-by)[[:space:]]*:|generated with|🤖'

status=0
for sha in $(git rev-list "$range"); do
    if hits=$(git log -1 --format=%B "$sha" | grep -inE "$pattern"); then
        printf '%s %s\n' "$(git log -1 --format=%h "$sha")" "$(git log -1 --format=%s "$sha")" >&2
        printf '  line %s\n' "$hits" >&2
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    printf '\nRemove the attribution line with `git commit --amend` or an\n' >&2
    printf 'interactive rebase, then force-push. See CONTRIBUTING.md.\n' >&2
fi

exit "$status"
