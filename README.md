# LanraragiDesk

macOS (Apple Silicon-first) LANraragi desktop client for managing a LANraragi server, with a deduplication workbench inspired by LRReader.

![LanraragiDesk app icon](docs/images/app-icon.png)

## Features

- **Library**
  - Grid or list layout
  - Grid cards use a fixed frame size (cover/title/artist/group region) for a consistent tile layout
  - Tighter grid spacing for denser cover browsing
  - Grid content is centered within the library panel
  - Library frame containers (header/results/cards) are centered in their parent frames
  - Library cover previews are shown without a thumbnail border frame
  - Header toggle next to `Grid|List` to crop covers to fill the fixed preview area (centered, off by default)
  - Server-side paging (scales to large libraries)
  - Default sort: **Newest added first** (`date_added desc`), with server capability detection and automatic fallback to Title when unsupported
  - Cover overlays: **NEW**, **Date added**, **Page count**
  - Hover a cover to show the selection checkbox (top-left)
  - Shows **Artist** and **Group** (when present) under the title (on separate lines)
  - Hover details only activate while the cursor is inside the archive results panel
  - Hover a cover to see full **Title**, **Summary**, and grouped **Tags** (click tags to add them to search)
  - Hover details popover is taller to reduce scrolling
  - Hover details keep title fixed while summary and tags scroll together in one shared body area
  - Search + tag suggestions (debounced + cached, with prefix/namespace/contains matching)
  - Search follows LANraragi tokenization (comma-separated tokens; spaces preserved inside a term; wildcard tokens pass through)
  - Search bar includes inline query tips (negation and wildcard examples)
  - List view uses a table with columns: Select, Title, New, Date, Artist, Group, Tags (sortable and re-orderable)
  - Filters: New only, Untagged only, Category (server-backed)
  - Right-click: open Reader, open in browser, edit metadata, copy archive id
  - Open in browser now targets LANraragi reader URLs (`/reader?id=<arcid>`)
  - Grid layout no longer forces fixed content width that can overflow the visible panel
  - Library page state now persists while switching sidebar sections (no forced rebuild/reload on return)
- **Duplicates**
  - Local cover fingerprint index (rebuilt at the start of every scan)
  - Finds **exact** and **similar** cover matches
  - Review as **pairs** with side-by-side comparison
  - Actions: delete left/right, mark “Not a match” (persisted locally and excluded from future scans)
  - Duplicates workflow events are logged to Activity (scan start/complete/fail/cancel, exclusions, removals, deletes)
  - Synced page preview scrolling for visual verification
  - Review now appears directly under the Find Duplicates panel in the Duplicates page
  - After a scan completes, the Find Duplicates panel auto-collapses to title-only so review gets more space (manual expand/collapse available)
  - Separate Review sidebar tab removed (all duplicate review stays in Duplicates)
- **Reader**
  - Keyboard navigation
  - Left/Right arrow keys now always move pages in addition to click zones and move commands
  - Optional auto-advance timer (off by default)
  - Two-page spread, fit modes, zoom controls
  - View zoom controls include Increase, Decrease, and Reset (`Cmd+=`, `Cmd+-`, `Cmd+0`)
  - Left-to-right / right-to-left “Next page” behavior (configured in Settings)
- **Metadata editor**
  - Edit title/tags/summary
  - Save uses LANraragi-compatible metadata update payloads (title/tags/summary are always sent)
  - Supports cover override by setting thumbnail from a selected archive page
  - Supports deleting the current archive with confirmation
  - Queue selected metadata plugins against the current archive
  - Delete handling is resilient if an archive was already removed server-side (idempotent cleanup in Library and Duplicates flows)
  - Tags are shown grouped/sorted like Library hover tags (chip-based editor; raw CSV field hidden)
  - Date tags are rendered in human-readable form
  - Click-to-remove tag chips plus tag autocomplete from server database stats (configurable cache)
  - Title and summary inputs use full-width editor sections for stable text placement while typing/editing
- **Batch**
  - Bulk add/remove tags for selected archives
  - Queue selected metadata plugins for selected archives
  - Tag and plugin queues support pause/resume and recoverable checkpoints after app restart
  - Pause waits for the current archive to finish safely before stopping
  - Resume re-runs the last in-progress archive before continuing
- **Activity**
  - Local activity log with filtering and search
- **Window chrome**
  - Sidebar toggle is fixed in the titlebar next to the macOS traffic-light controls, at traffic-light button size
  - App title text is hidden from the titlebar (no extra `LanraragiDesk` title label in the window header)
  - Native toolbar/titlebar remains enabled with compact style; sidebar uses a fixed top safe-area spacer to avoid titlebar overlap
- **Statistics** (optional; enable in Settings)
  - Sidebar page that mirrors LANraragi’s `/stats` behavior
  - Tag cloud from `/api/database/stats?minweight=<n>` rendered with a WebKit/jQCloud view (cloud-like layout, lower CPU than the old SwiftUI flow layout)
  - Cloud rendering is capped to the top 1000 tags by weight for responsiveness
  - Detailed stats list sorted by weight (excluding `source` and `date_added`, matching LANraragi)
  - Header counters from server info (`total_archives`, `total_pages_read`, and distinct tag count)
  - Clicking a tag in cloud/details jumps to **Library** and runs a search for that tag
  - Local filter field for quickly finding tags in the cloud and detailed list

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
- Thumbnail crop/fill is configurable in **Settings → Thumbnails** (off by default).

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
- [x] Fingerprint index (SQLite) + duplicate candidate scan
- [x] Manual review UI + persistent "Not a match"
- [x] Core client features (library/reader/metadata editor/batch/plugins/activity)
- [x] Optional statistics page that mirrors LANraragi stats
- [x] Plugins: job status tracking UI (running/finished/failed)
- [ ] Activity: structured entries + export/severity UX
- [ ] Reader: add optional "Open in LANraragi" action and complete narrow-window verification
- [ ] Duplicates: better "Not a match" management (search/undo) and additional error-path UX polish
