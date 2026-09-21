#!/bin/bash
# SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
# SPDX-License-Identifier: MIT

# Verify the app users actually receive: the copy inside the disk image, not
# the build-directory copy it was made from.

set -euo pipefail

if (( $# != 5 )); then
    echo "usage: $0 DMG APP_NAME IDENTIFIER VERSION BUILD_NUMBER" >&2
    exit 64
fi

dmg=$1
app_name=$2
identifier=$3
version=$4
build_number=$5

if [[ ! -f "$dmg" ]]; then
    echo "DMG not found: $dmg" >&2
    exit 66
fi

work_dir=$(mktemp -d -t ds-menu-bar-verify.XXXXXX)
mount_dir="$work_dir/mount"
device=
staged_dir=

# One trap. A second `trap ... EXIT` replaces this rather than adding to it,
# which previously left the image attached and the staged copy on disk.
cleanup() {
    if [[ -n "$device" ]]; then
        hdiutil detach -quiet "$device" || true
    fi
    if [[ -n "$staged_dir" ]]; then
        rm -rf -- "$staged_dir"
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -p -- "$mount_dir"

device=$(hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$mount_dir" \
    "$dmg" | awk '/Apple_HFS/ { print $1; exit }')

if [[ -z "$device" ]]; then
    echo "could not determine the mounted disk-image device" >&2
    exit 1
fi

app_path="$mount_dir/$app_name"
plist_path="$app_path/Contents/Info.plist"

# Contents: the app, the drag-to-Applications link, and the Finder layout.
test -d "$app_path"
test -L "$mount_dir/Applications"
test -f "$mount_dir/.DS_Store"

executable_path="$app_path/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$plist_path")"

test "$(plutil -extract CFBundleIdentifier raw "$plist_path")" = "$identifier"
test "$(plutil -extract CFBundleShortVersionString raw "$plist_path")" = "$version"
test "$(plutil -extract CFBundleVersion raw "$plist_path")" = "$build_number"
test "$(lipo -archs "$executable_path")" = arm64

codesign --verify --deep --strict --verbose=2 "$app_path"

signature=$(codesign --display --verbose=4 "$app_path" 2>&1)
printf '%s\n' "$signature"

# Notarization requires the hardened runtime; check it rather than infer it.
# Matched in a variable, not through a pipe: grep -q exits early and the
# resulting SIGPIPE would fail the script under pipefail.
if [[ "$signature" != *"flags="*"runtime"* ]]; then
    echo "app is not signed with the hardened runtime: $app_path" >&2
    exit 1
fi

# `spctl` is NOT authoritative and must never be the notarization gate. It
# reported "accepted / source=Notarized Developer ID" for v0.0.5 and v0.0.6,
# whose apps carried no stapled ticket, while macOS refused to open them with
# "Apple could not verify this app is free of malware". Kept only as context
# in the log; `syspolicy_check` below is what decides.
spctl --assess --type execute --verbose=4 "$app_path" || true

# Apple's own pre-distribution check. This is the one that catches a missing
# notarization ticket, which is invisible to codesign and to spctl.
if ! syspolicy_result=$(syspolicy_check distribution "$app_path" 2>&1); then
    printf '%s\n' "$syspolicy_result" >&2
    echo "app inside the image failed syspolicy_check: $app_path" >&2
    exit 1
fi
printf '%s\n' "$syspolicy_result"
if [[ "$syspolicy_result" != *"ready for distribution"* ]]; then
    printf '%s\n' "$syspolicy_result" >&2
    echo "app inside the image is not ready for distribution" >&2
    exit 1
fi

# The ticket must be stapled to the APP, not merely to the image. An app copied
# out of the DMG -- by Homebrew, or by dragging it to Applications -- leaves the
# image behind, and with it any ticket stapled only to the image. Gatekeeper
# then has to resolve one online at launch, which macOS 26 treats as fatal.
if ! xcrun stapler validate "$app_path"; then
    echo "no notarization ticket is stapled to the app itself: $app_path" >&2
    echo "staple the app before building the image; see release-process.md" >&2
    exit 1
fi

# Verify the state the user actually runs: copied out of the image, carrying
# the quarantine flag a download or a Homebrew install applies. The checks
# above all passed for v0.0.6 in its in-image state; this is the one that
# reproduces what broke.
staged_dir=$(mktemp -d "${TMPDIR:-/tmp}/verify-dmg-staged.XXXXXX")
ditto "$app_path" "$staged_dir/$app_name"
xattr -w com.apple.quarantine \
    "0081;$(printf %x "$(date +%s)");Safari;$(uuidgen)" \
    "$staged_dir/$app_name"

if ! staged_result=$(syspolicy_check distribution "$staged_dir/$app_name" 2>&1) \
    || [[ "$staged_result" != *"ready for distribution"* ]]; then
    printf '%s\n' "$staged_result" >&2
    echo "app fails once copied out of the image under quarantine" >&2
    echo "this is the state users install into" >&2
    exit 1
fi
printf 'post-install state: %s\n' "$staged_result"
xcrun stapler validate "$staged_dir/$app_name"
