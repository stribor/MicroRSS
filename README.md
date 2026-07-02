# MicroRSS

MicroRSS is a minimal native macOS RSS reader that lives in the menu bar. It is inspired by classic utilities like RSS Menu and RSS Bot, with a focus on being small, stable, dependency-free, and buildable from the terminal with Xcode tooling.

## Features

- Menu bar first: no Dock icon and no main window by default.
- Native AppKit interface with a settings window for feed management.
- Add, edit, remove, reorder, and group feeds with separators.
- Global refresh interval with optional per-feed overrides.
- Feed submenus with unread indicators, feed icons, and current stories.
- Inline WebKit story previews from the menu.
- Separate WebKit preview windows for articles.
- Open story links in the default browser.
- Mark stories read or unread per feed or globally.
- Optional unread counts in the menu bar and feed titles.
- Optional notifications for newly discovered articles.
- Optional launch at login.
- Local persistence through `UserDefaults`.
- No external package dependencies.

## Requirements

- macOS 14.0 or later.
- Xcode with Swift 6 support.

## Build

Build from the repository root:

```sh
xcodebuild -project MicroRSS.xcodeproj -scheme MicroRSS -configuration Debug -derivedDataPath DerivedData build
```

The built app is placed under `Build/Products/Debug/MicroRSS.app`.

## Run

After building, launch the app with:

```sh
open Build/Products/Debug/MicroRSS.app
```

MicroRSS appears in the macOS menu bar. Open the menu, choose **General > Settings...**, and add RSS or Atom feed URLs from the Feeds pane.

## Usage

- Use **Update all feeds** or a feed's **Refresh Now** command to fetch stories immediately.
- Hover or open a story submenu to see an HTML preview.
- Choose a story title to open the article in your default browser.
- Choose **Open Preview Window** to read in a dedicated WebKit window.
- Use the read/unread actions to manage unread state globally or per feed.
- Use **Pause Updates** to stop scheduled refreshes temporarily.

## Settings

The Settings window includes:

- **Feeds**: manage feed names, URLs, refresh overrides, separators, and ordering.
- **General**: configure refresh timing, launch at login, notifications, preview size, unread counts, menu bar icon behavior, and global menu actions.
- **About**: app version and short project description.

## Project Layout

```text
MicroRSS/
  AppDelegate.swift                 App startup and application menu
  main.swift                        Accessory app entry point
  Models.swift                      Feed, separator, and story models
  FeedStore.swift                   Persistence and read/unread state
  RSSService.swift                  RSS/Atom fetching and XML parsing
  StatusMenuController.swift        Menu bar UI, refresh scheduling, notifications
  PreferencesWindowController.swift Settings window
  PreviewWindowController.swift     WebKit preview windows
  FeedIconCache.swift               Feed favicon loading and caching
  Assets.xcassets/                  App and menu bar icons
```

## Development Notes

MicroRSS intentionally avoids third-party dependencies. Prefer native Apple APIs, explicit code, and small local helpers. Keep changes focused and buildable with the command above.
