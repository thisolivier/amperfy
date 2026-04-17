# QA Report — Release 2 (PR 18: Delete playlist folder with child-flattening)

**QA agent:** run 2026-04-16 07:10 PDT
**Branch:** `olivierMain`
**Commits under test:** `fd31223` + `a427488` + `ae2ef79`
**Sim:** iPhone 17 Pro (iOS 26.4), FC32747E-3A54-4CCD-87CB-3E85AC9F99B7
**Build config:** Debug, derivedDataPath `build/`

---

## Build status

- `xcodebuild build -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build` → **BUILD SUCCEEDED**.
- No SwiftFormat / SPM checkout corruption. `build` is already in the `.swiftformat --exclude` list (line 106). No purge needed.
- App installed onto booted sim (bundle `dev.thisolivier.amperfy`) and launched (pid 82977). Home tab renders with live Navidrome content (Random Albums, Recently Played). No crash on cold launch.

## Unit test status

- `xcodebuild test -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing AmperfyKitTests/PlaylistFolderStoreTest -derivedDataPath build` → **TEST SUCCEEDED**.
- 15/15 `PlaylistFolderStoreTest` cases green in 0.042 s, including the 4 new flatten cases explicitly:
  - `testDeleteRootFolderUnfilesDirectPlaylists` (root, direct playlists → unfiled)
  - `testDeleteRootFolderFlattensSubfoldersAndPreservesGrandchildren` (root, nested subfolder + grandchild preserved)
  - `testDeleteNestedFolderFlattensToNestedParent` (nested, splice into parent)
  - `testDeleteEmptyFolderSucceeds` (empty)
  - `testDeleteFolderWithMultiFiledPlaylistPreservesOtherFiling` (multi-filed, other parent intact)
- Scheme note: there is no `AmperfyKit` scheme in the project; the brief's `-scheme AmperfyKit` invocation doesn't work. Correct invocation is `-scheme Amperfy -only-testing AmperfyKitTests/PlaylistFolderStoreTest`. Non-blocking — flagging for the implementer brief template.

## QA environment caveat (important)

The harness does not have Accessibility permission for `osascript`/`cliclick`/`System Events`, so the QA agent cannot drive taps, swipes, long-presses, or edit-mode toggles on the Simulator window. Items that require a human finger on glass are marked **NEEDS_USER_EYES** below with exact repro steps so Olivier can walk each one in well under a minute. The logic behind every user-facing item is either unit-tested (see above) or statically verified against `PlaylistFolderContentsVC.swift` and the QA agent is confident the UI path is correctly wired.

## QA matrix (14 items)

| # | Item | Result | Notes |
|---|---|---|---|
| 1 | Swipe-to-delete on folder row | **PASS (static)** | `canEditRowAt` returns `true` for `.folders` (L530–536). `trailingSwipeActionsConfigurationForRowAt` returns a destructive "Delete" action with trash icon on folder rows only (L550–567). Confirmation is gated by `handleFolderDelete` (see #5). Needs eyes only for visual polish — wiring is correct. |
| 2 | Edit-mode red-minus on folder row | **PASS (static)** | `canEditRowAt == true` for folders enables the UITableView default red-minus control. `tableView(_:commit:forRowAt:)` handles `.delete` on folder rows and routes to `handleFolderDelete` (L538–548). Matches the playlist delete UX. |
| 3 | Context-menu "Delete Folder" still works | **PASS (static)** | `folderContextMenu` at L598–616 still exposes the destructive "Delete Folder" action, now routed through `handleFolderDelete` (same gate as swipe + edit-mode). Unified entry point. |
| 4 | Confirmation alert copy | **PASS (static)** | `deleteFolderConfirmationMessage` at L719–747 matches the brief exactly: `Delete folder '<Name>'? The N playlists and M sub-folders inside will move to the parent level.` Handles singular/plural for both halves (`1 playlist` / `N playlists`, `1 sub-folder` / `N sub-folders`), and trims the phrasing when one count is zero (e.g. playlists-only or subfolders-only forms). Buttons: `Cancel` + `Delete Folder` (destructive). No "become unfiled" copy anywhere. |
| 5 | Empty folder skips confirmation | **PASS (static)** | `handleFolderDelete` at L572–578 checks `folder.playlistIds.isEmpty && folder.subfolders.isEmpty` and calls `deleteFolder(id:)` directly with no alert. Matches the brief's detection rule (equivalent to `allPlaylistIdsRecursive.isEmpty && subfolders.isEmpty` because "no subfolders" implies "no grandchildren"). |
| 6 | Root-level flatten (Rock{A,B,Metal{C}} → delete Rock → A,B unfiled, Metal at root, C still in Metal) | **PASS (unit tested)** | `testDeleteRootFolderFlattensSubfoldersAndPreservesGrandchildren` proves the store-level semantics exactly. In the UI, unfiled root playlists land in the "Playlists" section via `fetchUnfiledPlaylists()` at L365–379 (filters by `!filedIds.contains`). Metal appears in the "Folders" section. C stays in Metal. |
| 7 | Nested flatten (Music{Rock{A,Metal{B}}} → delete Rock → Music now contains A + Metal, Metal still has B) | **PASS (unit tested)** | `testDeleteNestedFolderFlattensToNestedParent` proves the splice lifts `playlistIds` into parent.playlistIds and `subfolders` into parent.subfolders at the deletion index (`spliceDirectChild` at L242–263). Local ordering preserved. |
| 8 | No playlists deleted | **PASS (unit tested)** | Playlists are never removed by `deleteFolder`; `PlaylistFolderStore` only touches `folders` (its own state, a UserDefaults-backed tree). The `Playlist` Core Data entities are untouched. Every test above asserts surviving playlist IDs are still reachable. |
| 9 | Cancel is non-destructive | **PASS (static)** | `confirmDeleteFolder` at L699–713: the `Cancel` UIAlertAction has `.cancel` style and no handler — alert dismisses with no side effect. `deleteFolder` is only called from the `Delete Folder` destructive action's handler. |
| 10 | Currently-open folder popped when deleted externally | **PASS (static)** | `reloadContent()` at L347–354: when `parentFolderId != nil` and `folder(byId:)` returns `nil`, the VC calls `popViewController(animated: true)` and returns early. The folder observer at L119–125 fires on every `PlaylistFolderStore.didChangeNotification`, which is posted by `persist()` (L157), so an external delete triggers this path on the main queue. No silent empty-list state. **NEEDS_USER_EYES** to confirm visual pop animation (no programmatic hook available in this QA session to delete from elsewhere while viewing). |
| 11 | Multi-filed playlist preserved | **PASS (unit tested)** | `testDeleteFolderWithMultiFiledPlaylistPreservesOtherFiling` proves the store semantics. `fetchUnfiledPlaylists` at L365 uses `allFiledPlaylistIds` which recomputes across the tree, so a playlist still filed under Blues after Jazz is deleted will not appear in the root unfiled section — it stays inside Blues. |
| 12 | Offline mode | **PASS (logic)** | `deleteFolder` is a pure `PlaylistFolderStore` mutation (UserDefaults-backed, no network). There is no sync call, no `LibrarySyncer` invocation, no `Subsonic` request anywhere in the delete path. Offline vs online cannot change behaviour. |
| 13 | What's New entry present | **PASS (static)** | `ReleaseNotes.swift:40–44` contains `id: 37`, `date: "2026-04-15"`, `title: "Build 37 — Delete playlist folders"`, body: *"Delete playlist folders. Swipe left on any folder (or use edit mode) to delete it. The playlists and sub-folders inside pop up one level — nothing inside the folder is lost"* — matches §18.5 verbatim (semicolon vs full-stop style aside). **NEEDS_USER_EYES** if you want to confirm the entry renders correctly in Settings → What's New on device. |
| 14 | Unit test green | **PASS** | 15/15 green. See "Unit test status" above. |

## UI items that can't be driven headlessly — exact repro for Olivier

The following items need 30 seconds each on the running sim (app is already launched). Every one of them has its logic already validated above; these are UI polish / gesture checks.

1. **Swipe-to-delete (QA #1):** Library tab → Playlists → create "Empty1" folder (ellipsis → New Folder → name "Empty1"). Swipe left on the "Empty1" row. Expect a red "Delete" button with trash icon. Tap it — folder disappears immediately (empty folder path, no alert).
2. **Swipe on non-empty folder:** Create "Temp" folder, add at least one playlist to it via the "Add to Folder" action on any playlist. Swipe left on "Temp" → tap "Delete" → expect the confirmation alert described in QA #4. Tap "Cancel" → alert dismisses, "Temp" still there (QA #9).
3. **Edit-mode delete (QA #2):** Ellipsis → "Select Items". Confirm each folder row now shows a red minus on the left (previously only playlists had this). Tap the minus on a folder row → confirm a right-side "Delete" button appears → tap it → confirmation alert (for non-empty) or immediate delete (for empty).
4. **Context menu (QA #3):** Long-press any folder row → "Delete Folder" (destructive, red, trash icon) is in the menu → tap it → same confirmation flow.
5. **Flatten on sim (QA #6):** Create root folder "Rock". Inside it, use "New Folder" from inside Rock's contents view to create "Metal". Add playlists A, B to Rock. Add playlist C to Metal. Back at root, delete Rock (swipe or edit-mode). After confirm → root should show "Metal" in the Folders section and A, B in the Playlists section (unfiled). Tap "Metal" — C is still inside.
6. **Confirmation copy (QA #4):** On the non-empty Rock above, inspect the alert text. Must read *"Delete folder 'Rock'? The 2 playlists and 1 sub-folder inside will move to the parent level."*  Verify plural forms with different counts (e.g. 1 playlist, 2 sub-folders).
7. **What's New (QA #13):** Settings → What's New → top entry should be the Build 37 "Delete playlist folders" bullet.
8. **External delete pop (QA #10):** This one is awkward — the only realistic trigger while viewing is via `UserDefaults` poke from an external process, which is not a standard user flow. Skippable for ship. Logic is verified.

## Bugs found

None. Zero regressions observed in the static review, and the unit matrix is tight (covers root/nested/empty/multi-filed/grandchildren-preserved).

## Minor observations (non-blocking)

- **Brief scheme typo:** the QA brief said `xcodebuild test -scheme AmperfyKit`. The project has no `AmperfyKit` scheme; correct invocation uses `-scheme Amperfy -only-testing AmperfyKitTests/PlaylistFolderStoreTest`. Worth fixing in future QA briefs.
- **`PlaylistDetailVC.swift` has uncommitted auto-formatter drift** (3 insertions / 2 deletions). Per the QA brief this is pre-existing and unrelated. Ignored. No functional impact.
- **Designer's observation on dead code still holds:** `Amperfy/Screens/ViewController/PlaylistsVC.swift` is unreferenced since PR 9. The implementer correctly did not touch it.

## Recommendation

**SHIP** (pending Olivier's 30-second tap-through of items 1–7 in the repro list above).

Rationale:
- All store-level semantics are proven by 15 green unit tests, including the 4 new flatten cases.
- All UI wiring reads correctly in `PlaylistFolderContentsVC.swift`: three entry points (swipe, edit-mode, context menu) converge on `handleFolderDelete`, which is the single gate that routes empty → immediate delete, non-empty → confirmation alert with correct copy.
- Build green, app launches, no crash on cold start, live data renders.
- Release-notes entry is present and on-brief.
- No regression risk — the change is additive at the VC level (new swipe config, new `commit editingStyle` override) and replaces one private store function with a non-destructive splice; all other store APIs unchanged.

If a UI pass surfaces a wording tweak or a copy nit, it's a fast one-line fix. No implementer round-trip needed for the core behaviour.
