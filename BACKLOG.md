# Amperfy Fork — Feature Backlog

**Scope:** user-visible features and research PRs on the Amperfy fork against a Navidrome server. PR 1 / PR 2 were the first pass. PR 3 / PR 4 / PR 5 are the second pass (added 2026-04-11 after QA round 1). PR 6 (share song) and PR 7 (custom styling, research-first) are the third pass (added 2026-04-11 during Wave 4). PR 9 (playlist folders, added 2026-04-12) is prioritized ahead of custom styling Phase 2.
**Audience:** the implementer agent on `navidrome-spike-phaseB`. This file is the authoritative spec — when it disagrees with anything in `IMPLEMENTATION.md` or the spike `NOTES.md`, this file wins.
**Companion reads (do not re-read unless stuck):** `PRIMER.md` (architecture), `IMPLEMENTATION.md` (dev loop + don't-touch list), `docs/DECISION.md` (why Amperfy).
**Branch:** work directly on `spike/extension-eval` with feature commits. No feature branches for this pass — Olivier wants two shippable TestFlight builds back-to-back, and branch gymnastics are friction.

---

## 0. Cross-cutting constraints

- **Hard fork posture for this pass.** Decided 2026-04-10 by team-lead during the offline run: we are NOT trying to keep the Ampache side upstreamable for these two features. That means the `AmpacheLibrarySyncer` stubs can stay empty/unreachable but we are not contorting feature shape around a friendly-fork aesthetic. The upstream-engagement decision is still tabled — we are deferring, not reversing.
- **Version bumping:** every TestFlight upload requires `CURRENT_PROJECT_VERSION` bumped in **all** build configs of both the `Amperfy` and `AmperfyKit` targets. See `spike/testflight-pipeline.md` §"Version bumping". Two builds, two bumps.
- **Test posture:** all new pure-logic additions (predicate builders, parser edits, range-math for the detail view) get `AmperfyKitTests` cases. Integration paths (view host wiring, menu entries) can stay manual-verified via sim build + launch.
- **Don't touch `spike/.signing/`.** The signing pipeline is parallel-owned and known-green.
- **No new SwiftPM dependencies.** Zero-budget for these two features.
- **Do not speculatively collapse the Ampache side.** Adding empty stubs for new protocol methods is the correct behavior.

---

## 1. Shared primitive: "is a whole album" (PR 1 foundation, PR 2 re-use)

Four of the five candidate features hinge on a single boolean query over `AlbumMO`/`SongMO`. We land it once, in one place, and call it from three sites.

### 1.1 The rule

**Updated 2026-04-11 — Option C (pure count) — see §4 decision log.** Earlier
revisions of this primitive used `"album"` / `"ep"` as a positive metadata
signal. Build 3 showed the metadata path letting single-track "albums"
through AND silently excluding all nil-metadata albums via a Core Data NULL
pitfall. The rule is now:

An album is **whole** iff **both** hold:

```
(releaseType IS NULL OR releaseType DOES NOT CONTAIN "single")
AND
remoteSongCount >= minSongCount
```

`"single"` is the sole metadata veto. All other metadata values (including
`"album"`, `"ep"`, `"compilation"`, `"live"`, multi-valued strings, nil) are
classified purely by `remoteSongCount`.

Where `minSongCount` is a parameter, **not a constant** — the call sites use two different thresholds:

| Call site | Threshold | Rationale |
|---|---|---|
| Albums tab "complete albums only" toggle | **3** | Olivier's final call — allow 3-track bags-of-tracks. |
| Home tab "new albums" section filter | **3** | Same as Albums tab. Consistency matters more than the threshold value. |
| Recent-tracks exclusion (PR 2 — "don't show tracks that belong to a whole album") | **5** | The 5-track threshold protects the recent-tracks widget from being dominated by album tracks where metadata is missing. Stricter than the library filters because false-negatives here (letting an album track slip into the singles list) are more annoying than false-positives. |

**Compilations** (`isCompilation="true"` attribute): IGNORED. Compilations flow
through the pure-count rule the same as any other non-`"single"` release.

**The 2-track EP edge case is intentionally unsupported.** A legitimate
`"ep"`-tagged 2-track release fails the count floor under Option C. Users
can find such releases via search or via the unfiltered Albums view. The
team considered a metadata-2-track-floor alternative and rejected it as too
much complexity for a shape that bad ID3 grouping in real libraries makes
unreliable anyway.

### 1.2 Schema addition — v50 bundle

AlbumMO has **no release-type attribute today**. We add it.

**v50 change (additive, inferred-mapping happy path):**
- New file: `AmperfyKit/Storage/ManagedObjects/Amperfy.xcdatamodeld/Amperfy v50.xcdatamodel/contents`
  - Clone v49's `contents` file.
  - On the `Album` entity, add attribute: `releaseType` — type `String`, optional, default nil.
  - No other changes. One attribute only.
- In the `.xcdatamodeld` bundle’s `.xccurrentversion` plist: bump `_XCCurrentVersionName` to `Amperfy v50.xcdatamodel`.
- `AmperfyKit/Storage/CoreDataMigrationVersion.swift`: add the `version50` case following the existing pattern; make it the new `latest`.
- `AmperfyKit/Storage/ManagedObjects/AlbumMO+CoreDataProperties.swift`: add the generated `@NSManaged public var releaseType: String?` following the existing `@NSManaged` style in that file. **Do not** re-run Xcode code-gen — these files are hand-maintained.

This is the textbook additive case `IMPLEMENTATION.md` §4 Feature 3 describes (but done on `AlbumMO` not `PlaylistMO`). `NSMappingModel.inferredMappingModel(...)` will handle the migration; no xcmappingmodel needed. Verify by launching a sim build against an already-seeded v49 store and confirming the app boots and the Albums view still lists every album.

### 1.3 Parser edit — SsAlbumParserDelegate

File: `AmperfyKit/Api/Subsonic/SsAlbumParserDelegate.swift`.

The parser today is attribute-only and only reads the `<album>` start-tag. Navidrome emits `<releaseTypes>` as a **nested text element** on the `getAlbum` (detail) response (and potentially on `getAlbumList2` bulk responses — the implementer must verify by running a fresh sync against the localhost Navidrome). The edit:

1. Add a `private var releaseTypesBuffer = ""` field and a `private var isInReleaseTypes = false` flag alongside `albumBuffer`.
2. In `didStartElement`, add a case for `elementName == "releaseTypes"` that sets `isInReleaseTypes = true` and clears the buffer.
3. Add `override func parser(_ parser: XMLParser, foundCharacters string: String)` that appends to the buffer when `isInReleaseTypes` is true. **Check whether the superclass already overrides `foundCharacters`** — if so, call `super` and guard; if not, add the override fresh.
4. In `didEndElement` for `"releaseTypes"`: trim + lowercase the buffer, write `albumBuffer?.releaseType = trimmed.isEmpty ? nil : trimmed`, clear `isInReleaseTypes`.
5. Also handle the case where `releaseTypes` arrives as an **attribute** on `<album>` (unknown whether Navidrome does this — treat both paths as valid). In `didStartElement` for `"album"`, after the existing attribute reads, do: `if let rt = attributeDict["releaseTypes"] { albumBuffer?.releaseType = rt.lowercased() }`. If the nested element also fires, the later write wins — that is fine.

**Multi-value handling:** if the buffer is `"album ep"` (space-separated) we write `"album ep"` as-is (lowercased). The predicate in §1.4 uses a `CONTAINS` match rather than exact-string `IN`, so multi-value still works.

**Do NOT add a separate `Ss*` parser delegate.** The shared `SsAlbumParserDelegate` is used by both `getAlbumList2` and `getAlbum` paths (confirmed via `LibrarySyncer` grep). One edit covers both.

**The `Album` entity wrapper** (`AmperfyKit/Storage/EntityWrappers/Album.swift`) needs a pass-through property:

```swift
public var releaseType: String? {
    get { managedObject.releaseType }
    set { managedObject.releaseType = newValue?.lowercased() }
}
```

Place it near the existing `remoteSongCount` wrapper.

### 1.4 Predicate builders

File: `AmperfyKit/Storage/ResultController/WholeAlbumPredicates.swift`.

```swift
import CoreData
import Foundation

public enum WholeAlbumPredicates {
    /// Matches AlbumMO rows where the album is "whole" — not tagged "single"
    /// and with remoteSongCount at or above the given floor.
    ///
    /// The `releaseType == nil OR ...` guard is load-bearing: without it,
    /// `NOT (releaseType CONTAINS[c] 'single')` is NULL when releaseType is
    /// nil, and `NULL AND <anything>` is NULL, silently excluding every
    /// nil-metadata album from the result set.
    public static func wholeAlbum(minSongCount: Int16) -> NSPredicate {
        NSPredicate(
            format: """
            (releaseType == nil OR NOT (releaseType CONTAINS[c] %@)) \
            AND remoteSongCount >= %d
            """,
            "single", minSongCount
        )
    }

    /// De Morgan inverse — matches SongMO rows whose parent album is NOT a
    /// whole album. Used by PR 2's recent-tracks widget.
    public static func songFromNonWholeAlbum(minSongCount: Int16) -> NSPredicate {
        NSPredicate(
            format: """
            (album.releaseType != nil AND album.releaseType CONTAINS[c] %@) \
            OR album.remoteSongCount < %d
            """,
            "single", minSongCount
        )
    }
}
```

**Notes for the implementer:**
- The `releaseType == nil OR ...` short-circuit is the fix for the SQLite
  NULL-propagation pitfall that the metadata-hybrid predicate shipped with
  in builds 2–4. Under the new rule, a nil-metadata album is classified by
  `remoteSongCount` alone — exactly the intended behavior for the majority
  of a typical Navidrome library.
- `CONTAINS[c] "single"` is deliberate over exact `== "single"` so multi-
  value strings like `"single, live"` are still vetoed. The
  MusicBrainz-derived vocabulary has no other token that contains `single`
  as a substring.
- `NSPredicate` requires Int for `%d` — `Int16` auto-promotes cleanly.

### 1.5 Unit tests for the primitive (AmperfyKitTests)

File: `AmperfyKitTests/Cases/Storage/ResultController/WholeAlbumPredicatesTest.swift`.

Under the Option C pure-count rule (threshold 3 unless noted):

1. `releaseType = "single"`, `remoteSongCount = 5` → NOT whole (veto wins).
2. `releaseType = "album"`, `remoteSongCount = 1` → NOT whole (count floor).
3. `releaseType = "ep"`, `remoteSongCount = 2` → NOT whole (count floor — intentional 2-track-EP regression).
4. `releaseType = "album"`, `remoteSongCount = 3` → whole (via count).
5. `releaseType = nil`, `remoteSongCount = 5` → whole (happy path, nil metadata majority case).
6. `releaseType = nil`, `remoteSongCount = 3` → whole — **regression guard for the SQLite NULL-handling pitfall** (was silently excluded in builds 2–4).
7. `releaseType = nil`, `remoteSongCount = 2` → NOT whole (count floor).
8. `releaseType = "album ep"` (multi-value), `remoteSongCount = 4` → whole (via count, does not contain "single").
9. `releaseType = "compilation"`, `remoteSongCount = 6` → whole (via count).
10. `releaseType = "compilation"`, `remoteSongCount = 2` → NOT whole (count floor).
11. Mixed-library smoke test — seeds 7 albums spanning the cases above and asserts the exact matched id set.
12. `songFromNonWholeAlbum` inverse: song on `"single"` parent is INCLUDED.
13. `songFromNonWholeAlbum` inverse: song on `"album", count=10` parent is EXCLUDED.
14. `songFromNonWholeAlbum` inverse: song on `nil, count=3` parent is EXCLUDED — inverse regression guard for the NULL pitfall.
15. `songFromNonWholeAlbum` inverse: song on `nil, count=1` parent is INCLUDED.

Total: 15 cases (13 from the original suite rewritten + 2 new NULL-pitfall regression guards).

**PR 2 `RecentTracksQueryTest` re-verified:** all 9 existing cases still green under Option C. `testTopNExcludesWholeAlbumSongs` (album `count=8` excluded, single `count=2` included) and `testTopNExcludesHighCountUntaggedAlbumSongs` (`nil count=5` excluded, `nil count=2` included) still match their assertions — they were incidentally validating count-floor behavior already.

---

## 2. PR 1 — Feature A: whole-album primitive + Albums toggle + home new-albums filter

**Release target:** TestFlight build #1 (bump `CURRENT_PROJECT_VERSION` by 1 from the current signed-pipeline baseline).

### 2.1 A.1 — Albums view "complete albums only" toggle

**Where it lives:** the existing Albums tab entry point in the Library side of the app. Find it by opening the app in the sim and tapping "Albums" from the Library tab; the nav stack will tell you the VC. Likely `AlbumsVC` or similar inside `Amperfy/Screens/ViewController/Library/`.

**UI shape:**
- Add a persistent toggle/segmented-control in the nav bar right-bar-button area labeled "Complete" / "All" — or a `UIBarButtonItem` with an SF symbol (`rectangle.stack.fill` when on, `rectangle.stack` when off). Pick whichever matches the idiom in the file on touch. Either is fine for an internal build.
- Toggle state persists across app launches via `@AppStorage("wholeAlbumsOnly")` or the equivalent `UserDefaults` key if the VC is UIKit. Default: off.
- When on, the Albums FRC fetch request gets its `predicate` set to `WholeAlbumPredicates.wholeAlbum(minSongCount: 3)` (ANDed with any existing filter that's already there). When off, the original predicate.
- Toggling MUST re-run `performFetch` on the FRC and reload the table/collection view. If the view uses `@FetchRequest` directly (SwiftUI), the predicate is a `@State`-driven parameter and FRC handles the rest.

**Files expected to touch (prediction — the implementer verifies on first read):**
1. The Albums-list VC (UIKit) or SwiftUI view — add toggle + FRC predicate swap. ~30–50 LOC.
2. If UIKit: a small `Notification` or delegate callback so the toggle flips the predicate. If SwiftUI: `@AppStorage` + predicate recomputation.

**Manual acceptance (sim):**
- Toggle OFF → full Albums list (what the user sees today).
- Toggle ON → filtered list. At least one album that existed in OFF-mode is hidden.
- Toggle back OFF → list restored without a scroll jump bug.
- Kill + relaunch app → toggle state restored.

### 2.2 A.2 — Home tab "new albums" section filter

**Where it lives:** the home tab's "newest" / "recently added" albums section. Find the view that binds the `syncNewestAlbums` output; it should be a section of the Home VC with its own FRC or `@FetchRequest`.

**Shape:**
- No UI change. The filter is **always on** for this section — there is no toggle; "new albums" on the home tab means whole new albums by Olivier's decision.
- Set `WholeAlbumPredicates.wholeAlbum(minSongCount: 3)` on whatever predicate currently drives the section (ANDed with its existing predicate, which is typically a sort on `newestSong.addedDate` DESC + a `remoteStatus == .available` guard).

**Files expected to touch:** 1 file, ~5 LOC. If the section uses a shared `FRCProvider` it may be one line.

**Manual acceptance:**
- Home tab → new albums row → verify every album displayed satisfies the rule (spot-check 3 of them by opening — each should have ≥3 tracks OR a recognizable release-type).
- Albums filtered out by A.2 still appear in the full Albums tab with the toggle OFF — sanity check.

### 2.3 A.3 — Feature B exclusion wiring (deferred to PR 2)

PR 1 does **NOT** touch PR 2's recent-tracks widget (which doesn't exist yet). The third call site of the primitive lands in PR 2 alongside the widget itself. A.3 is just a reminder in this doc that the primitive exists specifically so PR 2 can plug into it cheaply.

### 2.4 PR 1 test matrix (AmperfyKitTests)

All 11 cases from §1.5 (the predicate unit tests).

No new UI tests. Manual sim verification of A.1 and A.2 covers the integration.

### 2.5 PR 1 acceptance checklist

- [ ] v50 `.xcdatamodel` created, `.xccurrentversion` bumped, `CoreDataMigrationVersion.version50` added + marked latest.
- [ ] `AlbumMO+CoreDataProperties.swift` has `@NSManaged public var releaseType: String?`.
- [ ] `Album.swift` wrapper has the pass-through.
- [ ] `SsAlbumParserDelegate.swift` reads `releaseTypes` via both nested-element and attribute paths, lowercased.
- [ ] `WholeAlbumPredicates.swift` exists with the two builders.
- [ ] 11 unit tests in `WholeAlbumPredicatesTest.swift`, all green.
- [ ] Albums tab toggle A.1 lands and flips the list.
- [ ] Home tab new-albums section A.2 is filtered at threshold 3.
- [ ] Full `xcodebuild test -only-testing:AmperfyKitTests` is green (no regressions elsewhere).
- [ ] Sim build launches, connects to the preconfigured localhost / olivierSoulseek Navidrome account, and the user can navigate through both surfaces.
- [ ] Additive migration verified: an app previously seeded on v49 boots cleanly into v50 without a reset (test by launching the PR 1 build without wiping the sim first if you have an already-logged-in sim state; otherwise document that inferred mapping was not end-to-end verified and flag it to team-lead).

### 2.6 PR 1 ship steps

1. Commit all changes on `spike/extension-eval`.
2. Bump `CURRENT_PROJECT_VERSION` in `Amperfy.xcodeproj/project.pbxproj` — **all** build configs, both the `Amperfy` target and the `AmperfyKit` framework target. Single monotonic increment.
3. Follow `spike/testflight-pipeline.md` §1 Amperfy pipeline: source `api-key.env`, unlock keychain, archive, exportArchive, altool upload.
4. Capture the delivery UUID from altool's output and append it to the "Release log" at the bottom of this file.
5. Report back to `team-lead` with: delivery UUID, the new `CURRENT_PROJECT_VERSION`, and a one-line feature summary for TestFlight release notes.

---

## 3. PR 2 — Feature B: recently added tracks widget + synthetic playlist detail view

**Release target:** TestFlight build #2, after PR 1 is uploaded. Another `CURRENT_PROJECT_VERSION` bump.

### 3.1 B.1 — Home tab widget "recently added tracks"

**Where it lives:** the home tab's vertical stack, in the same neighborhood as the "new albums" row edited in A.2. Sits **above or below** the new-albums row (whichever reads better visually — pick one and document).

**Shape:**
- A compact section header "Recently added tracks".
- Body: up to **7** track rows, each showing track name + artist name. Tap target is the row.
- Footer text: "`(N more in the last 7 days)`" where N is the count of additional tracks (beyond the 7 visible) whose `addedDate >= now - 7.days` AND which pass the "not from a whole album" filter. If N == 0, the footer line reads simply "`(Tap to see more)`" or similar — the widget always offers the tap-through even if there are no extras in the 7-day window.
- **Hide the whole widget** iff all of the freshest 7 passing tracks have `addedDate < now - 7.days`. In other words: if the user has had nothing added in the last week that qualifies, the widget disappears entirely from the home stack — no empty state, no "nothing here" row.

**Query:**
- Entity: `SongMO`.
- Predicate: `WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 5)` — **threshold 5**, not 3. This is intentional and matches Olivier's final rule (stricter here than in the library filters; §1.1 covers the why).
- Additional predicate conjunct: `remoteStatus == .available` (follow the existing "live rows only" pattern).
- Sort: `\SongMO.addedDate` DESC.
- Fetch limit: 7 for the visible rows. A separate count fetch gets the "X more in the last 7 days" number (or use a `@FetchRequest` with no limit + a window predicate + `.prefix(7)`).

**Widget show/hide logic:** done in the view's body, not in the fetch. Fetch the top 7 unconditionally; if all 7 have `addedDate < now - 7.days`, return `EmptyView()` (or remove the section entirely from the UIKit stack).

**Files expected to touch (prediction):**
1. `Amperfy/SwiftUI/Home/RecentTracksWidgetView.swift` — new SwiftUI view, `@FetchRequest`-driven, ~80 LOC.
2. `Amperfy/Screens/ViewController/Home/RecentTracksWidgetHostVC.swift` — `UIHostingController` shim, ~20 LOC. (Skip if the Home VC is already SwiftUI-hosted — embed directly.)
3. The Home-stack parent VC — one-line insertion of the host VC / SwiftUI view. ~5 LOC.

### 3.2 B.2 — Synthetic playlist detail view (tap-through)

**Tap behavior:** tapping any track row in B.1 OR tapping the footer opens the detail view. Not per-track-plays-that-track — the row and footer both open the detail view. (Track-tap-to-play is a separate feature; Olivier's brief says "Tap a track to open the view".)

**Shape:**
- A full-screen playlist-like view modeled on the existing playlist detail pattern (whatever Amperfy's `PlaylistDetailVC` is). Reuses the existing row cells, context-menu actions, and "play all" affordance by mimicking what the real playlist view does.
- **Header controls (above the track list):**
  - A mode segmented control: **"Top N"** ↔ **"Last M days"**.
  - In "Top N" mode: a stepper or number field for N. Default: **14**.
  - In "Last M days" mode: a stepper or number field for M. Default: **7**.
  - Switching modes swaps the stepper control; the other value is remembered (stash both in `@AppStorage` keys `recentTracksTopN` and `recentTracksLastMDays`).
- **Track list below:** recomputed live from the current mode + parameter.
  - "Top N": the freshest N songs by `addedDate` DESC that pass the non-whole-album filter at threshold 5.
  - "Last M days": all songs with `addedDate >= now - M.days` that pass the non-whole-album filter at threshold 5, sorted by `addedDate` DESC. No cap on the number of rows in this mode (if the user says "last 30 days", they see all of them).
- **Play-all / play-next / shuffle:** wire to Amperfy's existing `PlayContext` mechanism the way the real playlist detail view does. The tracks in the current list form the queue. Tapping an individual row plays from that row with the full list as the queue — same as playlist behavior.
- **Title:** "Recent tracks" (static — doesn't change with mode).

**Why "synthetic" playlist:** there is no `PlaylistMO` backing this view. It is a transient view that reuses the playlist detail visual shell + play-context wiring. Do **not** create a `PlaylistMO` row; do **not** persist the list; do **not** write to `PlaylistItemMO`. The view holds a `[Song]` (entity-wrapper array) in a `@State` or equivalent, rebuilds on mode/parameter change, and feeds the player queue on play.

**How to reuse playlist visuals without coupling to `Playlist`:**
- The cleanest path is a **new** SwiftUI detail view that copies the layout of the existing playlist detail but takes a `[Song]` parameter + a title. Do NOT try to instantiate `PlaylistDetailVC` with a fake `Playlist` — the class has too many assumptions about a real MO.
- Reuse the row-cell component (extract it if it's currently private to the playlist detail file; otherwise copy it — the shape is small and duplication is cheaper than refactoring upstream code on a hard-fork pass).
- The play-context wiring goes through the existing `PlayContext(name:playables:)` or equivalent constructor. Grep for how `PlaylistDetailVC` builds its play context; mimic it.

**Files expected to touch (prediction):**
1. `Amperfy/SwiftUI/Home/RecentTracksDetailView.swift` — the synthetic detail view, ~150 LOC.
2. `Amperfy/SwiftUI/Home/RecentTracksQuery.swift` — a small helper struct that exposes two static funcs: `topN(context:n:)` → `[Song]` and `lastMDays(context:m:)` → `[Song]`, both applying the threshold-5 predicate. ~40 LOC. Keeps the view thin and the logic unit-testable.
3. `RecentTracksDetailHostVC.swift` — hosting shim if needed. ~20 LOC.
4. Row cell: either extracted or duplicated from playlist detail. ~20 LOC if duplicated.
5. Navigation wiring: the widget's tap action pushes the detail view onto the home tab's nav stack.

**Expected total for PR 2:** ~4–6 files, ~300 LOC, plus tests.

### 3.3 B.3 — The primitive's third call site

This is the moment `WholeAlbumPredicates.songFromNonWholeAlbum(minSongCount: 5)` earns its existence. It is called from:
- B.1's `@FetchRequest` predicate.
- B.2's `RecentTracksQuery.topN` and `lastMDays` helpers.

No additional file for B.3 itself — it's the same builder from PR 1, imported where needed.

### 3.4 PR 2 test matrix (AmperfyKitTests)

New file: `AmperfyKitTests/Cases/Storage/RecentTracksQueryTest.swift`.

Test cases (uses the in-memory stack + seeder):

1. Seed 20 songs over the last 30 days, mixed across a whole album (8 tracks, `releaseType="album"`), a single (`releaseType="single"`), and loose tracks (no `releaseType`, various `album.remoteSongCount` values 1/2/3/4). Run `topN(n: 14)` and assert:
   - Result count is 14 (seed has enough qualifying).
   - No song from the 8-track whole album is present.
   - No song from the single is present.
   - Loose tracks with `album.remoteSongCount < 5` ARE present.
   - Loose tracks with `album.remoteSongCount == 5` are NOT present (threshold-5 boundary).
   - Results are sorted by `addedDate` DESC.
2. Same seed, run `lastMDays(m: 7)`. Assert:
   - Only songs with `addedDate >= now - 7.days` are in the result.
   - Same predicate semantics (whole-album tracks excluded at threshold 5).
3. Boundary: a song with `addedDate = now - 7.days + 1.second` IS included; `addedDate = now - 7.days - 1.second` is NOT.
4. Empty-state: seed only whole-album songs. `topN(n: 14)` returns `[]`. `lastMDays(m: 7)` returns `[]`.
5. Widget-hide predicate: seed 7 qualifying songs all older than 7 days, 0 fresher. A test at the view-query layer (pure function) asserts that the "should show widget" helper returns `false`. If this is only checkable inside the view, document it as a manual check instead — acceptable.
6. Threshold boundary: same predicate unit test cases #4 and #5 from §1.5 re-verified through the `RecentTracksQuery` helper (not duplicating the `NSPredicate` tests, but verifying the helper uses the right threshold).
7. Compilation-track exclusion: a song on a compilation with `album.remoteSongCount = 6` → EXCLUDED (compilation over threshold-5 → whole album → its tracks are filtered out).
8. Compilation-track inclusion: a song on a compilation with `album.remoteSongCount = 2` → INCLUDED (compilation under threshold).

Total: 8 query-layer cases on top of the 11 predicate cases from PR 1.

No UI snapshot tests. The widget + detail view are validated by sim + device smoke.

### 3.5 PR 2 acceptance checklist

- [ ] Home widget B.1 appears in the home stack with up to 7 rows.
- [ ] Widget hides entirely when the freshest 7 qualifying tracks are all >7 days old.
- [ ] Footer text is correct ("X more in the last 7 days" or fallback).
- [ ] Tapping any row or the footer opens B.2.
- [ ] B.2 defaults to "Top N" mode with N=14.
- [ ] Mode toggle works; stepper swaps; previous value is remembered per-mode.
- [ ] Track list updates live on mode/parameter change.
- [ ] "Play all" / row-tap-to-play correctly uses the current list as the queue.
- [ ] `@AppStorage` restores the user's last mode/N/M across app relaunches.
- [ ] No whole-album tracks appear in either B.1 or B.2 (spot-check against a known whole album the user can identify).
- [ ] 8 new `RecentTracksQueryTest` cases green.
- [ ] All PR 1 tests still green (regression guard).
- [ ] Sim build reaches the widget, opens the detail view, and plays a track through to the lock screen / system player.

### 3.6 PR 2 ship steps

Same as §2.6 but for the second monotonic version bump. Append PR 2's delivery UUID to the Release log.

---

## PR 3 — Feature C: "Show playlists" in the song ... menu

**Release target:** TestFlight build after Wave 3 closes. Bump `CURRENT_PROJECT_VERSION` monotonically.

**Intent:** from any song row's `...` (context/more) menu, open a list of playlists that song currently belongs to. Tapping a playlist pushes that playlist onto the current navigation stack.

### C.1 Attach points

Add the new menu entry at these two sites only:

1. **Song row context menu** — `UIContextMenuConfiguration` for song cells. Find the site by grepping for `UIContextMenuConfiguration` in `Amperfy/Screens/ViewController/` and looking for the song-cell branch (likely reached through a shared `SongActionBuilder` or similar). Add the action alongside the existing "Add to playlist", "Download", etc.
2. **Mini-player `...` button** — the popover/sheet that the mini-player surfaces when its action button is tapped. Find via the mini-player VC in `Amperfy/Screens/ViewController/Player/`.

**NOT** the full-player's `...` button unless it shares the same builder as the mini-player (it probably does — consolidate through one builder). Do NOT add this to the nav bar or library-level menus — there is no single-song context there.

### C.2 User flow

1. User taps `...` on a song → menu opens → "Show playlists" entry visible and **always enabled** (see C.3).
2. User taps "Show playlists" → playlists sheet/VC appears.
3. User taps a playlist row → if the sheet is presented modally, **dismiss the sheet first**; if the mini-player is the entry point, **dismiss the mini-player detail sheet first** (Olivier impulse: yes, dismiss); then **push** the tapped playlist onto the current nav stack. Do NOT `popToRoot` first — the user's current context is preserved.
4. The pushed playlist VC is the existing `PlaylistDetailVC` (or whatever the playlist detail VC is called — grep for the existing "playlists tab" → playlist-row tap push).

### C.3 Scope

- **Real playlists only.** No smart playlists, no synthetic views. Filter against `PlaylistMO` where `isSmartPlaylist == false` (or the equivalent flag in the schema — implementer verifies).
- **Lazy query, no pre-counting.** The ... menu entry is **always enabled** and shows no count. Counting each song's playlist membership at cell-render time in a long list is the exact perf trap we want to avoid. The query fires when the user taps the entry. If the result is empty, show an empty state ("This song isn't in any playlists") with a dismiss affordance — do not surface a disabled menu entry.
- **Show all known playlists** the song appears in (no pagination cap, no "Top N" limit). The query scope is the full local `PlaylistMO` set.

### C.4 Query design

File: `AmperfyKit/Storage/PlaylistMembershipQuery.swift` (new, ~30 LOC).

```swift
public enum PlaylistMembershipQuery {
    /// Returns every non-smart PlaylistMO that contains at least one
    /// PlaylistItemMO whose underlying song matches the given song id.
    /// Lazy — fires once per ... menu tap. Do not cache results beyond
    /// a single invocation.
    public static func playlistsContaining(
        songId: String,
        in context: NSManagedObjectContext
    ) -> [PlaylistMO]
}
```

Implementation sketch: fetch `PlaylistMO` with predicate
`ANY items.playable.id == %@ AND isSmartPlaylist == NO`.
Sort by `name` ascending. The `ANY` traversal is Core Data's supported
subquery form and maps to a SQL `EXISTS` under the hood — fine for
per-tap use. **Don't** iterate PlaylistMO objects in Swift and filter —
that would fault every playlist's items array.

Unit tests: `AmperfyKitTests/Cases/Storage/PlaylistMembershipQueryTest.swift` —
3 cases:
1. Song in 2 playlists → returns both, sorted by name.
2. Song in 0 playlists → returns empty array.
3. Song in 1 smart playlist + 1 real playlist → returns only the real one.

### C.5 UI

Reuse the existing `PlaylistsVC` (or the lightweight equivalent from the playlists tab) by feeding it a pre-filtered list. Two acceptable shapes — pick whichever is less invasive on first read:

- **Option A (preferred):** present a new lightweight `PlaylistMembershipVC` that subclasses or composes the existing `PlaylistsVC` with an `initWithPlaylists: [Playlist]` override. On row-tap, dismiss self and push `PlaylistDetailVC` onto the presenting VC's nav stack.
- **Option B:** if subclassing `PlaylistsVC` is awkward (its data source is likely FRC-backed over the full `PlaylistMO` set), build a bare `UITableViewController` that takes `[Playlist]` directly and reuses the existing `PlaylistTableCell`.

Either way: ~80–120 LOC. No new assets.

### C.6 Tests & acceptance

**AmperfyKitTests:** 3 `PlaylistMembershipQueryTest` cases (see C.4).

**Manual acceptance (sim):**
- Song with 0 playlists → menu entry opens sheet → empty state visible → dismiss works.
- Song with ≥1 playlist → menu entry opens sheet → listed → tapping pushes playlist detail onto nav stack.
- Mini-player entry point → mini-player sheet dismisses before nav push (no sheet-above-nav glitch).
- Long song list scroll → no lag regression (perf-sanity, since the menu entry is always enabled and lazy).

### C.7 Ship steps

Same monotonic bump pattern as §2.6.

---

## PR 4 — Research: Albums view performance investigation

**Release target:** no TestFlight build. Deliverable is a markdown document.

**Intent:** diagnose the lag Olivier reports on the Library → Albums view (high lag tapping in/out of albums, high lag scrolling the index list, high lag on the top-level library view, one crash). The simulator does not reproduce the lag, so the investigation is static-first; the implementer may attach a physical device later if static analysis is inconclusive.

### D.1 Symptom summary

- **Device:** Olivier's aging iPhone (exact model TBD — team-lead to ask if needed).
- **Reproducer:** Library → Albums view. Tap into an album detail VC and back. Scroll the section index (`UITableView.sectionIndexTitles`) on the left edge. Top-level Library root also exhibits lag.
- **Persistence:** "The lag remains long after the recalculation" — i.e. the filter toggle is not the sole cause. Switching from the Complete filter to the unfiltered list is the reported trigger, but the lag persists after the FRC has stabilized. **Hold this as the leading hypothesis but do not fixate.**
- **Crash:** one observed, stack trace not captured. If the investigator encounters any memory-pressure signals statically, flag them.

### D.2 Deliverable

A single markdown document at `spike/amperfy/PERFORMANCE_ALBUMS.md` with this structure:

```markdown
# Albums view performance — investigation notes (2026-04-XX)

## Symptom
<one-paragraph repro + what was observed>

## Methodology
<static: which files read, which call graphs traced; dynamic: any sim
Instruments runs or device runs, what was measured>

## Hypotheses tested
### H1: <name>
- Evidence for:
- Evidence against:
- Verdict: likely / unlikely / inconclusive

<repeat per hypothesis>

## Findings
<concrete bottlenecks identified, with file:line refs>

## Recommended follow-ups
<ordered list of optimizations, with rough effort estimates and risk>
```

### D.3 Hypotheses to seed the investigation

**Research-only — do not implement fixes in this PR.** The investigator should pressure-test each hypothesis and fall back to static reading of the suspect call sites. Add new hypotheses as they surface.

- **H1 — Stale post-swap state in the FRC / snapshot.** The Complete → unfiltered predicate swap leaves the FRC with an invalidated section cache or a diffable-data-source snapshot that is out of sync with the current fetch set. Each subsequent push/pop or scroll triggers a reconcile pass. Look at `AlbumFetchedResultsController.search` (the B-1 fix site) and how `AlbumsVC` drives its data source after the toggle. Specifically: does the toggle trigger `applySnapshot(animatingDifferences: true)` with a large diff? Is the section-index recomputed on every update?
- **H2 — Artwork decode on cell-render.** `AlbumMO.artwork` is a synchronous Core Data relationship traversal; each cell may be decoding a PNG/JPEG on the main thread during scroll. Check `AlbumsVC`'s cell configuration — is there an async image-loader path, or a direct `UIImage(data:)` call? Is there an image cache (`AmperfyKit/ArtworkCache` or similar)?
- **H3 — Section-index scroll recomputes the full section titles.** `UITableView.sectionIndexTitles` fires `tableView:sectionForSectionIndexTitle:atIndex:` for every tap; if the data source recomputes the section title array each call instead of caching, that's O(n_albums) per index tap on a ~500+ album library.
- **H4 — Core Data fault storms.** The Albums VC may be iterating `AlbumMO` objects (e.g. in a `numberOfSections` or grouping pass) and triggering faults on every row. Check for any `.forEach`/`.map` over the FRC's `fetchedObjects` that touches non-prefetched attributes.
- **H5 — The `CONTAINS[c]` predicate is non-SARGable on SQLite.** The `wholeAlbum` predicate uses `releaseType CONTAINS[c] "single"` which cannot use a btree index; on a 500+ album library this is a table scan per toggle. Not the lag source (toggle is one-shot), but confirm it's not being re-evaluated on every scroll by the FRC.

### D.4 Methodology

1. **Static first.** Read `AlbumsVC` (or the SwiftUI equivalent), its data source, the cell config, the FRC wiring, the section-index delegate. Walk the call graph from `scrollViewDidScroll` / `tableView(_:cellForRowAt:)` / `tableView(_:sectionForSectionIndexTitle:atIndex:)` and flag any main-thread work that scales with library size.
2. **Targeted signpost build.** If static reading is inconclusive, add temporary `os_signpost` markers around the suspect sites, build for sim, and run Instruments → Points of Interest. Signposts must be behind a `#if DEBUG` gate and removed before ship.
3. **Device attach (if requested).** If the investigator concludes the lag is device-only and reproducible only on Olivier's phone, team-lead queues a device session — Olivier pre-authorized attaching his phone: "if it only shows on at all on my aging iPhone, we can attach my phone and your team member can poke it."

### D.5 Non-goals

- No fixes land in this PR. Findings feed into a follow-up PR sized per the recommendations.
- No broader performance sweep (Home tab, Recent Tracks detail, Player) — scope is Albums view + its detail push/pop.
- No new dependencies (no `Instruments` framework helpers, no third-party profilers).

### D.6 Ship steps

1. Write `PERFORMANCE_ALBUMS.md` to the spec above.
2. Commit to `spike/extension-eval` with message `perf: Albums view investigation — findings only`.
3. Append a dated row to the Release log under "Research" (new sub-heading, no TestFlight UUID).
4. Notify team-lead of findings; team-lead decides whether to queue a follow-up implementation PR.

---

## PR 5 — Feature D: Favourited playlists + home screen widgets for favourites

**Release target:** TestFlight build after PR 3 ships. Bump `CURRENT_PROJECT_VERSION` monotonically.

**Intent:** Amperfy already surfaces `isFavorite` for albums and artists (backed by Subsonic `star` on the server). Extend the same affordance to playlists, then add three new Home tab sections — Favourite Albums, Favourite Artists, Favourite (pinned) Playlists — each hidden when empty.

Olivier's guidance unpacks this into **two sub-features**:

- **D.1 — Favourite albums & artists sections on Home.** Existing server-backed `isFavorite` state. No Core Data schema change. Pure UI addition.
- **D.2 — Pinned playlists (local-only) + playlist "favourite" affordance.** Navidrome's OpenSubsonic `star` endpoint accepts playlist IDs in some implementations, but we are NOT relying on that — see D.2.1 for the rationale. Local-only state, stored outside Core Data to preserve upstream merge compatibility.

### D.1 Favourite albums & artists on Home

**Where it lives:** Home tab. Add two new sections above or below the existing "Newest Albums" / "Recent Tracks" sections — order tbd on implementer's visual judgment, Olivier did not specify.

**Data source:** existing `AlbumMO.isFavorite == YES` / `ArtistMO.isFavorite == YES` predicates. Reuse the existing FRC providers in `HomeManager` if they exist; otherwise add two new FRCs following the `albumsNewestFetchController` pattern.

**Section visibility:** hidden when empty (reuse the `sectionsHiddenWhenEmpty` allowlist introduced by B-2 hotfix 3 — see §6 Hotfix 3). This is the **additive sections** pattern Olivier explicitly called out.

**Interaction with the Complete Albums filter:** **team-lead default is (b) favourites win** — Favourite Albums section ignores the whole-album filter. Rationale: favourites are an explicit user signal; filtering them by the same heuristic that hides bags-of-tracks would second-guess the user. Flag this decision as open in the PR description and await Olivier's confirmation before merge.

**Files expected to touch:** `HomeVC.swift`, `HomeManager.swift`, `HomeSection` enum (if present). ~80–120 LOC + the section visibility wiring.

### D.2 Pinned playlists (local-only) + playlist "favourite" affordance

#### D.2.1 Storage design

**Decision: do NOT add `isPinned: Bool` (or equivalent) to `PlaylistMO`.** Any Core Data schema change is a v51 bundle, a migration, and a merge conflict every time upstream Amperfy touches the data model. Olivier's constraint is explicit: "device only is A-OK, but it may harm our ability to work with upstream if we do DB changes. Is there some way to store this which won't block our ability to pull in future DB migrations from upstream?"

**Instead:** new service `AmperfyKit/Favorites/PinnedPlaylistStore.swift` (~60 LOC).

```swift
public final class PinnedPlaylistStore {
    public static let shared = PinnedPlaylistStore()

    private let defaultsKey = "amperfy.fork.pinnedPlaylists"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Set of pinned playlist ids (the Subsonic playlist id string).
    public private(set) var pinnedIds: Set<String> {
        get { Set(defaults.stringArray(forKey: defaultsKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: defaultsKey) }
    }

    public func isPinned(_ playlistId: String) -> Bool
    public func pin(_ playlistId: String)
    public func unpin(_ playlistId: String)
    public func toggle(_ playlistId: String) -> Bool   // returns new state

    /// Posts a `PinnedPlaylistStore.didChange` notification on every mutation
    /// so UI layers can refresh without KVO on a non-@objc type.
    public static let didChangeNotification = Notification.Name("amperfy.fork.pinnedPlaylists.didChange")
}
```

**Why UserDefaults and not a JSON file in Application Support:**
- `UserDefaults` is atomically written and survives app termination without risk of half-written files.
- Set size is bounded by human attention — even 1000 pinned playlists is ~30KB of string array, well inside `UserDefaults` comfort zone.
- Zero filesystem permission ceremony.
- If Olivier later wants sync across devices via iCloud Key-Value Store, swapping `UserDefaults.standard` for `NSUbiquitousKeyValueStore` is a one-line change behind the same interface.

**Why not Core Data with a separate store coordinator:**
- Two Core Data stacks in one app is a maintainability hazard and a merge-conflict target.
- The whole point of this decision is to minimize schema surface against upstream.

#### D.2.2 UI — playlist favourite toggle

The existing album/artist detail VCs have a favourite button (likely a heart or star in the nav bar). `PlaylistDetailVC` should get the same affordance:

- Nav bar button, SF symbol `star` / `star.fill`.
- On tap: `PinnedPlaylistStore.shared.toggle(playlist.id)` → update the button state.
- On init / viewWillAppear: read `isPinned(playlist.id)` → set initial state.
- Use **"favourite" / "pin"** as the user-visible label — Olivier: "Favorite is how it's described in Amperfy, and separately you can apply a star rating. We're looking at the favorite aspect." The UI affordance on playlist detail should match the existing album/artist favourite button idiom (heart or star — match whatever albums/artists use today). Internally the Store talks about "pinned" to keep the code distinct from the Core Data `isFavorite` flag.

#### D.2.3 Home tab — Favourite Playlists section

Third new Home section (alongside D.1's Favourite Albums + Favourite Artists).

**Data source:** `PinnedPlaylistStore.shared.pinnedIds` → fetch `PlaylistMO` with predicate `id IN %@`. Not an FRC (UserDefaults isn't FRC-observable); instead, subscribe to `PinnedPlaylistStore.didChangeNotification` in `HomeVC` and call `applySnapshot` on change.

**Section visibility:** hidden when empty (same `sectionsHiddenWhenEmpty` allowlist).

### D.3 Tests

**AmperfyKitTests:**
- `PinnedPlaylistStoreTest` (~6 cases): empty state, pin one, unpin, toggle, persistence across store instances (use a throwaway `UserDefaults(suiteName:)`), notification fires on mutation.
- `HomeManager` favourite-sections FRC cases (2 cases): D.1 predicates select only `isFavorite == YES` rows.

**Manual acceptance (sim):**
- Home tab with zero favourited albums / artists / pinned playlists → three sections hidden.
- Favourite one album → section appears → unfavourite → section disappears.
- Pin a playlist via playlist detail → Home shows pinned playlists section with it → relaunch app → state persists.
- Pinned section respects `sectionsHiddenWhenEmpty` (no empty-header ghost).

### D.4 Decision point (open — Olivier to confirm)

**Do Favourite Albums / Favourite Artists sections respect the Complete Albums filter?** Team-lead default: **(b) no, favourites win.** Rationale in D.1. Implementer should implement (b), surface the question in the PR description, and be prepared to flip to (a) in a one-line change if Olivier overrides.

### D.5 Ship steps

Same monotonic bump pattern as §2.6. **Ship D.1 and D.2 in a single PR** — they're bundled under one Home-tab UX intent and splitting them is more churn than value.

---

## PR 6 — Feature E: Share a song via the native iOS share sheet

**Release target:** TestFlight build after PR 5. Bump `CURRENT_PROJECT_VERSION` monotonically.

**Intent:** from any song's `...` menu (song row context menu + mini-player `...` sheet), tap "Share" to download the underlying audio file (if not already cached locally) and present the native `UIActivityViewController` with the file attached. Lets the user forward a song to Messages / AirDrop / Files / etc., exactly like iOS Music or Files.app does.

### E.1 Attach points

Reuse the shared action builder that PR 3 §C.1 consolidates (song row context menu + mini-player `...` sheet). Add the "Share" action next to the existing "Add to playlist" / "Download" entries. This is a second-tenant feature on top of PR 3's builder — do NOT build a parallel action list.

If PR 3 went with Option A (sub-classed `PlaylistMembershipVC`) and the shared builder happened to cover full-player too, PR 6 automatically picks that up. Same rule: no full-player-specific wiring unless it's incidental.

### E.2 User flow

1. User taps `...` on a song → menu opens → "Share" entry visible and enabled.
2. User taps "Share":
   - **If the song is already downloaded** (check via the existing `DownloadManager` / `PlayableFileCache` API — grep for `isCached`, `localURL`, or the equivalent): skip to step 4.
   - **If not downloaded:** kick off a download through the existing download manager. Show an in-flight indicator — a small progress HUD is fine, or reuse whatever the existing "Download" menu item shows when triggered. **Do not block the UI thread.** Cancellable via a Cancel button if the download takes more than ~2s.
3. On download completion, proceed to step 4. On download failure (network error, server 404), surface a simple error alert ("Couldn't download this song — please try again.") and abort.
4. Construct a `UIActivityViewController` with the local file `URL` as the primary activity item. Include a short text item (`"Song title — Artist"`) as a secondary item so the sharing target (Messages / Mail) can show sensible default text. Present it from the `...` menu's source view (for iPad popover anchoring).
5. Dismiss the activity controller per standard iOS behavior on completion/cancel. Do not hold onto the file URL after dismissal — the cached copy remains on disk under Amperfy's existing download management.

### E.3 Scope decisions (team-lead defaults — surface for Olivier's review)

- **Format:** share whatever the local cache contains — `.mp3`, `.m4a`, `.ogg`, etc. depending on what Navidrome transcoded. Do NOT transcode on-device. **Confirmed by Olivier:** ship whatever format is cached, no forced `.m4a` transcode.
- **Side effect of the download:** piggyback on the existing download manager, so sharing a song ALSO adds it to the user's offline library. **Confirmed by Olivier:** this is a feature, not a bug. No tmp-dir alternative needed.
- **Metadata:** the shared file will have whatever ID3 tags Navidrome's transcode emits. We do NOT rewrite tags in-app. If the user shares a file that lands in another Music app, it'll show whatever the server encoded. Acceptable.
- **Multi-song share:** out of scope for PR 6. Single-song only. If multi-selection becomes a request later, it's PR 6-follow-up.
- **DRM / licensing:** not our problem. Users sharing music files from their personal server is the same as sharing any other file from their phone. No warning dialogs, no restrictions.

### E.4 Implementation sketch

File: `Amperfy/Screens/Common/ShareSongAction.swift` (new, ~80–120 LOC).

```swift
public final class ShareSongAction {
    public static func share(
        song: Song,
        from sourceView: UIView,
        presenter: UIViewController,
        downloadManager: DownloadManager,
        fileCache: PlayableFileCache  // or whatever the existing cache type is
    ) {
        if let localURL = fileCache.localURL(for: song), FileManager.default.fileExists(atPath: localURL.path) {
            presentActivityController(for: song, fileURL: localURL, sourceView: sourceView, presenter: presenter)
            return
        }

        // Kick off download with progress UI, then continue on completion.
        let progressAlert = ProgressAlertController(title: "Downloading", message: song.title)
        presenter.present(progressAlert, animated: true)

        downloadManager.download(song, priority: .userInitiated) { result in
            DispatchQueue.main.async {
                progressAlert.dismiss(animated: true) {
                    switch result {
                    case .success(let url):
                        presentActivityController(for: song, fileURL: url, sourceView: sourceView, presenter: presenter)
                    case .failure:
                        presenter.presentSimpleAlert(
                            title: "Download failed",
                            message: "Couldn't download this song. Please try again."
                        )
                    }
                }
            }
        }
    }

    private static func presentActivityController(
        for song: Song,
        fileURL: URL,
        sourceView: UIView,
        presenter: UIViewController
    ) {
        let textItem = "\(song.title) — \(song.artist?.name ?? "Unknown artist")"
        let activityVC = UIActivityViewController(
            activityItems: [fileURL, textItem],
            applicationActivities: nil
        )
        activityVC.popoverPresentationController?.sourceView = sourceView
        activityVC.popoverPresentationController?.sourceRect = sourceView.bounds
        presenter.present(activityVC, animated: true)
    }
}
```

**Implementer verifies on first read:**
- Exact `DownloadManager` API surface — the callback / completion shape may differ. Adapt.
- Exact `PlayableFileCache` or equivalent — Amperfy may use `CommonLibraryEntities.LocalFileURLProvider` or similar.
- Whether `ProgressAlertController` already exists in the codebase (grep); if not, a plain `UIAlertController` with a `UIActivityIndicatorView` is fine.
- `presentSimpleAlert` is a placeholder — use whatever the existing alert helper is.

### E.5 Tests

**AmperfyKitTests:** minimal — this is mostly UI glue over existing download/cache APIs, which are already tested. One case worth adding:
- `ShareSongActionTest.testTextItemFormatting` — given a Song with a known title+artist, the secondary text item reads `"Title — Artist"`, and falls back to `"Title — Unknown artist"` when artist is nil.

**Manual acceptance (sim):**
- Song already downloaded → tap ... → Share → activity sheet appears with the file attached.
- Song NOT downloaded → tap ... → Share → progress HUD → activity sheet appears.
- Download failure path → error alert surfaces.
- AirDrop target on macOS → file arrives and plays.
- Messages target → file attaches correctly with the title text.
- iPad regression: popover anchors to the source view, does NOT crash on present.

### E.6 Ship steps

Same monotonic bump pattern as §2.6.

---

## PR 7 — Research + (conditional) Feature F: Custom styling

**Release target (Phase 1):** no TestFlight build. Research deliverable only — `spike/amperfy/STYLING_RESEARCH.md`.
**Release target (Phase 2, conditional):** TestFlight build IF Phase 1 concludes the path is tractable. Bump `CURRENT_PROJECT_VERSION` monotonically.

**Intent:** let the user set background color, font color, and tint color for the app's views from a Settings screen, with independent color sets for light and dark mode. The theme is configurable from the Settings panel and can be turned off entirely (restoring stock Amperfy colors). Olivier flagged this up front as "might be implausible/a huge refactor" — we respect that and **split the PR into a research phase (binding) and an implementation phase (conditional on research)**.

Phase 1 is research-only and ships a markdown document. Phase 2 only happens if Phase 1 concludes the refactor is tractable (rough threshold: fits in ~500 LOC across ≤10 files) AND the team-lead + Olivier greenlight it. This framing protects us from discovering three turns in that Amperfy's view hierarchy scatters color literals across 200 files.

### F.1 Phase 1 — research deliverable

File: `docs/STYLING_RESEARCH.md` with this structure:

```markdown
# Custom styling — investigation notes (2026-04-XX)

## Current theming story
<what does Amperfy do TODAY for colors? Is there a Theme struct?
A UIAppearance pass? Asset catalog color sets? Inline UIColor.systemFoo
calls? Dark mode support shape. Screenshots or code refs welcome.>

## Color surface inventory
<where are background / text / tint colors actually set? Table:
file | type of reference | count>

## Central injection points
<are there chokepoints we could hijack, or is it scattered?>

## Proposed shapes
### Option A — Asset-catalog color sets + UIAppearance
<describe, pros/cons, LOC estimate, risk>
### Option B — Global Theme struct + explicit per-view apply()
<describe, pros/cons, LOC estimate, risk>
### Option C — <any other viable path>
### Recommendation
<pick one, justify, include go/no-go call>

## Font customization feasibility
<Olivier wants custom fonts but expects UIKit makes this hard.
Investigate: does Amperfy use a centralized font helper or inline
UIFont calls? Is there a chokepoint? Report feasibility separately
from colors — if fonts are tractable, include in Phase 2; if not,
document the blocker and park.>

## Non-goals
<per-view color overrides, image filtering, etc.>

## Estimated cost
<LOC, file count, risk level, test surface>
```

### F.2 Phase 1 methodology

1. **Grep the codebase.** Count `UIColor.` / `.tintColor` / `.backgroundColor` / `.textColor` references across `Amperfy/` and `AmperfyKit/`. Raw count → order-of-magnitude estimate of the refactor surface.
2. **Find existing theme infrastructure.** Does `Amperfy` already have a Theme struct, a colors asset catalog, a `UIAppearance` proxy pass? Dark mode is built into iOS — is Amperfy using `UITraitCollection.userInterfaceStyle` or forcing a style? The answer shapes which option is viable.
3. **Identify chokepoints.** If most colors flow through a single "cell style" helper or a `UITableViewCell` base class, that's tractable. If they're scattered across 100 view controllers with inline literals, it's not.
4. **Confirm iOS appearance API suitability.** `UIView.appearance(whenContainedInInstancesOf:)` is sometimes viable, sometimes not (depends on whether the views use `@available` API for colors). Check a representative sample.
5. **Sketch the Settings UI.** Settings → "Appearance" section with: a **master toggle** ("Custom theme: ON/OFF" — when OFF, stock Amperfy colors apply, all pickers hidden), separate Light and Dark color sets (six `UIColorPickerViewController` triggers total — bg/text/tint × light + dark), and a "Reset to defaults" button that clears all custom values and flips the toggle OFF. Persist to UserDefaults under `amperfy.fork.theme.*` keys (same local-only pattern as PR 5 PinnedPlaylistStore — NO Core Data schema changes, same upstream-merge-compat reason).
6. **Investigate font customization.** Olivier wants custom fonts but suspects UIKit makes this hard. Research should separately assess whether a font override is tractable: grep for `UIFont` / `.font =` references, check whether Amperfy centralizes font selection or scatters it. Include findings in a separate section of the research doc — if fonts ARE tractable, fold into Phase 2 scope; if not, document the blocker and park. Font family/size customization is aspirational, not required for Phase 2 greenlight.

### F.3 Phase 1 decision gate

After the research doc lands, team-lead reviews and classifies the recommendation:

- **GREEN** (tractable, ≤500 LOC, clear path) → dispatch Phase 2 implementation PR.
- **YELLOW** (tractable but larger than ~500 LOC, or significant risk) → team-lead surfaces to Olivier, Olivier decides whether to fund the larger scope.
- **RED** (implausible without a codebase-wide refactor) → close PR 7 as research-only; document the blocker; park the feature.

### F.4 Phase 2 — conditional implementation (IF greenlit)

**Scope (indicative, to be refined by Phase 1 findings):**

- New Settings screen section: "Appearance" with a **master toggle** ("Custom theme: ON/OFF"), **two color sets** (Light + Dark — three pickers each: bg/text/tint), and a "Reset to defaults" button that clears all values and disables the toggle.
- Backing store: new `ThemeStore` service following `PinnedPlaylistStore` pattern (UserDefaults-backed, `didChangeNotification`, no Core Data). Keys: `amperfy.fork.theme.enabled` (Bool), `amperfy.fork.theme.light.bg` / `.text` / `.tint`, `amperfy.fork.theme.dark.bg` / `.text` / `.tint` (stored as hex strings or `Data`-archived `UIColor`).
- Application: whichever option the research settles on (Theme struct + explicit apply, UIAppearance proxy, or asset-catalog swap).
- **Dark mode interaction (Olivier confirmed):** user sets independent color sets for light and dark modes. The active set is selected by `UITraitCollection.userInterfaceStyle` at runtime — the user is NOT overriding the system light/dark toggle, they are customizing what each mode looks like. When the toggle is OFF, stock Amperfy colors apply for both modes.
- Reset to defaults: clears all stored colors, flips toggle OFF, restores Amperfy's stock colors (whatever they are today).
- **Font customization (conditional):** if Phase 1 research concludes fonts are tractable, include a font picker (family, optionally size) in the Appearance section alongside the color pickers. If not, park — fonts are aspirational, not a Phase 2 gate.

**Constraint that holds regardless of option:** **NO changes under `AmperfyKit/`** for Phase 2 — styling is an app-layer concern. If Phase 1 finds that `AmperfyKit` emits colors (via custom UI in the framework), that's a blocker worth escalating, not a reason to edit `AmperfyKit`. Keeping framework-layer clean preserves upstream-merge compat.

**Tests:**
- `ThemeStoreTest` — UserDefaults persistence, notification fires, defaults-reset round-trip.
- Manual acceptance: change each of the three colors in Settings → verify the change applies to Home tab / Albums tab / Player / Settings itself without app restart. Kill+relaunch → colors persist.

### F.5 Phase 2 ship steps

Same monotonic bump pattern as §2.6.

### F.6 Resolved questions (Olivier, 2026-04-11)

1. **Color-vs-dark-mode interaction: RESOLVED → (c) independent color sets.** User specifies separate light and dark mode colors. System `userInterfaceStyle` picks which set is active. Custom theme toggle OFF → stock colors for both modes. This is more work than (a) but is the right UX.
2. **Per-view vs global: RESOLVED → global.** One bg/text/tint set per mode, applied everywhere. No per-tab or per-section customization.
3. **Fonts: RESOLVED → aspirational, investigate in Phase 1.** Olivier wants custom fonts but acknowledges UIKit makes this hard. Phase 1 research doc includes a dedicated section on font feasibility. If tractable, include in Phase 2; if not, park with a documented blocker. Font _color_ is in scope (it's one of the three main colors); font _family/size_ is the aspirational add-on.
4. **Red outcome disposition: RESOLVED → commit doc to `docs/`, close PR, park.** Research doc lives at `docs/STYLING_RESEARCH.md` (not `spike/amperfy/`). Olivier wants it saved where he can find it next time we talk.
5. **Settings UX: RESOLVED → configurable via Settings panel with an ON/OFF toggle.** Theme is off by default. When off, stock Amperfy colors. When on, user's custom colors apply. "Reset to defaults" clears all and turns toggle off.

---

## PR 9 — Feature G: Playlist folders with batch selection

**Release target:** TestFlight build. Bump `CURRENT_PROJECT_VERSION` monotonically. **Prioritized ahead of custom styling (PR 7 Phase 2)** per Olivier, 2026-04-12.

**Intent:** let the user organize playlists into local-only folders with support for nesting, multi-folder membership, and batch selection. Folders live in the Playlists tab. A playlist can appear in multiple folders (references, not copies); once filed in at least one folder, it no longer appears at the top level. Unfiled playlists remain visible at root.

### G.1 Data model

**Local-only, no Core Data.** Same upstream-merge-compat rationale as `PinnedPlaylistStore`. Storage: JSON-serialized tree in UserDefaults (or a `.json` file in Application Support if the tree gets large — implementer's judgment on first read, noting that UserDefaults handles ~100KB of JSON comfortably and most users will have <50 folders).

```swift
public struct PlaylistFolder: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var playlistIds: [String]    // Subsonic playlist IDs, ordered
    public var subfolders: [PlaylistFolder]  // recursive nesting
}
```

**Service:** `AmperfyKit/Storage/PlaylistFolderStore.swift` (~120-150 LOC).

```swift
public final class PlaylistFolderStore {
    public static let shared = PlaylistFolderStore()

    private let defaultsKey = "amperfy.fork.playlistFolders"

    /// Top-level folders. The root is implicit — unfiled playlists are those
    /// whose ID does not appear in ANY folder at any depth.
    public private(set) var folders: [PlaylistFolder]

    // CRUD
    public func createFolder(name: String, parent: UUID?) -> PlaylistFolder
    public func renameFolder(id: UUID, to name: String)
    public func deleteFolder(id: UUID)  // removes folder, playlists become unfiled if not in another folder

    // Membership
    public func addPlaylists(_ playlistIds: [String], to folderId: UUID)
    public func removePlaylists(_ playlistIds: [String], from folderId: UUID)
    public func movePlaylist(_ playlistId: String, from sourceFolderId: UUID, to destFolderId: UUID)

    /// All playlist IDs that appear in at least one folder at any depth.
    /// Used to partition the Playlists tab: filed playlists are hidden from root.
    public var allFiledPlaylistIds: Set<String>

    /// Posts on every mutation so UI can refresh.
    public static let didChangeNotification = Notification.Name("amperfy.fork.playlistFolders.didChange")
}
```

**Key invariants:**
- A playlist ID can appear in multiple folders (multi-membership). Each is a reference to the same underlying `PlaylistMO`, not a copy.
- Deleting a folder does NOT delete the playlists — they become unfiled (return to root) unless they're still referenced by another folder.
- `allFiledPlaylistIds` is a computed traversal of the full tree. Cache if perf becomes an issue (unlikely with <100 folders).

### G.2 Playlists tab UI

**Current state (implementer verifies):** the Playlists tab shows a flat list of all `PlaylistMO` objects, likely via an FRC. The new view replaces this with a two-tier display:

**Root level:**
1. **Folders** — each rendered as a folder row (SF symbol `folder` / `folder.fill`, folder name, subtitle showing playlist count). Tapping a folder pushes a new VC showing that folder's contents (playlists + sub-folders).
2. **Unfiled playlists** — all playlists whose ID is NOT in `allFiledPlaylistIds`. Rendered exactly as today (same cells, same tap-to-open behavior). These sit below the folders section.

**Inside a folder:**
- Sub-folders (if any) at top, then playlists in that folder.
- Same push-based navigation as root → folder. Nesting is recursive — a folder can contain sub-folders to arbitrary depth.
- Tapping a playlist pushes the existing `PlaylistDetailVC` (same as today).
- Nav bar title = folder name. Back button returns to parent.

### G.3 Folder management (editing)

All editing happens at the list/folder view level — NOT inside playlist detail.

**Add a folder:**
- Nav bar "+" button (or Edit mode action) → alert with text field for folder name → creates folder at current level (root or inside current folder).

**Batch select + add to folder:**
- Standard iOS edit mode: tap "Edit" → checkmark multi-select on playlists → toolbar action "Add to Folder" → picker showing existing folders (with create-new option) → selected playlists added to chosen folder.
- Playlists that were at root level and are now filed in at least one folder disappear from root on next refresh.

**Three-dots menu on a playlist row (context menu):**
- **"Add to Folder…"** — always available. Shows folder picker. Adds the playlist to the selected folder (reference, not move). If the playlist was at root and is now filed, it disappears from root.
- **"Move to Folder…"** — available only when the playlist is currently inside a folder (i.e., you're viewing a folder's contents). Removes from current folder, adds to selected folder.
- **"Also Show in Folder…"** — available when inside a folder. Adds the playlist to an additional folder without removing from the current one. Makes the multi-membership explicit to the user.
- **"Remove from Folder"** — available only inside a folder view. Removes the playlist from this folder. If it's not in any other folder, it returns to root.

**Three-dots menu on a folder row:**
- **"Rename"** → alert with text field.
- **"Delete Folder"** → confirmation alert. Deletes the folder; contained playlists become unfiled unless they're also in another folder. Sub-folders are also deleted (recursive).

### G.4 Storage design notes

- **Why not Core Data:** same rationale as `PinnedPlaylistStore` §D.2.1 — no schema changes, no upstream merge conflicts. The folder tree is local organizational state, not library data.
- **Why JSON in UserDefaults vs. a file:** UserDefaults is atomic and survives app termination. The tree is small (a user with 50 playlists and 10 folders produces ~5KB of JSON). If implementer finds the tree growing past ~50KB in testing, switch to a `.json` file in Application Support with atomic writes.
- **Migration from PinnedPlaylistStore:** PR 5's "pinned playlists" and PR 9's "playlist folders" are complementary features. Pinned = shown on Home tab. Folders = organizational structure in Playlists tab. A playlist can be both pinned AND in a folder. No migration needed — they're orthogonal.

### G.5 Tests

**AmperfyKitTests:**
- `PlaylistFolderStoreTest` (~10-12 cases):
  1. Empty state — no folders, `allFiledPlaylistIds` empty.
  2. Create folder + add playlist → `allFiledPlaylistIds` contains it.
  3. Add same playlist to two folders → still one entry in `allFiledPlaylistIds`.
  4. Remove playlist from one folder → still filed (in the other).
  5. Remove from both → unfiled, returns to `allFiledPlaylistIds` empty.
  6. Delete folder → contained playlists unfiled.
  7. Nested subfolder — create, add playlist, verify `allFiledPlaylistIds` traverses depth.
  8. Delete parent folder → subfolders and their memberships also removed.
  9. Rename folder persists across store instances.
  10. `didChangeNotification` fires on every mutation.
  11. JSON round-trip — encode → decode → structural equality.
  12. Move playlist between folders — removed from source, present in dest.

**Manual acceptance (sim):**
- Root shows folders + unfiled playlists.
- Tap folder → shows contents. Tap playlist → detail opens.
- Edit mode → multi-select 3 playlists → "Add to Folder" → playlists disappear from root.
- Three-dots on a playlist inside folder → "Also Show in Folder…" → playlist now in two folders.
- "Remove from Folder" on a multi-filed playlist → still visible in the other folder.
- "Remove from Folder" on a single-filed playlist → returns to root.
- Delete folder → playlists return to root.
- Kill+relaunch → folder structure persists.
- Create subfolder inside a folder → navigate in → works recursively.

### G.6 Ship steps

Same monotonic bump pattern as §2.6. Ship with `scripts/ship.sh`.

### G.7 Resolved questions (Olivier, 2026-04-12)

1. **Local-only: RESOLVED.** No server sync. UserDefaults/JSON-backed.
2. **Nesting: RESOLVED → subfolders allowed** (recursive).
3. **Location: RESOLVED → Playlists tab.**
4. **Unfiled playlists: RESOLVED → visible at root level, above folders or alongside.**
5. **Batch selection: RESOLVED → iOS edit-mode multi-select with "Add to Folder" action.**
6. **Multi-membership: RESOLVED → a playlist can be in multiple folders (references). Once in at least one folder, hidden from root. Removing from all folders returns to root.**
7. **Priority: RESOLVED → before custom styling (PR 7 Phase 2).**
8. **Editing: RESOLVED → list/folder view level only.** Three-dots on playlist: Add to Folder / Move to Folder / Also Show in Folder / Remove from Folder. Three-dots on folder: Rename / Delete.

---

## 4. Decision log (why the spec looks like this)

- **Metadata-path dropped, went to pure count** (Olivier, 2026-04-11, after observing build 3 in production): the shipped predicate let single-track split-off "albums" through because (a) the metadata path had no count floor and (b) a Core Data NULL-handling pitfall silently excluded nil-metadata albums. Olivier explicitly chose pure-count (Option C) over the more-complex 2-track-floor-on-metadata alternative, and told the team NOT to assume a server-side metadata repair sweep is imminent. The 2-track-EP-via-metadata edge case is intentionally unsupported — users with legitimate small EPs will need to find them via search or unfiltered Albums view until/unless we revisit. See §1.1 for the new rule.
- **Two thresholds, 3 and 5, deliberately different** (Olivier, 2026-04-10): "3 or more tracks in the recent albums view and in the albums view, keep the filtering in the recent tracks at 5 track threshold." Consistency was considered and rejected — the UX asymmetry (false-negatives on the library side are mild; false-positives on the recent-tracks side are annoying) justifies the split.
- **`isCompilation` attribute NOT used** (Olivier, 2026-04-10): "Compilations are albums, they should be skipped from recent tracks if they cross the 5 song rule, and included in recent albums if 5 or more songs." Flows through the same rule. No special case.
- **"Small complete" (EP with metadata-declared total tracks = actual) DROPPED** (Olivier, 2026-04-10): "Drop small complete." Navidrome's XML does not expose a declared-total-tracks field per the XML captures we have, so this would have required a roundabout metadata fetch anyway. Olivier killed it directly.
- **`releaseType` stored as lowercase `String?` not an enum**: Navidrome's set is MusicBrainz-aligned but there is no guarantee that *this* Navidrome instance emits only known values. Keeping it as a raw string avoids parse-time throw-aways. The predicate uses `CONTAINS[c]` against lowercased substrings so a typo or extra value doesn't blow up the filter.
- **Additive schema, no xcmappingmodel**: Amperfy has 49 versions, 2 of which needed custom mapping models (`V4toV5`, `V10toV11`) — both renames/restructures. A new optional attribute is the textbook inferred-mapping happy path. The fallback is re-seeding from the server, which is cheap for spike testing.
- **Parser edit in `SsAlbumParserDelegate` (not a new parser)**: the same delegate handles both `getAlbumList2` and `getAlbum` paths. One edit covers the full library sync AND the detail view. If only `getAlbum` emits `releaseTypes` (to be verified by the implementer), the `releaseType` column gets populated lazily as users browse individual albums — the `remoteSongCount` threshold fallback picks up the slack for un-browsed albums. This is an acceptable degradation.
- **Hard-fork posture on this pass**: deferring the friendly-fork question (`docs/DECISION.md` "Trade-offs we are accepting"). Not collapsing Ampache speculatively.
- **Synthetic playlist view (not a real `PlaylistMO`)**: persisting a system-generated "recent tracks" playlist to Core Data would create sync-loop hazards (does it sync to the server? does it survive account switch?) that have no upside. A transient view fed by a live query is strictly simpler.
- **Row-tap opens the detail view, not plays the track** (Olivier, 2026-04-10): "Tap a track to open the view." Playback from within the detail view uses the standard playlist-row-tap behavior.
- **Default N=14 for Top N mode** (Olivier, 2026-04-10): "Default is last 14 tracks."
- **No feature branches, direct commits to `spike/extension-eval`**: Olivier wants two TestFlight builds back-to-back. Branching ceremony is friction for a spike-era workflow where the branch IS the feature.

---

## 5. Don't-touch (PR-scope guardrails)

- Do NOT edit the `AmpacheLibrarySyncer` beyond adding empty stubs IF a new `LibrarySyncer` protocol method is required (none expected for these features).
- Do NOT touch `spike/.signing/`, `spike/flo/`, `spike/agin-music-mobile/`.
- Do NOT reorganize `AmperfyKit/Api/Subsonic/` parser delegates. Edit one file (`SsAlbumParserDelegate.swift`).
- Do NOT introduce a new Core Data entity for PR 2. The detail view is synthetic.
- Do NOT wire up the two remaining candidate features from `IMPLEMENTATION.md` §4 (Pinned playlists, Local playlist folders, Gigs near you). Those are deferred until after the two bug investigations.

---

## 6. Release log (append-only)

| PR | Delivery UUID | `CURRENT_PROJECT_VERSION` | Date | Notes |
|---|---|---|---|---|
| (baseline) | b05a69dc-ea19-431d-b08b-48b40251b419 | (pre-feature) | 2026-04-10 | Phase A signing-pipeline green upload |
| PR 1 | ae15846d-c2f0-4d99-a407-ea4763282e9e | 2 | 2026-04-11 | Feature A — whole-album primitive + Albums toggle + home new-albums filter. `spike/extension-eval` @ `0912be4`. 373 AmperfyKitTests green. v49→v50 inferred migration NOT end-to-end verified (manual check pending). |
| PR 2 | f15c7024-3a14-4c6b-b7e1-f6ba4074416b | 3 | 2026-04-11 | Feature B — recent tracks widget + synthetic detail VC. `spike/extension-eval` @ `49cb166`. 9 new RecentTracksQueryTest cases green; all PR 1 tests still green. UIKit implementation (not SwiftUI) matching HomeVC's compositional layout. "(X more in last 7 days)" footer deferred — count exposed as `HomeManager.recentTracksExtraCount` for future header-subtitle. CarPlay recent-tracks rendering deferred. Widget visibility on real data untested — manual smoke on first TestFlight install. |
| Hotfix 1 | 97a9be31-de08-4c5d-84a3-c330ac45071c | 4 | 2026-04-11 | Bug #22 — unknown track length in player UI. `spike/extension-eval` @ `c56fc7b`. `PlayerUIHandler.effectiveDuration` falls back to `AbstractPlayable.duration` (known from Subsonic parse) when the `AudioStreaming` engine's bitrate-estimation duration returns 0 during early stream playback. Single-file, additive, ~20 LOC. No new tests (PlayerUIHandler not previously tested — flagged as test-debt). Bug pre-existed PR 1 — AudioStreaming dep + PlayerUIHandler untouched by either PR. |
| Hotfix 2 | 0292c470-9f85-4e51-b597-4bb9dfd53f42 | 5 | 2026-04-11 | Complete Album filter pure-count rewrite (Option C) + underlying SQLite NULL-handling fix. `spike/extension-eval` @ `6a3b84f`. `WholeAlbumPredicates.wholeAlbum`/`songFromNonWholeAlbum` rewritten: `"single"` is the sole metadata veto, everything else is classified by `remoteSongCount >= minSongCount`. Explicit `releaseType == nil OR ...` guard short-circuits the NULL-propagation pitfall that was silently excluding every nil-metadata album from build 3's Complete filter. `WholeAlbumPredicatesTest` rewritten (15 cases, +2 new NULL-pitfall regression guards). All 385 AmperfyKitTests green; 9 PR 2 `RecentTracksQueryTest` cases unchanged. Commit also includes a doc comment on `PlayerUIHandler.effectiveDuration` reinforcing that it is a computed property and must not be memoized. Intentional 2-track-EP regression — see §4. |
| Hotfix 3 | e535f18c-566d-4c8a-a49c-0b127e5bea94 | 6 | 2026-04-11 | QA round 1 fallout — B-1 (High) + B-2 (cosmetic). `spike/extension-eval` @ `02b6199`. B-1: `AlbumFetchedResultsController.search(predicate:)` now AND-composes the init-time `wholeAlbumsOnly` sub-predicate into every search predicate before delegating to super. `BasicFetchedResultsController.search` was destructively replacing the predicate, so the Home tab's `search(displayFilter: .newest)` silently dropped the whole-album clause and leaked 1-track releases (God's Son, Sleepless, The Claw). New `AlbumFetchedResultsControllerTest` (4 cases) is the regression guard. B-2: `HomeVC.applySnapshot` gained a `sectionsHiddenWhenEmpty` allowlist so the "Recently Added Tracks" header is dropped from the diffable-data-source snapshot when its data is empty — other Home sections keep their existing render-empty-header behavior. 389 AmperfyKitTests green (was 385 — +4 from the new FRC regression suite). Phase 3 `ADDED_DATE_INVESTIGATION.md` confirms the B-2 secondary observation (bulk `getAlbumList2` never materializes songs, so post-sync widget stays empty until album drill-in); cold-seed fix is NOT a few-line change and is deferred to a dedicated PR. Bug #23 still parked — no repro in this session. |
| PR 3 | (delivered prior session) | 7 | 2026-04-11 | Feature C — "In Playlists" action in song context menu. `spike/extension-eval` @ `71adb7e`. `PlaylistMembershipQuery` + `PlaylistMembershipVC` + `EntityPreviewVC` builder edit. 3 new `PlaylistMembershipQueryTest` cases green. 393 AmperfyKitTests green. |
| PR 4 | (research — no TestFlight) | — | 2026-04-11 | Albums view performance investigation. Deliverable: `PERFORMANCE_ALBUMS.md`. 7 hypotheses tested, 6 findings, 5 recommended follow-ups. `spike/extension-eval` @ `b87f196`. |
| PR 5 | 06c3790e-27b3-41df-a8c7-3257925d4962 | 8 | 2026-04-11 | Feature D — Favourite Albums/Artists/Playlists on Home. `spike/extension-eval` @ `76f40d6`. `PinnedPlaylistStore` (UserDefaults-backed, NOT Core Data). Heart toggle in `PlaylistDetailVC`. 3 new Home sections hidden-when-empty. D.4(b): favourites ignore Complete filter. 6 new `PinnedPlaylistStoreTest` cases; 398 AmperfyKitTests green. First dogfood of `scripts/ship.sh`. |
| PR 6 | 1079aa12-991b-47c3-9284-4dfd30c5bbc7 | 9 | 2026-04-11 | Feature E — Share a song via iOS share sheet. `spike/extension-eval` @ `c94db32`. `ShareSongAction` + "Share" entry in `EntityPreviewActionBuilder`. Download-then-share via polling for cached file. Ships cached format, download side-effect adds to offline library. 398 AmperfyKitTests green. |
| PR 7 | (research — no TestFlight) | — | 2026-04-11 | Custom styling research. Deliverable: `docs/STYLING_RESEARCH.md` (parent repo @ `9dddf96`). Recommends Option A (UtilitiesExtensions + UIAppearance proxy) — GREEN verdict, ~370-410 LOC across 8-10 files. Color surface inventory: 223 refs across ~60 files, but `UtilitiesExtensions.swift` color helpers + `UIAppearance` cover ~70% for free. Font family feasible (~30-40 LOC), font size parked (layout risk). |
| PR 8 | 048964f6-98d7-4964-be80-24d78c4be894 | 10 | 2026-04-11 | Albums view performance fixes. `spike/extension-eval` @ `faffa3d`. F1: `sectionIndexTitles` cached + off-by-one `0...sectionCount` → `0..<sectionCount` in `AlbumsDiffableDataSource`. F2: `SingleSnapshotFetchedResultsTableViewController.controller(_:didChangeContentWith:)` short-circuits O(n) `existingObject(with:)` scan when `managedObjectContext.updatedObjects` is empty. F4: `AlbumMO.relationshipKeyPathsForPrefetching` now includes `songs` — eliminates fault storms in `handleHeaderPlay/Shuffle`. 398 AmperfyKitTests green. |
| Hotfix 4 | c56d628e-ec67-476c-a600-c5865692aeeb | 11 | 2026-04-11 | "In Playlists" only showed recently-opened playlists. Root cause: bulk `getPlaylists` API returns metadata only — `PlaylistItemMO` entries are only created by per-playlist `getPlaylist` calls. Fix: `PlaylistItemsSyncTracker` (UserDefaults-backed) tracks which playlists have had items synced; on "In Playlists" tap, any unsynced playlists are fetched sequentially via `syncDown(playlist:)` before running the Core Data query. First tap incurs O(n_playlists) API calls; subsequent taps are instant. `spike/extension-eval` @ `55b20f7`. 398 AmperfyKitTests green. |
| PR 9 | bf4b4d5e-3058-4d17-9693-ed5e1df19b36 | 12 | 2026-04-12 | Feature G — Playlist folders with batch selection. `spike/extension-eval` @ `16a0820`. `PlaylistFolderStore` (JSON in UserDefaults): recursive folder tree, multi-folder membership, CRUD + membership ops. `PlaylistFolderContentsVC` replaces `PlaylistsVC` as Playlists tab entry point — folders section + unfiled playlists at root, recursive navigation into subfolders. Context menus on playlists (Add/Move/Also Show in/Remove from Folder) and folders (Rename/Delete). Edit mode multi-select with "Add to Folder" toolbar action. Folder picker with create-new option. Flat View fallback to legacy `PlaylistsVC`. 12 new `PlaylistFolderStoreTest` cases; 410 AmperfyKitTests green. |

---

**End of backlog.** The implementer should now:
1. Read `PRIMER.md` and `IMPLEMENTATION.md` if not already.
2. Run the test baseline per `IMPLEMENTATION.md` §5.2 to confirm green starting state.
3. Start PR 1 §1.2 (schema bump) → §1.3 (parser) → §1.4 (predicates) → §1.5 (tests) → §2.1 (A.1) → §2.2 (A.2) → §2.6 (ship).
4. Only after PR 1 is uploaded, begin PR 2 §3.
