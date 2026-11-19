#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mos-trackpad-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/Sources/TrackpadTapCore" "$test_dir/Tests/TrackpadTapCoreTests"
cp "$repo_root/Mos/InputEvent/TrackpadTapRecognizer.swift" "$test_dir/Sources/TrackpadTapCore/"
cp "$repo_root/Mos/Trackpad/TrackpadTapInput.swift" "$test_dir/Sources/TrackpadTapCore/"
cp "$repo_root/Mos/Shortcut/TrackpadShortcutEvents.swift" "$test_dir/Sources/TrackpadTapCore/"
# Run the actual MosTests file; adapt only the module import for this isolated host.
sed 's/@testable import Mos_Debug/@testable import TrackpadTapCore/' \
    "$repo_root/MosTests/TrackpadTapRecognizerTests.swift" \
    > "$test_dir/Tests/TrackpadTapCoreTests/TrackpadTapRecognizerTests.swift"
sed 's/@testable import Mos_Debug/@testable import TrackpadTapCore/' \
    "$repo_root/MosTests/TrackpadTapInputTests.swift" \
    > "$test_dir/Tests/TrackpadTapCoreTests/TrackpadTapInputTests.swift"
cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version:5.3
import PackageDescription
let package = Package(
    name: "TrackpadTapCore",
    platforms: [.macOS(.v10_13)],
    targets: [
        .target(name: "TrackpadTapCore"),
        .testTarget(name: "TrackpadTapCoreTests", dependencies: ["TrackpadTapCore"])
    ],
    swiftLanguageVersions: [.v5]
)
SWIFT
xcrun swift test --package-path "$test_dir" --scratch-path "$repo_root/build/trackpad-tests"
