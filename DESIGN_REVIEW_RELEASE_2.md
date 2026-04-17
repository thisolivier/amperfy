# Design Review — Release 2 (PR 18: Delete playlist folder with child-flattening)

**Reviewer:** designer agent
**Date:** 2026-04-15
**Scope:** `BACKLOG.md` §18.1–18.6

---

## Validation summary

**Spec needs adjustment.** The backlog writes PR 18 as if the Playlists tab is still rooted at `PlaylistsVC`, citing `PlaylistsVC.swift:54` (commit editingStyle) and `:161` (swipe callback) as the sites to match. That is **stale**: PR 9 (Feature G) replaced the Playlists tab root with `PlaylistFolderContentsVC` — see `AppStoryboard.swift:127` (`PlaylistFolderContentsVC(account: account)`). `PlaylistsVC` is no longer instantiated anywhere in the app. All PR 18 work lands in `PlaylistFolderContentsVC`. The symmetry goal (swipe + edit-mode on folders matching the playlist UX) is still achievable in that VC, but the implementer will be extending the existing folder delete path (context-menu) rather than porting playlist delete.

Additionally the proposed algorithm in §18.3 assumes `folder.parent` is a direct pointer. It isn't — `PlaylistFolder` is a **nested tree** (`subfolders: [PlaylistFolder]`) with no parent back-reference. Re-parenting means a tree-walk that locates the node being deleted and splices its `playlistIds` + `subfolders` into the containing array at the deletion site. The semantics (one-level pop) still hold; only the implementation description needs correcting.

---

## Code refs (for the implementer)

**Data model**
- `AmperfyKit/Storage/PlaylistFolderStore.swift:26-52` — `PlaylistFolder` struct (no `parent` field; `subfolders: [PlaylistFolder]`)
- `AmperfyKit/Storage/PlaylistFolderStore.swift:115-118` — existing `deleteFolder(id:)` **destroys** subfolders and orphans direct-child playlists (they become unfiled because `removingFolder` recursively drops subfolders, and the playlist IDs that were inside the deleted folder are now in no folder). This is the behaviour to replace.
- `AmperfyKit/Storage/PlaylistFolderStore.swift:197-204` — `removingFolder` helper that currently does the destructive recursion
- `AmperfyKit/Storage/PlaylistFolderStore.swift:176-195` — `applyingMutation` tree-walk pattern; the new flatten-delete should follow the same shape

**UI / VC**
- `Amperfy/Screens/ViewController/PlaylistFolderContentsVC.swift:34` — the actual Playlists tab root (not `PlaylistsVC`)
- `Amperfy/Screens/ViewController/PlaylistFolderContentsVC.swift:523-528` — `canEditRowAt` currently returns `true` only for the playlists section. Must also return `true` for folders to enable swipe-to-delete + edit-mode minus.
- `Amperfy/Screens/ViewController/PlaylistFolderContentsVC.swift:548-566` — existing `folderContextMenu` with its Delete action. Reuse `confirmDeleteFolder(folder)` as the confirmation target for both new entry points.
- `Amperfy/Screens/ViewController/PlaylistFolderContentsVC.swift:649-664` — existing `confirmDeleteFolder`. Its copy is wrong for the new semantics ("Playlists inside will become unfiled") and must be rewritten to describe the one-level pop. Counts are already computed here.
- `Amperfy/Screens/ViewController/PlaylistFolderContentsVC.swift:87-93` — `viewDidDisappear` already tears down the folder observer; the observer at `:119-125` calls `reloadContent()` on any store change, which naturally handles mutations from elsewhere.

**Dead code**
- `Amperfy/Screens/ViewController/PlaylistsVC.swift` — no longer referenced. Backlog line numbers cited here are irrelevant. Do NOT modify; do NOT port from.

**Tests**
- `AmperfyKitTests/Cases/Storage/PlaylistFolderStoreTest.swift` — extend with the new flatten-delete coverage

---

## Edge cases confirmed

- **Empty folder:** skip confirmation, delete immediately. Detection: `folder.playlistIds.isEmpty && folder.subfolders.isEmpty`. (Note: semantically equivalent to `folder.allPlaylistIdsRecursive.isEmpty && folder.subfolders.isEmpty`.)
- **Currently-open folder deleted externally:** `PlaylistFolderContentsVC` already observes `PlaylistFolderStore.didChangeNotification` (`:119`). The observer currently calls `reloadContent()` which will no-op silently if `parentFolderId` points to a now-missing folder (the `folder(byId:)` lookup returns nil and `displayedFolders`/`displayedPlaylists` become empty). **Needs fix for §18.4:** after `folder(byId: parentFolderId)` returns nil in `reloadContent`, the VC should `popViewController(animated: true)` if `parentFolderId != nil`.
- **Grandchildren stay in their direct parent:** confirmed possible — the implementation moves only the **direct** `playlistIds` and `subfolders` arrays up one level. The subfolder's own `playlistIds` and `subfolders` are carried along intact inside the subfolder struct.
- **Playlist in currently-playing queue:** store-level operation; queue state is independent. No impact.
- **Root-level delete:** "parent" is the top-level `folders` array. Splice children into the top level at the deleted folder's former index (or append — either is acceptable since sort on reload controls order).
- **Playlist appears in multiple folders (duplicate filing is allowed per store semantics, see `testSamePlaylistInTwoFolders`):** when a folder is deleted, its `playlistIds` become unfiled relative to that folder only — they remain filed in any other folder they're in. `allFiledPlaylistIds` recomputes naturally. Document this in the test matrix.

---

## QA acceptance criteria

Folder delete is invoked from **three** entry points post-PR 18: context menu (existing), left-swipe (new), edit-mode red-minus (new). The flatten semantics apply identically to all three.

1. **Swipe-to-delete appears on folder rows.** Open Playlists tab. Long-left-swipe on a folder row. A red "Delete" button appears. Tap it — the confirmation alert appears (unless folder is empty; see #5).
2. **Edit-mode red-minus appears on folder rows.** Open Playlists tab → ellipsis → "Select Items" (or whichever enters edit mode). A red minus circle appears on the left of each folder row (previously only playlists had this). Tapping it reveals a "Delete" button on the right of the row; tapping "Delete" shows the confirmation alert.
3. **Context-menu delete still works.** Long-press a folder row. The "Delete Folder" destructive action is still there and shows the confirmation alert.
4. **Confirmation alert copy.** For a folder named "Rock" containing 3 playlists and 1 subfolder, the message reads: `Delete folder 'Rock'? The 3 playlists and 1 sub-folder inside will move to the parent level.` Singular/plural must be correct (`1 playlist`, `2 sub-folders`, etc.). Buttons: `Delete Folder` (destructive, red) and `Cancel`.
5. **Empty folder skips confirmation.** Create folder "Empty", leave it empty, swipe-delete it — folder disappears immediately with no alert.
6. **Root-level flatten.** Set up: at root, folder "Rock" contains playlists A, B and subfolder "Metal" (which contains playlist C). Delete "Rock". Verify: A, B, and "Metal" are now at root; C is still inside "Metal"; "Rock" is gone.
7. **Nested flatten.** Set up: root contains folder "Music". Inside "Music": folder "Rock" contains playlist A and subfolder "Metal" (which contains playlist B). Delete "Rock". Verify: "Music" now contains "Metal" and playlist A at its top level; "Metal" still contains B; "Rock" is gone; root still contains only "Music".
8. **No playlists are deleted.** After #6 and #7, tap each surviving playlist — it opens and plays normally. Nothing was lost.
9. **Cancel is non-destructive.** Start a delete, tap "Cancel". Folder and contents are unchanged.
10. **Currently-open folder popped when deleted externally.** Open two sim instances is not possible, so simulate with context menu: navigate into folder "Rock". Pull down search, then use split-screen or simply invoke delete via context menu at a parent level is non-trivial from inside — instead, QA can verify by calling `folderStore.deleteFolder(id:)` from the debugger / an explicit test hook while viewing "Rock". Acceptance: the VC pops back to the parent view, no crash.
11. **Multi-filed playlist preserved.** Set up: playlists A and B are both filed under folders "Jazz" and "Blues". Delete "Jazz". Verify A and B are no longer unfiled (they're still in "Blues"); they do NOT appear twice at the root.
12. **Offline mode.** Toggle offline mode on. Folder delete still works (it's a local-only operation per §18.1); no sync error is logged.
13. **What's New entry appears.** Install the built IPA; open What's New; confirm the §18.5 copy is present and reads correctly.
14. **Unit test green.** `AmperfyKitTests` passes, including the new `deleteFolder` flatten coverage (root + nested + multi-filed + grandchildren-preserved cases).

---

## Open questions

**None blocking.** The spec is sound in intent; the adjustments above are implementation-detail corrections (cite `PlaylistFolderContentsVC` instead of `PlaylistsVC`; tree-walk splice instead of `folder.parent` pointer) that do not change the product-facing behaviour. The implementer can proceed using this review plus the backlog as a paired reference.

One note worth flagging to Olivier (not blocking): the existing context-menu delete (`confirmDeleteFolder` at line 649) currently has "become unfiled" copy that will be contradicted by PR 18's new semantics. The rewrite replaces it with the new copy, so there's no inconsistency at ship — just noting that the existing behaviour is being changed, not merely extended. If Olivier expected the old orphan-on-delete behaviour to remain available (it probably isn't wanted), the spec would need a branch; the current read is that flatten-on-delete is the single canonical behaviour going forward.
