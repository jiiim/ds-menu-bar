#!/bin/bash
# SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
# SPDX-License-Identifier: MIT

set -euo pipefail

if (( $# < 3 || $# > 4 )); then
    echo "usage: $0 APP_PATH OUTPUT_DMG VOLUME_NAME [SIGN_IDENTITY]" >&2
    exit 64
fi

app_path=$1
output_dmg=$2
volume_name=$3
sign_identity=${4:-}

if [[ ! -d "$app_path" || "${app_path##*.}" != app ]]; then
    echo "app bundle not found: $app_path" >&2
    exit 66
fi

if [[ -z "$output_dmg" || "${output_dmg##*.}" != dmg ]]; then
    echo "output must be a .dmg path" >&2
    exit 64
fi

work_dir=$(mktemp -d -t ds-menu-bar-dmg.XXXXXX)
staging_dir="$work_dir/staging"
mount_dir="$work_dir/mount"
read_write_dmg="$work_dir/layout.dmg"
device=

cleanup() {
    if [[ -n "$device" ]]; then
        hdiutil detach -quiet "$device" || true
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -p -- "$staging_dir" "$mount_dir"
mkdir -p -- "$(dirname "$output_dmg")"
ditto "$app_path" "$staging_dir/${app_path##*/}"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
    -quiet \
    -volname "$volume_name" \
    -fs HFS+ \
    -srcfolder "$staging_dir" \
    -format UDRW \
    -ov \
    "$read_write_dmg"

device=$(hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$mount_dir" \
    "$read_write_dmg" | awk '/Apple_HFS/ { print $1; exit }')

if [[ -z "$device" ]]; then
    echo "could not determine the mounted disk-image device" >&2
    exit 1
fi

osascript - "$mount_dir" "${app_path##*/}" <<'APPLESCRIPT'
on run arguments
    set mountPath to item 1 of arguments
    set appName to item 2 of arguments

    tell application "Finder"
        set dmgFolder to folder (POSIX file mountPath as alias)
        open dmgFolder
        set dmgWindow to container window of dmgFolder
        set current view of dmgWindow to icon view
        set toolbar visible of dmgWindow to false
        set statusbar visible of dmgWindow to false
        set bounds of dmgWindow to {100, 100, 660, 420}

        set viewOptions to icon view options of dmgWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 14
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to true

        set position of item appName of dmgFolder to {145, 160}
        set position of item "Applications" of dmgFolder to {415, 160}
        update dmgFolder without registering applications
        delay 2
        close dmgWindow
    end tell
end run
APPLESCRIPT

sync
rm -rf -- "$mount_dir/.fseventsd"
hdiutil detach -quiet "$device"
device=

hdiutil convert \
    -quiet \
    "$read_write_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$output_dmg"

if [[ -n "$sign_identity" ]]; then
    codesign --force --timestamp --sign "$sign_identity" "$output_dmg"
    codesign --verify --strict --verbose=2 "$output_dmg"
fi

hdiutil verify "$output_dmg"
