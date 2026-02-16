# Codex Tracking (Internal)

This file tracks what still needs to be built, what may be broken, and what to verify.
It is intentionally pragmatic and may be blunt.

## High Priority: Possible Breakage / UX Regressions

- Sidebar "Review" visibility behavior:
  - Requirement: "hide review unless review is active".
  - Current: Review link is only shown when `duplicates.result != nil`.
  - Risk: if the user is *on* Review and `result` becomes nil (clear results/reset/index rebuild), the sidebar hides the item and selection binding may behave oddly. Confirm and adjust logic to: show Review when `section == .review || duplicates.result != nil`.
  - File: `Sources/LanraragiDeskApp/UI/RootView.swift`

## Recently Fixed

- Region numbers (UI labels):
  - Fixed: `Settings -> UI labels -> Show region numbers` now applies overlays across the app (not just Review).
  - Files:
    - `Sources/LanraragiDeskApp/UI/Components/DebugFrameNumber.swift`
    - `Sources/LanraragiDeskApp/UI/SettingsView.swift`
    - `Sources/LanraragiDeskApp/UI/LibraryView.swift`
    - `Sources/LanraragiDeskApp/UI/ActivityView.swift`
    - `Sources/LanraragiDeskApp/UI/BatchView.swift`
    - `Sources/LanraragiDeskApp/UI/PluginsView.swift`

- Tag suggestions + stats decoding:
  - Fixed: `/api/database/stats` now decodes whether the server returns a top-level array or a wrapped `{ "tags": [...] }` object.
  - This unblocks tag autocomplete and the Statistics sidebar page.
  - Files:
    - `Packages/LanraragiKit/Sources/LanraragiKit/Models/DatabaseStats.swift`
    - `Packages/LanraragiKit/Tests/LanraragiKitTests/DatabaseStatsDecodingTests.swift`

- Library search + autocomplete behavior:
  - Suggestions now support prefix, post-namespace prefix, and contains matching.
  - If a stats refresh fails, stale disk cache is still used so suggestions can continue working.
  - Added visible suggestion status text to surface failures instead of silently returning empty.
  - Query submission normalizes explicit separators for LANraragi-style multi-term search while preserving spaces inside each term and preserving wildcard tokens.
  - Files:
    - `Sources/LanraragiDeskApp/Services/TagSuggestionStore.swift`
    - `Sources/LanraragiDeskApp/UI/LibraryView.swift`

- Statistics page behavior + performance:
  - Statistics now mirrors LANraragi `/stats`: weighted word cloud + detailed weighted list.
  - Detailed list excludes `source` and `date_added` namespaces (matching LANraragi `stats.js`).
  - Added top counters from server info (`total_archives`, `total_pages_read`) plus distinct tag count.
  - Replaced the SwiftUI cloud with a WebKit/jQCloud renderer to reduce CPU and match LANraragi cloud visuals.
  - Cloud is capped to top 1000 tags by weight; detailed list still stages in batches to avoid UI/system stalls.
  - Clicking a tag in Statistics now switches to Library and executes a search for that tag.
  - Files:
    - `Sources/LanraragiDeskApp/UI/StatisticsView.swift`
    - `Sources/LanraragiDeskApp/UI/RootView.swift`
    - `Sources/LanraragiDeskApp/UI/LibraryView.swift`
    - `Packages/LanraragiKit/Sources/LanraragiKit/Models/ServerInfo.swift`
    - `Packages/LanraragiKit/Tests/LanraragiKitTests/ServerInfoDecodingTests.swift`

- Thumbnail presentation:
  - Added `Settings -> Thumbnails -> Crop thumbnails to fill` toggle (off by default).
  - Cover previews now keep a consistent framed size even when not cropped.
  - Files:
    - `Sources/LanraragiDeskApp/UI/SettingsView.swift`
    - `Sources/LanraragiDeskApp/UI/Components/CoverThumb.swift`

- Performance setting expectations:
  - `network.maxConnectionsPerHost` affects URLSession `httpMaximumConnectionsPerHost` only.
  - App-level limiters are still hard-coded (`AsyncLimiter(limit: 4)` in loaders and `IndexerConfig(concurrency: 4)` for indexing).
  - Users may expect "Max connections" to speed up/slow down scanning more than it currently does.
  - Files:
    - `Sources/LanraragiDeskApp/Services/ArchiveLoader.swift`
    - `Sources/LanraragiDeskApp/Services/ThumbnailLoader.swift`
    - `Sources/LanraragiDeskApp/ViewModels/DuplicateScanViewModel.swift`

## High Priority: Missing From Requested Plan

- Library (search and quality):
  - Add a small "help" on LANraragi query syntax and negation (`-tag:`).
  - Category selector is now server-backed (pinned categories show as buttons).
  - Tag suggestions are shown under the search field; hover popover tag chips can be clicked to add to search.
  - Add server capability detection for `date_added` sort (today it falls back on HTTP 400/422 only).
  - Consider adding "Open in browser" from library context menu.
  - Files:
    - `Sources/LanraragiDeskApp/UI/LibraryView.swift`
    - `Sources/LanraragiDeskApp/ViewModels/LibraryViewModel.swift`

- Metadata editor:
  - Missing: set/override cover page (LANraragi supports custom cover selection; needs API endpoint wiring).
  - Missing: archive delete from editor (optional).
  - Tag editing is a raw comma string; consider structured tag chips editor later.
  - Files:
    - `Sources/LanraragiDeskApp/UI/ArchiveMetadataEditorView.swift`
    - `Packages/LanraragiKit/Sources/LanraragiKit/HTTP/LANraragiClient.swift`

- Reader:
  - Ensure no controls "hide" due to toolbar overflow; current strategy is stable-width items and no `Spacer()`, but verify on narrow windows.
  - Confirm keyboard controls cover expected behavior (arrows swapped for RTL, Space/Shift+Space, +/-/0, Esc).
  - Add an optional "Open in LANraragi" action.
  - File: `Sources/LanraragiDeskApp/UI/ReaderView.swift`

- Plugins:
  - Missing: Job status view (poll minion job IDs, show running/finished/failed).
  - Plugin arg UX: might need per-plugin placeholder/help if server exposes it.
  - Files:
    - `Sources/LanraragiDeskApp/UI/PluginsView.swift`
    - `Sources/LanraragiDeskApp/ViewModels/PluginsViewModel.swift`
    - `Packages/LanraragiKit/Sources/LanraragiKit/HTTP/LANraragiClient.swift`

- Activity / Log viewer:
  - Exists, but events are unstructured strings.
  - Consider log export (copy/save) and severity icons.
  - File: `Sources/LanraragiDeskApp/UI/ActivityView.swift`

## Medium Priority: Review / Duplicates Improvements

- Pages error handling:
  - There were earlier HTTP 400 errors for page listing; ArchiveLoader forces file listing on 400.
  - Verify this covers the "need a valid pathname" cases; if not, capture response body and present more actionable UI.
  - File: `Sources/LanraragiDeskApp/Services/ArchiveLoader.swift`

- Ensure exact matches do not appear in "Similar" section:
  - Filtering logic is by `pair.reason`, but confirm pipeline never produces duplicates with different reasons for the same pair.
  - Files:
    - `Sources/LanraragiDeskApp/UI/PairReviewView.swift`
    - `Packages/LanraragiKit` duplicate scan core

- "Not a match" management UX:
  - Exists under Duplicates -> Advanced.
  - Consider adding search and "undo last" action.
  - Files:
    - `Sources/LanraragiDeskApp/UI/NotMatchesView.swift`
    - `Sources/LanraragiDeskApp/ViewModels/DuplicateScanViewModel.swift`

## Low Priority: Architecture / Cleanups

- Single-profile assumption:
  - User stated only one profile will exist; app still supports multiple.
  - Option: simplify UI by removing profile naming and multi-profile selection and keeping only one connection config.
  - Files:
    - `Sources/LanraragiDeskApp/Services/ProfileStore.swift`
    - `Sources/LanraragiDeskApp/UI/ProfileEditorView.swift`

- Consolidate client creation:
  - Many call sites build a client; consider a single `ClientFactory` in app layer that always applies:
    - API key, accept language, maxConnectionsPerHost, timeouts, etc.
  - Files: multiple (search for `LANraragiClient(configuration:`)

## Verification Checklist (Manual)

- Settings:
  - Connection header appears only on Settings.
  - "Show region numbers" toggles overlays on key panels.
  - Max connections changes influence behavior (at least URLSession limits).

- Sidebar:
  - Review item behavior matches requirement when scan results exist and when cleared.
  - Sidebar background respects system transparency settings (vibrancy/material).

- Reader:
  - Toolbar items remain visible; do not vanish when auto-advance toggled.
  - RTL swaps next/prev arrows and arrow keys.

- Library:
  - Default sort tries newest-first and falls back gracefully with banner.
  - Search suggestions do not spam network (debounced).
  - Search text does not apply until the user presses Search/Enter; filters (New/Untagged/Category) apply immediately.
  - Cover overlays: NEW/date/page count.
  - List view is a Table (columns, multi-sort).
  - Hover popover shows full title/summary/tags; clicking a tag appends the raw tag token into the search field (search does not auto-run).

- Statistics page:
  - Settings checkbox should conditionally add/remove Statistics item in sidebar.
  - Statistics should continue mirroring LANraragi (`/api/database/stats`) including jQCloud-like cloud behavior and detailed list behavior.
  - Verify large libraries stay responsive while cloud/details stage in.
  - Verify clicking a cloud word opens browser search for that tag token.
  - Verify top counters are populated when server exposes `total_archives` and `total_pages_read`.
  - Files:
    - `Sources/LanraragiDeskApp/UI/SettingsView.swift`
    - `Sources/LanraragiDeskApp/UI/RootView.swift`
    - `Sources/LanraragiDeskApp/UI/StatisticsView.swift`

## Process

- Keep Markdown docs updated alongside code changes:
  - `README.md` (user-facing)
  - `CODEX_TODO.md` (internal tracking)
  - `CONTRIBUTING.md` (contributor guidance)
