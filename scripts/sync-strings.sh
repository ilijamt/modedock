#!/bin/sh
# Builds ModeDock and adds new strings to the String Catalogs, marking removed ones stale.
# Xcode does this by itself when building in the IDE; this is for command-line builds.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -scheme ModeDock -configuration Debug -derivedDataPath build -quiet build
intermediates=build/Build/Intermediates.noindex

sync() {
    catalog=$1
    shift
    # shellcheck disable=SC2046
    xcrun xcstringstool sync "$catalog" --stringsdata $(find "$@" -name '*.stringsdata')
}

sync ModeDock/Localizable.xcstrings "$intermediates/ModeDock.build"
for target in DisplayKit ModeDockCore; do
    sync "Packages/ModeDockKit/Sources/$target/Localizable.xcstrings" \
        "$intermediates/ModeDockKit.build/Debug/$target-t.build"
done
echo "String Catalogs are up to date. New strings need translating in Xcode or on your translation platform."
