# Regression Results — 2026-08-27

Release-candidate commit: `74b899afb917a18b0157fb0dd67595797fe7b8b0`

Checklist source: [`REGRESSION_CHECKLIST.md`](REGRESSION_CHECKLIST.md)

## Summary

| Status | Count |
|---|---:|
| Pass | 6 |
| Fail | 0 |
| Blocked | 26 |
| Not Applicable | 0 |
| **Total** | **32** |

No product failure was observed, so this pass did not identify a failure that
needs a follow-up GitHub issue. This is not a fully qualified manual release
pass: the 26 blocked checks still need the access or operator evidence listed
below.

## Environment and evidence

- MacBook Pro (`MacBook-Pro`), macOS 26.6.2, Apple Silicon (`arm64`), Xcode
  26.6 (build 17F113).
- Installed candidate: `/Applications/LanraragiDesk.app`, version 1.1 (build
  2). `codesign --verify --deep --strict` passed. The bundle's recorded
  modification time was `2026-08-27T17:38:17-0400`.
- The candidate launched with `open -a /Applications/LanraragiDesk.app`,
  remained running, exposed its main accessibility window after activation,
  and populated Library with 30 archive images from the saved HTTP profile.
  The app was returned to its prior not-running state after verification.
- The saved profile inventory contained one HTTP profile and no HTTPS profile.
  No endpoint, credential, or other secret was copied into this report.
- Library accessibility verification selected List and then restored Grid. The
  selected states were `List=1` followed by `Grid=1`.
- Moving the Library grid scrollbar to the bottom grew the accessible archive
  image count from 30 to 45. The scrollbar was restored to the top.
- `~/Library/Application Support/LanraragiDesk/activity.json` parsed as a JSON
  array containing 2,000 events, was owner-writable, and had a newest event at
  `2026-08-27T16:14:56.787480Z`. Batch 6's 111 passing app tests include the
  `ActivityStoreTests` persistence and termination-flush coverage.
- Batch integration evidence supplied by the batch coordinator for this exact
  commit and fresh Mac tree `/tmp/LanraragiDesk-batch6.33IfGi`:
  - native macOS arm64 app tests: 111 passed, 0 failed, 0 skipped;
  - `LanraragiKit`: 53 XCTest tests plus 1 Swift Testing example passed, with
    0 failures;
  - clean app build with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and
    `GCC_TREAT_WARNINGS_AS_ERRORS=YES`: exit 0;
  - installed bundle passed strict deep signature verification.
  - Xcode also emitted an out-of-date CoreSimulator/iOS-device diagnostic; it
    did not affect the native macOS destination or result.

Representative commands used for read-only verification:

```sh
git rev-parse HEAD
ssh chronostriker1@macbook-pro.local 'sw_vers -productVersion; uname -m; xcodebuild -version'
ssh chronostriker1@macbook-pro.local 'codesign --verify --deep --strict /Applications/LanraragiDesk.app'
ssh chronostriker1@macbook-pro.local 'open -a /Applications/LanraragiDesk.app; pgrep -x LanraragiDesk'
# System Events accessibility inspection toggled Library Grid/List and scrolled the grid.
# Python's json module validated activity.json and counted records without printing content.
```

## Environment

| Check | Status | Evidence or blocker |
|---|---|---|
| Confirm app launches and connects to target server profile. | **Pass** | Installed candidate launched and remained alive; after activation, Library populated 30 archive images from the saved HTTP profile. |
| Confirm both HTTP and HTTPS profile endpoints can complete `Test Connection`. | **Blocked** | The Mac has one saved HTTP profile and no HTTPS profile. Completing the exact UI check requires a known-good HTTPS profile and explicit operation of `Test Connection`; URL-construction unit tests are not a substitute for a live authenticated check. |
| Confirm Activity log is writable (`~/Library/Application Support/LanraragiDesk/activity.json` updates). | **Pass** | File is writable and valid JSON with 2,000 events and a newest event dated 2026-08-27. All Batch 6 `ActivityStoreTests` passed, including durable flush behavior. |

## Library

| Check | Status | Evidence or blocker |
|---|---|---|
| Open Library in both Grid and List layout. | **Pass** | Accessibility state changed Grid → List (`List=1`) → Grid (`Grid=1`). |
| Verify archives load, paginate, and continue loading when scrolling. | **Pass** | Library initially exposed 30 archive images. Scrolling to the bottom increased that count to 45 without an error, demonstrating a subsequent page load. |
| Verify search submit works and category/new/untagged filters update results. | **Blocked** | Remote accessibility could not reliably edit/commit the SwiftUI search field, and a controlled expected-result query/filter fixture was not available. Needs an operator to submit a known query and compare result counts for a known category, New only, and Untagged only. |
| Verify archive selection checkbox is stable on hover and easy to click. | **Blocked** | Hover stability and click usability are visual/manual qualities not established by the unit suite or accessibility tree. Needs an operator with pointer access. |
| Verify metadata edits from editor are reflected after refresh. | **Blocked** | Requires a reversible test archive and authorized server metadata write, which were outside this read-only pass. |

## Reader

| Check | Status | Evidence or blocker |
|---|---|---|
| Open reader from Library and confirm first page loads. | **Blocked** | Requires controlled selection of an archive and visual confirmation that decoded page content rendered. Existing loader tests do not prove the installed UI. |
| Verify left/right arrow, space/shift-space, and escape behavior. | **Blocked** | Navigation model tests passed in Batch 6, but installed-app keyboard behavior needs an operator in an open reader window. |
| Verify `Open in LANraragi` opens `/reader?id=<arcid>` in browser. | **Blocked** | Requires opening an external browser and observing its URL; that side effect was not performed in this read-only pass. |
| Verify toolbar controls remain usable in narrow window widths. | **Blocked** | Requires visual/manual resizing and interaction at a documented narrow width. |

## Metadata Editor + Plugins

| Check | Status | Evidence or blocker |
|---|---|---|
| Open editor and save title/tags/summary changes. | **Blocked** | Requires a reversible test archive and authorized server metadata write. |
| Run a plugin from editor and confirm result updates fields. | **Blocked** | Requires a known safe plugin, test archive, and authorized server/plugin operation. |
| Verify source-tag click opens URL in browser. | **Blocked** | Requires a suitable source tag and external-browser side effect. |
| Verify saving with no changes does not submit duplicate metadata write. | **Blocked** | Requires request instrumentation or server logs while operating the installed editor; neither was available under read-only scope. |

## Batch (Tags + Plugins)

| Check | Status | Evidence or blocker |
|---|---|---|
| Queue tag batch and confirm pause/resume/cancel behavior. | **Blocked** | Requires a disposable archive set and authorized state-changing batch operations. |
| Queue plugin batch with preview enabled and verify preview rows/log updates. | **Blocked** | Batch preview workflow unit tests passed, but the installed UI check requires a known safe plugin and controlled archive set. |
| Queue plugin batch with preview disabled and verify metadata saves to server. | **Blocked** | Requires authorized server metadata writes. |
| Confirm resume after relaunch restores recoverable batch and redoes last archive. | **Blocked** | Source contains checkpoint UI restoration and last-archive redo logic, but end-to-end confirmation requires interrupting an authorized live batch and relaunching. |

## Duplicates

| Check | Status | Evidence or blocker |
|---|---|---|
| Run duplicate scan and confirm groups/pairs render. | **Blocked** | Running a live scan changes the local fingerprint index and requires visual result confirmation. No disposable index/profile fixture was provided. |
| Open inline edit from left and right sides; verify editor stays fully visible even after scrolling page previews. | **Blocked** | Requires duplicate results plus visual/manual scrolling on both sides. |
| Save metadata changes from inline duplicates editor and confirm values refresh in compare panel without leaving the pair. | **Blocked** | Requires an authorized server metadata write against a reversible pair. |
| Use page tile context menu `Set as cover (page N)` on both sides and confirm cover thumbs refresh in compare + pair list. | **Blocked** | Requires authorized cover writes and visual confirmation on a reversible pair. |
| Mark pair as `Not a match`; confirm it disappears from results. | **Blocked** | Changes the user's local duplicate decisions. A disposable index was not provided. |
| Open embedded `Not a match` manager, search by arcid, remove a pair, and undo. | **Blocked** | Changes the user's local duplicate decisions and needs a known disposable pair. |
| Force an error-path (bad connection or cancelled run) and verify failed-state actions (`Retry`, `Copy Error`) work. | **Blocked** | Requires intentionally disturbing profile/run state and manual clipboard/UI verification. |

## Activity

| Check | Status | Evidence or blocker |
|---|---|---|
| Confirm severity icons/chips appear on new entries. | **Blocked** | Requires generating known entries and visually checking icon/chip rendering. |
| Confirm filtering/search works for title, detail, and metadata. | **Blocked** | Requires interactive entry queries with known expected matches in the installed UI. |
| Export filtered entries to JSON and CSV and verify files are created. | **Blocked** | Requires Save-panel interaction and filesystem writes. No export destination was authorized for this read-only pass. |

## Final Sanity

| Check | Status | Evidence or blocker |
|---|---|---|
| Build succeeds. | **Pass** | Exact-commit Batch 6 clean native macOS build exited 0 with Swift and Clang warnings treated as errors. App and package test suites also passed. |
| README roadmap reflects current state of implemented/unimplemented work. | **Pass** | README marks checkpoint restoration and diagnostic-bundle work complete; matching implementations are present in `BatchView+TagBatch.swift`, `BatchView+PluginBatch.swift`, and `ActivityView.swift`. No unchecked roadmap entry is presented as implemented. |

## Evidence needed to clear blockers

1. A known-good HTTPS LANraragi test profile, plus an operator-recorded successful
   `Test Connection` result for both HTTP and HTTPS.
2. A disposable archive/pair set and permission to perform reversible metadata,
   cover, plugin, batch, scan, and `Not a match` mutations.
3. An interactive Mac operator pass for hover behavior, keyboard shortcuts,
   narrow-window controls, context menus, browser opening, clipboard checks, and
   Save-panel exports.
4. For “no duplicate metadata write,” request-level evidence such as a controlled
   proxy trace or server log showing the number of metadata update requests.
