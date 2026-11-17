#!/bin/sh
# Updates the String Catalogs on command-line builds. Xcode does this itself in the IDE.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate -q
# Clean first: an incremental build keeps the strings of deleted code, so they'd never go stale.
xcodebuild -scheme ModeDock -configuration Debug -derivedDataPath build -quiet clean build
# Debug only: other configurations and architectures in build/ are from older builds.
intermediates=build/Build/Intermediates.noindex

sync() {
    catalog=$1
    shift
    newline=$(tail -c1 "$catalog" | wc -l)
    # shellcheck disable=SC2046
    xcrun xcstringstool sync "$catalog" --stringsdata $(find "$@" -name '*.stringsdata')
    # xcstringstool writes `"key" : {` and drops a final newline; each catalog keeps its own
    # layout, so a sync only shows the strings that changed.
    perl -pi -e 's/^(\s*"(?:[^"\\]|\\.)*") : /$1: /' "$catalog"
    if [ "$newline" -gt 0 ] && [ -n "$(tail -c1 "$catalog")" ]; then echo >>"$catalog"; fi
}

sync ModeDock/Localizable.xcstrings "$intermediates/ModeDock.build/Debug"
for target in DisplayKit ModeDockCore; do
    sync "Packages/ModeDockKit/Sources/$target/Localizable.xcstrings" \
        "$intermediates/ModeDockKit.build/Debug/$target-t.build"
done
echo "String Catalogs are up to date. New strings need translating in Xcode or on your translation platform."
