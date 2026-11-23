#!/bin/zsh
set -eu

project_root=${0:A:h}
product="$project_root/CueIsland.app"
bundle_id=local.shaurya.CueIsland
if [[ -e "$product" ]]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$product/Contents/Info.plist")
    if [[ "$existing_id" != "$bundle_id" ]]; then
        print -u2 "An unrelated app already exists at $product."
        exit 1
    fi
fi

build_dir=$(mktemp -d "${TMPDIR:-/tmp}/cue-island-build.XXXXXXXX")
trap 'rm -rf "$build_dir"' EXIT
bundle="$build_dir/CueIsland.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project_root/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$project_root/Resources/CueIsland.icns" "$bundle/Contents/Resources/"
/usr/bin/xcrun swiftc -O -swift-version 6 -target arm64-apple-macos14.0 \
    -module-cache-path "$build_dir/ModuleCache" \
    "$project_root"/Sources/CameraPrompter/*.swift -o "$bundle/Contents/MacOS/CueIsland"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier "$bundle_id" "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/ditto "$bundle" "$product"
/usr/bin/codesign --verify "$product"
print "Built $product"
