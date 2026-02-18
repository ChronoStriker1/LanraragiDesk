# Regression Checklist

Use this checklist before release tags and after larger feature batches.

## Environment

- Confirm app launches and connects to target server profile.
- Confirm both HTTP and HTTPS profile endpoints can complete `Test Connection`.
- Confirm Activity log is writable (`~/Library/Application Support/LanraragiDesk/activity.json` updates).

## Library

- Open Library in both Grid and List layout.
- Verify archives load, paginate, and continue loading when scrolling.
- Verify search submit works and category/new/untagged filters update results.
- Verify archive selection checkbox is stable on hover and easy to click.
- Verify metadata edits from editor are reflected after refresh.

## Reader

- Open reader from Library and confirm first page loads.
- Verify left/right arrow, space/shift-space, and escape behavior.
- Verify `Open in LANraragi` opens `/reader?id=<arcid>` in browser.
- Verify toolbar controls remain usable in narrow window widths.

## Metadata Editor + Plugins

- Open editor and save title/tags/summary changes.
- Run a plugin from editor and confirm result updates fields.
- Verify source-tag click opens URL in browser.
- Verify saving with no changes does not submit duplicate metadata write.

## Batch (Tags + Plugins)

- Queue tag batch and confirm pause/resume/cancel behavior.
- Queue plugin batch with preview enabled and verify preview rows/log updates.
- Queue plugin batch with preview disabled and verify metadata saves to server.
- Confirm resume after relaunch restores recoverable batch and redoes last archive.

## Duplicates

- Run duplicate scan and confirm groups/pairs render.
- Mark pair as `Not a match`; confirm it disappears from results.
- Open embedded `Not a match` manager, search by arcid, remove a pair, and undo.
- Force an error-path (bad connection or cancelled run) and verify failed-state actions (`Retry`, `Copy Error`) work.

## Activity

- Confirm severity icons/chips appear on new entries.
- Confirm filtering/search works for title, detail, and metadata.
- Export filtered entries to JSON and CSV and verify files are created.

## Final Sanity

- Build succeeds:
  - `xcodebuild -project LanraragiDesk.xcodeproj -scheme LanraragiDesk -configuration Debug build`
- README roadmap reflects current state of implemented/unimplemented work.
