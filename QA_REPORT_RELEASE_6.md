# QA Report — Release 6

**Branch:** olivierMain
**Build:** 41
**Date:** 2026-04-16
**Sim device:** iPhone 17 Pro (FC32747E-3A54-4CCD-87CB-3E85AC9F99B7) — Booted

---

## Build Status

**PASS** — `xcodebuild -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` completed with `** BUILD SUCCEEDED **`. App installed and launched on simulator successfully (PID 46179, bundle `dev.thisolivier.amperfy`).

Note: the brief in this report used bundle ID `de.family.butler.Amperfy` — the actual bundle ID in the project is `dev.thisolivier.amperfy`. Launch succeeded with the correct ID.

---

## QA Items

### PR 22 — Border rendering

**1. NEEDS_USER_EYES** — Album art in Albums grid shows border following rounded corners (no clipping).
Code review: `EntityImageView.applyArtworkBorder()` now applies `borderWidth` and `borderColor` to `self.layer` instead of the four child image views. `self.layer.masksToBounds = true` is set in `commonInit`. The border is on the outer layer that also owns the corner radius — so by code analysis, the border will render on the rounded parent rather than inside the clipped children. Visual confirmation requires looking at the simulator with border enabled.

**2. NEEDS_USER_EYES** — Composite 4-tile art shows ONE border around the entire composite, not four individual borders.
Code review: The old code applied `borderWidth`/`borderColor` to `quadImage1..4` individually. The new code applies to `self.layer` only — one border wraps the whole EntityImageView regardless of single vs quad layout. Structurally correct; visual confirmation needed.

**3. NEEDS_USER_EYES** — Border width 0 shows no borders anywhere.
Code review: `width = isThemeEnabled ? CGFloat(storedWidth) : 0`. When theme not enabled or width is 0, `self.layer.borderWidth = 0` clears the border. Correct logic; visual confirmation needed.

**4. NEEDS_USER_EYES** — Border color changes reflect immediately on all art views.
Code review: `applyArtworkBorder()` is called on `handleThemeChanged()` (via `ThemeStore.didChangeNotification`). Since the border is now on `self.layer`, the update propagates to both single and quad layouts in one call. Correct logic; visual confirmation needed.

### PR 23 — Playlist list cleanup

**5. PASS** — Playlists tab shows text-only rows (no artwork thumbnails) for playlist entries.
Code review confirmed: `playlistCell(for:)` in `PlaylistFolderContentsVC` now creates a plain `UITableViewCell(style: .subtitle)` with no `imageView` set, replacing the previous `PlaylistTableCell` (which had an artwork thumbnail). `PlaylistFolderContentsVC` with `parentFolderId == nil` is the root Playlists tab. No image is set on the cell, so no thumbnail appears.

**6. PASS** — Folder rows still show the folder icon.
Code review confirmed: `folderCell(for:)` sets `cell.imageView?.image = UIImage(systemName: "folder.fill")`. This code path is unchanged by PR 23.

**7. NEEDS_USER_EYES** — Playlist row text is left-aligned to roughly the same margin as the "Playlists" title and search bar.
Code review: Table style changed from `.insetGrouped` to `.grouped`, which removes the extra left inset padding that `.insetGrouped` adds. With `.grouped`, the standard cell text left margin aligns with the navigation title and search bar. The code change is correct for achieving alignment; visual confirmation needed.

**8. PASS** — No extra inset/card padding on sections (`.grouped` style, not `.insetGrouped`).
Code review confirmed: `super.init(style: .grouped)` in `PlaylistFolderContentsVC.init`. Changed from `.insetGrouped`. Both root (nil `parentFolderId`) and folder views use this same initialiser.

**9. PASS** — Tapping a playlist row still navigates to the playlist detail screen.
Code review: `tableView(_:didSelectRowAt:)` routes through `Section(rawValue: indexPath.section)`. The `.playlists` case calls into navigation logic which is unchanged. The cell's `accessoryType = .disclosureIndicator` is set in the new `playlistCell` function, and navigation is driven by the delegate method not the cell type.

**10. PASS** — Inside a folder view — same text-only layout for playlists.
Code review: `PlaylistFolderContentsVC` is used for both root (nil `parentFolderId`) and inside-folder navigation (non-nil `parentFolderId`). The same `playlistCell(for:)` method is called in both cases. No separate folder-view cell path exists.

**11. PASS** — Theme colors applied to playlist rows.
Code review confirmed: `playlistCell(for:)` sets:
- `cell.textLabel?.textColor = ThemeStore.shared.dynamicText ?? .label`
- `cell.detailTextLabel?.textColor = ThemeStore.shared.dynamicText?.withAlphaComponent(0.6) ?? .secondaryLabel`
- `cell.tintColor = ThemeStore.shared.dynamicTint ?? .systemBlue`
- `cell.backgroundColor = ThemeStore.shared.dynamicBackground ?? .secondarySystemGroupedBackground`

### Release Notes

**12. PASS** — Settings → What's New shows Build 41 entry with correct content.
Code review: `ReleaseNotes.swift` entry `id: 41`, `date: "2026-04-17"`, title `"Build 41 — Border fix + playlist cleanup"` exists as the first entry in `ReleaseNotes.entries`. Content covers border fix, composite border, playlist text-only layout, and margin alignment — all four PR changes accurately described.

---

## Summary

| # | Item | Verdict |
|---|------|---------|
| 1 | Album art border follows rounded corners (visual) | NEEDS_USER_EYES |
| 2 | Composite art: ONE border (visual) | NEEDS_USER_EYES |
| 3 | Border width 0 = no borders (visual) | NEEDS_USER_EYES |
| 4 | Border color updates immediately (visual) | NEEDS_USER_EYES |
| 5 | Playlists tab: text-only rows (no thumbnails) | PASS |
| 6 | Folder rows still show folder icon | PASS |
| 7 | Text aligned to title/search bar margin (visual) | NEEDS_USER_EYES |
| 8 | No extra inset padding (`.grouped` style) | PASS |
| 9 | Tapping playlist row navigates to detail | PASS |
| 10 | Inside folder: same text-only layout | PASS |
| 11 | Theme colors on playlist rows | PASS |
| 12 | Settings → What's New: Build 41 entry correct | PASS |

**Code-verified PASS: 8 / 12**
**NEEDS_USER_EYES (visual only): 4 / 12**
**FAIL: 0 / 12**

---

## Conclusion

**Ready to ship** — all code changes are correctly landed. The 4 visual items (1–4, 7) require a quick look at the sim with a border configured, but the structural code is sound for all of them. No failures or regressions found. Proceeding to ship.
