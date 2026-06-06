# ModeDock

A free, open-source macOS menu-bar utility for everyday display and system controls: turn screens off and on, switch display modes and profiles, adjust brightness, manage power, and take screenshots.

Requires macOS 14 Sonoma or later. Work in progress.

## Building

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate          # creates ModeDock.xcodeproj (not committed)
open ModeDock.xcodeproj
```

Run the tests and the linter:

```sh
swift test --package-path Packages/ModeDockKit
swift format lint --strict --recursive ModeDock Packages
```

## Layout

- `ModeDock/` is the app target: the menu-bar UI and the Settings window.
- `Packages/ModeDockKit/` holds the logic, split into modules with unit tests.
- `project.yml` is the XcodeGen spec.

## License

MIT. See [LICENSE](LICENSE).
