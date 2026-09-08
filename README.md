# LanraragiDesk

A native macOS client for browsing, reading, and managing a LANraragi library. It includes duplicate review, metadata editing, and resumable batch operations. A separate LANraragi server stores and serves the archives.

![LanraragiDesk app icon](docs/images/app-icon.png)

## Features

- Browse a paginated library in grid or list view, with search, tag suggestions, categories, and new or untagged filters.
- Read archives with keyboard navigation, two-page spreads, zoom, reading-direction controls, and an optional auto-advance timer.
- Edit titles, tags, summaries, and cover pages; run the server's metadata plugins.
- Find exact or similar covers, compare pages side by side, and review duplicates before deleting an archive.
- Add or remove tags and queue metadata plugins across selected archives. Queues support previews, pause/resume, and recovery after relaunch.
- Review activity and errors, export filtered logs, or copy diagnostic information. An optional Statistics page shows library totals and tag usage.

## Requirements

- macOS 14 or later. Development targets Apple Silicon first.
- A LANraragi server reachable from your Mac, with its base URL and API key.
- To build: Xcode with Swift 6 support and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Build and run

Install Xcode and select its developer tools, then:

```sh
brew install xcodegen
git clone https://github.com/ChronoStriker1/LanraragiDesk.git
cd LanraragiDesk
xcodegen generate
open LanraragiDesk.xcodeproj
```

In Xcode, select the `LanraragiDesk` scheme and your Mac as the destination, then choose Run. To build from the command line:

```sh
xcodebuild -project LanraragiDesk.xcodeproj -scheme LanraragiDesk -configuration Debug build
```

## Connect to LANraragi

1. Open Settings and create or edit a server profile.
2. Enter the server's base URL, such as `http://lanraragi.local:3000`, and its API key.
3. Click **Test Connection**, then open Library.

Use the server's base address, not a reader or archive URL. `localhost` only works when LANraragi runs on the same Mac.

Search uses LANraragi's comma-separated query syntax. Spaces remain part of a term, and negation and wildcard queries pass to the server. The default sort is newest added first, with a title-sort fallback for servers that do not support it.

## Review duplicates

Open Duplicates and start a scan. The app compares cover fingerprints and presents candidate pairs with synchronized page previews. Review the pages and metadata before deleting either archive; a similar cover does not prove that the contents are identical.

Normal scans reuse the local fingerprint index and remove stale entries after a full library enumeration. Use **Rebuild index and scan** for a full refresh. **Not a match** decisions persist locally and exclude those pairs from later scans.

Metadata edits, cover changes, and archive deletions affect the connected server. Duplicate exclusions stay local.

## Batch operations

Select archives in Library or use the saved-query builder in Batch. **Select All Results** selects the whole current query, including results outside the visible page.

For metadata plugins, select a plugin, configure its options and any URL argument, and choose whether to combine or replace metadata. Keep **Preview Before Queue** enabled to inspect a sample. Pause lets the current archive finish; resuming a recovered queue retries the last in-progress archive.

## How it works

The SwiftUI app calls LANraragi's HTTP API for library search, pages, thumbnails, and metadata operations. The local `LanraragiKit` Swift package contains the API client and duplicate-indexing code. A SQLite database stores cover fingerprints and duplicate-review state.

Server paging keeps the full library out of memory. Request concurrency and tag-cache settings are configurable under Settings. Library request timings and Activity logs help diagnose slow or failed requests.

## Local data and privacy

API keys are stored in macOS Keychain. Profile files do not contain those keys.

| Data | Location |
| --- | --- |
| Fingerprint index | `~/Library/Application Support/LanraragiDesk/index.sqlite` |
| Tag cache | `~/Library/Application Support/LanraragiDesk/Cache/tagstats-<hash>.json` |
| Activity log | `~/Library/Application Support/LanraragiDesk/activity.json` |
| Saved batch queries | `~/Library/Application Support/LanraragiDesk/saved-batch-queries.json` |

Diagnostic bundles include the selected profile endpoint and filtered activity. Review them before sharing.

## Troubleshooting

- Connection test fails: check the base URL, API key, and server reachability from your Mac.
- Covers or scans are slow: lower network concurrency under Settings → Performance and inspect request timings or Activity errors.
- Search behaves unexpectedly: use comma-separated LANraragi terms and check the query tips.
- Duplicate results look stale: run **Rebuild index and scan** after confirming server availability.

## Development

`Sources/LanraragiDeskApp` contains the app. `Packages/LanraragiKit` contains the API client and indexing core. Regenerate the Xcode project after adding files or changing `project.yml`.

```sh
swift test --package-path Packages/LanraragiKit
```

See [contributing](CONTRIBUTING.md) and the [regression checklist](docs/REGRESSION_CHECKLIST.md) for development and manual testing.
