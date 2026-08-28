# Regression Results — 2026-08-27

The manual release pass begun on 2026-08-27 was completed on 2026-08-28 with
two disposable archives and controlled request tracing. All checklist rows are
now qualified.

Checklist source: [`REGRESSION_CHECKLIST.md`](REGRESSION_CHECKLIST.md)

## Validated candidate

- Validated `origin/main` commit:
  `c05d75b3176bdecf177e1cef5bb4be68e5fb159a`.
- Validated tree: `5a09156baae92ea05798d66e2656b81b7ec156ee`.
- The installed integration tip
  `1e78f9cef2a6701181eb4827c2356140d00c6d8c` had the identical tree.
- Installed bundle: LanraragiDesk 1.1 (build 2), native Apple Silicon.
- Target server: LANraragi 0.9.81. No credentials or private endpoint details
  are included in this report.

## Summary

| Status | Count |
|---|---:|
| Pass | 32 |
| Fail | 0 |
| Blocked | 0 |
| Not Applicable | 0 |
| **Total** | **32** |

| Section | Pass | Fail | Blocked | Total |
|---|---:|---:|---:|---:|
| Environment | 3 | 0 | 0 | 3 |
| Library | 5 | 0 | 0 | 5 |
| Reader | 4 | 0 | 0 | 4 |
| Metadata Editor + Plugins | 4 | 0 | 0 | 4 |
| Batch (Tags + Plugins) | 4 | 0 | 0 | 4 |
| Duplicates | 7 | 0 | 0 | 7 |
| Activity | 3 | 0 | 0 | 3 |
| Final Sanity | 2 | 0 | 0 | 2 |
| **Total** | **32** | **0** | **0** | **32** |

## Defects found and resolved during the pass

- [#82](https://github.com/ChronoStriker1/LanraragiDesk/issues/82): Library
  Search could retain the visible query while submitting a stale SwiftUI
  value. [PR #83](https://github.com/ChronoStriker1/LanraragiDesk/pull/83),
  merged as `1805d05a66af28554748a60cb520653a2196afbb`, retained the native search
  control, intercepted Return, and rejected stale unfiltered generations. The
  live retest returned exactly fixture B then A through the Search button,
  real Return (`keyCode 36`), and a 100 ms stale-load race.
- [#81](https://github.com/ChronoStriker1/LanraragiDesk/issues/81): the
  metadata editor discarded successful queued Minion metadata output.
  [PR #84](https://github.com/ChronoStriker1/LanraragiDesk/pull/84), merged as
  `c05d75b3176bdecf177e1cef5bb4be68e5fb159a`, decoded and applied queued
  results exactly once in editor and batch flows. Live job `105970` completed
  in one attempt, changed the title to `plugin fixture`, issued one metadata
  write, refreshed the editor, and did not rerun the plugin.

Both fixes completed their GLM-5.3-Flash audit/correction loops at 10/10 before
merge and were then exercised again in the installed application.

## Environment

| Check | Status | Evidence |
|---|---|---|
| Confirm app launches and connects to target server profile. | **Pass** | The installed arm64 app launched and populated Library from the saved profile. Its in-app connection test reported `OK • v0.9.81`. |
| Confirm both HTTP and HTTPS profile endpoints can complete `Test Connection`. | **Pass** | The saved authenticated HTTP profile reported `OK • v0.9.81`. A temporary profile using `https://lrr.tvc-16.science` returned HTTP 200 from `/api/info` (`LANraragi Demo`, v0.9.81) and the UI also reported `OK • v0.9.81`. The original profile was then restored and checksum-verified. |
| Confirm Activity log is writable. | **Pass** | An in-app refresh advanced `activity.json`, preserved valid JSON, and persisted the new activity entry. Later controlled actions and exports also appeared in the installed Activity UI. |

## Library

| Check | Status | Evidence |
|---|---|---|
| Open Library in both Grid and List layout. | **Pass** | Grid and List both rendered the controlled result set; switching either direction retained the same two archives and selection state. |
| Verify archives load, paginate, and continue loading when scrolling. | **Pass** | The normal library page loaded and its accessible archive count increased after scrolling to the end, proving the next page loaded. The controlled query rendered exactly B then A. |
| Verify search submit works and category/new/untagged filters update results. | **Pass** | After the #82 fix, the exact artist query returned B then A in both UI and API through button, real Return, and stale-load-race paths. On the two-fixture result, Untagged changed `2 → 0 → 2`, New remained 2, the first pinned category changed `2 → 0`, and All restored 2. |
| Verify archive selection checkbox is stable on hover and easy to click. | **Pass** | Real pointer hover left the 36×36 selection control stable; clicking changed `0 selected → 1 selected → 0 selected`. |
| Verify metadata edits from editor are reflected after refresh. | **Pass** | Fixture B's controlled title, tags, and summary change saved successfully and remained visible after refresh in Library/editor state. |

## Reader

| Check | Status | Evidence |
|---|---|---|
| Open reader from Library and confirm first page loads. | **Pass** | The first synthetic page visibly decoded and the two-page filmstrip rendered. |
| Verify left/right arrow, space/shift-space, and escape behavior. | **Pass** | In RTL mode: Right moved to `1/2`, Left to `2/2`, Space stayed at the end (`2/2`), Shift-Space moved to `1/2`, and Escape closed the reader. |
| Verify `Open in LANraragi` opens `/reader?id=<arcid>` in browser. | **Pass** | The command opened the exact fixture-B `/reader?id=<arcid>` URL in a browser; the test tab was then closed. |
| Verify toolbar controls remain usable in narrow window widths. | **Pass** | At 960×800 all reader toolbar controls remained visible and usable. |

## Metadata Editor + Plugins

| Check | Status | Evidence |
|---|---|---|
| Open editor and save title/tags/summary changes. | **Pass** | A controlled fixture edit saved all three fields, refreshed, and matched server metadata. |
| Run a plugin from editor and confirm result updates fields. | **Pass** | The initial run exposed #81. After PR #84, queued job `105970` finished in one attempt, applied `plugin fixture`, made exactly one metadata write, refreshed the field, and made no fallback rerun. |
| Verify source-tag click opens URL in browser. | **Pass** | Clicking the controlled source tag opened its exact stored URL in a browser; the test tab was then closed. |
| Verify saving with no changes does not submit duplicate metadata write. | **Pass** | An unchanged Save preserved the metadata checksum; a fresh Valkey trace recorded zero archive `HSET`/metadata writes. A changed-save positive control recorded exactly one write. |

## Batch (Tags + Plugins)

| Check | Status | Evidence |
|---|---|---|
| Queue tag batch and confirm pause/resume/cancel behavior. | **Pass** | A tag batch scoped only to A/B paused, resumed from the visible state, and cancelled without touching archives outside the fixture pair. |
| Queue plugin batch with preview enabled and verify preview rows/log updates. | **Pass** | `DateAddedPlugin` preview produced two populated rows and corresponding log updates while request tracing confirmed no metadata save. |
| Queue plugin batch with preview disabled and verify metadata saves to server. | **Pass** | Jobs `105971` (A) and `105972` (B) each finished in one attempt. A changed with one write; B was a zero-write no-op. Final counters were Success 2, Failed 0, Indeterminate 0. |
| Confirm resume after relaunch restores recoverable batch and redoes last archive. | **Pass** | A tag checkpoint for exactly A/B restored at `nextIndex=1`; Resume redid B as a zero-write no-op, completed normally, and cleared the checkpoint. |

## Duplicates

| Check | Status | Evidence |
|---|---|---|
| Run duplicate scan and confirm groups/pairs render. | **Pass** | A scan through the fixture-only proxy enumerated exactly A/B and rendered their duplicate pair. |
| Open inline edit from left and right sides; verify editor stays fully visible even after scrolling page previews. | **Pass** | Both inline editors opened after scrolling the temporary eight-page previews; each remained fully visible and usable. |
| Save metadata changes from inline duplicates editor and confirm values refresh in compare panel without leaving the pair. | **Pass** | The controlled inline save refreshed the compare values in place without dismissing or advancing the pair. |
| Use page tile context menu `Set as cover (page N)` on both sides and confirm cover thumbs refresh in compare + pair list. | **Pass** | Page 2 was set on both sides and both compare/list thumbnails refreshed. B emitted one cover PUT; A emitted two because the first automation attempt was deliberately repeated, with the same final cover. |
| Mark pair as `Not a match`; confirm it disappears from results. | **Pass** | Marking the exact pair removed it from the active results. |
| Open embedded `Not a match` manager, search by arcid, remove a pair, and undo. | **Pass** | Exact-arcid search found the pair; Remove changed database count `1 → 0` and enabled Undo, and Undo restored count `0 → 1`, the row, and disabled Undo. |
| Force an error-path and verify failed-state actions (`Retry`, `Copy Error`) work. | **Pass** | A single fixture-proxy HTTP 500 produced failed state; Copy Error placed the exact failure text on the clipboard. The same proxy was restarted, Retry completed, and the restored Not-a-match exclusion yielded `Scanned 2 / No Matches`. |

## Activity

| Check | Status | Evidence |
|---|---|---|
| Confirm severity icons/chips appear on new entries. | **Pass** | Newly generated information, warning, and error entries displayed their expected severity icons/chips. |
| Confirm filtering/search works for title, detail, and metadata. | **Pass** | Known controlled entries were independently found through title, detail, and metadata queries, and clearing each query restored the complete list. |
| Export filtered entries to JSON and CSV and verify files are created. | **Pass** | Both filtered exports were created; the JSON and CSV each parsed to 293 rows. The temporary export files were then deleted. |

## Final Sanity

| Check | Status | Evidence |
|---|---|---|
| Build succeeds. | **Pass** | The combined macOS arm64 build for the validated tree passed with Swift and Clang warnings treated as errors. The installed 1.1 (build 2) bundle passed strict deep signature verification. |
| README roadmap reflects current state of implemented/unimplemented work. | **Pass** | The roadmap's checked batch-recovery and Activity diagnostic items match their current implementations; no unchecked roadmap item is presented as complete. |

## Fixture isolation, restoration, and cleanup

The state-changing checks used only these two disposable archives:

- A: `08bd6297e6103cc794ca310b0688ef8404490591`
- B: `eb359e7dae254aa7b24c72c787016cd5fd2564d3`

The localhost regression proxy forced archive enumeration to the exact fixture
result set, rejected non-fixture archive access and random search locally,
allowed the required read-only control endpoints and A/B traffic, counted
fixture metadata/cover writes, and injected only the requested one-shot error.
The user's API key was loaded from the existing credential store and was never
printed or written to a test artifact. Pre-test preferences, profiles, and
runtime state were backed up before mutation; post-test state was retained
until byte-level restoration checks passed.

Restoration evidence:

- Preferences SHA-256:
  `4b8fff2c224028f32562fed3b0b6e9d2f61eb8a04b413b967434b8081f15cb01`.
- Profiles SHA-256:
  `dd08160f4e6e93b78b2796ee6bd1d228734a9e65314ca5036d74d99a1d7a29b2`.
- Runtime database, WAL, shared-memory file, and activity log matched the
  canonical backup byte-for-byte after restoration.
- All temporary proxies, monitors, response files, screenshots, exports, and
  rollback copies were removed. No helper remained, port 18777 had no
  listener, and LanraragiDesk was stopped.
- Hermes and cmux were visible, T3 Code (Alpha) was frontmost, and the pointer
  was restored to `(1280, 168)`.

Both archive deletes returned API success. The exact artist search then
returned zero results and neither fixture file remained in the library. This
LANraragi version returns HTTP 400 with `This ID does not exist on the server.`
for deleted metadata IDs rather than HTTP 404/410. The temporary server-side
fixture backups were removed after those checks, so the fixture deletion is
unrecoverable. Canonical user-state backups were preserved.

This report completes [#77](https://github.com/ChronoStriker1/LanraragiDesk/issues/77).
