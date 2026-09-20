#!/bin/bash
# SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
# SPDX-License-Identifier: MIT

# Every copyright notice in the tree must read the same.
#
# `reuse lint` checks that a file *has* licensing information, not whose name
# is in it, so a contributed file carrying its own name passes lint and still
# breaks the one rule CONTRIBUTING.md asks contributors to follow.
#
# The notice carries no year, which is what makes detection awkward: with no
# year, "Copyright" is just a word that also occurs in prose *about* copyright.
# A notice is therefore recognised as the token followed by a capitalised name,
# which "the copyright line" in a comment is not. All three spellings 17 U.S.C.
# 401(b)(1) recognises are matched -- "Copyright", "Copr." and the symbol --
# plus the "(c)" that is common in practice though not in the statute.

set -euo pipefail

notice="Copyright James Martin and DS Menu Bar contributors"
symbol="© James Martin and DS Menu Bar contributors"
# Split so this script's own source does not match the header scan below.
marker="SPDX-File""CopyrightText"

status=0
fail() {
    printf '%s: %s\n' "$1" "$(printf '%s' "$2" | sed 's/^[[:space:]]*//')" >&2
    status=1
}

# Pass 1 — SPDX headers. Compared exactly; nothing wraps these.
# --untracked so a contributor running this before committing sees their new
# file; plain git grep only scans what is already staged or committed.
while IFS= read -r entry; do
    file="${entry%%:*}"; rest="${entry#*:}"; text="${rest#*:}"
    value="${text#*"$marker"}"
    case "$value" in
        ': '*)   value="${value#: }" ;;
        ' = "'*) value="${value# = \"}"; value="${value%\"}" ;;
        *)       value="unrecognised notice syntax:$value" ;;
    esac
    [ "$value" = "$notice" ] || fail "$file" "$value"
done < <(git grep -n --untracked "$marker" -- .)

# Pass 2 — notices in prose, markup and source strings: LICENSE, the README
# footer, the About window, Info.plist. These carry punctuation and markup
# around the notice, so flatten markdown links and tags, then require an exact
# match with nothing alphanumeric trailing. Substring matching alone would let
# an appended second holder through. LICENSES/ is excluded: its MIT template
# placeholder is the one notice that must not change.
while IFS= read -r entry; do
    file="${entry%%:*}"; rest="${entry#*:}"; text="${rest#*:}"
    case "$text" in *"$marker"*) continue ;; esac

    flat=$(printf '%s' "$text" \
        | sed -e 's/\[\([^]]*\)\]([^)]*)/\1/g' -e 's/<[^>]*>//g')
    case "$flat" in
        *"$notice"*) found="$notice" ;;
        *"$symbol"*) found="$symbol" ;;
        *) fail "$file" "$flat"; continue ;;
    esac
    trailing="${flat#*"$found"}"
    case "$trailing" in
        *[A-Za-z0-9]*) fail "$file" "$flat"; continue ;;
    esac
    # A second holder placed before the notice leaves nothing trailing, so
    # check what precedes it too. Ordinary prose may lead in ("[MIT
    # License](LICENSE). Copyright ..."); a second copyright token may not.
    if printf '%s' "${flat%%"$found"*}" \
        | grep -qE '(Copyright|Copr\.?|©|\(c\)|\(C\))'; then
        fail "$file" "$flat"
    fi
# A year between the token and the name is matched even though this project
# carries none: copying a year-bearing notice from another project is the
# likeliest way to get this wrong, and the rule is worth nothing if the most
# probable mistake is the one form that slips past.
#
# Deliberately case-sensitive on `Copyright`: the MIT warranty clause is
# all-caps and contains "COPYRIGHT HOLDERS BE LIABLE", so a case-insensitive
# scan false-positives on the license text in every file that embeds it. The
# word forms require a following space so that the SPDX marker's own
# "CopyrightText" does not read as a notice; the symbol does not.
#
# `(c)` is not one of the statutory spellings and collides with enumerated
# clauses -- "Under (c) The rule applies" is not a notice -- so it counts only
# when a year follows, which is how it is actually copied and how no list item
# is ever written. A bare `(c) Jane Doe` is the one form left uncaught.
done < <(git grep -nE --untracked \
             '((Copyright|Copr\.?)[[:space:]]+|©[[:space:]]*)([0-9]{4}([[:space:]]*-[[:space:]]*[0-9]{4})?[[:space:]]*)?[A-Z]|\([cC]\)[[:space:]]*[0-9]{4}([[:space:]]*-[[:space:]]*[0-9]{4})?[[:space:]]*[A-Z]' \
             -- . ':(exclude)LICENSES/')

if [ "$status" -ne 0 ]; then
    printf '\nEvery notice must read exactly:\n  %s\n  %s\n' "$notice" "$symbol" >&2
    printf 'See CONTRIBUTING.md, "New files".\n' >&2
fi

exit "$status"
