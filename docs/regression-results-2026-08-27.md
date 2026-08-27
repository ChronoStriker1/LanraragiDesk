# Regression Results — 2026-08-27

Release-candidate commit: `81b6afaf7b440739fddc6fe78ee347105a550d98`

Checklist source: [`REGRESSION_CHECKLIST.md`](REGRESSION_CHECKLIST.md)

## Summary

| Status | Count |
|---|---:|
| Pass | 6 |
| Fail | 0 |
| Blocked | 26 |
| Not Applicable | 0 |
| **Total** | **32** |

Per-section reconciliation:

| Section | Pass | Blocked | Total |
|---|---:|---:|---:|
| Environment | 2 | 1 | 3 |
| Library | 2 | 3 | 5 |
| Reader | 0 | 4 | 4 |
| Metadata Editor + Plugins | 0 | 4 | 4 |
| Batch (Tags + Plugins) | 0 | 4 | 4 |
| Duplicates | 0 | 7 | 7 |
| Activity | 0 | 3 | 3 |
| Final Sanity | 2 | 0 | 2 |
| **Total** | **6** | **26** | **32** |

No product failure was observed. This is not a fully qualified manual release
pass: the 26 blocked checks still need the access or operator evidence listed
below. Every blocked row is linked to [#77][blocker-77], which is the remaining
release-readiness gate. Closing the checklist-recording issue does not imply
that #77 or the release gate is complete.

The #77 follow-up pass re-ran the safe environment checks against the Batch 7
candidate and attempted the remaining local-only UI checks. It did not promote
any blocked row: the app's saved window was outside the sole active display,
and the user's frontmost app repeatedly reclaimed focus during bounded
automation. Moving the window onscreen temporarily did not make scripted
SwiftUI search submission reliable. The window position, empty search draft,
profile file, and running state were restored, and focus was left with the
user's current app; no server write,
Unraid access, scan, batch, plugin, or duplicate-decision mutation was made.

## Environment and evidence

- MacBook Pro (`MacBook-Pro`), macOS 26.6.2, Apple Silicon (`arm64`), Xcode
  26.6 (build 17F113).
- Installed candidate: `/Applications/LanraragiDesk.app`, version 1.1 (build
  2). `codesign --verify --deep --strict` passed. The bundle's recorded
  modification time was `2026-08-27T18:20:48-0400`.
- The Batch 6 baseline launched with
  `open -a /Applications/LanraragiDesk.app`, remained running, exposed its main
  accessibility window after activation, and populated Library with 30 archive
  images from the saved HTTP profile. The #77 follow-up launched the Batch 7
  candidate and exposed 25 current Library images before restoring the app's
  prior not-running state.
- The installed app's `Test Connection` completed against the saved,
  authenticated HTTP profile and displayed `OK • v0.9.81`. A separate
  read-only `/api/info` request identified the server software as LANraragi
  0.9.81. No private endpoint or credential is included in this report.
- The saved profile inventory contained one HTTP profile and no HTTPS profile.
  A temporary no-key profile for the public LANraragi HTTPS demo confirmed
  HTTP 200, name `LANraragi Demo`, and version 0.9.81 at `/api/info`. The app's
  `Test Connection` stopped at `API key missing`, because this candidate
  requires a stored credential before making that request. The original
  profile was restored byte-for-byte afterward; its SHA-256 remained
  `dd08160f4e6e93b78b2796ee6bd1d228734a9e65314ca5036d74d99a1d7a29b2`.
- Library accessibility verification selected List and then restored Grid. The
  selected states were `List=1` followed by `Grid=1`.
- Moving the Library grid scrollbar to the bottom grew the accessible archive
  image count from 30 to 45. The scrollbar was restored to the top.
- `~/Library/Application Support/LanraragiDesk/activity.json` parsed as a JSON
  array containing 2,000 events and was owner-writable. During this session,
  the safe server-read-only `Refresh Now` tag-suggestions action changed the
  file's modification time from nanoseconds `1787847296794386576` to
  `1787868147638330555`; the newest persisted event became
  `Refreshed tag suggestions` at `2026-08-27T22:02:26.512805Z`. The count
  remained 2,000 because the store intentionally caps retained events. Batch
  7's 135 passing app tests also include `ActivityStoreTests` persistence and
  termination-flush coverage.
- Batch integration evidence supplied by the batch coordinator for this exact
  Batch 7 candidate:
  - native macOS arm64 app tests: 135 passed, 0 failed, 0 skipped;
  - `LanraragiKit`: 53 XCTest tests plus 1 Swift Testing example passed, with
    0 failures;
  - clean app build with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and
    `GCC_TREAT_WARNINGS_AS_ERRORS=YES`: exit 0;
  - installed bundle passed strict deep signature verification.
  - Xcode also emitted an out-of-date CoreSimulator/iOS-device diagnostic; it
    did not affect the native macOS destination or result.
- During the #77 follow-up, CoreGraphics reported one active display with
  bounds `(0, 0, 1800, 1169)`, while the app's persisted window was at
  `(-1310, 40)` with size `(1350, 1129)`. The window was temporarily moved
  onscreen for a bounded attempt, then restored exactly. Hermes and later cmux
  reclaimed frontmost status; scripted edits did not submit a Library query or
  alter the 25 visible-result image count. Coordinate/focus-sensitive testing
  was stopped rather than treating this as product evidence.
- The saved profile file's SHA-256 remained
  `dd08160f4e6e93b78b2796ee6bd1d228734a9e65314ca5036d74d99a1d7a29b2`.
  The app was quit after the attempt, matching its initial not-running state.

Representative commands used for verification (the UI commands run on the
approved Mac with the relevant app section already selected):

```sh
git rev-parse HEAD
ssh chronostriker1@macbook-pro.local 'sw_vers -productVersion; uname -m; xcodebuild -version'
ssh chronostriker1@macbook-pro.local 'codesign --verify --deep --strict /Applications/LanraragiDesk.app'
ssh chronostriker1@macbook-pro.local 'open -a /Applications/LanraragiDesk.app; pgrep -x LanraragiDesk'

# Library: select List, restore Grid, and report the selected states.
osascript <<'OSA'
tell application "System Events" to tell process "LanraragiDesk"
    tell radio group 1 of group 1 of front window
        click radio button 2
        set listState to value of radio button 2
        click radio button 1
        return {listState, value of radio button 1}
    end tell
end tell
OSA

# Library: move to the bottom, wait for pagination, report image counts, restore top.
osascript <<'OSA'
tell application "System Events" to tell process "LanraragiDesk"
    tell scroll area 2 of group 1 of front window
        set beforeImages to count of images of UI element 1
        set value of scroll bar 1 to 1
        delay 5
        set afterImages to count of images of UI element 1
        set value of scroll bar 1 to 0
        return {beforeImages, afterImages}
    end tell
end tell
OSA

# Settings: run the app's authenticated connection test and read its status pill.
osascript <<'OSA'
tell application "System Events" to tell process "LanraragiDesk"
    tell scroll area 2 of group 1 of front window
        click button 1
        delay 5
        return name of every static text
    end tell
end tell
OSA

# Validate the persisted activity file without printing event details or secrets.
/usr/bin/python3 <<'PY'
import json, os
p = os.path.expanduser("~/Library/Application Support/LanraragiDesk/activity.json")
events = json.load(open(p))
print(type(events).__name__, len(events), os.access(p, os.W_OK), os.stat(p).st_mtime_ns)
PY

# Prove an in-app action advances activity.json on disk.
activity="$HOME/Library/Application Support/LanraragiDesk/activity.json"
before=$(stat -f %m "$activity")
osascript -e 'tell application "System Events" to tell process "LanraragiDesk" to tell group 5 of scroll area 2 of group 1 of front window to click button 1'
sleep 12
after=$(stat -f %m "$activity")
test "$after" -gt "$before"
```

## Environment

| Check | Status | Evidence or blocker |
|---|---|---|
| Confirm app launches and connects to target server profile. | **Pass** | Installed candidate launched and remained alive; after activation, Library populated 30 archive images from the saved HTTP profile. |
| Confirm both HTTP and HTTPS profile endpoints can complete `Test Connection`. | **Blocked ([#77][blocker-77])** | The saved authenticated HTTP profile passed and reported v0.9.81. The public HTTPS demo's `/api/info` is healthy (HTTP 200, LANraragi Demo v0.9.81), but the candidate requires a stored API key before its UI test sends the request, so a no-key demo profile reports `API key missing`. Needs a credentialed HTTPS fixture or a deliberate product decision to allow no-key connection tests. |
| Confirm Activity log is writable (`~/Library/Application Support/LanraragiDesk/activity.json` updates). | **Pass** | A safe in-app tag-suggestions refresh changed `activity.json`'s modification time and persisted a new timestamped `Refreshed tag suggestions` event. The file remained valid JSON and owner-writable. All Batch 6 `ActivityStoreTests` also passed. |

## Library

| Check | Status | Evidence or blocker |
|---|---|---|
| Open Library in both Grid and List layout. | **Pass** | Accessibility state changed Grid → List (`List=1`) → Grid (`Grid=1`). |
| Verify archives load, paginate, and continue loading when scrolling. | **Pass** | Library initially exposed 30 archive images. Scrolling to the bottom increased that count to 45 without an error, demonstrating a subsequent page load. |
| Verify search submit works and category/new/untagged filters update results. | **Blocked ([#77][blocker-77])** | Remote accessibility could not reliably edit/commit the SwiftUI search field, and a controlled expected-result query/filter fixture was not available. Needs an operator to submit a known query and compare result counts for a known category, New only, and Untagged only. |
| Verify archive selection checkbox is stable on hover and easy to click. | **Blocked ([#77][blocker-77])** | Hover stability and click usability are visual/manual qualities not established by the unit suite or accessibility tree. Needs an operator with pointer access. |
| Verify metadata edits from editor are reflected after refresh. | **Blocked ([#77][blocker-77])** | Requires a reversible test archive and authorized server metadata write, which were outside this read-only pass. |

## Reader

| Check | Status | Evidence or blocker |
|---|---|---|
| Open reader from Library and confirm first page loads. | **Blocked ([#77][blocker-77])** | Requires controlled selection of an archive and visual confirmation that decoded page content rendered. Existing loader tests do not prove the installed UI. |
| Verify left/right arrow, space/shift-space, and escape behavior. | **Blocked ([#77][blocker-77])** | Navigation model tests passed in Batch 6, but installed-app keyboard behavior needs an operator in an open reader window. |
| Verify `Open in LANraragi` opens `/reader?id=<arcid>` in browser. | **Blocked ([#77][blocker-77])** | Requires opening an external browser and observing its URL; that side effect was not performed in this read-only pass. |
| Verify toolbar controls remain usable in narrow window widths. | **Blocked ([#77][blocker-77])** | Requires visual/manual resizing and interaction at a documented narrow width. |

## Metadata Editor + Plugins

| Check | Status | Evidence or blocker |
|---|---|---|
| Open editor and save title/tags/summary changes. | **Blocked ([#77][blocker-77])** | Requires a reversible test archive and authorized server metadata write. |
| Run a plugin from editor and confirm result updates fields. | **Blocked ([#77][blocker-77])** | Requires a known safe plugin, test archive, and authorized server/plugin operation. |
| Verify source-tag click opens URL in browser. | **Blocked ([#77][blocker-77])** | Requires a suitable source tag and external-browser side effect. |
| Verify saving with no changes does not submit duplicate metadata write. | **Blocked ([#77][blocker-77])** | Requires request instrumentation or server logs while operating the installed editor; neither was available under read-only scope. |

## Batch (Tags + Plugins)

| Check | Status | Evidence or blocker |
|---|---|---|
| Queue tag batch and confirm pause/resume/cancel behavior. | **Blocked ([#77][blocker-77])** | Requires a disposable archive set and authorized state-changing batch operations. |
| Queue plugin batch with preview enabled and verify preview rows/log updates. | **Blocked ([#77][blocker-77])** | Batch preview workflow unit tests passed, but the installed UI check requires a known safe plugin and controlled archive set. |
| Queue plugin batch with preview disabled and verify metadata saves to server. | **Blocked ([#77][blocker-77])** | Requires authorized server metadata writes. |
| Confirm resume after relaunch restores recoverable batch and redoes last archive. | **Blocked ([#77][blocker-77])** | Source contains checkpoint UI restoration and last-archive redo logic, but end-to-end confirmation requires interrupting an authorized live batch and relaunching. |

## Duplicates

| Check | Status | Evidence or blocker |
|---|---|---|
| Run duplicate scan and confirm groups/pairs render. | **Blocked ([#77][blocker-77])** | Running a live scan changes the local fingerprint index and requires visual result confirmation. No disposable index/profile fixture was provided. |
| Open inline edit from left and right sides; verify editor stays fully visible even after scrolling page previews. | **Blocked ([#77][blocker-77])** | Requires duplicate results plus visual/manual scrolling on both sides. |
| Save metadata changes from inline duplicates editor and confirm values refresh in compare panel without leaving the pair. | **Blocked ([#77][blocker-77])** | Requires an authorized server metadata write against a reversible pair. |
| Use page tile context menu `Set as cover (page N)` on both sides and confirm cover thumbs refresh in compare + pair list. | **Blocked ([#77][blocker-77])** | Requires authorized cover writes and visual confirmation on a reversible pair. |
| Mark pair as `Not a match`; confirm it disappears from results. | **Blocked ([#77][blocker-77])** | Changes the user's local duplicate decisions. A disposable index was not provided. |
| Open embedded `Not a match` manager, search by arcid, remove a pair, and undo. | **Blocked ([#77][blocker-77])** | Changes the user's local duplicate decisions and needs a known disposable pair. |
| Force an error-path (bad connection or cancelled run) and verify failed-state actions (`Retry`, `Copy Error`) work. | **Blocked ([#77][blocker-77])** | Requires intentionally disturbing profile/run state and manual clipboard/UI verification. |

## Activity

| Check | Status | Evidence or blocker |
|---|---|---|
| Confirm severity icons/chips appear on new entries. | **Blocked ([#77][blocker-77])** | Requires generating known entries and visually checking icon/chip rendering. |
| Confirm filtering/search works for title, detail, and metadata. | **Blocked ([#77][blocker-77])** | Requires interactive entry queries with known expected matches in the installed UI. |
| Export filtered entries to JSON and CSV and verify files are created. | **Blocked ([#77][blocker-77])** | Temporary `/tmp` exports were authorized, but the app window was outside the sole active display and Hermes/cmux repeatedly reclaimed focus. The bounded onscreen attempt was restored without entering Activity or a Save panel. Needs a hands-on Save-panel pass and validation of both output formats. |

## Final Sanity

| Check | Status | Evidence or blocker |
|---|---|---|
| Build succeeds. | **Pass** | Exact-commit Batch 7 clean native macOS build exited 0 with Swift and Clang warnings treated as errors. All 135 app tests, 53 package XCTest tests, and 1 Swift Testing example passed. |
| README roadmap reflects current state of implemented/unimplemented work. | **Pass** | README marks checkpoint restoration and diagnostic-bundle work complete; matching implementations are present in `BatchView+TagBatch.swift`, `BatchView+PluginBatch.swift`, and `ActivityView.swift`. No unchecked roadmap entry is presented as implemented. |

## Evidence needed to clear blockers

1. A credentialed HTTPS LANraragi test profile, or an intentional app change
   allowing `Test Connection` to call public `/api/info` endpoints without a
   stored key. The saved authenticated HTTP profile already passed.
2. A disposable archive/pair set and permission to perform reversible metadata,
   cover, plugin, batch, scan, and `Not a match` mutations.
3. An interactive Mac operator pass with the window on an active display for
   hover behavior, keyboard shortcuts, narrow-window controls, context menus,
   browser opening, clipboard checks, and Save-panel exports.
4. For “no duplicate metadata write,” request-level evidence such as a controlled
   proxy trace or server log showing the number of metadata update requests.

All items above, and every blocked table row, are tracked by
[#77][blocker-77].

[blocker-77]: https://github.com/ChronoStriker1/LanraragiDesk/issues/77
