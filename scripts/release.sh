#!/bin/bash
# Builds, signs, notarizes and publishes a ModeDock release.
#
#   scripts/release.sh 0.1.0 [notes.md]
#
# Without a notes file, the notes list the feat: and fix: commits since the last release.
set -euo pipefail

version=${1:?usage: scripts/release.sh <version> [notes.md]}
notes_file=${2:-}
profile=${NOTARY_PROFILE:-modedock}
repo=ilijamt/modedock
tag=v$version

cd "$(dirname "$0")/.."
out=build/release
app=$out/ModeDock.app
dmg=$out/ModeDock-$version.dmg
feed=$out/feed
sparkle=build/SourcePackages/artifacts/sparkle/Sparkle/bin

fail() { echo "release: $*" >&2; exit 1; }
step() { echo "==> $*"; }

step "Checking"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3"
[[ $(git branch --show-current) == main ]] || fail "not on main"
[[ -z $(git status --porcelain) ]] || fail "the working tree isn't clean"
[[ -z $notes_file || -f $notes_file ]] || fail "no notes file at $notes_file"
grep -q 'SUPublicEDKey: ""' project.yml && fail "SUPublicEDKey in project.yml is empty"
identities=$(security find-identity -v -p codesigning)
identity=$(sed -nE 's/.*"(Developer ID Application[^"]*)".*/\1/p' <<<"$identities" | head -1)
[[ -n $identity ]] || fail "no Developer ID Application certificate in the keychain"
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 ||
    fail "no notarytool credentials named '$profile'"
gh auth status >/dev/null 2>&1 || fail "gh isn't logged in"
# Fail now rather than after notarizing: the push at the end needs these.
git fetch -q origin main --tags
git merge-base --is-ancestor origin/main HEAD || fail "main is behind origin/main"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "$tag already exists"

step "Testing"
swift test --package-path Packages/ModeDockKit -q

step "Setting the version to $version"
# A timestamp, so it keeps growing even if history is rewritten. Sparkle compares it.
build_number=$(date -u +%Y%m%d%H%M)
sed -i '' -E -e "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$version\"/" \
    -e "s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"$build_number\"/" project.yml
committed=false
trap '$committed || git checkout -q -- project.yml' EXIT

step "Building"
rm -rf "$out" && mkdir -p "$out" "$feed"
xcodegen generate -q
xcodebuild -project ModeDock.xcodeproj -scheme ModeDock -configuration Release -derivedDataPath build \
    -destination 'generic/platform=macOS' -archivePath "$out/ModeDock.xcarchive" archive -quiet
team=$(sed -nE 's/^ *DEVELOPMENT_TEAM: *//p' project.yml | head -1)
cat >"$out/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$out/ModeDock.xcarchive" -exportOptionsPlist "$out/export.plist" \
    -exportPath "$out" -quiet
codesign --verify --deep --strict "$app"
[[ $(codesign -dvv "$app" 2>&1) == *"Authority=Developer ID Application"* ]] ||
    fail "the app isn't signed with Developer ID"

step "Notarizing the app"
ditto -c -k --keepParent "$app" "$out/ModeDock.zip"
xcrun notarytool submit "$out/ModeDock.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl -a -t exec "$app"

step "Making the DMG"
mkdir -p "$out/dmg"
cp -R "$app" "$out/dmg/"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -volname ModeDock -srcfolder "$out/dmg" -ov -format UDZO "$dmg" -quiet
codesign --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature "$dmg"

step "Writing the release notes and the Sparkle feed"
notes=$feed/ModeDock-$version.md
if [[ -n $notes_file ]]; then
    cp "$notes_file" "$notes"
else
    since=$(git describe --tags --abbrev=0 2>/dev/null || true)
    git log --format=%s ${since:+"$since"..HEAD} |
        perl -ne 'print "- \u$1\n" if /^(?:feat|fix)(?:\(.+?\))?!?: (.+)/' >"$notes"
    [[ -s $notes ]] || echo "- Small fixes." >"$notes"
fi
cp "$dmg" "$feed/"
# The app reads the feed from the latest release, so it goes up with the DMG.
"$sparkle/generate_appcast" "$feed" --embed-release-notes \
    --download-url-prefix "https://github.com/$repo/releases/download/$tag/"

step "Publishing $tag"
git commit -q -am "chore: release $version"
committed=true
git tag "$tag"
git push -q origin main "$tag"
gh release create "$tag" "$dmg" "$feed/appcast.xml" --repo "$repo" --title "ModeDock $version" \
    --notes-file "$notes"

step "Done. The Homebrew workflow updates the cask."
