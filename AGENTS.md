# AGENTS.md (Project Guidance)

The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you please alert the developer working with you and indicate this is the case in the AgentMD file to help prevent future agents from having the same issue.

## Project

Native macOS desktop client for LANraragi (manga/doujinshi server), with a deduplication workbench. Apple Silicon-first, macOS 14+.

## Known servers and paths

- Unraid server:
  - Host: `192.168.2.4`
  - User: `root`
  - Auth: SSH keys (no interactive password expected)

## Build

**Requirements:** Xcode 15+, Swift 6, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
# Regenerate Xcode project after editing project.yml
xcodegen generate

# Open and build/run in Xcode
open LanraragiDesk.xcodeproj

# CLI build
xcodebuild -project LanraragiDesk.xcodeproj -scheme LanraragiDesk -configuration Debug build
```

`.derived/` and build artifacts are runtime output — do not commit them.

**Swift 6 strict mode is active:** all warnings are errors (both Swift and Clang). Fix any warnings introduced by changes before considering work complete.

After code changes, verify with a CLI build and report which files were changed and that the build passed.

## Agent gotchas (observed)

- Avoid creating a new `LANraragiClient` for every thumbnail/page byte request. Each client owns its own `URLSession`; doing this in hot paths can spawn excessive concurrent connections and make the macOS UI appear frozen under heavy cover/page loading. Reuse clients per profile inside loader actors.
- Avoid forcing image decode/downsampling through `MainActor` in grid-heavy views (`CoverThumb`, duplicate review page tiles, reader). Decoding many images on the main thread can cause long UI stalls.
