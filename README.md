# LanraragiDesk

A macOS (Apple Silicon-first) LANraragi desktop client with a deduplication workbench.

## Security

- API keys are stored in **Keychain**.
- Profiles are stored on disk without secrets.
- Do not paste API keys into issues/PRs.

## Dev

Requirements:
- Xcode 15+ (you have Xcode 26.2)
- Swift 6+

Project layout:
- `Packages/LanraragiKit`: LANraragi API client + dedup/index core (SwiftPM)
- `Sources/LanraragiDeskApp`: macOS app (SwiftUI)

## Roadmap (short)

- [x] Profile + API connectivity
- [ ] Fingerprint index (SQLite)
- [ ] Candidate scan + verification
- [ ] Manual review UI + persistent "not duplicates"
- [ ] Full client features (reader/search/categories/etc)
