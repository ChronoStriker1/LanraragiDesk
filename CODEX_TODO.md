# Codex Tracking (Internal)

This file tracks what still needs to be built, what may be broken, and what to verify.
It is intentionally pragmatic and may be blunt.

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
  - Grid card overlap fix: library grid column minimum now matches card outer width to prevent frame overlap between neighboring cards.
  - Grid cards now use a fixed tile size so cover/title/artist/group blocks are uniform per card.
  - Grid spacing was reduced for a denser layout.
  - Library grid content is now centered in the panel instead of sticking to the left edge.
  - Grid rendering no longer forces a fixed computed content width, preventing cards/frames from spilling outside the visible area on constrained layouts.
  - Library root/header/results/card frames were normalized to centered parent-frame alignment.
  - Removed thumbnail border frame in Library previews (grid + list) while keeping cover overlays/selection behavior.
  - Added a `Crop Covers` checkbox next to the `Grid|List` layout control to toggle thumbnail crop-to-fill quickly.
  - Library hover details now only activate while cursor is in the archive results panel.
  - Increased hover details panel/tag region height to reduce scrolling.
  - Hover details now keep title fixed while summary+tags share one vertical scroll area.
  - Added inline query syntax help under the search field (`-tag` negation and wildcard examples).
  - Added server capability detection for `date_added` sort with automatic fallback to Title when unsupported.
  - Added `Open in Browser` to Library context menus (grid + list).
  - Fixed `Open in Browser` URL generation to use LANraragi reader route (`/reader?id=<arcid>`) instead of archive path routing.
  - Files:
    - `Sources/LanraragiDeskApp/Services/TagSuggestionStore.swift`
    - `Sources/LanraragiDeskApp/UI/LibraryView.swift`
    - `Sources/LanraragiDeskApp/UI/Components/CoverThumb.swift`
    - `Sources/LanraragiDeskApp/ViewModels/LibraryViewModel.swift`

- Reader navigation + zoom menu:
  - Added explicit left/right arrow key handling in-reader (in addition to move command handling) for reliable keyboard page turns.
  - Added `Increase`, `Decrease`, and `Reset` zoom controls in the Reader `View` menu with shortcuts (`Cmd+=`, `Cmd+-`, `Cmd+0`).
  - Added a reset action/button for zoom inside the Reader view options menu.
  - Files:
    - `Sources/LanraragiDeskApp/UI/ReaderView.swift`
    - `Sources/LanraragiDeskApp/LanraragiDeskApp.swift`

- Duplicates/review workspace layout:
  - Moved review UI under the Find Duplicate Archives panel within the Duplicates page.
  - Scan panel now auto-collapses to title-only when a scan completes with results, and can be manually expanded/collapsed.
  - Removed the redundant "Go To Review" action from completed scan status.
  - Removed the standalone Review sidebar section; Duplicates is now the only review entrypoint.
  - Added duplicate workflow activity logging via `AppModel.activity`: scan start/completed/failed/cancelled, mark/remove/clear "Not a match", and archive delete success/failure.
  - Files:
    - `Sources/LanraragiDeskApp/UI/RootView.swift`
    - `Sources/LanraragiDeskApp/ViewModels/DuplicateScanViewModel.swift`
    - `Sources/LanraragiDeskApp/ViewModels/AppModel.swift`

- Sidebar toggle placement:
  - Removed the default moving split-view sidebar toggle from toolbar.
  - Added a fixed titlebar toggle anchored next to macOS traffic-light controls (same button size as minimize).
  - Hid the window title text and forced compact titlebar style to prevent titlebar growth/shrink while switching sidebar sections.
  - Disabled transparent titlebar for the main window so sidebar content no longer intrudes into titlebar space.
  - Moved window titlebar styling to one-time-per-window configuration to prevent relayout churn when sidebar selection changes.
  - Kept native toolbar/titlebar visible (compact style) and explicitly cleared split-view navigation title to remove stray `LanraragiDesk` header text.
  - Added fixed top safe-area spacer in sidebar list for stable clearance below traffic lights + custom sidebar toggle.
  - Removed plain button styling from sidebar `NavigationLink`s so selection rendering remains stable.
  - File:
    - `Sources/LanraragiDeskApp/UI/RootView.swift`

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

- Metadata editor save + tag UX:
  - Fixed metadata save transport for LANraragi by using `application/x-www-form-urlencoded` in `PUT /api/archives/{id}/metadata` (JSON payloads are rejected by LANraragi's API handler).
  - Added cover override: metadata editor can set archive thumbnail from a selected page (`PUT /api/archives/{arcid}/thumbnail?page=<n>`), with thumbnail cache invalidation.
  - Added archive delete from metadata editor, with confirmation and caller-specific refresh behavior for Library and Duplicates workflows.
  - Hardened metadata-editor delete flow in both Library and Duplicates:
    - Archive deletion is now idempotent in app-layer transport handling (404/410 treated as already deleted).
    - Library path explicitly clears selection state for deleted archive IDs.
    - Duplicates path now invalidates deleted archive thumbnails, rebuilds groups from surviving pairs, and prunes stale "Not a match" records (in-memory + index store).
  - Metadata editor now normalizes tags, shows grouped/sorted tag chips (matching Library hover grouping), renders date tags human-readably, and supports remove-by-chip plus autocomplete add flow.
  - Raw tags CSV editor field is now hidden; metadata tag editing uses grouped chips + add/remove actions.
  - Save now preserves untouched fields from latest metadata so title/tags/summary are always sent.
  - Replaced `Form`-based field layout with explicit full-width sections so title and summary text placement stays correct during editing.
  - Files:
    - `Packages/LanraragiKit/Sources/LanraragiKit/HTTP/LANraragiClient.swift`
    - `Sources/LanraragiDeskApp/Services/ArchiveLoader.swift`
    - `Sources/LanraragiDeskApp/Services/ThumbnailLoader.swift`
    - `Sources/LanraragiDeskApp/UI/ArchiveMetadataEditorView.swift`
    - `Sources/LanraragiDeskApp/UI/LibraryView.swift`
    - `Sources/LanraragiDeskApp/UI/PairReviewView.swift`
    - `Sources/LanraragiDeskApp/ViewModels/DuplicateScanViewModel.swift`

- Performance setting expectations:
  - `network.maxConnectionsPerHost` affects URLSession `httpMaximumConnectionsPerHost` only.
  - App-level limiters are still hard-coded (`AsyncLimiter(limit: 4)` in loaders and `IndexerConfig(concurrency: 4)` for indexing).
  - Users may expect "Max connections" to speed up/slow down scanning more than it currently does.
  - Files:
    - `Sources/LanraragiDeskApp/Services/ArchiveLoader.swift`
    - `Sources/LanraragiDeskApp/Services/ThumbnailLoader.swift`
    - `Sources/LanraragiDeskApp/ViewModels/DuplicateScanViewModel.swift`

## High Priority: Missing From Requested Plan

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
