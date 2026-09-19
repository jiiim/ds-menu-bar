#!/bin/bash
# SPDX-FileCopyrightText: Copyright 2026 James Martin
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

cleanup() {
    if [[ -n "$device" ]]; then
        hdiutil detach -quiet "$device" || true
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

spctl --assess --type execute --verbose=4 "$app_path"
