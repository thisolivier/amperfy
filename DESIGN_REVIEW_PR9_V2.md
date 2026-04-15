# Design Review: PR 9 v2 — Playlist Folders (Unified View Redesign)

**Reviewer:** Designer Agent
**Date:** 2026-04-12
**Status:** Pre-implementation review (addresses Olivier's feedback on v1)
**Inputs:** PlaylistFolderContentsVC.swift, PlaylistFolderStore.swift, PlaylistsVC.swift, Olivier's feedback via team-lead

---

## Problem Statement

Olivier flagged two fundamental issues with the current implementation:

1. **The Flat View / Folder View toggle is unnecessary.** A single list can show folders and playlists together — no mode switching needed. The toggle splits one feature into two mental models.
2. **Multi-select has no working action route.** You can select playlists in edit mode, but the toolbar buttons overlap the tab bar and are untappable.

Additionally, QA confirmed the toolbar/tab bar overlap bug.

---

## 1. Interaction Design

### 1.1 The Unified List (replacing Flat View / Folder View toggle)

The Playlists tab shows a **single list** with two sections, always visible, no toggle:

```
┌──────────────────────────────────────────┐
│  Playlists                    [...] [Edit]│  ← large title + options + edit
├──────────────────────────────────────────┤
│  🔍 Search in "Playlists"               │  ← always-present search bar
├──────────────────────────────────────────┤
│  FOLDERS                                 │
│  ┌──────────────────────────────────────┐│
│  │ 📁 Chill Vibes          3 playlists ││
│  │ 📁 Workout              5 playlists ││
│  │ 📁 Road Trip            2 playlists ││
│  └──────────────────────────────────────┘│
│                                          │
│  PLAYLISTS                               │  ← unfiled playlists (at root)
│  ┌──────────────────────────────────────┐│
│  │ 🎵 Sunday Morning       24 songs    ││
│  │ 🎵 New Discoveries      89 songs    ││
│  │ 🎵 Liked Songs          312 songs   ││
│  └──────────────────────────────────────┘│
└──────────────────────────────────────────┘
```

**Key behaviors:**

- **Folders section** shows top-level folders, sorted alphabetically. Always visible (even if empty — section header just doesn't show when count is 0).
- **Playlists section** shows **unfiled** playlists only (playlists not in any folder). Sorted by the active sort type.
- Tapping a folder pushes a new `PlaylistFolderContentsVC` showing that folder's contents (subfolders + playlists). The pushed view uses the same unified layout.
- Tapping a playlist pushes `PlaylistDetailVC` (unchanged).
- The "Folders" section header is hidden when there are zero folders (no empty header).
- The "Playlists" section header is hidden when there are zero unfiled playlists.

**What this replaces:**
- Remove `isShowingFlatView` property entirely.
- Remove the "Flat View" / "Folder View" toggle action from the options menu.
- Remove the conditional that shows `flatSearchController` only in flat mode — search is always available.
- Remove `flatViewSortType` / `flatSearchText` — sort and search apply to the playlists section always.

### 1.2 Search

Search is **always present** via `navigationItem.searchController` (not conditional on flat mode).

**Behavior:**
- **At root level:** Search filters the **Playlists section only** (unfiled playlists) by name. The Folders section remains visible and unfiltered during search. Rationale: folders are a small, user-created set; filtering them adds complexity for near-zero value.
- **Inside a folder:** Search filters that folder's playlists by name. Subfolders remain visible.
- When the search field is active and has text, and no playlists match, show the standard `UIContentUnavailableConfiguration.search()` empty state — but only in the playlists section (folders section still shows).
- When the search field is cleared or cancelled, the full list restores.

**Implementation:** Move `flatSearchController` setup into `viewDidLoad` unconditionally. Rename `flatSearchText` to `searchText`. The `reloadContent()` method always applies the search filter to playlists.

### 1.3 Sort

Sort applies to the **Playlists section** (both at root level and inside folders). Folders are always sorted alphabetically by name.

**Behavior:**
- The sort menu is always available in the options button (not conditional on flat mode).
- Sort options: Name, Last Played, Change Date, Duration (same as current `createSortMenu()`).
- The active sort has a checkmark.
- Sort persists while the VC is alive but does NOT persist to UserDefaults (lightweight — matches current behavior).

**Implementation:** Remove the `if isShowingFlatView` guard around `createSortMenu()` in `rebuildNavigationItems()`. Sort always appears in the options menu.

### 1.4 Multi-select and batch actions

**The fix for toolbar/tab bar overlap:**

The current implementation uses `navigationController?.setToolbarHidden(false, animated: true)` which shows the standard UIKit toolbar. This toolbar renders **behind** the tab bar on iPhones because the navigation controller's toolbar and the tab bar controller's tab bar occupy the same space.

**Solution:** Replace the navigation controller toolbar with a **custom floating action bar** anchored above the tab bar. This is the pattern used by Apple's Files app and Mail app.

**Custom action bar spec:**

```
┌──────────────────────────────────────────┐
│                                          │
│  (table view with checkmarks)            │
│                                          │
├──────────────────────────────────────────┤
│  [Add to Folder]                [Done]   │  ← floating bar, above tab bar
├──────────────────────────────────────────┤
│  🏠  📚  🔍  📋  ⚙️                     │  ← tab bar (untouched)
└──────────────────────────────────────────┘
```

**Implementation details:**

- Create a simple `UIView` subview (not the navigation toolbar) pinned to `view.safeAreaLayoutGuide.bottomAnchor`. This naturally sits above the tab bar.
- Background: `.systemBackground` with a top separator line (same as tab bar style).
- Contains `UIButton` elements for the available actions.
- Appears when `setEditing(true)` is called; hides when `setEditing(false)`.
- Remove all `navigationController?.setToolbarHidden` calls and `toolbarItems` assignments.

**Batch action buttons by context:**

| Context | Buttons shown |
|---------|--------------|
| Root level (unfiled playlists) | **"Add to Folder"** |
| Inside a folder | **"Move to Folder"**, **"Remove from Folder"** |

**Flow: Multi-select at root level**

1. User taps Edit (or the edit button in the nav bar).
2. Table enters multi-select mode (checkmarks appear on playlist rows).
3. The floating action bar slides up from the bottom with "Add to Folder" button.
4. Folder rows are **not selectable** in edit mode (unchanged from current behavior).
5. User checks one or more playlists.
6. User taps "Add to Folder".
7. Folder picker action sheet appears (same `presentFolderPicker` as current).
8. User picks a folder (or creates a new one inline).
9. Selected playlists are added to the folder. They disappear from the unfiled list. Edit mode exits.

**Flow: Multi-select inside a folder**

1. User taps Edit.
2. Floating action bar shows "Move to Folder" and "Remove from Folder".
3. User selects playlists, taps an action.
4. "Move to Folder" → folder picker (excluding current folder). Playlists move.
5. "Remove from Folder" → immediate removal (no confirmation needed — the playlists become unfiled, not deleted). Playlists disappear from current folder view.

**Button enable/disable:** The action buttons should be **disabled** (grayed out) until at least one playlist is selected. This prevents confusion about tapping an action with nothing selected.

### 1.5 Options menu (ellipsis button)

The options menu simplifies to:

```
┌─────────────────────┐
│ New Folder           │  ← always present
│ Sort ▸              │  ← always present, submenu with sort options
└─────────────────────┘
```

Removed: "Flat View" / "Folder View" toggle.

### 1.6 Inside a folder (pushed view)

When the user taps a folder, a new `PlaylistFolderContentsVC` is pushed with `parentFolderId` set. The layout is identical to the root, but:

- Title = folder name (unchanged).
- Folders section shows subfolders of this folder.
- Playlists section shows playlists in this folder (not unfiled — all members).
- Search filters this folder's playlists.
- Sort applies to this folder's playlists.
- Edit mode action bar shows "Move to Folder" + "Remove from Folder" (not "Add to Folder").

### 1.7 Empty states

| State | What to show |
|-------|-------------|
| No folders, no unfiled playlists | Standard empty: playlist icon + "No Playlists" |
| Folders exist, no unfiled playlists | Folders section visible. Playlists section hidden (no header). |
| No folders, unfiled playlists exist | Folders section hidden. Playlists section visible. |
| Inside folder: no subfolders, no playlists | "Empty Folder" with folder icon |
| Search active, no matches | `UIContentUnavailableConfiguration.search()` — replaces playlists section only |

---

## 2. Edge Cases & UX Flags

### 2.1 Toolbar/tab bar overlap (confirmed QA bug)

**Root cause:** `navigationController?.setToolbarHidden(false)` shows the UINavigationController's built-in toolbar, which occupies the same bottom space as the UITabBarController's tab bar. On iPhones, the toolbar renders behind/under the tab bar.

**Fix:** Replace with custom floating action bar as specified in 1.4. The context menu equivalents already work (confirmed by QA) and serve as a fallback for single-item actions.

### 2.2 Last playlist removed from a folder

When the last playlist is removed from a folder (via "Remove from Folder" or batch remove):
- The folder becomes empty.
- The folder still exists — it shows "Empty Folder" empty state.
- The folder is NOT auto-deleted. Users must explicitly delete folders via context menu.
- The removed playlist reappears in the root-level unfiled list.

### 2.3 Playlist added to a folder disappears from root

When a playlist is added to its first folder:
- It disappears from the root-level "Playlists" section (it's now filed).
- The `reloadContent()` call handles this via `fetchUnfiledPlaylists()` which excludes `allFiledPlaylistIds`.
- **Edge case:** If the user is looking at the root list and adds the last unfiled playlist to a folder, the Playlists section disappears and only Folders remain. This is correct — no special handling needed.

### 2.4 Multi-membership visibility

A playlist can be in multiple folders. When removed from one folder, it only disappears from that folder's view — it remains in all other folders. It only returns to "unfiled" at root when removed from ALL folders. This is already handled correctly by `allFiledPlaylistIds` checking the full tree.

### 2.5 Folder rows in edit mode

Folder rows should NOT be selectable in edit mode. The current implementation (`canEditRowAt` returns false for folders section) is correct. However, visually the folder rows should appear slightly dimmed or without checkmarks to signal they're not part of the selection. The current code already handles this via `allowsMultipleSelectionDuringEditing` — only rows where `canEditRowAt` returns true get checkmarks.

### 2.6 Folder picker with many folders

The current folder picker uses `UIAlertController.actionSheet`, which becomes unwieldy with many folders (scrolling alert sheet). This is acceptable for v1 since most users will have <10 folders. If it becomes a problem, migrate to a pushed table view in a future PR.

### 2.7 Deleting a folder that has subfolders

Current behavior: `deleteFolder(id:)` removes the folder and all its subfolders recursively. Playlists that were only in the deleted folder (or its subfolders) become unfiled. The confirmation message says "Playlists inside will become unfiled" which is correct. **Enhancement:** If the folder has subfolders, the message should mention that too: "Delete 'X' and its subfolders? Playlists inside will become unfiled."

### 2.8 Pull-to-refresh

The original `PlaylistsVC` had pull-to-refresh (`UIRefreshControl`) that syncs playlists from the server. `PlaylistFolderContentsVC` does NOT have this. **Flag:** Pull-to-refresh should be added to trigger a playlist sync. Folder data is local-only (UserDefaults), but the playlist list comes from the server and should be refreshable.

### 2.9 Swipe actions

The original `PlaylistsVC` supported swipe-to-delete (server-side delete + sync) and swipe actions via `swipeCallback`. `PlaylistFolderContentsVC` has no swipe actions. **Flag for future PR:** Swipe actions (download, delete, etc.) should be ported from `PlaylistsVC` to maintain feature parity. Not a blocker for this redesign, but should be tracked.

### 2.10 iPad popover anchoring

The folder picker action sheet uses `popoverPresentationController` anchored to the center of the view (`view.bounds.midX/midY`). On iPad, this places the popover in the middle of the screen rather than near the button that triggered it. **Fix:** Pass the source `UIBarButtonItem` or the cell's frame as the anchor point.

---

## 3. QA Acceptance Criteria

### Navigation & display

| # | Test | Pass condition |
|---|------|---------------|
| 1 | Open Playlists tab (no folders exist) | Single list shows all playlists sorted by name. No "Folders" section header. No toggle button. |
| 2 | Create a folder via options menu | Folder appears in a "Folders" section at the top. |
| 3 | Add a playlist to the folder (context menu) | Playlist disappears from root "Playlists" section. Folder shows updated count. |
| 4 | Tap folder to open it | Pushed view shows folder name as title, contains the added playlist. |
| 5 | Back to root, verify unfiled list | Only unfiled playlists shown. Filed playlist is gone from root. |

### Search

| # | Test | Pass condition |
|---|------|---------------|
| 6 | Type in search bar at root level | Playlists section filters by name. Folders section remains visible and unfiltered. |
| 7 | Search with no matches | Playlists section shows search empty state. Folders still visible. |
| 8 | Clear search | Full playlist list restores. |
| 9 | Search inside a folder | Only that folder's playlists are filtered. Subfolders remain visible. |

### Sort

| # | Test | Pass condition |
|---|------|---------------|
| 10 | Open sort menu from options button | Sort options visible: Name, Last Played, Change Date, Duration. Active sort has checkmark. |
| 11 | Change sort to "Duration" | Playlists reorder by duration. Folders remain alphabetical. |

### Multi-select & batch actions (the core fix)

| # | Test | Pass condition |
|---|------|---------------|
| 12 | Tap Edit at root level | Checkmarks appear on playlist rows only. Floating action bar appears ABOVE the tab bar. Tab bar remains fully visible and tappable. |
| 13 | Action bar buttons disabled with no selection | "Add to Folder" button is grayed out / non-interactive until at least one playlist is checked. |
| 14 | Select 3 playlists, tap "Add to Folder" | Folder picker appears. Select a folder. All 3 playlists added. They disappear from root. Edit mode exits. |
| 15 | Inside a folder: tap Edit, select playlists | Floating action bar shows "Move to Folder" and "Remove from Folder". Both above tab bar. |
| 16 | Tap "Move to Folder" | Folder picker excludes current folder. Select destination. Playlists move. |
| 17 | Tap "Remove from Folder" | Selected playlists removed from current folder immediately. They reappear in root unfiled list. |

### Context menus (regression)

| # | Test | Pass condition |
|---|------|---------------|
| 18 | Long-press a playlist at root | Context menu shows "Add to Folder..." |
| 19 | Long-press a playlist inside a folder | Context menu shows "Move to Folder...", "Also Show in Folder...", "Remove from Folder" |
| 20 | Long-press a folder | Context menu shows "Rename", "Delete Folder" |

### Folder management

| # | Test | Pass condition |
|---|------|---------------|
| 21 | Create a subfolder inside a folder | Subfolder appears in the folder's "Folders" section. |
| 22 | Delete a folder with playlists inside | Confirmation dialog shown. On confirm, folder removed. Playlists become unfiled at root. |
| 23 | Rename a folder | Name updates immediately in the list. |

### Edge cases

| # | Test | Pass condition |
|---|------|---------------|
| 24 | Remove last playlist from a folder | Folder shows "Empty Folder" state. Folder still exists. |
| 25 | Add last unfiled playlist to a folder | Root "Playlists" section disappears (only folders remain). |
| 26 | Kill app and relaunch | Folder structure and memberships persist. |

### Regression: no flat/folder toggle

| # | Test | Pass condition |
|---|------|---------------|
| 27 | Check options menu at root level | Contains "New Folder" and "Sort" submenu. Does NOT contain "Flat View" or "Folder View". |
| 28 | No mode-switching behavior | There is no toggle or mode indicator anywhere in the UI. One view, one list. |

---

## 4. Specific Changes Needed in PlaylistFolderContentsVC.swift

### Remove (delete entirely)

| Lines | What | Why |
|-------|------|-----|
| 49-52 | `isShowingFlatView`, `flatViewSortType`, `flatSearchText` properties | Flat view mode is eliminated. Replace with `searchText` and `sortType` that are always active. |
| 131-146 | Flat/Folder toggle action in `rebuildNavigationItems()` | No toggle in the new design. |
| 156-167 | `toggleFlatView()` method | Eliminated entirely. |
| 277 | `if isShowingFlatView && parentFolderId == nil` branch in `reloadContent()` | Flat view code path removed. |
| 337 | `if isShowingFlatView && !flatSearchText.isEmpty` in `updateContentUnavailable()` | Replaced by simpler search check. |
| 373 | `if isShowingFlatView { return "All Playlists" }` in `titleForHeaderInSection` | No flat view label needed. |

### Modify

| What | Change |
|------|--------|
| **Properties** (lines 49-52) | Replace with: `private var sortType: PlaylistSortType = .name` and `private var searchText: String = ""`. No `isShowingFlatView`. |
| **`viewDidLoad()`** (line 83) | Add `navigationItem.searchController = flatSearchController` unconditionally. Add `definesPresentationContext = true`. Remove `flatSearchController` lazy var's conditional setup — it's always installed. Rename placeholder to `"Search in \"Playlists\""` at root or `"Search in \"\(folderName)\""` inside a folder. |
| **`rebuildNavigationItems()`** (line 120) | Options menu always contains: `addFolderAction` + `createSortMenu()`. Remove the `if parentFolderId == nil` guard around sort and toggle. Sort is available at all levels. |
| **`setEditing(_:animated:)`** (line 195) | Replace `toolbarItems` + `navigationController?.setToolbarHidden` with showing/hiding a custom `editActionBar` view. See new code below. |
| **`reloadContent()`** (line 276) | Two code paths only: (a) if `parentFolderId` is set, show subfolder + folder's playlists (with search + sort applied); (b) if nil, show top-level folders + unfiled playlists (with search + sort applied). Remove the `isShowingFlatView` branch. |
| **`fetchUnfiledPlaylists()`** (line 316) | Apply `searchText` filter and `sortType` sort. Currently it only sorts by name. |
| **`fetchPlaylists(ids:)`** (line 325) | Apply `searchText` filter and `sortType` sort (inside folders should also be searchable/sortable). |
| **`updateSearchResults(for:)`** (line 645) | Set `searchText` (renamed from `flatSearchText`). |
| **`updateContentUnavailable()`** (line 335) | Check `!searchText.isEmpty` instead of `isShowingFlatView && !flatSearchText.isEmpty`. |

### Add

| What | Details |
|------|---------|
| **`editActionBar` view** | A `UIView` property, created in `viewDidLoad()`, initially hidden. Contains horizontally laid out `UIButton`s. Pinned to `view.safeAreaLayoutGuide.bottomAnchor` with a fixed height (~50pt). Background `.systemBackground`, top border `UIView` 0.5pt `.separator`. |
| **`configureEditActionBar()`** | Called in `viewDidLoad()`. Creates the bar with the correct buttons based on `parentFolderId`. Root: "Add to Folder" button. Inside folder: "Move to Folder" + "Remove from Folder" buttons. |
| **`updateEditActionBarState()`** | Called whenever table selection changes during edit mode. Enables/disables action buttons based on whether any playlists are selected. Override `tableView(_:didSelectRowAt:)` and `tableView(_:didDeselectRowAt:)` to call this in edit mode. |
| **Table view bottom inset** | When `editActionBar` is visible, add bottom content inset to `tableView` (equal to bar height) so the last row isn't hidden behind the bar. Reset inset when edit mode exits. |
| **Delete folder subfolder warning** | In `confirmDeleteFolder()`, check if `folder.subfolders.count > 0` and adjust the message: "Delete 'X' and its N subfolders? Playlists inside will become unfiled." |

### Summary of structural changes

```
BEFORE (current):
  Root view has TWO modes:
    - Folder View: folders + unfiled playlists (default)
    - Flat View: all playlists, searchable, sortable (toggle)
  Edit mode: navigation controller toolbar (hidden behind tab bar)

AFTER (redesign):
  Root view has ONE mode:
    - folders + unfiled playlists, always searchable + sortable
  Edit mode: custom floating action bar (above tab bar)
```

**Estimated scope:** ~80-100 lines removed (flat view logic), ~60-80 lines added (floating action bar + always-on search/sort). Net change is roughly neutral in LOC.
