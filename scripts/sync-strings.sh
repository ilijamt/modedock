#!/bin/sh
# Updates the String Catalogs on command-line builds. Xcode does this itself in the IDE.
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
