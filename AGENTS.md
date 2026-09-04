# MicroRSS

MicroRSS is a minimal native macOS RSS reader inspired by RSS Menu and RSS Bot. It lives in the menu bar, keeps external dependencies to zero, and aims to be stable, small, and buildable from the terminal with Xcode tooling.

## Goals

- Native macOS app using Swift, AppKit, and WebKit.
- Menu bar first: no Dock icon, no main window by default.
- Feed management in Settings: add, remove, reorder, name, URL, per-feed refresh interval.
- Global refresh interval with per-feed overrides.
- Feed submenus show current stories.
- Story preview opens in a Safari/WebKit-based preview window.
- Story activation opens the article URL in the default browser.
- Favor simple, explicit code over frameworks or external packages.

## Workflow

- Commit after each contextual change so the project history stays readable.
- Keep commits focused: project setup, feed model, UI behavior, persistence, networking, and polish should be separate when possible.
- Before pushing, squash unpushed intermediate implementations, corrections, and follow-up tests for the same contextual change into one coherent commit. Keep distinct fixes, features, and unrelated cleanup in separate commits; do not squash solely because commits are adjacent. Describe the final behavior and scope in the resulting commit message. Verify that all commits being rewritten are unpushed; do not rewrite pushed history without explicit authorization.
- Do not add external dependencies unless the stability or size tradeoff is clearly worth it.
- Prefer native Apple APIs and small local helpers.

## Build

```sh
xcodebuild -project MicroRSS.xcodeproj -scheme MicroRSS -configuration Debug -derivedDataPath DerivedData build
```
