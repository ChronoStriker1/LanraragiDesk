# LanraragiDesk

macOS (Apple Silicon-first) LANraragi desktop client for managing a LANraragi server, with a deduplication workbench inspired by LRReader.

This is a personal project intended to be published on GitHub (not the Mac App Store).

## Features

- **Library**
  - Grid or list layout
  - Server-side paging (scales to large libraries)
  - Default sort: **Newest added first** (`date_added desc`), with an automatic fallback to Title if the server rejects it
  - Cover overlays: **NEW**, **Date added**, **Page count**
  - Shows **Artist** and **Group** (when present) under the title
  - Hover a cover to see full **Title**, **Summary**, and grouped **Tags** (click tags to add them to search)
  - Search + tag suggestions (shown under the search field)
  - Filters: New only, Untagged only, Category (server-backed)
  - Right-click: open Reader, edit metadata, copy archive id
- **Duplicates**
  - Local cover fingerprint index (rebuilt at the start of every scan)
  - Finds **exact** and **similar** cover matches
  - Review as **pairs** with side-by-side comparison
  - Actions: delete left/right, mark “Not a match” (persisted locally and excluded from future scans)
  - Synced page preview scrolling for visual verification
- **Reader**
  - Keyboard navigation
  - Optional auto-advance timer (off by default)
  - Two-page spread, fit modes, zoom controls
  - Left-to-right / right-to-left “Next page” behavior (configured in Settings)
- **Metadata editor**
  - Edit title/tags/summary
  - Tag autocomplete using server database stats (configurable cache)
- **Batch**
  - Bulk add/remove tags for selected archives
- **Plugins**
  - List server plugins and queue them for selected archives
- **Activity**
  - Local activity log with filtering and search

## Setup

1. Open **Settings** and set:
   - Base URL (example: `http://127.0.0.1:3000`)
   - API key (stored in Keychain)
2. Click **Test Connection**.
3. Use **Library** for browsing/reading and **Duplicates** for scanning.

## Security / Privacy

- API keys are stored in **Keychain**.
- Profiles are stored on disk **without secrets**.
- The app stores local caches and an index database in your user Library directories (see below).
- Do not paste API keys into issues/PRs.

## Data Locations

The app writes local data under your user Library directories:

- Fingerprint index DB: `~/Library/Application Support/LanraragiDesk/index.sqlite`
- Tag suggestion cache: `~/Library/Caches/LanraragiDesk/tag-stats-<hash>.json`
- Activity log: `~/Library/Application Support/LanraragiDesk/activity.json`

## Build (Developer)

Requirements:

- macOS 14+
- Xcode 15+
- Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Build steps:

```sh
cd LanraragiDesk
xcodegen generate
open LanraragiDesk.xcodeproj
```

Then build/run the `LanraragiDesk` scheme.

## Notes

- “Not a match” decisions are stored locally and are not written back to LANraragi.
- Network concurrency is configurable in **Settings → Performance** so scans don’t monopolize your Mac.

## Dev

Requirements:
- Xcode 15+ (you have Xcode 26.2)
- Swift 6+

Project layout:
- `Packages/LanraragiKit`: LANraragi API client + dedup/index core (SwiftPM)
- `Sources/LanraragiDeskApp`: macOS app (SwiftUI)

## Contributing

See `CONTRIBUTING.md` (includes a rule to keep Markdown docs updated alongside code changes).

## Roadmap (short)

- [x] Profile + API connectivity
- [ ] Fingerprint index (SQLite)
- [ ] Candidate scan + verification
- [ ] Manual review UI + persistent "not duplicates"
- [ ] Full client features (reader/search/categories/etc)
