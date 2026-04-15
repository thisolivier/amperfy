# Design Review: Recently Added Tracks (Home Widget + Detail View)

**Reviewer:** Designer Agent
**Date:** 2026-04-12
**Status:** Post-implementation review + bug triage
**Inputs:** HomeManager.swift, HomeSection.swift, RecentTracksQuery.swift, RecentTracksDetailVC.swift, PlaylistMembershipQuery.swift, EntityPreviewVC.swift, SsPlaylistParserDelegate.swift, BACKLOG.md

---

## 1. Summary of Current Implementation

The "Recently Added Tracks" feature consists of two parts:

### 1.1 Home Widget (HomeManager.swift:509-533)
- Shows up to **7 tracks** added to the library, excluding whole-album tracks (threshold: 5 songs per album)
- Auto-hides when all 7 top tracks are older than 7 days
- Footer shows "(X more in the last 7 days)" count
- Tapping the section header navigates to the detail view
- Data is snapshot-based (pure fetch, no FRC) — refreshed on `viewIsAppearing`

### 1.2 Detail View (RecentTracksDetailVC.swift)
- Two modes via segmented control:
  - **Top N** — most recent N tracks (default 14, range 5-50)
  - **Last M days** — all tracks from last M days (default 7, range 1-60)
- Settings persisted in UserDefaults
- Stepper for adjusting N/M values
- Tapping a row plays the synthetic queue starting at that index

### 1.3 "In Playlists" (PlaylistMembershipQuery.swift)
- Song context menu action showing which user playlists contain a song
- Queries `PlaylistMO` entities where `ANY items.playable.id == songId`
- Filters out smart playlists via `NOT (id BEGINSWITH "smart_")`
- First tap syncs unsynced playlists from server, subsequent taps are instant

---

## 2. Bug Analysis

### Bug 1: "In Playlists" shows recent-tracks-related playlists (circular reference)

**Root cause hypothesis:** This is NOT caused by the client-side Recently Added Tracks feature, which is purely synthetic (no `PlaylistMO` created). The issue is almost certainly **server-side auto-generated playlists from Navidrome** that:

1. Contain recently added songs (matching the same songs shown in the widget)
2. Have regular server-assigned IDs (no `smart_` prefix) — so they pass through `PlaylistMembershipQuery`'s smart-playlist filter
3. Are synced to the client via `SsPlaylistParserDelegate` like any other playlist

Navidrome creates auto-playlists (e.g., "Recently Added", "Most Played") that appear alongside user playlists in the Subsonic API's `getPlaylists` response. These lack the `smart_` prefix convention that Amperfy uses to identify generated playlists.

### Bug 2: Shows twice with no proper name

**Root cause hypothesis:** The duplication likely comes from:
- Two server-side auto-playlists containing the same song (e.g., a "Recently Added" playlist and a "Most Played" playlist, or two instances of the same auto-playlist with different internal IDs)
- The "no proper name" issue suggests these playlists have empty or machine-generated names (e.g., empty string, UUID, or internal identifier) that aren't human-readable

**Investigation needed:** Query the Navidrome server's `/rest/getPlaylists` endpoint to identify which playlists have empty/generated names and overlap with recently added tracks. Check if Navidrome exposes a `public` or `comment` attribute that distinguishes auto-generated playlists.

---

## 3. UX Recommendations

### 3.1 Section Placement on Home — Good as-is

The Recently Added Tracks section is well-placed. In `HomeSection.defaultValue`, it sits at position 5 (after Random Albums, Recently Played Albums, Recently Played Playlists, and Newest Albums). This is appropriate:
- It's below the "what you've been listening to" sections (high-frequency use)
- It's near Newest Albums (both are "what's new" concepts — good proximity)
- Users who don't add individual tracks won't see it (auto-hides when stale)

**No change needed.**

### 3.2 Time Window (7 days) — Appropriate with one enhancement

The 7-day freshness window is reasonable for the home widget. The detail view already allows expansion to 60 days, which covers power users.

**Minor enhancement:** When the widget shows 0 tracks (all stale), the section hides entirely. Consider showing a subtle "No new tracks this week" state instead of hiding, so users know the feature exists and can tap through to the detail view with a longer window. **Priority: Low.** Current hide behavior is acceptable — this is a polish item.

### 3.3 Context Menu Actions — One issue to fix

The current song context menu includes all standard actions (play, show album, add to playlist, In Playlists, download, share, rate, etc.). This is correct for the detail view where songs use `PlayableTableCell` with full context menu support.

**Issue:** On the home widget, tracks are displayed as `HomeItem` tiles. Verify that long-press on a home widget tile opens the same full context menu. If it shows a reduced menu (or no menu), this should be parity-fixed.

### 3.4 "In Playlists" — Filter server-generated playlists (Bug fix)

The `PlaylistMembershipQuery` correctly filters out `smart_`-prefixed playlists, but server-generated playlists from Navidrome bypass this filter because they use regular IDs.

**Recommended fix — two-tier approach:**

**Tier 1 (immediate): Name-based heuristic filter**
Add a predicate to `PlaylistMembershipQuery` that excludes playlists with empty or blank names:
```swift
let hasNamePredicate = NSPredicate(
  format: "%K != nil AND %K != ''",
  #keyPath(PlaylistMO.name),
  #keyPath(PlaylistMO.name)
)
```
This addresses Bug 2 (nameless playlists) immediately.

**Tier 2 (robust): Server-generated playlist detection**
During playlist sync in `SsPlaylistParserDelegate`, detect and flag server-generated playlists. Options:
- **Option A:** Check for Navidrome-specific attributes (e.g., `owner`, `public`, `comment` fields in the `<playlist>` XML) that identify auto-generated playlists. Mark them with a new `isAutoGenerated` flag on `PlaylistMO`, and exclude them in `PlaylistMembershipQuery`.
- **Option B:** Maintain a local blocklist of known Navidrome auto-playlist patterns (by name prefix or ID pattern). Less robust but zero schema change.
- **Option C:** Add a user-facing "Hide from In Playlists" toggle per playlist. Most flexible but highest implementation cost.

**Recommended: Option A.** It's the most principled approach. Navidrome's Subsonic API response includes `owner` and `public` attributes on playlists — auto-generated playlists typically have a system owner or are marked public. This can be detected at parse time.

### 3.5 Empty State for "In Playlists"

When a song isn't in any user playlist, verify the `PlaylistMembershipVC` shows an appropriate empty state (not just a blank table). If it currently shows blank, add a centered label: "This song isn't in any of your playlists."

### 3.6 Detail View UX Polish

The detail view's stepper + segmented control header works but could be clearer:

- **Label clarity:** "Top N" and "Last M days" are programmer-speak. Consider "Most Recent 14" and "Last 7 Days" as segment labels — use the actual current value in the segment title so users don't need to read the stepper label to understand the mode.
- **Stepper accessibility:** The stepper value meaning changes with mode (count vs. days). Ensure VoiceOver announces "14 tracks" or "7 days" rather than just the number.

---

## 4. Bug Fix Specifications

### Fix 1: Filter nameless playlists from "In Playlists" results

**File:** `AmperfyKit/Storage/PlaylistMembershipQuery.swift`

**Change:** Add a predicate requiring non-empty playlist name:

```swift
let hasNamePredicate = NSPredicate(
  format: "%K != nil AND %K.length > 0",
  #keyPath(PlaylistMO.name),
  #keyPath(PlaylistMO.name)
)
fetchRequest.predicate = NSCompoundPredicate(
  andPredicateWithSubpredicates: [
    membershipPredicate, notSmartPredicate, hasNamePredicate
  ]
)
```

**Impact:** Eliminates Bug 2 (nameless duplicates) immediately. Does not address named auto-playlists.

### Fix 2: Detect and exclude Navidrome auto-generated playlists

**Files:**
- `AmperfyKit/Storage/ManagedObjects/PlaylistMO+CoreDataProperties.swift` — add `isAutoGenerated: Bool` attribute (requires schema version bump)
- `AmperfyKit/Api/Subsonic/SsPlaylistParserDelegate.swift` — detect auto-generated playlists during sync (check `owner` attribute, or name patterns like "Recently Added", "Most Played", etc.)
- `AmperfyKit/Storage/PlaylistMembershipQuery.swift` — add `isAutoGenerated == false` predicate
- `AmperfyKit/Storage/LibraryStorage.swift` — add `.userOnly` filter awareness for auto-generated flag

**Alternatively (no schema change):** If the problematic playlists can be reliably identified by a naming pattern or by the Navidrome `owner` field equaling a system account, filter at the query level without a new attribute.

**Decision needed:** Inspect the actual Navidrome API response for these auto-playlists before choosing the implementation path. Run `curl "https://<server>/rest/getPlaylists?u=<user>&p=<pass>&v=1.16.1&c=amperfy&f=json"` and examine the output.

---

## 5. Priority Ordering

| # | Item | Priority | Effort | Bug? |
|---|------|----------|--------|------|
| 1 | Filter nameless playlists from "In Playlists" (Fix 1) | **P0** | Small | Yes — Bug 2 |
| 2 | Investigate Navidrome auto-playlist API response | **P0** | Small | Yes — Bug 1 prereq |
| 3 | Filter/flag auto-generated playlists (Fix 2) | **P1** | Medium | Yes — Bug 1 |
| 4 | Verify home widget tile long-press opens full context menu | **P1** | Small | Possible gap |
| 5 | Empty state for PlaylistMembershipVC | **P2** | Small | UX gap |
| 6 | Detail view segment label clarity | **P3** | Small | Polish |
| 7 | VoiceOver stepper accessibility | **P3** | Small | Accessibility |
| 8 | "No new tracks this week" empty state on home | **P3** | Small | Polish |

---

## 6. QA Acceptance Criteria

### Recently Added Tracks — Home Widget
1. **Widget visibility:** Widget appears on the Home tab when at least one qualifying track was added in the last 7 days.
2. **Widget auto-hide:** Widget does NOT appear when all qualifying tracks are older than 7 days.
3. **Track count:** Widget shows at most 7 tracks, sorted by `addedDate` descending (newest first).
4. **Whole-album exclusion:** Tracks from albums with 5+ songs (and no `"single"` release type) do NOT appear in the widget.
5. **Footer count:** Footer reads "(X more in the last 7 days)" where X = total 7-day count minus visible fresh tracks. Footer does not show negative or zero values.
6. **Navigation:** Tapping the section header navigates to `RecentTracksDetailVC`.
7. **Context menu parity:** Long-pressing a track tile on the home widget opens the same context menu as long-pressing a track in a playlist or album view (including "In Playlists", "Add to Playlist", "Share", etc.).

### Recently Added Tracks — Detail View
8. **Mode switching:** Segmented control switches between "Top N" and "Last M days" modes. Data refreshes immediately on switch.
9. **Stepper bounds:** Top N stepper range is 5-50. Last M Days stepper range is 1-60. Values persist across app launches.
10. **Playback:** Tapping a row plays the synthetic queue starting at that track. Queue contains all currently visible tracks.

### "In Playlists" — Bug Fixes
11. **No nameless playlists:** "In Playlists" results never include playlists with empty or nil names.
12. **No auto-generated playlists:** "In Playlists" results do not include server-generated/auto playlists (e.g., Navidrome's "Recently Added", "Most Played"). Only user-created playlists appear.
13. **No duplicates:** Each playlist appears at most once in the "In Playlists" results for a given song.
14. **No circular reference:** When viewing "In Playlists" for a song shown in the Recently Added Tracks widget/detail view, the results do not include any system playlist that is itself a "recently added" collection.
15. **Smart playlist exclusion preserved:** Smart playlists (ID starting with `smart_`) never appear in "In Playlists" results (existing behavior, must not regress).
16. **Sync on first tap:** First tap on "In Playlists" triggers playlist item sync. Progress indicator appears. Subsequent taps are instant.
17. **Empty state:** When a song is not in any user playlist, "In Playlists" shows a meaningful empty state message rather than a blank list.
18. **Navigation from results:** Tapping a playlist in the "In Playlists" sheet dismisses the sheet and navigates to that playlist's detail view.

---

## 7. Open Questions

1. **What does Navidrome's `getPlaylists` response look like for auto-generated playlists?** We need to inspect the actual XML/JSON to determine the best detection strategy. The `owner` field or absence of a `name` may be sufficient.
2. **Are there other Navidrome auto-playlists beyond "Recently Added"?** If so, the filter needs to be comprehensive, not just targeting one name pattern.
3. **Should auto-generated playlists be visible in the Playlists tab?** If we add detection, should they be hidden everywhere or only from "In Playlists"? Recommendation: hide from "In Playlists" only — some users may want to browse auto-playlists directly.
