# Design Review: Feature Sweep (Builds 8-20)

**Reviewer:** Designer Agent
**Date:** 2026-04-12
**Scope:** UX sweep of all shipped features. Excludes items already covered in DESIGN_REVIEW_PR9_V2.md (playlist folders), DESIGN_REVIEW_PR11.md (custom theme), and DESIGN_REVIEW_RECENTLY_ADDED_TRACKS.md.

---

## 1. Complete Albums Filter + Albums Split (PR 1 / PR 8 / Build 17)

### What shipped
Two separate Library entries: "Albums" (unfiltered) and "Complete Albums" (filtered by `remoteSongCount >= 3`, excluding singles). Migration adds "Complete Albums" for existing users.

### UX observations

**A. Naming ambiguity.** "Complete Albums" implies the album's tracks are fully downloaded or synced, not that it has enough tracks. A user might expect "Complete" means "all songs cached offline." Consider **"Full Albums"** or **"Albums (3+ tracks)"** as alternatives — though this is a naming preference, not a blocker.

**B. No visual indicator of the filter.** When browsing "Complete Albums," there's no persistent subtitle or badge telling the user what's excluded. If a user wonders why a specific album is missing, there's no discoverability path. **Suggestion:** Add a subtle footer or section header note: "Showing albums with 3 or more tracks" — similar to how Apple Music shows "Showing X of Y" in filtered views. Low priority but improves transparency.

**C. Migration placement.** `migrateCompleteAlbums()` inserts the new entry after `.albums` or at the start of `inUse`. If a user has customized their Library tab order, the new entry appears without explanation. This is acceptable for a TestFlight audience but would need a first-launch callout for a wider release.

**D. Sort/filter state is independent.** Each Albums view maintains its own sort and filter. This is correct — a user browsing "Complete Albums" by artist shouldn't affect the unfiltered "Albums" sort. No issue here.

---

## 2. Share Song (PR 6 / Build 16 rename)

### What shipped
"Share" action in song context menu. Downloads if not cached, presents `UIActivityViewController` with a renamed file ("Title - Artist.ext") and a text item.

### UX observations

**A. Temp file cleanup.** `ShareSongAction.swift:118` copies the cached file to a temp directory with the friendly name, but never cleans it up. Over time, `FileManager.default.temporaryDirectory` accumulates renamed song files. iOS eventually cleans temp, but the app should clean up after the activity controller completes. **Fix:** Use the `UIActivityViewController.completionWithItemsHandler` to remove the temp file after the share sheet dismisses. ~5 LOC.

**B. Filename character sanitization is incomplete.** Lines 113-114 replace `/` and `:` but not other filesystem-unsafe characters (`\`, `?`, `*`, `"`, `<`, `>`, `|`). Most song titles won't hit these, but a title like `"Why?"` would produce a file named `Why? - Artist.mp3` which could cause issues on some share targets (e.g., AirDrop to Windows via SMB). **Suggestion:** Use `CharacterSet` to strip all non-filename-safe characters in one pass.

**C. Two items in the share sheet.** The activity controller receives both the file URL and a text string (`"Title — Artist"`). Some share targets (Messages, Mail) will include both — the file as an attachment AND the text as message body. This is arguably the right behavior (the text acts as a caption), but it means sharing to Files.app shows both items. If Olivier finds the text redundant, it could be removed — the renamed filename already carries the title and artist. **Flag for preference.**

**D. Download side-effect.** Sharing a non-cached song triggers a permanent download to the offline library. The spec notes this intentionally, but the user isn't told. The progress alert says "Downloading..." but doesn't mention the song will stay cached. This is fine for a power-user audience but worth noting.

**E. No share for podcasts.** `ShareSongAction` accepts `AbstractPlayable` so it technically works for podcast episodes, but the context menu entry is only wired in `EntityPreviewActionBuilder` for songs. This is likely intentional scope limitation — just noting it.

---

## 3. "In Playlists" in Song Context Menu (PR 3 / Hotfix 4 / Build 20)

### What shipped
Long-press song > "In Playlists" shows a sheet listing which playlists contain the song. Tapping a playlist navigates to it. First use triggers sequential sync of all playlist items (O(n) API calls).

### UX observations

**A. First-use sync has no progress indication.** Hotfix 4 added `PlaylistItemsSyncTracker` that fetches unsynced playlists before querying. For a library with 50+ playlists, this is multiple seconds of waiting with no feedback. The user taps "In Playlists" and the sheet appears after a delay with no spinner or progress. **Suggestion:** Show the `PlaylistMembershipVC` immediately with an activity indicator, then populate the table when sync completes. This makes the feature feel responsive even when syncing.

**B. Empty state message could be more helpful.** "This song isn't in any playlists" is accurate, but doesn't offer an action. **Suggestion:** Add a secondary line: "Add it from the song's context menu" or a button to dismiss and show the "Add to Playlist" action. Low priority — the empty state is already clean.

**C. No search in the playlist list.** If a user has 30+ playlists containing a popular song, scrolling to find a specific one is tedious. Not a blocker for the TestFlight audience size, but worth tracking for scale.

**D. Navigation after dismiss.** Tapping a playlist in the sheet dismisses it and calls `onSelect`. The navigation happens via the callback, which pushes `PlaylistDetailVC`. If the user was in a deeply nested navigation stack (e.g., Artist > Album > Song context menu > In Playlists > tap playlist), the push adds another level. This is standard iOS navigation behavior and correct — just noting the stack can get deep.

---

## 4. Home Tab Sections — Favourites (PR 5 / Build 8)

### What shipped
Three new Home tab sections: Favourite Albums, Favourite Artists, Favourite Playlists. Hidden when empty. Backed by `PinnedPlaylistStore` (UserDefaults). Heart toggle in `PlaylistDetailVC`.

### UX observations

**A. Heart toggle discoverability.** The favourite heart is only in `PlaylistDetailVC` — you have to open a playlist to favourite it. There's no heart in the playlist list row or context menu. For albums and artists, the favourite mechanism uses the server's star/favourite API, which is a different system from `PinnedPlaylistStore`. **Potential confusion:** Users might not realize that "favourite" for playlists is local-only while album/artist favourites sync to the server. Not a bug — just a mental model mismatch to be aware of.

**B. Favourites bypass the Complete Albums filter.** The spec says this is intentional (F.4(b)). This means a user who curates their Home to only show "complete" albums will still see single-track favourited albums in the Favourites section. This is the right call — if a user explicitly favourites something, they want to see it.

**C. Section ordering.** Favourite sections appear after the standard sections (Random Albums, Recently Played, Newest Albums, Recent Tracks). With all sections visible, the Home tab is quite long. The user currently cannot reorder Home sections. **Future consideration:** A "Customize Home" settings screen (like Apple Music's) would let users choose which sections appear and in what order. Not actionable now, but the most impactful Home polish item.

---

## 5. Release Notes in Settings (PR 10 / Build 13)

### What shipped
"What's New" entry at top of Settings navigation. `WhatsNewSettingsView` renders the 5 most recent `ReleaseNote` entries with "What's New" and "Testing Focus" bullet sections.

### UX observations

**A. No "new" badge.** When a new build is installed, there's no visual indicator that release notes have been updated. The user has to remember to check. **Suggestion:** Show a small badge (red dot or "NEW" text) on the "What's New" row when the current build number is newer than the last-viewed build. Store `lastViewedBuildNumber` in UserDefaults. Clear the badge when the user opens the view. ~15 LOC. This directly addresses the feature's goal: closing the feedback loop between builds and testing.

**B. Static data maintenance burden.** `ReleaseNotes.swift` is a manual array literal updated at ship time. The `ship.sh` script prints a reminder, which is the right process. No UX issue — just noting the operational dependency.

**C. "Testing Focus" color.** The orange color for "Testing Focus" bullets is hardcoded (`.foregroundColor(.orange)`) and doesn't adapt to the custom theme's tint color. With a dark custom background + orange text, contrast may be poor. **Suggestion:** Use the theme's tint color for "Testing Focus" headers when custom theme is active, or verify the contrast ratio. Minor.

**D. All entries expanded.** Every release note is fully expanded on load. With 5 entries, scrolling to see older notes requires passing through all of the newest one's bullets. **Suggestion:** Collapse all except the newest entry by default, with a tap-to-expand. This is a polish item — the current always-expanded approach is simple and works fine for 5 entries.

---

## 6. Floating Action Bar (PR 9 v2 / Build 16)

### What shipped
Custom `editActionBar` UIView pinned above the tab bar, replacing the navigation controller toolbar that was hidden behind the tab bar.

### UX observations

**A. No selection count feedback.** The buttons enable/disable based on selection, but don't show how many items are selected. Apple's Mail and Files apps show "N Selected" in the toolbar during multi-select. **Suggestion:** Add a centered label in the action bar showing "N playlists selected" that updates as items are checked/unchecked. Improves confidence before committing to a batch action. ~10 LOC.

**B. Action bar doesn't theme.** The action bar uses `ThemeStore.shared.dynamicBackground` (confirmed in the code), so this is actually handled. Good.

**C. Keyboard avoidance.** If the search bar is active and the keyboard is up when the user enters edit mode, the action bar appears above the tab bar but could overlap with keyboard-pushed content. Edge case — unlikely in practice since search and edit mode are rarely active simultaneously.

---

## 7. Cross-Feature Observations

### A. Context menu consistency

The song context menu has grown significantly across these PRs:
- Play / Shuffle / Add to queue (stock)
- Add to Playlist (stock)
- **Share** (PR 6)
- **In Playlists** (PR 3)
- Download / Delete (stock)

The folder context menu has:
- Rename (PR 9)
- Delete Folder (PR 9)

**Observation:** "Share" and "In Playlists" are near each other in the menu. "In Playlists" is informational (shows which playlists), while "Add to Playlist" is an action (adds to a playlist). Their names are similar enough to cause momentary confusion. **Suggestion:** Rename "In Playlists" to "Show in Playlists" to better signal it's a lookup, not an action. Aligns with Apple's "Show in Finder" / "Show in Library" naming pattern.

### B. UserDefaults proliferation

Multiple features now use independent UserDefaults stores:
- `PinnedPlaylistStore` (favourites)
- `PlaylistFolderStore` (folders)
- `ThemeStore` (custom theme)
- `PlaylistItemsSyncTracker` (sync tracking)

Each has its own key prefix (`amperfy.fork.*`), which is clean. However, there's no unified "export my settings" or "reset all fork customizations" path. If Olivier wants to start fresh, he'd need to delete the app. **Future consideration:** A "Reset All Customizations" option in Settings that clears all `amperfy.fork.*` keys. Not urgent — just noting the accumulation.

### C. Empty state consistency

Different features handle empty states differently:
- Playlist folders: `UIContentUnavailableConfiguration.empty()` with icon + text
- In Playlists: `UIContentUnavailableConfiguration.empty()` with text only
- Home sections: Hidden entirely (`sectionsHiddenWhenEmpty`)
- What's New: Always has content (static data)

The first two approaches are inconsistent — folders show an icon, In Playlists doesn't. **Suggestion:** Add a playlist icon to the "In Playlists" empty state to match. 1 line.

### D. Theme interaction with all features

Build 19-20 brought comprehensive theme coverage, but a few feature-specific views deserve a spot check:
- `PlaylistMembershipVC` (In Playlists sheet): Uses standard table view — should pick up theme via `UIAppearance`. **Verify:** Does the sheet's navigation bar and background theme correctly?
- `WhatsNewSettingsView` (Release Notes): SwiftUI view. Standard SwiftUI `Text` views pick up theme via `Color.label` / `Color.systemBackground` from `UtilitiesExtensions`. The hardcoded `.orange` for Testing Focus bullets won't adapt. Already noted in 5C above.
- `ShareSongAction` progress alert: Uses `UIAlertController` — system-provided, won't theme. Acceptable.

---

## Summary: Priority-Ranked Action Items

| Priority | Feature | Item | Effort |
|----------|---------|------|--------|
| High | Release Notes | Add "new" badge on What's New row when build updated | ~15 LOC |
| High | In Playlists | Add loading spinner during first-use playlist sync | ~20 LOC |
| Medium | Share Song | Clean up temp files in completion handler | ~5 LOC |
| Medium | Context Menus | Rename "In Playlists" to "Show in Playlists" | ~2 LOC |
| Medium | Floating Action Bar | Add "N selected" count label | ~10 LOC |
| Low | Share Song | Expand filename sanitization to full character set | ~5 LOC |
| Low | Complete Albums | Add filter description footer text | ~5 LOC |
| Low | In Playlists | Add playlist icon to empty state | ~1 LOC |
| Low | Release Notes | Theme "Testing Focus" orange with custom tint | ~3 LOC |
| Future | Home Tab | "Customize Home" section reordering | Larger scope |
| Future | All | "Reset All Customizations" in Settings | ~20 LOC |
