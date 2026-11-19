#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output_dir="$repo_root/build/trackpad-probe"
mkdir -p "$output_dir"

xcrun clang -std=c11 -Wall -Wextra -Werror -c \
    "$repo_root/Mos/Trackpad/MultitouchBridge.c" -o "$output_dir/MultitouchProbe.o"
xcrun swiftc -swift-version 5 -parse-as-library \
    -import-objc-header "$repo_root/Mos/Trackpad/MultitouchBridge.h" \
    "$repo_root/Mos/InputEvent/TrackpadTapRecognizer.swift" \
    "$repo_root/Mos/Trackpad/TrackpadTapInput.swift" \
    "$repo_root/Mos/Shortcut/TrackpadShortcutEvents.swift" \
    "$repo_root/tools/trackpad/probe.swift" "$output_dir/MultitouchProbe.o" \
    -framework Cocoa -framework IOKit -o "$output_dir/probe"
printf 'Built %s\n' "$output_dir/probe"
