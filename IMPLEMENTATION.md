# Amperfy Implementation Playbook

**For:** a future Claude Code session picking up custom-feature work on the Amperfy fork cold.
**Companion doc:** `spike/amperfy/PRIMER.md` (architecture, patterns, Recipe A walkthrough, pressure tests, footguns). This playbook does **not** duplicate the primer — it points at it and adds implementation-phase logistics.
**Decision record:** `docs/DECISION.md` (why Amperfy, trade-offs accepted, what was ruled out).
**Spike scratch:** `spike/amperfy/.spike/NOTES.md` (Day 1–3 raw findings — reference only).

---

## 1. Orientation

You are working on a fork of [`BLeeEZ/amperfy`](https://github.com/BLeeEZ/amperfy), a Swift/UIKit Subsonic + Ampache client for iOS/iPadOS/macOS. This fork has been selected as the base for a custom feature roadmap against a Navidrome server. The working directory is `spike/amperfy/` inside the `navidromClient` repo; the upstream git history is preserved.

**Before you touch code, read:**

1. `spike/amperfy/PRIMER.md` end-to-end. The primer is the single source of truth for architecture, the Recipe A "add-a-new-view-and-query" recipe, known footguns, and pressure-tested cost curves. Every section of this playbook assumes you have read it.
2. `docs/DECISION.md` for the why. Understanding *why* Amperfy was picked over flo and Agin (filter/sort/join workload fit, background-sync-to-view repaint, FRC reactivity, offline-browsable mirror, real test target) will tell you which Amperfy properties are load-bearing and which are accidental — the former are what you build on.
3. `docs/COMPARISON.md` Amperfy section only if you hit an ambiguity that the PRIMER doesn't resolve; otherwise skip it.

**Branching convention:**

- Long-lived integration branch: `spike/extension-eval` (already checked out).
- Feature branches: `spike/extension-eval/<feature-slug>` off `spike/extension-eval`. Merge back into `spike/extension-eval` when the feature is landed; do not push to `main`.
- Upstream engagement strategy (friendly fork vs hard fork) has not been decided — default to **additive changes** that would in principle be upstreamable until the first backlog item explicitly decides otherwise. This means: prefer new files over invasive edits to existing ones, prefer additive Core Data schema over entity renames, prefer new SwiftUI views hosted via `UIHostingController` over UIKit rewrites.

**Scope boundaries you inherited from the spike:**

- Navidrome is the only target server. The Ampache side of the codebase is dead code for our purposes but is load-bearing for the build until deliberately removed (see §5).
- No new top-level dependencies without a written justification. SwiftPM only; no CocoaPods (the repo already is SwiftPM-only — don't regress).
- UIKit app target stays UIKit. New views land as SwiftUI inside `Amperfy/SwiftUI/` and are mounted via `UIHostingController`, per the `SettingsHostVC` + `LargeCurrentlyPlayingPlayerView` precedent documented in the PRIMER.

---

## 2. Implementation loop

The inner dev loop for this fork is Xcode-incremental. You can use `xcodebuild` from the command line for sanity builds and test runs; interactive device debugging still requires Xcode.app or the signing pipeline's device-build output.

### Simulator build + install + launch

From `spike/amperfy/`:

```bash
# Sim build (iPhone 15 scheme is the default; adjust if the scheme list changes)
xcodebuild \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -configuration Debug \
  build

# Install & launch on the booted sim
xcrun simctl install booted \
  build/Build/Products/Debug-iphonesimulator/Amperfy.app
xcrun simctl launch booted de.BLeeEZ.Amperfy
```

The bundle identifier you install is the upstream one (`de.BLeeEZ.Amperfy`) for sim builds; the fork's signing pipeline rewrites to `com.oliviercharavel.Spike.Amperfy` for device builds only.

If the default destination build path differs (CI-generated, derived-data), run the build with `-derivedDataPath ./build` to pin it, then update the `install` path accordingly.

### Running AmperfyKit tests

AmperfyKit ships a real unit test target — this is one of Amperfy's distinguishing advantages over flo/Agin (both ship zero tests). Use it. All new pure-logic code (predicates, query builders, decoders) should have a test before it lands.

```bash
# Full AmperfyKit test suite
xcodebuild test \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:AmperfyKitTests

# One file
xcodebuild test \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:AmperfyKitTests/PlaylistTest
```

Relevant test fixtures live at `AmperfyKitTests/Helper/` — `CoreDataHelper.swift`, `CoreDataSeeder.swift`, `UnitTestHelper.swift`. The helpers spin up an in-memory Core Data stack and seed sample entities — use this harness for any new predicate / fetch-request tests rather than building your own stack.

**Test culture note:** the existing tests are heavy on parser fidelity (`Cases/API/Subsonic/Ss*ParserTest.swift`) and MO round-trips (`Cases/Storage/ManagedObjects/*Test.swift`). Follow their shape; don't introduce XCTest helpers that diverge from the project conventions.

### Device build (handoff to signing pipeline)

Device builds are **not** your job. A parallel session owns the signing pipeline and delivers signed `.ipa` (or derived-data `.app`) artifacts into `spike/.signing/`. The pipeline references (read-only):

- `spike/.signing/api-key.env`
- `spike/.signing/AuthKey_2A3HT77RSP.p8`
- `spike/.signing/distribution.{cer,csr,key,p12,pem}`
- `spike/.signing/Spike_Amperfy_App_Store.mobileprovision`
- `spike/.signing/AppleWWDRCAG3.cer`
- `spike/.signing/{keychain,p12}.password`

If you ever need a device build to validate a feature (background-sync behavior, background `URLSession` under real network conditions, microphone/location permission flows), ping `team-lead` and they will coordinate with the signing pipeline — do **not** run signing commands yourself from this session.

### Dev loop tips

- **Core Data model churn:** when you add a new version to the `.xcdatamodeld` bundle, confirm `NSMappingModel.inferredMappingModel(...)` still succeeds by launching the app against a real seeded store (migrated from vN-1). The PRIMER's "Local data store" section explains the inferred-mapping fast path; if inference fails, do **not** reach for an xcmappingmodel as a first resort — re-check whether the change is actually additive or whether you've drifted into a rename/restructure.
- **DebugCoreData:** upstream ships a debug inspector view — use it to sanity-check MO state while iterating on predicates rather than re-seeding a fresh store per run.
- **SwiftFormat + Google Swift Style:** configs live in the repo root. Run SwiftFormat before opening a PR. The PRIMER documents the exact style anchors; match them.
- **Honest status flagging:** if a build succeeds but the feature is only half-wired, say so in the commit message body. The next session is cold — commit subjects carry a lot of the handoff.

---

## 3. Recipe A rehearsal (first-touch warm-up)

Before picking up any backlog item, rehearse Recipe A Path A from the PRIMER by building a small throwaway view. Target: `RecentlyAddedAlbumsView` — a vertical list of albums sorted by `addedDate` descending. This is the exact shape the PRIMER walks through.

**Do not re-read the walkthrough here — it is in the PRIMER under "Add a new view + query: Recipe A, Path A".** That section contains verbatim code for:

- The `NSFetchedResultsController<AlbumMO>` subclass with the predicate and sort descriptors.
- The SwiftUI `RecentlyAddedAlbumsView` using `@FetchRequest` against `AlbumMO` with `\AlbumMO.addedDate` as the sort key.
- The `RecentlyAddedAlbumsHostVC: UIHostingController<RecentlyAddedAlbumsView>` shim.
- How to wire `.environment(\.managedObjectContext, appDelegate.storage.main.context)` on the hosted view.
- The one-line entry from `LibraryVC.swift` or a new menu row.

**Pedagogical gotcha to re-read first:** the PRIMER's "Brief error" callout — the Day 3 brief originally asserted `Album.addedDate` was added in v46 for `AlbumMO`, but v46 actually added it on `SongMO`. The corrected Path A uses `AlbumMO.newestSong.addedDate` or the latest-`addedDate`-song on the album; the PRIMER has the definitive form. Do not copy a stale snippet from NOTES.md that pre-dates the correction — lift from the PRIMER.

**Rehearsal acceptance criteria:**

1. App builds + installs on the booted sim.
2. The new view opens from a menu entry; scrolls smoothly; shows at least 50 albums if the account is synced.
3. A fresh `syncNewestAlbums` pull causes the view to repaint automatically (no manual refresh) — this validates the background-sync → FRC auto-merge → view repaint chain that is the load-bearing Amperfy property for every feature in §4.
4. One test lands in `AmperfyKitTests` exercising the predicate or sort comparator in isolation against the seeded in-memory store.

Once the rehearsal is green, delete the throwaway files (or keep them parked behind a debug-flag menu entry) and start on the first backlog item. The warm-up pays for itself by verifying the dev loop and the FRC-repaint property before you are committed to a feature with real scope.

---

## 4. Feature sketches

Five candidate features have been proposed. Each sketch is **structural only** — it names the shape, estimated file count, Core Data impact, query/FRC touches, and open questions. None of these are implementations; do not start coding from a sketch without first agreeing scope with `team-lead` or the user. Open questions are flagged inline because in most cases they dominate the true cost of the feature.

File-count estimates assume Path A (native `@FetchRequest`) wherever possible, falling back to Path B (`BasicFetchedResultsController` subclass) only where the filter requires an imperative Core Data pass.

### Feature 1 — "Complete albums only"

**Intent:** a Library view that lists albums where all expected tracks are present in the mirror (filter out albums the user has partial coverage of — e.g. bought-only-half from another source, or broken metadata).

**Shape:** filter view, read-only, zero schema.

**Query (sketch):** predicate on `AlbumMO` — roughly `songCount > 0 AND songs.@count == songCount` (or the equivalent using the authoritative track count field from `AlbumMO+CoreDataProperties.swift`; confirm the attribute name on touch). Sort by `name` or `addedDate` descending.

**Files (estimate):** 2–3 files, ~80 LOC.
- `Amperfy/SwiftUI/Library/CompleteAlbumsView.swift`
- `Amperfy/Screens/ViewController/CompleteAlbumsHostVC.swift` (host shim)
- optional: one-line `LibraryVC` entry

**Sync touches:** none. Works against the existing mirror.

**Open questions (dominant):**
- Does "complete" mean `songs.@count == songCount` (MO-child count vs server-reported), or does it mean all songs have a downloaded-file path on disk? These are **very different features**. The former is a library-mirror property; the latter is a download-queue property and requires joining `DownloadMO`.
- If the user hasn't synced an artist yet, `songCount` is a Subsonic-reported field — is it reliable on Navidrome specifically? Check two or three known albums during the rehearsal build.
- What should the empty state say if the user has no "complete" albums yet?

### Feature 2 — "Single tracks added recently"

**Intent:** a discovery view of songs added to the server in the last N days where the parent album contains only one song (loose singles, compilations of size 1, or B-sides filed standalone).

**Shape:** filter view with one join, read-only, zero schema.

**Query (sketch):** predicate on `SongMO` — `addedDate >= cutoffDate AND album.songCount == 1` (note: the `addedDate` lives on `SongMO`, not `AlbumMO`; this is the correction that came out of Day 3). Sort by `addedDate` descending.

**Files (estimate):** ~2 files, ~60 LOC.
- `Amperfy/SwiftUI/Library/RecentSingleTracksView.swift`
- Host shim if needed.

**Sync touches:** none. Uses `syncNewestAlbums` / `syncRecentlyAddedSongs` output.

**Open questions:**
- Time window — is "recently" last 7 days, last 30 days, or a user-tunable setting? A user-tunable window is 2 extra files (settings row + a `@AppStorage` key).
- "Single" semantic — does a 2-song EP count? Does a 12-track album where only one song was added in the window count (and the query should actually be per-song-added-date, not per-album)?
- Should podcasts (`PodcastEpisodeMO`) and radios be excluded? Default yes.

### Feature 3 — "Pinned playlists"

**Intent:** let the user mark playlists as pinned so they sort to the top of the playlist list view.

**Shape:** additive user-local schema + UI affordance.

**Schema impact:** add `pinnedAt: Date?` to `PlaylistMO` in a new `.xcdatamodeld` version (v50 or whatever the next free version is at the time — check the model bundle). This is a textbook additive change: no renames, no entity restructure, so `NSMappingModel.inferredMappingModel(...)` handles it. See the PRIMER's schema-cost section for the fallback path.

**Query:** FRC on `PlaylistMO` with sort descriptors `[pinnedAt DESC (nils last), name ASC]`. Use `NSSortDescriptor(keyPath: \PlaylistMO.pinnedAt, ascending: false)` with nil handling via a compound `sortDescriptors` array.

**Files (estimate):** 5–6 files, ~120 LOC.
- `AmperfyKit/Storage/AmperfyKitDataModel.xcdatamodeld/AmperfyKitDataModel<N>.xcdatamodel/contents` — bump
- `AmperfyKit/Storage/ManagedObjects/PlaylistMO+CoreDataProperties.swift` — add the generated property (or re-gen if the project uses codegen)
- `AmperfyKit/Storage/EntityWrappers/Playlist.swift` — expose `pinnedAt` on the Swift wrapper
- The FRC subclass (or `@FetchRequest` amendment) powering the playlist list view
- A context-menu action ("Pin" / "Unpin") that writes `pinnedAt = Date()` or `nil` through `storage.main.context`, `save()`
- A small pin-indicator icon in the row cell

**Sync touches:** none. This is pure user-local state — no server round-trip, no sync touchpoint. It persists because `PlaylistMO` is already a mirror entity and writes to the main context flow through the normal save chain.

**Open questions:**
- **Per-account or cross-account?** Amperfy supports multi-account. If the user pins a playlist under account A, does it stay pinned if they switch to account B and that account has a playlist with the same name? Default: per-account via the existing `Playlist.library.account` chain — no extra modeling needed.
- Re-ordering support: is the user expected to drag-reorder pinned playlists among themselves, or is `pinnedAt DESC` (most recently pinned first) good enough? Drag-reorder is another ~2 files and a user-ordered integer column.
- Round-trip on sync: `syncPlaylists` rewrites the `Playlist` entity rows — confirm the sync path does not clobber `pinnedAt` (it shouldn't, because the sync writes server-known attributes only, but verify with a two-device test).

### Feature 4 — "Local playlist folders"

**Intent:** let the user group playlists into folders that exist only on-device (the server has no concept of playlist folders).

**Shape:** new user-local entity + parent-pointer on `PlaylistMO`.

**Schema impact:** introduce a new `PlaylistFolder` entity with attributes `id: UUID`, `name: String`, `createdAt: Date`, `sortOrder: Int32`. Add a to-one relationship `PlaylistMO.folder -> PlaylistFolder?` with inverse `PlaylistFolder.playlists ->> PlaylistMO`. This is still additive (new entity + new optional relationship) so inferred mapping should succeed — but it is the **largest additive change** of the five features and is the one most likely to bump into an inferred-mapping edge case. Rehearse the migration against a seeded v49 store before committing.

**Query:** a folder-list view on top, then tapping a folder navigates to a playlist-list view filtered `folder == selectedFolder`. "Uncategorized" pseudo-folder filters `folder == nil`.

**Files (estimate):** 6–8 files, ~200 LOC.
- `.xcdatamodeld` bump (new version, new entity, new relationship)
- `AmperfyKit/Storage/ManagedObjects/PlaylistFolderMO+CoreDataClass.swift` + `+CoreDataProperties.swift`
- `AmperfyKit/Storage/EntityWrappers/PlaylistFolder.swift` (Swift wrapper, matching the existing wrapper pattern)
- `PlaylistMO+CoreDataProperties.swift` amendment for the `folder` relationship
- `Amperfy/SwiftUI/Library/PlaylistFoldersView.swift`
- `Amperfy/SwiftUI/Library/PlaylistsInFolderView.swift`
- Context-menu actions: "Create folder", "Move to folder…", "Remove from folder"
- Host VC shim

**Sync touches:** none. Entirely user-local. Server sync of `Playlist` entries must continue to work untouched — confirm by grepping `SubsonicLibrarySyncer` for playlist writes and making sure the new relationship defaults sensibly on newly-synced playlists (`folder = nil` = Uncategorized).

**Open questions (dominant):**
- **Nesting.** Single level of folders or arbitrary depth? Single level is ~200 LOC; nested is a recursive data structure, a tree view, and drag-drop promotion/demotion — easily 2× the file count. **Strong default: single level**, and push back on nesting unless the user explicitly wants it.
- **Multi-folder membership.** Can a playlist live in more than one folder? If yes, the relationship becomes many-to-many and the data model changes meaningfully. **Strong default: single-folder (to-one)** — matches how users think about file-system folders.
- **Uncategorized handling.** Is "Uncategorized" a real entity or a filter (`folder == nil`)? Filter is simpler.
- **Cross-account bleeding.** Same concern as feature 3 — default to per-account scoping.
- **Delete semantics.** When a folder is deleted, do the playlists inside it get un-foldered (`folder = nil`) or also deleted? Almost certainly the former; make the default obvious in the delete confirmation UI.

### Feature 5 — "Gigs near you"

**Intent:** surface upcoming concerts for artists the user has recently listened to, near the user's current location, via the Bandsintown API.

**Shape:** third-party REST integration + CoreLocation + ephemeral (non-persisted) result display.

**Pattern:** follows the `parseLyrics(relFilePath:) async throws -> LyricsList` escape hatch documented in the PRIMER's "Direct-REST escape hatch" section (`SubsonicLibrarySyncer.swift:1298`). That is: hit an arbitrary REST endpoint, decode into a plain Swift struct, return to the view layer, **do not persist to Core Data**. This is the explicit "call a thing that isn't Subsonic" recipe the spike validated.

**However:** Bandsintown is **not** Subsonic-related, so the call does **not** belong inside `SubsonicLibrarySyncer`. Create a **new top-level service class** — `BandsintownApi` or `GigsService` — colocated with other API clients (`AmperfyKit/API/` area; confirm the exact location on touch). The `parseLyrics` pattern is the *shape* to mimic (`async throws -> PlainStruct`, no MO writes), not the *location*.

**Files (estimate):** 8–12 files, ~350 LOC, plus Info.plist edits.
- `AmperfyKit/API/Bandsintown/BandsintownApi.swift` — the thin client (async/await, URLSession)
- `AmperfyKit/API/Bandsintown/BandsintownEvent.swift` — plain `Decodable` struct matching the v3 events endpoint
- `AmperfyKit/API/Bandsintown/BandsintownError.swift`
- `AmperfyKit/Location/LocationProvider.swift` — a thin `CLLocationManager` wrapper (one-shot location, not continuous)
- `Amperfy/SwiftUI/Discovery/GigsNearYouView.swift`
- `Amperfy/SwiftUI/Discovery/GigRowView.swift`
- `Amperfy/Screens/ViewController/GigsNearYouHostVC.swift`
- A "recently listened artists" source — either a new predicate on `ArtistMO` sorted by an existing play-stat attribute, or (if no such attribute exists) **add** a `lastPlayedAt: Date?` additive column to `ArtistMO` (another v51 bump) and write to it from the player on play
- `Info.plist` — `NSLocationWhenInUseUsageDescription` string
- Settings row for Bandsintown API key (if the key is not committed — see open questions)
- Tests for the decoder against a fixture JSON

**Sync touches:** none persisted. The `lastPlayedAt` write, if that path is taken, happens in the player's on-play hook — find the existing play-logging call site and extend it.

**Open questions (dominant — this feature is the riskiest of the five):**
- **API key model.** Bandsintown's public API historically uses an `app_id` rather than a per-user OAuth token. Is the app_id committed to the repo, fetched from an env var at build time, or entered by the user in Settings? Committing is simplest but foreclosures on distribution; build-time env var is clean but ties the feature to the signing pipeline.
- **"Recently listened" semantic.** Last N songs? Last N distinct artists? Last 7 days? And does it include background-play / CarPlay sessions?
- **Location permissions UX.** If the user declines location, the feature needs a graceful fallback — either "enter a city manually" or "hide the feature entirely". Fallback is another ~2 files.
- **Search radius.** Bandsintown's API accepts a radius; expose as a setting or hardcode (e.g. 50km)?
- **Caching.** A user opening the view 3 times in a minute should not hammer Bandsintown. A 15-minute in-memory TTL is enough and requires no persistence layer.
- **Offline behavior.** No network → what does the view show? Empty with a "check your connection" banner is fine; do **not** mirror events to Core Data (that's out of the escape-hatch shape).
- **Rate limiting + quota.** Worth a one-hour investigation of Bandsintown's terms before committing to the integration.

This feature has the **most open questions dominating its cost**. The other four features are ~1-day implementations once the questions are nailed; this one is ~3–5 days even with clean answers because CoreLocation permission flows, API key handling, and UX fallbacks all add paper-cut friction. **Strongly recommend this lands last in the backlog**, after the four cheaper features have exercised the dev loop and the PRIMER's recipes.

---

## 5. Prereq cleanups

These are investigations / small diffs that should land **before** the first real feature so they don't recur as friction during every feature PR. Keep this list to three items — if it grows, the team is being too ambitious for the implementation phase.

### 5.1 Ampache-side collapse investigation (optional, deferred decision)

**What:** upstream Amperfy supports both Subsonic and Ampache backends via the `LibrarySyncer` / `LibrarySyncerProxy` / `AmpacheLibrarySyncer` 3-place protocol ceremony. This fork only ever targets Navidrome (Subsonic). Every new protocol method currently requires an empty/unreachable stub on `AmpacheLibrarySyncer`, which is a recurring per-feature tax.

**Why deferred:** the PRIMER flagged this as a one-afternoon investigation for Day 6 that was **not** needed to make the decision. The decision doc (`docs/DECISION.md` under "Trade-offs we are accepting") explicitly defers the call on whether to collapse until the upstream engagement strategy is chosen (friendly fork ↔ hard fork). **Do not rip out the Ampache side speculatively** — if we're building a friendly fork, upstream won't accept the collapse and we pay a merge-conflict tax forever. Wait for the strategy decision, then either (a) collapse it as a hard-fork delta or (b) live with the ceremony.

**Action now:** add a standing note in the first feature PR's description: "this change touches `LibrarySyncer` — the Ampache stub is intentional pending upstream-fork strategy decision". That's the entire prereq until the strategy is set.

### 5.2 Confirm test target green on first boot

**What:** before touching feature code, run `xcodebuild test -only-testing:AmperfyKitTests` on a fresh checkout and confirm all existing tests pass. If anything is red, fix or triage before adding new tests — you do not want to be the session that can't tell whether *their* change broke the tests.

**Why:** the PRIMER documents that AmperfyKit has a real test target, but the spike never ran it end-to-end — it only verified the target exists and sampled a few files. The implementation phase should start with a known-green baseline.

**Action:** run it, fix trivial rot (deprecation warnings as errors, etc.), file a task for anything non-trivial. Commit the green baseline, then start feature work.

### 5.3 Check deployment target consistency

**What:** there have been several deployment-target bumps upstream over the years. Quickly grep `IPHONEOS_DEPLOYMENT_TARGET` in the project file and confirm it's at one consistent value across both targets (`Amperfy` and `AmperfyKit`). Inconsistent rows cause silent build-config drift.

**Why:** cheap five-minute check. Not a blocker if consistent. If inconsistent, normalize to the higher value — we're not shipping to ancient devices.

**Action:** one-command grep, one-line fix if needed, commit.

---

## 6. Initial backlog skeleton

Dependency-ordered. The coordinator and the user will finalize this list; treat this as a starting skeleton, not the committed backlog.

1. **Warm up dev loop.** Rehearse Recipe A Path A from §3 against a throwaway view. Validates sim build, install, launch, FRC-repaint chain, and the test target. Land a single test that exercises the throwaway predicate.
2. **Prereq 5.2 — test baseline green.** Document the baseline in a commit message.
3. **Prereq 5.3 — deployment target consistency.** One-line fix if needed.
4. **Feature 1 — Complete albums only.** Cheapest filter feature, zero schema, zero sync touches. Validates the "add-a-filter-view" shape without introducing any new moving parts. First real feature because it is the lowest-risk way to build confidence in the Path A recipe on a non-throwaway view.
5. **Feature 2 — Single tracks added recently.** Same shape as Feature 1 but with a compound predicate and a join, so it stresses the predicate authoring a little more. Still zero schema.
6. **Feature 3 — Pinned playlists.** First feature that writes user-local state. Exercises the v50-bump inferred-mapping flow and the `storage.main.context.save()` path. If anything is going to surprise us about the "additive schema is cheap" claim, this is where it will happen — hence it lands **before** Feature 4 (which is a bigger additive change).
7. **Feature 4 — Local playlist folders.** Only after Feature 3 has validated the inferred-mapping happy path on a small additive change. New entity + new relationship is the biggest additive schema bump of the five features; de-risk with Feature 3 first.
8. **Upstream engagement strategy decision.** This is a doc, not a code change, but it belongs in the backlog because it unblocks prereq 5.1 and sets the policy for all subsequent PRs. Should happen **before** Feature 5, because Feature 5 may want to touch `Info.plist` and introduce a new service class — decisions that are friendlier to land under a known strategy.
9. **Prereq 5.1 — Ampache collapse (if hard fork).** Conditional on the strategy decision. If friendly fork, **skip this item entirely**.
10. **Feature 5 — Gigs near you.** Last because of the dominant open-question load (API key, location UX, recency semantic, caching, fallback). By the time this lands, the dev loop, Recipe A, user-local state, and schema-bump paths have all been validated — the remaining risk is all in the third-party integration, which is exactly what this feature is actually about.

Expect the user to re-order, drop, or split these. What matters is that items 1–3 stay at the top (dev-loop warm-up + baseline), that Feature 3 comes before Feature 4 (additive-schema de-risking), and that Feature 5 comes after the strategy decision.

---

## 7. What the implementation agent should NOT do

Ordered by how much damage the mistake would cause.

1. **Do not run the signing pipeline or touch `spike/.signing/`.** That directory is owned by a parallel session. Read-only reference from this side. If you need a device build, message `team-lead`.
2. **Do not revert Phase A work or flo/Agin artifacts.** `spike/flo/` and `spike/agin/` are archived reference material per `docs/DECISION.md`. Their `PRIMER.md` files remain as cross-stack comparison reading. Leave them alone.
3. **Do not collapse the Ampache side of `LibrarySyncer` speculatively.** Prereq 5.1 explains why this must wait for the upstream engagement strategy. Adding empty stubs on `AmpacheLibrarySyncer` for every new protocol method is the *correct* behavior until that decision is made.
4. **Do not introduce new top-level dependencies** (SwiftPM packages, external SDKs) without explicit written justification in the feature PR description and `team-lead` sign-off. The decision record names "build dependency footprint larger than flo's" as an already-accepted cost; don't compound it.
5. **Do not rewrite existing patterns you don't like.** If you hit the `LibrarySyncer` 3-place ceremony, the FRC base-class hierarchy, or the `CoreDataCompanion`/`AsyncCoreDataAccessWrapper` split and feel like refactoring — **stop and message `team-lead`**. These shapes are load-bearing for the decision and predate any single feature's need.
6. **Do not mirror Bandsintown (or any other third-party REST result) into Core Data.** The escape-hatch pattern is deliberately non-persisted. Mirroring creates a sync-invalidation problem we don't want to own.
7. **Do not treat the spike `NOTES.md` scratch as authoritative.** `PRIMER.md` and `DECISION.md` are the authoritative artifacts. NOTES.md is raw scratch that has been superseded in places (see the Day 2 → Day 3 schema overstatement correction). When they disagree, PRIMER wins.
8. **Do not commit customer/account credentials, test accounts, or server URLs** to any file in `spike/amperfy/`. The spike's `.spike/` subtree is for scratch; customer data does not belong there either.
9. **Do not change commit conventions, CI config, or the branching convention** without a task. The implementation phase is additive-feature-focused.
10. **Do not duplicate PRIMER content into feature PR descriptions.** Link to PRIMER sections by filename and section header. The PRIMER is the shared reference; inlining copies will drift.

---

**End of playbook.** Your first move should be: read PRIMER end-to-end, read DECISION, run the baseline test suite, then start the §3 rehearsal. Good luck.
