# Design Review — Custom Feature Sweep

**Reviewer:** Designer Agent
**Date:** 2026-04-12
**Branch:** spike/extension-eval
**Scope:** All 10 custom features added to the Amperfy fork

---

## Summary

Ten features reviewed. Two confirmed code bugs found. Several missing empty states, one infinite-spinner defect, and a pervasive accessibility gap across all features. Items below are actionable and tied to specific files and line numbers.

Priority scale:
- **P0** — Broken UX that actively confuses or blocks users
- **P1** — Missing polish that makes features feel unfinished
- **P2** — Nice-to-have improvements

---

## Feature 1 — Whole Album Primitive

**Files:** `AlbumsCollectionVC.swift`, `AlbumsCommonVCInteractions.swift`, `WholeAlbumPredicates.swift`

### Issues

**P1 — Albums tab has no empty state for "Complete Albums" when the filter is very strict**
If a library consists entirely of singles (all albums have < 3 tracks), the "Complete Albums" tab shows a blank collection view with no explanation. The standard Amperfy `emptyContentConfig` is applied for search-miss cases but not for the "filter eliminated everything" case. Add an empty state: *"No albums with 3 or more tracks found."*

**P1 — Off-by-one in `indexTitles` (`AlbumsCollectionVC.swift:100`)**
```swift
for i in 0 ... sectionCount {   // ← inclusive upper bound
```
`numberOfSections` returns `sectionCount`; valid indices are `0..<sectionCount`. The loop iterates one extra time, calling `getFirstAlbum(in: sectionCount)` which returns `nil`, causing `sectionTitle(for:)` to return `""` and producing a blank phantom entry at the bottom of the section index bar. Should be `0 ..< sectionCount`. (The Build 10 changelog mentions fixing an off-by-one — this may be a regression or a different one.)

**P2 — "Complete Albums" label is not self-explanatory**
Users won't know what "complete" means without reading documentation. Consider a tooltip or subtitle: *"Albums with 3 or more tracks."* Or rename to "Full Albums (3+ tracks)" for clarity.

**P2 — Three different `minSongCount` thresholds are hardcoded in different files**
Library Albums: 3, Home Newest Albums: 3, Recently Added Tracks: 5. There is no shared constant. A change to one doesn't propagate to others.

---

## Feature 2 — Recently Added Tracks Widget

**Files:** `RecentTracksDetailVC.swift`

### Issues

**P0 — Section header constraints accumulate on each scroll-off/scroll-on cycle**
`viewForHeaderInSection` (`RecentTracksDetailVC.swift:298-323`) creates a fresh `UIView()` on every call. `modeControl`, `stepperLabel`, and `stepper` are instance variables (created once), so they get re-added to the new header view each time the header re-enters the visible area. `NSLayoutConstraint.activate([...])` is called each time without removing the previous constraints. When a view moves to a new superview, UIKit deactivates constraints linking it to its previous superview, but constraints between the subviews themselves survive. Over repeated scroll cycles, conflicting constraints accumulate, producing Autolayout warnings and potentially layout drift. **Fix:** Cache the header view in an instance variable and return the same instance each time, or deactivate old constraints before activating new ones.

**P1 — No empty state when there are zero qualifying tracks**
When `songs.isEmpty` after `refreshSongs()`, the table displays a completely blank screen. No `contentUnavailableConfiguration` is set. Every other modal sheet in these features (PlaylistMembershipVC, RelatedTracksVC) uses `UIContentUnavailableConfiguration.empty()`. Add: *"No recently added singles or EPs"* with a secondary note about the 5-track threshold.

**P1 — No loading state during `refreshSongs()`**
`refreshSongs()` is a synchronous main-context Core Data fetch. For large libraries it may take >100ms, during which the table reloads abruptly with no visual indicator. Consider a brief spinner or at minimum prevent the jarring reload flash by using `performBatchUpdates` or an animated diff.

**P2 — Mode segmented control labels ("Top N", "Last M days") don't reflect current values**
A user glancing at the control can't tell what N or M currently are. Consider embedding the values: *"Top 14"* / *"Last 7 days"* as segment titles (updated as the stepper changes), so the control itself is self-describing at a glance.

**P2 — Threshold inconsistency is invisible to users**
An album with 4 tracks appears in "Newest Albums" (threshold 3) but its tracks don't appear in "Recently Added Tracks" (threshold 5). Users will notice the discrepancy without any explanation. A small info button or subtitle on the section header ("Singles and EPs with fewer than 5 tracks") would prevent confusion.

---

## Feature 3 — Show in Playlists

**Files:** `PlaylistMembershipVC.swift`

### Issues

**P0 — No timeout on playlist sync: infinite spinner**
`PlaylistMembershipVC` shows a loading spinner (`UIContentUnavailableConfiguration.loading()`) while waiting for background playlist sync. The sync has no completion callback into this VC and no timeout guard. If the server is slow, offline, or the sync silently fails, the spinner shows forever. The user sees "Syncing playlists…" indefinitely; the only escape is the Done button. Compare with `ShareSongAction.swift` which has a 60-second polling timeout. Add a timeout (e.g., 30s) that transitions to an error state: *"Couldn't load playlists — check your connection."*

**P1 — Error state is missing**
If sync fails (network error, server 500), the sheet has no error state. It stays on the loading spinner until dismissed. Add a retry button in the error state.

**P1 — No indication of which playlists are being synced**
"Syncing playlists…" is generic. For a user with 200 playlists, this could take several seconds. Even a simple *"Syncing N playlists…"* count would set expectations.

**P2 — Sheet title "Show in Playlists" vs nav bar title "Show in Playlists"**
Consistent, good. Minor: the sheet could benefit from a subtitle showing the song title, so users remember which song they long-pressed while the sheet loads.

---

## Feature 4 — Playlist Folders

**Files:** `PlaylistFolderContentsVC.swift`, `PlaylistFolderStore.swift`

### Issues

**P1 — Duplicate folder names allowed at the same level**
Creating two folders both named "Rock" in the same parent is silently permitted. The second appears immediately below the first with no warning. Users who create duplicates will not understand why there are two. Add a unique-name check within the same parent and show an alert: *"A folder named 'Rock' already exists here."*

**P1 — Search/sort state is lost when entering a subfolder**
Opening a subfolder creates a new `PlaylistFolderContentsVC` with `searchText = ""` and `sortType = .name`. If the user was mid-search at the root, they lose that context. Consider passing the search/sort state to the child VC or resetting intentionally with an animation that signals the context change.

**P1 — No "Move to another folder" operation in multi-select**
Multi-select offers "Add to Folder" or "Remove from Folder" but no "Move" (i.e., remove from current + add to another in one step). Users who want to reorganize must do two passes. This is a missing affordance for the primary folder-management use case.

**P1 — Orphaned pins when a playlist is deleted server-side**
`PinnedPlaylistStore` (UserDefaults JSON) holds playlist IDs. If a playlist is deleted on the server and removed from Core Data, the pin entry persists and the Home tab "Pinned Playlists" section will show a broken/empty row. No cleanup logic is visible. Add a reconciliation step during library sync that removes stale pin IDs.

**P2 — Folder deletion doesn't communicate what happens to contents**
The delete confirmation presumably says something like "Delete folder?" but doesn't mention that the playlists inside will be returned to root (not deleted). Add: *"The playlists inside will be moved to the root level."*

---

## Feature 5 — Favourite Albums/Artists/Playlists on Home

**Files:** `HomeVC.swift`, `HomeManager.swift`

### Issues

**P1 — Mixed persistence models without server sync for albums/artists**
Album and Artist favourites use the Core Data `favorite` flag. It's unclear from the code whether this syncs to the Navidrome server (via the star rating API) or is local-only. If local-only, it will be lost on reinstall and won't sync across devices. Playlists use `PinnedPlaylistStore` (UserDefaults), which is explicitly local. The inconsistency should be documented and ideally both should follow the same policy.

**P1 — Favourite albums bypass the Whole Albums filter with no visual indication**
A user who has the "Complete Albums" tab filtered to 3+ tracks will be confused when a single they've favourited appears on the Home tab. The special-case bypass is not communicated anywhere. At minimum, favourite album rows on Home could show a small tag or the section header could say *"Favourited albums (includes singles)"*.

**P2 — Sections hidden when empty give no onboarding hint**
A first-time user sees no Favourite sections at all on Home. This is correct (no clutter), but there's no tooltip or hint about how to add favourites. If all favourite sections are hidden, consider a brief first-launch card: *"Heart an album, artist, or playlist to pin it here."*

---

## Feature 6 — Share Song

**Files:** `ShareSongAction.swift`

### Issues

**P1 — Download progress alert has no progress indicator**
`ShareSongAction.swift:50-59` shows a `UIAlertController` with title "Downloading…" and the song title as the message. For a large file on a slow connection, the user sees a static alert with no indication whether the download is progressing or stalled. A `UIProgressView` added as `contentViewController` on the alert (or a simple pulsing animation) would significantly reduce anxiety.

**P1 — Temp file path collision: two simultaneous shares of same-title songs overwrite each other**
`presentActivityController` builds the temp path as:
```swift
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent(safeFileName)
    .appendingPathExtension(fileURL.pathExtension)
try? FileManager.default.removeItem(at: tempURL)   // removes existing!
try? FileManager.default.copyItem(at: fileURL, to: tempURL)
```
If a user long-presses two different songs with identical "Title - Artist" strings simultaneously (e.g., both already cached), the second call removes the first call's temp file before the share sheet for the first song has been dismissed. Use a UUID-suffixed temp directory to isolate each share session.

**P1 — Download is triggered even when the download manager has already queued the song**
`ShareSongAction.swift:61` calls `.download(object: song)` unconditionally after the cached-file check. If the song is already in a download queue (e.g., the user is syncing their library), this may enqueue a duplicate download. Check if the song is already queued before triggering.

**P2 — `safeFileName` doesn't sanitize all potentially problematic characters**
Only `/` and `:` are replaced. Characters like `?`, `*`, `"`, `\`, `<`, `>`, `|` and leading/trailing spaces are left intact. While APFS permits most of these in filenames, receiving apps (AirDrop targets, Files.app) may struggle. Consider a broader sanitization pass.

---

## Feature 7 — Custom Theme

**Files:** `ThemeStore.swift`, `ThemeSettingsSection.swift`

### Issues

**P1 — Font picker uses family name with `Font.custom` (SwiftUI), which expects a PostScript name**
`ThemeSettingsSection.swift:279`:
```swift
Font.custom(family, size: UIFont.preferredFont(forTextStyle: .body).pointSize)
```
SwiftUI's `Font.custom(_:size:)` takes a PostScript font name, not a family name. For most fonts the family name differs from the PostScript name (e.g., family "Helvetica Neue", PostScript "HelveticaNeue-Light"). When they don't match, SwiftUI silently falls back to the system font, meaning the preview row shows the *wrong font* for many entries. The UIKit side (`ThemeStore.swift:276`) correctly looks up the first specific font name via `UIFont.fontNames(forFamilyName:)`, but the SwiftUI preview doesn't. Fix: use the same lookup for the preview label.

**P1 — Contrast warning is positioned far from the color pickers it references**
The warning text (`contrastWarning`) appears inside the first `SettingsSection` (the toggle section, `ThemeSettingsSection.swift:103-110`), but the color pickers are in subsequent sections. A user who sees "Light: low text/background contrast" must scroll up to notice it and doesn't know which of the three light colors to change. Move the warning inline to the affected color section, or annotate the specific offending row.

**P1 — No live preview of theme changes in Settings**
Color and font changes apply immediately to the rest of the app (`applyTheme()` fires `applyCustomThemeAndReload()`) but the Settings screen itself is partially SwiftUI and may not reflect the new theme immediately. Users must navigate away to verify changes. Consider a small preview swatch or a "Preview" row showing sample text in the selected background/text/tint combination inline.

**P1 — Reset to Defaults is immediately destructive with no undo**
`ThemeStore.resetToDefaults()` (`ThemeStore.swift:181-189`) calls `defaults.removeObject(forKey:)` for all keys. There is an alert with "Cancel" / "Reset" buttons, which is correct. However, after reset, there is no way to recover the previous colors. Consider writing the current colors to a "last known good" key before wiping, enabling a single "Undo Reset" action.

**P2 — Theme toggle flashes the UI when enabled**
Enabling the toggle calls `populateDefaultsIfNeeded()` then `applyCustomThemeAndReload()`, which triggers a full window reload. On older devices this briefly flashes blank. Consider a fade transition.

**P2 — `dynamicSecondaryText` derives from `darkText`/`lightText` at 60% alpha**
`ThemeStore.swift:130-135`: secondary text is the theme text color at 0.6 opacity. This could fall below the WCAG 3.0:1 threshold even when the primary text passes 4.5:1. The contrast checker doesn't check secondary text. Add a check for secondaryText if it's used in visible cells.

---

## Feature 8 — In-App Release Notes

**Files:** `ReleaseNotes.swift`, `SettingsView.swift`

### Issues

**P1 — Diagnostic builds appear in the release notes visible to users**
Builds 26 and 27 are labelled "DIAGNOSTIC BUILD" in their titles and whatsNew arrays. These internal debug builds are included in the `entries` array shown to all users. A user who sees "DIAGNOSTIC BUILD: Track Adjacency Engine ONLY — Custom theme fully disabled" will be confused. Filter out builds whose titles contain "DIAGNOSTIC" before display, or mark them with a flag and hide them from the release notes UI.

**P1 — No filtering by the user's installed build number**
All 5 entries are shown regardless of what build the user is running. A user on Build 28 who upgrades to Build 29 sees Build 25–29 entries, but Build 25–27 are irrelevant noise (including two diagnostic builds). Consider filtering to only show entries newer than the previously-launched build number (stored in UserDefaults).

**P2 — Testing focus items are shown to end users**
The `testingFocus` arrays contain QA instructions like *"Fresh install: launch app, wait for background sync"*. These are developer-facing. If displayed in the release notes UI, they add clutter for regular users. Either hide them behind a developer toggle or move them to a separate QA-only view.

---

## Feature 9 — Track Adjacency Engine

**Files:** `TrackAdjacencyStore.swift`, `RelatedTracksVC.swift`

### Issues

**P1 — `loadRelatedTracks()` runs synchronously on the main thread in `viewDidLoad`**
`RelatedTracksVC.swift:55-88`: `loadRelatedTracks()` is called directly from `viewDidLoad`. It:
1. Iterates the entire `scores` dictionary (O(n) over all pairs — could be tens of thousands for a large library)
2. Issues up to 20 individual `NSFetchRequest` calls to Core Data for each result song
3. Issues up to 20 more `playlistCoOccurrenceCount` reads

All of this runs synchronously on the main thread. For a library with 10k songs across 100 playlists, the scores dictionary alone could have hundreds of thousands of entries. This will freeze the UI for 100–500ms before the sheet animates in. **Fix:** Move loading to a `Task { @MainActor in }` block and show a loading spinner while results resolve, similar to PlaylistMembershipVC.

**P1 — Album bonus dead code creates misleading comment (`TrackAdjacencyStore.swift:352-355`)**
```swift
if scores[pair] != nil {
    // Only apply album bonus to pairs that already exist (from playlist co-membership)
    // UNLESS they share an album — the spec says album bonus applies even without playlists
}
var existingScore = scores[pair] ?? SimilarityScore()
existingScore.album = Self.albumWeight
scores[pair] = existingScore
```
The `if` block is empty — it was presumably intended as a guard but was never filled in. The code unconditionally falls through and applies the album bonus to all same-album pairs. However, the fetched `allSongIds` set (line 325-328) is built from existing `scores.keys`, meaning only songs that already co-appear in playlists are fetched. Songs in an album who have **never** co-appeared in any playlist are not in `allSongIds` and are never fetched. This means the "applies even without playlists" comment describes intent that is not implemented — album-only pairs with no playlist history get no score at all. The dead `if` block should be removed and the comment should be corrected to accurately describe the actual behaviour.

**P1 — No progress or status indication during background computation**
The adjacency engine runs silently on launch. Users who open "Related Tracks" immediately after install see an empty state with no indication that computation is in progress. The `isStale` flag is never surfaced in the UI. At minimum, `RelatedTracksVC` could check `TrackAdjacencyStore.shared.isStale` and show a "Building recommendations…" subtitle in the empty state.

**P2 — "Related Tracks" in context menu is shown even when no data exists for the song**
The context menu always adds the "Related Tracks" action. If the user taps it and the adjacency store has no data for that song (fresh install, or song was never in any playlist), they see the empty state. Consider hiding or disabling the action using `TrackAdjacencyStore.shared.hasData(for: songId)` so the menu entry only appears when there are actual results.

**P2 — Duplicate songs in a playlist only contribute once (by design), but this is surprising**
`extractDeduplicatedSongIds` (`TrackAdjacencyStore.swift:305-316`) uses first-occurrence deduplication. A song appearing at positions 1 and 45 in a playlist only contributes position-1 adjacency. This is documented in comments but makes the scoring less intuitive for users who would expect repeated pairings to reinforce the relationship.

---

## Feature 10 — Albums Performance Fixes

**Files:** `AlbumsCollectionVC.swift`

### Issues

*(The off-by-one in `indexTitles` is listed under Feature 1 as it affects the same file.)*

**P2 — Section index title cache (`indexTitles`) is not invalidated on sort type change**
`indexTitles(for:)` recomputes from scratch on each call (there is no explicit cache here — the recomputation happens every scroll). This is correct but means every index bar touch during a slow scroll re-fetches section headers. The upstream `sectionTitle(for:)` calls `getFirstAlbum(in:)` which materialises Core Data objects. For a library with 500+ sections, this is frequent work. Consider caching index titles and invalidating the cache only when the FRC snapshot changes.

---

## Cross-Feature Consistency Issues

### Loading States

Three different patterns are used across features:

| Feature | Loading Pattern |
|---------|----------------|
| Show in Playlists | `UIContentUnavailableConfiguration.loading()` |
| Share Song (download) | `UIAlertController` with "Downloading…" |
| Recently Added Tracks | None |
| Related Tracks | None |

Standardise on `UIContentUnavailableConfiguration.loading()` for modal sheets (PlaylistMembership, RelatedTracks). Use the alert only for operations that can be explicitly cancelled (Share Song download), which is the current correct usage.

### Empty States

| Feature | Empty State |
|---------|------------|
| Show in Playlists | ✅ "This song isn't in any playlists" |
| Related Tracks | ✅ "No related tracks found" + secondary text |
| Recently Added Tracks | ❌ Blank table |
| Complete Albums (all filtered) | ❌ Blank collection |

Add empty states to Recently Added Tracks and Complete Albums.

### Accessibility (VoiceOver / Dynamic Type)

**P1 — Pervasive gap across all custom features**

A search for `accessibilityLabel` across all custom files returns near-zero results. Specific gaps:

- **FloatingActionBar** (`PlaylistFolderContentsVC`): Action buttons have no `accessibilityLabel`. VoiceOver will read "Button" with no context.
- **RelatedTracksVC source info**: The artist label is mutated to append "· In 3 playlists nearby". VoiceOver will read this literally, but it would be cleaner to set `accessibilityLabel` separately: "Radiohead — In 3 playlists nearby".
- **ThemeSettingsSection font rows**: Each font row in `FontPickerView` is a `Button` with a `Text` label — VoiceOver will read the font family name, which is acceptable. The checkmark image should have `accessibilityLabel("Selected")` on the marked row.
- **RecentTracksDetailVC stepper**: `UIStepper` has no `accessibilityLabel`. Should be labelled "Number of tracks" or "Number of days" depending on the active mode.
- **PlaylistMembershipVC title bar**: Title "Show in Playlists" is fine. The Done button is standard and accessible.

Dynamic Type is generally well-handled via `preferredFont(forTextStyle:)`. The main risk is the custom theme's font override: `UIFont.themed(style:)` (`ThemeStore.swift:267-282`) correctly uses `UIFontMetrics.scaledFont(for:)` for custom fonts, which is the right approach.

---

## Prioritised Action List

### P0 — Fix first
1. **No timeout on PlaylistMembershipVC sync** → Add 30s timeout + error state (`PlaylistMembershipVC.swift`)

### P1 — High impact polish
2. **Header constraint accumulation in RecentTracksDetailVC** — cache the header view instance (`RecentTracksDetailVC.swift:298`)
3. **Related Tracks loads synchronously on main thread** — move to async Task (`RelatedTracksVC.swift:55`)
4. **Font preview uses family name instead of PostScript name** — fix preview lookup (`ThemeSettingsSection.swift:279`)
5. **Diagnostic builds visible in release notes** — filter or flag them (`ReleaseNotes.swift`)
6. **No empty state for Recently Added Tracks** (`RecentTracksDetailVC.swift`)
7. **Contrast warning disconnected from color pickers** — inline the warning (`ThemeSettingsSection.swift:103`)
8. **Orphaned playlist pins when playlist deleted** — add reconciliation in library sync
9. **Duplicate folder names permitted silently** (`PlaylistFolderContentsVC.swift`)
10. **Album bonus dead code + misleading comment** — clean up (`TrackAdjacencyStore.swift:352-358`)
11. **Add accessibility labels to floating action bar, stepper, and source info cells**

### P2 — Nice-to-have
12. "Complete Albums" tab: add descriptive subtitle or info tooltip
13. Share Song: add UUID-based temp file isolation
14. Share Song: broaden filename character sanitization
15. Related Tracks: hide menu item when `hasData(for:)` is false
16. Release Notes: filter entries to show only builds newer than previous launch
17. Playlist Folders: add "Move" operation to multi-select
18. Theme: add inline preview swatch in Settings
19. Theme: persist "last known good" colors before Reset
20. Home Favourites: add onboarding hint when all favourite sections are empty
21. Albums sort index: fix off-by-one (`AlbumsCollectionVC.swift:100`, `0 ... sectionCount` → `0 ..< sectionCount`)
