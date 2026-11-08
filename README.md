# ModeDock

A free, open-source menu-bar app for macOS 14 or later. It turns screens off and on, switches
resolutions, sets brightness on every monitor, applies display profiles, keeps the Mac awake
and takes screenshots.

Website: [modedock.app](https://modedock.app)

## Install

```sh
brew install --cask ilijamt/tap/modedock
```

Or download it from [Releases](https://github.com/ilijamt/modedock/releases).

## Build

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate          # creates ModeDock.xcodeproj, which isn't committed
open ModeDock.xcodeproj
```

Tests and lint:

```sh
swift test --package-path Packages/ModeDockKit
swift format lint --strict --recursive ModeDock Packages
```

## Layout

- `ModeDock/`: the app, with the menu-bar panel and the Settings window.
- `Packages/ModeDockKit/`: the logic and its tests.
- `server/telemetry/`: the Cloudflare Worker that receives the opt-in usage data.
- `web/`: the website.
- `scripts/`: string catalog sync.

## License

MIT. See [LICENSE](LICENSE).
