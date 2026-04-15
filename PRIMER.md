# Amperfy — Spike Primer

_Navidrome iOS client spike, Phase B Milestone 5 deliverable. Author: `explorer-amperfy`. Assembled 2026-04-10 from `.spike/NOTES.md` Days 1–3 and `docs/COMPARISON.md` Day 2 cross-pollination._

> **Scope:** Amperfy's Subsonic backend path only. Amperfy ships a parallel Ampache stack under `AmperfyKit/Api/Ampache/` that is routed at runtime by `BackendProxy` / `LibrarySyncerProxy`; Navidrome speaks Subsonic, so this primer treats the Ampache side as "stub required when you add a protocol method, otherwise ignore."

---

## 30-second project summary

Amperfy is a mature, UIKit-first Subsonic / Ampache / Jellyfin client (Swift 6, Xcode 26) with a clean `AmperfyKit` framework split separating the UI from a **full 22-entity Core Data mirror of the server library**. Reads go through `NSFetchedResultsController`; writes come from a layered Subsonic sync pipeline that uses a canonical two-pass parse template and commits on a background context that auto-merges into the main `viewContext`. New views are live-reactive to background sync for free (no `@Published` plumbing, no pull-to-refresh ceremony), and SwiftUI-via-`UIHostingController` is an already-idiomatic in-tree add-a-view path. License: **GPL-3.0**.

On the Navidrome spike's primary decision axis — _"can we write new remote queries against the Navidrome server in an elegant, modular fashion?"_ — Amperfy's answer is: **yes, with a 2-to-6-file cost curve depending on how much of the data is already in the schema**, and a meaningful ergonomic payoff in reactivity and filter expressiveness. On the secondary offline-browsing axis, Amperfy wins alone: the full Core Data mirror + the `DebugCoreData` inspector scheme means the entire Library tab works on a plane (playback of non-downloaded tracks still needs the server).

---

## Stack and key dependencies

- **Language / toolchain:** Swift 6, Xcode 26.4+ required (README insists).
- **Project type:** plain `Amperfy.xcodeproj` — **no `.xcworkspace`**, no CocoaPods, no Carthage, SwiftPM only.
- **Deployment target:** iOS 26.0. Two stale `IPHONEOS_DEPLOYMENT_TARGET = 15.0` entries still live in `project.pbxproj` around lines 2981 and 3043 — they coexist with the real `26.0` values and don't break the build; cosmetic cleanup only.
- **Targets:** `Amperfy` (UIKit app), `AmperfyKit` (framework), `AmperfyKitTests` (XCTest). Secondary: `AmperfyIntents` (App Intents extension), `DebugCoreData` (diagnostic tool), `DominantColors` / `DominantColorsTests` (transitive from the DCLib SPM package — not ours).
- **SwiftPM dependencies** (auto-resolved on first `xcodebuild`):
  - Alamofire 5.6.2
  - AudioStreaming 1.4.4
  - CallbackURLKit 3.0.0
  - DominantColors (DCLib) 1.2.2
  - ID3TagEditor 4.6.0
  - Ifrit 2.0.3
  - MarqueeLabel 4.5.3
  - NotificationBannerSwift 3.2.0
  - SnapKit 5.7.1
  - swift-collections 1.1.4
  - VYPlayIndicator 1.5.4
  - ogg-binary-xcframework 0.1.2
  - vorbis-binary-xcframework 0.1.2
- **Architecture:** UIKit app target with an **in-tree SwiftUI sub-tree** under `Amperfy/SwiftUI/` (`Basics/` + `Settings/`). `UIHostingController` callsites exist today at `Amperfy/Screens/ViewController/SettingsHostVC.swift` and `LargeCurrentlyPlayingPlayerView.swift:91,99` — idiomatic precedent for "drop in a new SwiftUI-first view that reads from Core Data."
- **Backend abstraction:** `BackendProxy` holds an `Atomic<BackenApiType>` and dispatches to `ampacheApi` / `subsonicApi` / `subsonicLegacyApi`. `LibrarySyncerProxy` is the `@MainActor` forwarder for the `LibrarySyncer` protocol. For Navidrome only the `Subsonic` branch matters.
- **Core Data posture:** manual migrations (`shouldInferMappingModelAutomatically = false`, `shouldMigrateStoreAutomatically = false`) gated by `CoreDataMigrator.requiresMigration(...)`. **The manual posture is a misnomer for most feature work** — see the Local Data Store section for the schema-cost correction.

---

## Directory map

Two levels deep for the parts that matter. ★ = load-bearing for add-a-query work.

```
amperfy/
├── Amperfy/                                  # UIKit app target (view layer + scene delegates + CarPlay + Intents)
│   ├── AppDelegate*.swift                    # Split into Alert/Keyboard/MainMenu/Notification files
│   ├── SceneDelegate.swift                   # + MiniPlayerSceneDelegate + SettingsSceneDelegate
│   ├── Screens/
│   │   ├── ViewController/                   # ★ canonical place for a new UIKit VC reading from AmperfyKit
│   │   │   ├── SettingsHostVC.swift          # ★ the UIHostingController template to copy for SwiftUI-first views
│   │   │   ├── DownloadsVC.swift             # Good worked example of a FRC-consumer VC
│   │   │   └── ...
│   │   ├── View/ / Basics/ / Player/         # UIKit subviews + storyboards
│   ├── SwiftUI/                              # ★ in-tree SwiftUI sub-tree (NOT "pure UIKit" — see Doc corrections)
│   │   ├── Basics/                           # Reusable SwiftUI primitives
│   │   └── Settings/                         # SettingsView, SettingsTabView, feature panels
│   ├── CarPlay/ / Intents/                   # CarPlay scene handlers + App Intents
│   ├── Amperfy.entitlements                  # carplay-audio + siri stripped (Phase A rebrand)
│   └── Info.plist / AppIntentVocabulary.plist
├── AmperfyKit/                               # ★ framework: data layer, API sync, downloads, player, MetaManager
│   ├── Api/
│   │   ├── BackendApi.swift                  # ★ LibrarySyncer protocol + DTO structs (e.g. LyricsList)
│   │   ├── BackendProxy.swift                # Runtime backend dispatch (Subsonic vs Ampache vs Legacy)
│   │   ├── LibrarySyncerProxy.swift          # ★ @MainActor forwarder for every LibrarySyncer method
│   │   ├── CommonLibrarySyncer.swift         # Base class with shared fields + storage.async.perform example
│   │   ├── AutoDownloadLibrarySyncer.swift   # + BackgroundLibrarySyncer + BackgroundFetchTriggeredSyncer
│   │   ├── Subsonic/                         # ★ Subsonic backend — the one that matters for Navidrome
│   │   │   ├── SubsonicServerApi.swift       # ★ HTTP layer; endpoints are `request { version in createAuthApiUrlComponent(...) + addQueryItem(...) }` closures
│   │   │   ├── SubsonicLibrarySyncer.swift   # ★ 1430 lines — two-pass parse template (see canonical syncNewestAlbums at :636-668)
│   │   │   ├── Ss{Album,Artist,Directory,Genre,IDs,Lyrics,MusicFolder,OpenSubsonicExtensions,Ping,Playable,Playlist,PlaylistSongs,PodcastEpisode,Podcast,Radio,Song}ParserDelegate.swift
│   │   │   └── SsXmlParser.swift             # Base XMLParserDelegate
│   │   └── Ampache/                          # Parallel stack for the other backend (read-once, mostly ignore)
│   ├── Storage/
│   │   ├── PersistentStorage.swift           # NSPersistentContainer + merge policy + migration gate
│   │   ├── LibraryStorage.swift              # Top-level DAO facade (the object VCs call into)
│   │   ├── ManagedObjects/
│   │   │   ├── Amperfy.xcdatamodeld/         # ★ 49 versioned .xcdatamodel bundles (Amperfy.xcdatamodel → v2 → v49)
│   │   │   ├── Migration/
│   │   │   │   ├── CoreDataMigrationVersion.swift   # ★ The enum that tracks every version
│   │   │   │   └── CoreDataMigrationStep.swift      # ★ :36-52 — inferredMappingModel fallback (the "schema-tax" answer)
│   │   │   ├── VersionMappings/              # ★ Only TWO custom .xcmappingmodel bundles exist (V4→V5, V10→V11)
│   │   │   └── *MO+CoreDataClass.swift / *MO+CoreDataProperties.swift  # Generated-ish NSManagedObject classes
│   │   ├── EntityWrappers/                   # ★ Hand-written Swift wrappers (Album.swift, Song.swift, …) — the view-layer boundary
│   │   ├── ResultController/
│   │   │   ├── BasicFetchedResultsController.swift  # ★ 569 lines — Basic + CachedFetchedResultsController<ResultType>
│   │   │   └── FetchedResultsControllers.swift      # ★ ~1200 lines — ~25 concrete subclasses
│   │   ├── DownloadRequestManager.swift      # ★ Core Data queue backing the download pipeline
│   │   └── CacheFileManager.swift            # ★ 883 lines — filesystem layout + MIME tables + per-account cache sizes
│   ├── Download/
│   │   ├── DownloadManager.swift             # ★ 548 lines — actor DownloadManager: NSObject, DownloadManageable
│   │   ├── DownloadManagerSessionExtension.swift   # ★ URLSessionDownloadDelegate half (see :96-104 for the "no progress reporting" call)
│   │   ├── DownloadProtocols.swift           # ★ DownloadManageable + DownloadManagerDelegate + DownloadRequest
│   │   ├── PlayableDownloadDelegate.swift    # In-tree delegate example
│   │   └── DownloadError.swift
│   ├── Player/                               # AudioPlayer, BackendAudioPlayer, PlayerFacade, NowPlayingInfoCenter
│   ├── Common/                               # FuzzySearcher, NetworkMonitor, LogData, notification handlers
│   ├── Screens/                              # KIT-level view glue (EntityImageView, ArtworkCollection, CommonString)
│   ├── MetaManager.swift                     # ★ :129-195 — two-instance DownloadManager wiring
│   └── AmperfyKit.h / .swift / .docc         # Module umbrella + entry + DocC catalogue
├── AmperfyKitTests/                          # ★ The only real test target of the three spike apps
│   └── Cases/                                # Mirrors kit layout: API/, Common/, Player/, Storage/
├── BuildTools/                               # SwiftFormat runner (Package.swift + applyFormat.sh)
├── Amperfy.xcodeproj/                        # ⚠ read-only (signing agent's territory)
├── .swiftformat                              # Google Swift Style enforcement
├── Helper/add-license-header.sh              # GPLv3 header stamping
├── LICENSE                                   # GPL-3.0
└── README.md / CHANGELOG.md
```

---

## Local data store

**Technology:** Core Data with 22 entities mirroring the Subsonic library, managed by `NSPersistentContainer` (`AmperfyKit/Storage/PersistentStorage.swift`). The store is intentionally a **full local mirror** of the remote library, not a cache — this is what gives Amperfy stable offline browsing.

### Schema hierarchy

Clean abstract-class inheritance:

- `AbstractLibraryEntity` (id, isFavorite, lastPlayedDate, playCount, rating, remoteStatus, starredDate, alphabeticSectionInitial)
  - `AbstractPlayable` (bitrate, duration, replayGain*, url, title, track, year, relFilePath, contentType)
    - `Song`, `PodcastEpisode`, `Radio`
  - Direct children: `Album`, `Artist`, `Genre`, `Directory`, `Podcast`
- Standalone: `Account`, `Artwork`, `EmbeddedArtwork`, `Download`, `LogEntry`, `MusicFolder`, `Player`, `Playlist`, `PlaylistItem`, `ScrobbleEntry`, `SearchHistoryItem`, `UserStatistics`

Rich relationships: `Album ↔ Artist ↔ Genre ↔ Song`, `Playlist → PlaylistItem → AbstractPlayable`, artwork pairs, per-account scoping via `Account` back-refs. Every `id` field has a fetch index.

### Stack setup

- `CoreDataCompanion { context, library }` — the "hand me a (context, LibraryStorage) pair" unit of work.
- `actor AsyncCoreDataAccessWrapper.perform { body }` — Swift actor vending `persistentContainer.newBackgroundContext()`, configured with the same merge policy as the main context, runs `body` inside `context.perform { }`, auto-saves on exit.
- **Main context** (`PersistentStorage.swift`):
  - `automaticallyMergesChangesFromParent = true`
  - `mergePolicy = .mergeByPropertyObjectTrumpMergePolicyType`
  - `retainsRegisteredObjects = true`
- **This is what makes background syncer writes flow automatically to every `NSFetchedResultsController` bound to the main context.** It is the load-bearing piece of Amperfy's free live-reactivity story.
- **`EntityWrappers/`** — hand-written Swift classes (`Album.swift`, `Song.swift`, …) wrap their `*MO` NSManagedObject counterparts. View code is expected to touch `Album`, never `AlbumMO`. This is the boundary that keeps Core Data out of view-layer signatures.

### Query layer — `NSFetchedResultsController`-driven, reactive by construction

`AmperfyKit/Storage/ResultController/`:

- **`BasicFetchedResultsController.swift` (569 lines)** defines three shapes:
  - `CustomSectionIndexFetchedResultsController<ResultType>: NSFetchedResultsController<NSFetchRequestResult>` — adds a `sectionIndexType` enum (alphabet, rating, newestOrRecent, durationSong/Album/Artist, year, none).
  - `BasicFetchedResultsController<ResultType>` — wraps one FRC; exposes `fetch()`, `search(predicate:)`, `showAllResults()`, `clearResults()`, `fetchedObjects`, section/row counts, `titleForHeader(inSection:)`, `sectionIndexTitles`.
  - `CachedFetchedResultsController<ResultType>` — maintains **two** internal FRCs (one "cached" main-list keyed by `"\(typeName)-\(account.serverHash)-\(account.userHash)"`, one "live search" FRC), swaps via `isSearchActive`. This is the "preserved scroll + instant search" spine.
- **`FetchedResultsControllers.swift` (~1200 lines)** contains **~25 concrete subclasses** — `AlbumFetchedResultsController`, `ArtistFetchedResultsController`, `SongsFetchedResultsController`, `PlaylistFetchedResultsController`, `GenreArtistsFetchedResultsController`, `DownloadsFetchedResultsController`, etc. Canonical shape:

```swift
public class AlbumFetchedResultsController: CachedFetchedResultsController<AlbumMO> {
  public init(coreDataCompanion: CoreDataCompanion, account: Account,
              sortType: AlbumElementSortType, isGroupedInAlphabeticSections: Bool,
              fetchLimit: Int? = nil) {
    var fetchRequest = AlbumMO.alphabeticSortedFetchRequest        // static factory on the MO
    switch sortType { /* ratingSortedFetchRequest / newestSortedFetchRequest / ... */ }
    fetchRequest.fetchLimit = fetchLimit ?? 0
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(onlyCachedAlbums: true),
      ]),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = AlbumMO.relationshipKeyPathsForPrefetching
    super.init(..., sectionIndexType: sortType.asSectionIndexType, ...)
  }
}
```

**End-to-end reactivity loop:** background syncer's `storage.async.perform { ... }` saves → parent merges to main `viewContext` (automatic, via `automaticallyMergesChangesFromParent = true` + object-trump merge policy) → `NSFetchedResultsController` delegates fire on main → `FetchUpdatePerObjectHandler` in `SingleFetchedResultsTableViewController<ResultType>` applies per-row `.insert/.delete/.update/.move` to the table view. **Zero manual refresh. Zero `@Published`/`ObservableObject` ceremony. Zero pull-to-refresh boilerplate.** New views get this for free just by creating an FRC subclass or using SwiftUI `@FetchRequest` with the right predicate.

### Schema-extension cost profile (corrected Day 3)

> My Day 2 framing overstated the schema-change cost. This section is the corrected version. The "Doc corrections" block at the bottom flags this.

`CoreDataMigrationStep.swift:36-52` is the load-bearing file for understanding Amperfy's schema-extension cost:

```swift
private static func mappingModel(fromSourceModel: ..., toDestinationModel: ...) -> NSMappingModel? {
  guard let customMapping = customMappingModel(...) else {
    return inferredMappingModel(fromSourceModel:toDestinationModel:)
  }
  return customMapping
}
```

The migrator **tries for a custom `NSMappingModel(from: [Bundle.main], forSourceModel:, destinationModel:)` first** and **falls back to `NSMappingModel.inferredMappingModel(...)` when none exists**. So the 49 model versions are not 48 hand-written mapping models — they are 48 migrations, **only 2 of which are custom**. On disk:

```
AmperfyKit/Storage/ManagedObjects/VersionMappings/
├── MappingModelV4toV5.xcmappingmodel
├── MappingModelV10toV11.xcmappingmodel
└── MigrationPolicyV4toV5.swift   (NSEntityMigrationPolicy subclass)
```

Every migration from v11 → v49 rides the inferred-mapping happy path. The smoking-gun evidence is in `CoreDataMigrationVersion.swift` inline comments — recent additive features all shipped without custom mappings:

- `v43`: "Add isCached, Increase duration for collections from Int16 to Int64"
- `v46`: "Add addedDate for songs"
- `v47`: "Add replay gain and peak for songs"
- `v48`: "Account support: add account (url + user)" — **multi-entity add**
- `v49`: "Account: add apiType"

**Corrected cost profile:**

| Scenario | Files touched | Custom mapping? | Migration policy? |
|---|---|---|---|
| **Best case** — add an attribute to an existing entity (~95% of additive features) | 3–4 (new v50 bundle + `CoreDataMigrationVersion` enum case + `nextVersion()` switch line + optional EntityWrapper getter) | no | no |
| **Typical case** — add a brand-new entity for a custom feature | 5–6 (v50 bundle + enum/switch + new `XxxMO` + hand-written `Xxx.swift` EntityWrapper + fetch-request static helpers on the MO + new FRC subclass) | no | no |
| **Worst case** — data-transforming / restructural migration (split a column, merge entities, non-trivial rename) | 4–6 + custom `.xcmappingmodel` + `NSEntityMigrationPolicy` subclass | **yes** | **yes** |

**Worst case is rare.** Two custom mapping models in six years of migrations; both triggered by restructures, not by feature adds. When you do hit it, `VersionMappings/MigrationPolicyV4toV5.swift` is the in-tree template to copy.

**Pedagogical callout — verify the schema in minutes, not days.** The schema is stored as plain XML at `AmperfyKit/Storage/ManagedObjects/Amperfy.xcdatamodeld/Amperfy v49.xcdatamodel/contents`. If any brief, ticket, or previous agent tells you "entity X has attribute Y, we added it in version Z," verify it by opening that file and grepping for the attribute name. Don't trust the claim — `*.xcdatamodel/contents` is ground truth. (This lesson is from the Day 3 recipe work — see the brief-error pedagogical note below.)

---

## API sync layer

Layered from the HTTP socket up to the protocol the app consumes:

### 1. `AmperfyKit/Api/Subsonic/SubsonicServerApi.swift` — HTTP layer

Endpoints are async methods returning `APIDataResponse`, shaped as closures inside a shared `request { version in ... }` wrapper that handles auth / version negotiation / error mapping:

```swift
public func requestNewestAlbums(offset: Int, count: Int) async throws -> APIDataResponse {
  try await request { version in
    var urlComp = try self.createAuthApiUrlComponent(version: version, forAction: "getAlbumList2")
    urlComp.addQueryItem(name: "type", value: "newest")
    urlComp.addQueryItem(name: "size", value: count)
    urlComp.addQueryItem(name: "offset", value: offset)
    return try self.createUrl(from: urlComp)
  }
}
```

**Adding a new Subsonic action is ~10 lines** — the URL builder + query items. Auth, version, error handling are already solved by `request { … }`.

### 2. Parser delegates — `Ss*ParserDelegate.swift`

XML `XMLParserDelegate` classes under `AmperfyKit/Api/Subsonic/`, one per response shape (`SsAlbumParserDelegate`, `SsSongParserDelegate`, `SsArtistParserDelegate`, `SsIDsParserDelegate`, `SsLyricsParserDelegate`, etc.). Shared base: `SsXmlParser.swift`. `SsIDsParserDelegate` is the **reusable ID-prefetch pre-pass** used by every two-pass sync method.

When a new query's XML shape matches an existing parser, reuse it. Otherwise: one new parser delegate file, ~50–100 lines.

### 3. `AmperfyKit/Api/Subsonic/SubsonicLibrarySyncer.swift` — two-pass template

1430 lines, every method shaped identically. Canonical example (`syncNewestAlbums(offset:count:)` at lines 636–668):

```swift
@MainActor func syncNewestAlbums(offset: Int, count: Int) async throws {
  guard isSyncAllowed else { return }
  let response = try await subsonicServerApi.requestNewestAlbums(offset: offset, count: count)
  try await storage.async.perform { asyncCompanion in
    let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
    // Pass 1: ID pre-scan (cheap, memory-only)
    let idParserDelegate = SsIDsParserDelegate(performanceMonitor: self.performanceMonitor)
    try self.parse(response: response, delegate: idParserDelegate, isThrowingErrorsAllowed: false)
    let prefetch = asyncCompanion.library.getElements(account: accountAsync,
                                                      prefetchIDs: idParserDelegate.prefetchIDs)
    // Pass 2: real parse, prefetch lookup in memory (no per-row Core Data fetch)
    let parserDelegate = SsAlbumParserDelegate(
      performanceMonitor: self.performanceMonitor,
      prefetch: prefetch,
      account: accountAsync,
      library: asyncCompanion.library)
    try self.parse(response: response, delegate: parserDelegate)
    // Post-process: stamp ordering, invalidate stale flags
    asyncCompanion.library.getNewestAlbums(for: accountAsync, offset: offset, count: count)
      .forEach { $0.markAsNotNewAnymore() }
    parserDelegate.parsedAlbums.enumerated().forEach { i, album in
      album.updateIsNewestInfo(index: i + 1 + offset)
    }
  }
}
```

Two passes because the prefetch pass lets pass 2 resolve every referenced entity via an in-memory dictionary instead of per-row fetches — a huge throughput win on large responses. **Every sync method in this file follows this shape.** The `storage.async.perform` closure saves on exit → main context auto-merges → bound FRCs fire.

### 4. `AmperfyKit/Api/LibrarySyncerProxy.swift` — the UI-facing façade

`@MainActor class LibrarySyncerProxy: LibrarySyncer`. Holds `backendApi: BackendApi`, computes `var activeSyncer: LibrarySyncer { backendApi.createLibrarySyncer(account:storage:) }`, and **forwards every `LibrarySyncer` protocol method** to `activeSyncer`. This is the **single UI-facing sync API** — view code calls `appDelegate.librarySyncer.syncNewestAlbums(offset:count:)`, never `subsonicLibrarySyncer` directly.

### 5. `AmperfyKit/Api/BackendProxy.swift` — runtime backend dispatch

`final class BackendProxy: Sendable, BackendApi`. Holds `Atomic<BackenApiType>` and dispatches to `ampacheApi` / `subsonicApi` / `subsonicLegacyApi`. Exposes `login(apiType:credentials:)`, `generateUrl(forDownloading/Streaming/Artwork:)`, and `createLibrarySyncer(account:storage:)`.

### Adding a new Subsonic query: the 4-file "spine" ceremony

For any persisted query whose target entity already exists in the schema:

1. ~10 lines in `SubsonicServerApi.swift` — new `requestXxx(...) async throws -> APIDataResponse` in a `request { version in ... }` closure.
2. New or reused `Ss*ParserDelegate.swift` for the response XML shape.
3. New `@MainActor func syncXxx(...) async throws` in `SubsonicLibrarySyncer.swift` following the two-pass template.
4. **Ceremony** — mirror the signature on three places:
   - The `LibrarySyncer` protocol in `BackendApi.swift`
   - The `LibrarySyncerProxy` forwarder in `LibrarySyncerProxy.swift`
   - An `AmpacheLibrarySyncer` stub (`throw BackendError.notImplemented` or an empty return) so the forwarder compiles

That's **4 source files + 1 protocol edit + 1 Ampache stub** = ~6 touches for a net-new query. The "ceremony" bullet is the file-count tax Amperfy charges for backend-agnostic consistency. If you don't need the query to flow through the proxy (direct-REST escape hatch, below), you can skip items (4) entirely — but that's unusual.

---

## Direct-REST escape hatch (non-persisted queries)

**Not every query needs to write to the Core Data mirror.** Amperfy has an in-tree escape hatch for "fire a Subsonic request, get a plain Swift struct back, render it from `@State`." The proof is `parseLyrics(relFilePath:) async throws -> LyricsList`.

`LyricsList` is a plain Swift struct defined in `AmperfyKit/Api/BackendApi.swift:94`:

```swift
public struct LyricsList {
  var lyrics = [StructuredLyrics]()
  // ...
}
```

It is declared on the `LibrarySyncer` protocol at `BackendApi.swift:211`:

```swift
func parseLyrics(relFilePath: URL) async throws -> LyricsList
```

And implemented in `SubsonicLibrarySyncer.swift:1298` with **no `storage.async.perform`, no managed-object writes, no FRC binding**:

```swift
@MainActor
func parseLyrics(relFilePath: URL) async throws -> LyricsList {
  let parserDelegate = SsLyricsParserDelegate(performanceMonitor: performanceMonitor)
  guard let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath) else {
    throw ResponseError(type: .xml)
  }
  try parse(absFilePath: absFilePath, delegate: parserDelegate, isThrowingErrorsAllowed: false)
  guard let lyricsList = parserDelegate.lyricsList else { throw ResponseError(type: .xml) }
  return lyricsList
}
```

### Non-persisted query recipe — 5 files

1. ~10 lines on `SubsonicServerApi` for the HTTP endpoint.
2. One new `Ss*ParserDelegate` that builds a plain struct instead of mutating MOs (or a `Codable` JSON decode if the response happens to be JSON-shaped).
3. One protocol method on `LibrarySyncer` in `BackendApi.swift` returning your struct type.
4. One forwarder line in `LibrarySyncerProxy`.
5. One stub in `AmpacheLibrarySyncer` (throws `notImplemented` or returns an empty value).

The view holds the result in `@State` instead of `@FetchRequest`. **5 files total** — one more than flo's 3-step "constant + DTO + service method" because Amperfy insists on routing through the `LibrarySyncer` protocol. The extra file buys consistency: every remote call is discoverable from one protocol, and every backend implementation has a symmetric obligation.

### Hybrid pattern — ephemeral ranked list over persistent rows

Also worth knowing: `requestSimilarSongs(song:count:) async throws -> [Song]` at `SubsonicLibrarySyncer.swift:908` **persists the returned songs to Core Data AND returns them as an ordered in-memory array** via `storage.async.performAndGet { ... return objectIDs }` + a main-context `existingObject(with:)` rehydrate. Use this idiom when you want both the live table (persistent, searchable) **and** the server's ordering (ephemeral, specific to one call) — "top songs this month," "similar to this artist," "recently played on another device."

---

## Download manager

Amperfy's download pipeline is the most sophisticated of the three spike apps. Five files under `AmperfyKit/Download/` (982 lines) + `AmperfyKit/Storage/DownloadRequestManager.swift` (306 lines) + `AmperfyKit/Storage/CacheFileManager.swift` (883 lines) + wiring in `AmperfyKit/MetaManager.swift:129-195`.

### Two-instance actor architecture

**Two independent `DownloadManager` actors** live on the account-scoped `MetaManager` singleton, lazily built:

- **`playableDownloadManager`** (`MetaManager.swift:129-167`) — songs, podcast episodes, radios.
  - `name: "PlayableDownloader"`
  - `parallelDownloadsCount: 4`
  - `limitCacheSize: true`
  - `isFailWithPopupError: true`
  - Delegate: `PlayableDownloadDelegate` (`AmperfyKit/Download/PlayableDownloadDelegate.swift`, 157 lines)
- **`artworkDownloadManager`** (`MetaManager.swift:169-195`) — cover art, embedded artwork.
  - `name: "ArtworkDownloader"`
  - `limitCacheSize: false`
  - `isFailWithPopupError: false`
  - Delegate: `backendApi.getActiveArtworkDownloadDelegate()` — proxied through `BackendProxy` so Subsonic and Ampache each have their own artwork delegate.

Each manager owns its own **background `URLSession`** via `URLSessionConfiguration.background(withIdentifier: "<bundle>.<account.ident>.<name>.background")`. The background session identifier is **account-scoped**, so multi-account installs don't collide. `DownloadManager` itself is declared:

```swift
actor DownloadManager: NSObject, DownloadManageable
```

— Swift actor for concurrent safety, `NSObject` inheritance for `URLSessionDownloadDelegate` conformance wired via `DownloadManagerSessionExtension.swift`. State held:

- `urlSession: URLSession?` — the background session
- `tasks: [URLSessionTask: DownloadTaskInfo]` — live task → request map
- `taskQueue: OperationQueue` — `maxConcurrentOperationCount = delegate.parallelDownloadsCount`
- `taskOperations: [DownloadRequest: DownloadOperation]` — dedup map
- `requestManager: DownloadRequestManager` — Core Data queue (see below)
- `getDownloadDelegateCB: @MainActor () -> DownloadManagerDelegate` — delegate fetched lazily on MainActor, not captured
- `preDownloadIsValidCheck: PreDownloadIsValidCB?` — optional async filter (artwork uses this to honor `AccountSettings.artworkDownloadSetting`)
- `isCacheSizeLimited: Bool` + `settings.user.cacheLimit` comparison — auto-abort if the active download would push total cache over the limit

### Core Data surface — `DownloadMO` as a durable queue

All download state lives in the `Download` entity (`DownloadMO`). `DownloadRequestManager` treats `DownloadMO` rows as a **durable queue**: they survive app termination, process kill, and background download completion. Key fields (v49 model):

- `id` (String, default `"Empty String"`)
- `creationDate` / `startDate` / `finishDate` / `errorDate`
- `isDownloading: Bool`, `isCanceled: Bool`
- `element` relationship → `AbstractLibraryEntity` (one `JOIN` from download to target)
- `account` relationship → `Account`

**Partitioning — the footgun.** Both `DownloadManager` instances share **one** `DownloadMO` SQL table. They stay out of each other's rows purely by the `DownloadManagerDelegate.requestPredicate` they return:

- `PlayableDownloadDelegate.requestPredicate = DownloadMO.onlyPlayablesPredicate`
- `ArtworkDownloadDelegate.requestPredicate = <artwork-only predicate>`

`DownloadRequestManager.getRequestedDownloads()` / `clearFinishedDownloads()` / `cancelDownloads()` compose that predicate with `account scope + finishDate == nil + errorDate == nil` into one `DownloadMO.creationDateSortedFetchRequest`. **Any new `DownloadManager` instance MUST return a non-overlapping `requestPredicate`** — a permissive predicate (e.g. `NSPredicate(value: true)`) would scoop other managers' requests. Keep the partition predicate as narrow as the delegate's scope.

**Progress reporting is deliberately absent.** `DownloadManagerSessionExtension.swift:96-104` contains a commented-out `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)` delegate with the inline note:

```swift
// ignore progress: don't save progress in CoreData -> huge CPU load
```

The UI gets **completion-level** progress only, via `NSNotification.Name.downloadFinishedSuccess` posted after each successful file lands (around line 504–508). Per-byte progress is not surfaced to the view layer at all. **Any feature wanting a progress bar per row must use in-memory state, not Core Data writes** — either re-enable the commented delegate and aggregate off-MO, or drive the bar from task state via a subscribe-to-actor observable on `DownloadManager`.

### End-to-end flow — `download(object:)` → file on disk

1. **`playableDownloadManager.download(object: someSong)`** (`DownloadManager.swift:189`, `@MainActor`). Skip if `isCached`. Grab `threadSafeInfo` (Sendable snapshot of `objectID` + type). `Task.detached` to escape main.
2. **Cache-limit gate** — `storageExceedsCacheLimit()` checks `CacheFileManager.completePlayableCacheSize` against `settings.user.cacheLimit`. If over, abort silently.
3. **Pre-validation hook** — `preDownloadIsValidCheck?(validDls)` (artwork uses this to filter by `artworkDownloadSetting`; playables pass `nil`).
4. **Request-manager add** — `requestManager.add(downloadInfo:)` (`DownloadRequestManager.swift:52`) writes a new `DownloadMO` row (or resets an existing errored/not-cached one) on the async background context. Returns a `DownloadRequest { objectID, id, title, info }` struct.
5. **Enqueue** — `addDownloadTaskOperation(downloadRequest:)` (line 356) builds a `DownloadOperation: AsyncOperation` whose `main()` runs `self.manageDownload(downloadRequest:)`, stashes it in `taskOperations[downloadRequest] = op`, adds to `taskQueue` (respects `maxConcurrentOperationCount`).
6. **`manageDownload`** (`DownloadManager.swift:367`) — marks `DownloadMO.isDownloading = true` in a `storage.perform { ... saveContext() }` closure, then calls `delegate.prepareDownload(downloadInfo:storage:)` which for playables resolves `backendApi.generateUrl(forDownloadingPlayable:)` (account-scoped signed URL — for Subsonic: `/rest/stream?id=<id>&...`).
7. **`fetch(downloadTaskInfo:)`** — creates `urlSession.downloadTask(with: url)`, stashes into `tasks[task] = info`, `task.resume()`. From here iOS owns the transfer and keeps running even if the app is backgrounded or killed.
8. **`urlSession(_:downloadTask:didFinishDownloadingTo:)`** (`DownloadManagerSessionExtension.swift:34`) — iOS drops the file in a tmp URL. Immediately move it to `CacheFileManager`'s tmp-with-unique-name area (iOS deletes the original as soon as the delegate returns). Then `await finishDownload(downloadRequest:task:fileURL:fileMimeType:)`.
9. **Validate** — `delegate.validateDownloadedData(fileURL:downloadURL:)` (`PlayableDownloadDelegate.swift:74`). Reads up to `maxFileSizeOfErrorResponse = 2000` bytes and feeds them to `backendApi.checkForErrorResponse(response:)`. Catches the "server replied 200 with a Subsonic `<error>` XML blob instead of audio" case. If error → `finishDownload(error:)` marks `DownloadMO.errorDate` and reports via `eventLogger` (popup for playables, silent for artwork).
10. **Commit** — `delegate.completedDownload(downloadInfo:fileURL:fileMimeType:storage:)` (`PlayableDownloadDelegate.swift:93`). Inside another `storage.perform` closure: load target `AbstractPlayable` by `objectID`, compute a relative file path via `CacheFileManager.shared.createRelPath(for:)`, call `CacheFileManager.moveExcludedFromBackupItem(at:to:accountInfo:)` to move the tmp file into the app's Library directory (iCloud-backup-excluded), stamp `playableAsync.relFilePath = relFilePath`. The MO save merges to `viewContext` → every FRC observing cached state re-fires → the row flips from "download" to "play" in the UI automatically.
11. **Post-completion** — embedded artwork extraction (`artworkExtractor.extractEmbeddedArtwork(...)`), `downloadFinishedSuccess` notification posted (~line 504), cache-limit re-check (may trigger a cascade of cancellations if this download pushed us over the limit), task + operation cleared from maps.

### Cache location

All bytes live under `CacheFileManager.amperfyLibraryDirectory = FileManager.libraryDirectory/<Bundle.main.bundleIdentifier>/` (`CacheFileManager.swift:101-116`). Per-file relative paths are composed from `account + entity type + id + file extension` (extension derived from `fileMimeType` via `MimeFileConverter`). `moveExcludedFromBackupItem` sets the `isExcludedFromBackup` resource value so iCloud doesn't sync the cache.

Per-account cache-size tracking: `_accountPlayableCacheSize: [AccountInfo: Int64]` (`CacheFileManager.swift:93-99`), recalculated on init via `recalculatePlayableCacheSizes()`. This is the number `settings.user.cacheLimit` is compared against for the auto-abort gate.

### Background session, not `BGTaskScheduler`

Amperfy uses `URLSessionConfiguration.background(withIdentifier:)` — **not** `BGTaskScheduler`. iOS manages the background transfer lifecycle natively. The app hook is `urlSessionDidFinishEvents(forBackgroundURLSession:)` (`DownloadManagerSessionExtension.swift:106`), which calls the app's previously-registered `backgroundFetchCompletionHandler` once all pending tasks have dispatched their events. The `AmperfyAppDelegate` handles `application(_:handleEventsForBackgroundURLSession:completionHandler:)` and forwards the handler via `setBackgroundFetchCompletionHandler`.

### Concurrency, retry, suspend/resume, offline-aware

- **Concurrency** — 4 parallel downloads for playables, set on `OperationQueue.maxConcurrentOperationCount` at `initialize(...)` time. Hard-coded per-delegate via `parallelDownloadsCount: Int { get }`. Not dynamic.
- **Retry** — not explicit. `resetFailedDownloads()` (`DownloadManager.swift:329`) walks `DownloadMO` rows where `errorDate != nil`, resets them to pending, and re-enqueues. Called from UI or on network-reconnect. **No automatic exponential-backoff, no per-row attempt counter.** One failure moves a row into the failed bucket until the user (or a reconnect) re-triggers.
- **Suspend/resume** — `suspendDownloads()` marks active rows via `download.suspend()` in Core Data and cancels `URLSessionTask`s; `start()` re-runs `setupDownloadQueue()` which scans `getRequestedDownloads()` and enqueues fresh `DownloadOperation`s for everything pending. **Restarts from scratch, not from partial byte offsets** — iOS background sessions can resume partials at the OS layer, but the app-visible state is "cancel and re-start."
- **Offline-aware** — `networkStatusChanged(notification:)` (`DownloadManager.swift:526`) observes `.offlineModeChanged` + `.networkStatusChanged` via `NotificationHandler`. Online-and-running → `setupDownloadQueue()`. Offline → `suspendDownloads()`. **Automatic.**
- **Cancel** — `cancelDownloads()` calls `taskQueue.cancelAllOperations()` + cancels active `URLSessionTask`s + `requestManager.cancelDownloads()` (marks MO rows `isCanceled = true`). Rows stay in the DB as "canceled."

### Cost to extend — worked example: "per-file bitrate transcoding pass before cache"

The natural customization point is a new `DownloadManagerDelegate`, not a new `DownloadManager`. Two shapes of work:

1. **Modify `PlayableDownloadDelegate.completedDownload(...)` in place.** Cleanest if the transcoding is always wanted for playables. Insert the transcode between `storage.performAndGet { playable.info }` and `savePlayableData(...)`. **1 file, ~30–60 lines.** No protocol changes. Risk: blocks the operation queue slot while transcoding — effective parallelism drops if transcoding is slow.
2. **New dedicated `DownloadManager` + delegate for transcoded playables.** If transcoding is opt-in or varies by account/format: write a `TranscodingPlayableDownloadDelegate: DownloadManagerDelegate` with its own `requestPredicate` (new enum case on `DownloadElementInfo.type`, or a new `DownloadMO` flag), instantiate a third `DownloadManager` in `MetaManager.swift` with its own background session identifier `.Transcoded.background`, route transcoding-eligible songs to `transcodedDownloadManager.download(object:)` via a fork in the UI callsite. **~5 files, ~80–120 lines**, possibly + a v50 schema bump if you need new partitioning state. Isolation benefit: transcoding failures don't block regular playable downloads.

**Cheaper customization points** (when the feature is more about cache policy than transcoding):

- Change cache path scheme → `CacheFileManager.shared.createRelPath(for:)` (one file, one method).
- Change per-account limit semantics → `DownloadManager.storageExceedsCacheLimit()` + the cache-size table in `CacheFileManager`.
- Add progress reporting for a specific view → uncomment the `didWriteData` delegate, aggregate in-memory (**NOT** Core Data — the author already burned on that), expose via a subscribe-to-actor observable from `DownloadManager`.

---

## Add-a-new-view-and-query recipe (Recipe A)

The spike's central question. Worked example shared across all three explorers for cross-app comparison: **"Recently Added Albums (last 30 days)"** — library view showing albums added in the last 30 days, sorted descending by add date, paginated, live-reactive to background sync.

### Honest grounding: the brief's premise has a schema gap

Before walking the recipe, one correction the spec glosses over: **`Album.addedDate` does not exist** in the v49 model. The brief assumed v46 added it, but v46's actual comment in `CoreDataMigrationVersion.swift:58` is "Add addedDate for songs" — it's on `Song`, not `Album`. The `Album` entity's time-axis fields are `newestIndex` / `recentIndex` (both `Int16`, ordering indices stamped by `SubsonicLibrarySyncer.syncNewestAlbums` / `syncRecentAlbums` via `Album.updateIsNewestInfo(index:)` at `AmperfyKit/Storage/EntityWrappers/Album.swift:116-123`) — not dates. Subsonic's `getAlbumList2?type=newest` response carries the underlying timestamp as a `created` XML attribute which `SsAlbumParserDelegate` (`AmperfyKit/Api/Subsonic/SsAlbumParserDelegate.swift:48-117`) reads `name` / `year` / `coverArt` / `artistId` / `genre` from but **does not currently read `created` from**.

This materially shapes the recipe. There are two honest paths for "Recently Added Albums":

- **Path A (no schema)**: reuse the existing `syncNewestAlbums(offset:count:)` + filter by `newestIndex > 0` + sort by `newestIndex` ascending. **No schema change, no parser change, no sync change.** Gives you "top N newest as reported by the server," but *cannot* enforce a "last 30 days" cutoff because there's no date on the Album to compare against. It's an ordering list, not a date range.
- **Path B (single-attribute schema add)**: add `Album.addedDate: Date?` via a v50 bundle (inferred mapping handles it), teach `SsAlbumParserDelegate` to read `attributeDict["created"]`, and write an FRC predicate on `addedDate >= now - 30d`. **Gives you the true "last 30 days" semantics** the brief asked for.

Both paths are walked below so a future maintainer sees the trade-off.

### Path B walkthrough — "Recently Added Albums (last 30 days)"

#### Step 0: Schema — add `Album.addedDate: Date?` (v50)

**Files touched:**

1. `AmperfyKit/Storage/ManagedObjects/Amperfy.xcdatamodeld/Amperfy v50.xcdatamodel/` — new bundle (copy v49, add one attribute). In the `Album` entity:
   ```xml
   <attribute name="addedDate" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
   ```
2. `AmperfyKit/Storage/ManagedObjects/Amperfy.xcdatamodeld/.xccurrentversion` — point at v50.
3. `AmperfyKit/Storage/ManagedObjects/Migration/CoreDataMigrationVersion.swift`:
   ```swift
   case v50 = "Amperfy v50" // Add addedDate for albums
   ```
   And in the `nextVersion()` switch:
   ```swift
   case .v49:
     return .v50
   case .v50:
     return nil
   ```

**No mapping model.** `CoreDataMigrationStep.swift:36-52` will fall back to `NSMappingModel.inferredMappingModel(...)` because no `MappingModelV49toV50.xcmappingmodel` exists. This is the happy path; proof is in the siblings — v42-v49 all shipped this way for similar attribute/entity adds.

**Cost:** 2–3 files, ~10 lines of actual edit diff. No custom `NSEntityMigrationPolicy` subclass. Existing installs migrate silently on next launch.

#### Step 1: Parser — teach `SsAlbumParserDelegate` to read `created`

**File touched:** `AmperfyKit/Api/Subsonic/SsAlbumParserDelegate.swift:48-117` (`parser(_:didStartElement:...)`). Add one block alongside the existing `attributeDict["year"]` / `attributeDict["songCount"]` reads:

```swift
if let createdString = attributeDict["created"],
   let createdDate = ISO8601DateFormatter().date(from: createdString) {
  albumBuffer?.addedDate = createdDate
}
```

Subsonic's `created` attribute is an ISO8601 timestamp — OpenSubsonic 1.10.2+ servers (including all current Navidrome versions) populate it on album responses. We'd also need a setter on `Album.swift` (`AmperfyKit/Storage/EntityWrappers/Album.swift`) exposing `addedDate` through the `AlbumMO` property — one trivial computed var, ~4 lines:

```swift
public var addedDate: Date? {
  get { managedObject.addedDate }
  set { managedObject.addedDate = newValue }
}
```

**Cost:** 2 files, ~8 lines.

#### Step 2: Sync — REUSE `syncNewestAlbums`

**Files touched: 0.** `SubsonicLibrarySyncer.syncNewestAlbums(offset:count:)` (`SubsonicLibrarySyncer.swift:636-668`) already fetches `getAlbumList2?type=newest` and pipes the response through `SsAlbumParserDelegate`. Because Step 1 taught the parser to read `created`, the sync now populates `Album.addedDate` on every existing and future call — including the `syncNewestAlbums` that runs on library initial sync. **No new protocol method, no `LibrarySyncerProxy` forwarder, no `AmpacheLibrarySyncer` stub, no new HTTP endpoint.**

This is the Amperfy ergonomic bonus the "4-file recipe" shorthand understated: once the schema has the field, every existing sync method that already parses the entity gets the new field populated "for free" just by taking the parser-delegate edit. The "4 files per new query" recipe applies to genuinely new queries; this is actually closer to a "1 schema + 1 parser edit + 2 UI files" recipe because the sync already exists.

#### Step 3: FRC subclass — `RecentlyAddedAlbumsFetchedResultsController`

**File touched:** `AmperfyKit/Storage/ResultController/FetchedResultsControllers.swift` (new subclass, ~25 lines appended). Follows the `AlbumFetchedResultsController` template verbatim, diverging only on sort and predicate:

```swift
public class RecentlyAddedAlbumsFetchedResultsController: CachedFetchedResultsController<AlbumMO> {
  public init(coreDataCompanion: CoreDataCompanion, account: Account, windowDays: Int = 30) {
    let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())!
    let fetchRequest: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
    fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(AlbumMO.addedDate), ascending: false)]
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
      NSPredicate(format: "%K >= %@", #keyPath(AlbumMO.addedDate), cutoff as NSDate),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = AlbumMO.relationshipKeyPathsForPrefetching
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: false,
      sectionIndexType: .none
    )
  }
}
```

Pagination is already handled by `NSFetchedResultsController`'s native `fetchBatchSize` + lazy fault loading — set `fetchRequest.fetchBatchSize = 40` and UIKit/SwiftUI only materializes the visible rows. No manual offset/limit math.

**Cost:** 1 file, ~25 lines. **Optional** — if you go SwiftUI-first with `@FetchRequest`, Step 3 is not required (see Step 4).

#### Step 4: View — SwiftUI via `UIHostingController`

Two file touches: a new SwiftUI view + a new host VC.

**New file:** `Amperfy/SwiftUI/Library/RecentlyAddedAlbumsView.swift` (~40 lines):

```swift
import SwiftUI
import CoreData
import AmperfyKit

struct RecentlyAddedAlbumsView: View {
  @FetchRequest private var albums: FetchedResults<AlbumMO>

  init(windowDays: Int = 30) {
    let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())!
    _albums = FetchRequest(
      sortDescriptors: [SortDescriptor(\.addedDate, order: .reverse)],
      predicate: NSPredicate(format: "%K >= %@", #keyPath(AlbumMO.addedDate), cutoff as NSDate),
      animation: .default
    )
  }

  var body: some View {
    List(albums, id: \.objectID) { albumMO in
      let album = Album(managedObject: albumMO)
      AlbumRow(album: album)
    }
    .navigationTitle("Recently Added")
  }
}
```

Note we can use SwiftUI's native `@FetchRequest` directly — we do **not** need the `RecentlyAddedAlbumsFetchedResultsController` subclass from Step 3 for the SwiftUI path. The FRC subclass is only useful if the view is UIKit (`SingleFetchedResultsTableViewController<AlbumMO>`), or if you want the predicate reusable from both SwiftUI and UIKit, or if you want `CachedFetchedResultsController`'s search-mode preservation. **For a SwiftUI-first recipe, Step 3 is optional.**

**New file:** `Amperfy/Screens/ViewController/RecentlyAddedAlbumsHostVC.swift` (~30 lines, boilerplate copy of `SettingsHostVC`):

```swift
import SwiftUI
import UIKit
import AmperfyKit

class RecentlyAddedAlbumsHostVC: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    let rootView = RecentlyAddedAlbumsView()
      .environment(\.managedObjectContext, appDelegate.storage.main.context)
    let hostingVC = UIHostingController(rootView: rootView)
    hostingVC.view.frame = view.bounds
    hostingVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addChild(hostingVC)
    view.addSubview(hostingVC.view)
    hostingVC.didMove(toParent: self)
  }
}
```

The critical line is `.environment(\.managedObjectContext, appDelegate.storage.main.context)` — this is the in-tree pattern confirmed via `SettingsHostVC` and `LargeCurrentlyPlayingPlayerView`.

**Cost:** 2 files, ~70 lines total.

#### Step 5: Entry point — wire from existing library UI

One edit in the existing library tab's navigation. In `Amperfy/Screens/ViewController/LibraryVC.swift` (or wherever the library menu lives), add a new row that pushes `RecentlyAddedAlbumsHostVC()`. **Cost: ~5 lines in one existing file.**

#### Total cost tally for Path B

| Step | File | New or existing | Lines |
|---|---|---|---|
| 0a | `Amperfy v50.xcdatamodel/` | **new** | bundle copy + 1 attribute |
| 0b | `.xccurrentversion` | existing | 1 line |
| 0c | `CoreDataMigrationVersion.swift` | existing | 3 lines |
| 1a | `SsAlbumParserDelegate.swift` | existing | ~5 lines |
| 1b | `Album.swift` (EntityWrapper) | existing | ~4 lines |
| 2 | `SubsonicLibrarySyncer.swift` | untouched | 0 |
| 3 | `FetchedResultsControllers.swift` | existing | ~25 lines **(optional if SwiftUI-only)** |
| 4a | `RecentlyAddedAlbumsView.swift` | **new** | ~40 lines |
| 4b | `RecentlyAddedAlbumsHostVC.swift` | **new** | ~30 lines |
| 5 | library menu VC | existing | ~5 lines |

**6 file touches (7 if Step 3 FRC subclass is kept), 3 new files, ~115 lines of new code total, one schema bump via inferred mapping.**

#### One-time wiring cost vs per-feature cost

The **one-time infra** Amperfy gave us for free, that does NOT recur per feature:

- Background-context save → main-context merge → FRC delegate → view diff chain (the reactivity loop above)
- `UIHostingController` + `.environment(\.managedObjectContext, ...)` pattern (one copy-paste boilerplate per host VC, but no new infra)
- `CachedFetchedResultsController` search-preservation + section-index + alphabetic-header plumbing

The **per-feature cost** was the ~115 lines above.

### Path A — the "reuse `newestIndex`" alternative (no schema)

If we accept "top N newest per server, no date cutoff" semantics:

- Steps 0, 1, 2 are all zero files (sync and parser already exist).
- Step 3: FRC subclass uses existing `AlbumMO.newestSortedFetchRequest` (static factory on the MO) + predicate `newestIndex > 0`. The existing `AlbumFetchedResultsController` at `FetchedResultsControllers.swift` with `sortType: .newest` already does exactly this — so Step 3 is also zero files if we reuse.
- Step 4: SwiftUI view identical shape with `@FetchRequest(sortDescriptors: [SortDescriptor(\.newestIndex)], predicate: NSPredicate(format: "newestIndex > 0"))`.
- Step 5: same entry-point wiring.

**Path A total: ~70 lines, 2 new files, zero schema, zero parser, zero sync.** This is the Amperfy ergonomic peak — when the data is already in the schema and a sync already populates it, adding a new view is genuinely a 2-file change. **This is the headline number** for the cross-app comparison and is what "Recently Added" should actually ship as, unless the "last 30 days" date cutoff is a hard product requirement.

### Pressure-test examples

#### Easy case — "Songs with play count > N"

**Zero schema work.** `AbstractLibraryEntity.playCount: Int32` already exists (`Amperfy v49.xcdatamodel/contents` line 8), inherited by `Song`. Sync is already populated by every `syncXxxSongs` call that runs through `SsSongParserDelegate`. Files touched:

1. `FetchedResultsControllers.swift` — one `SongsWithPlayCountAboveFetchedResultsController` subclass (~20 lines, predicate `playCount > %d`, sort by `playCount` desc). **Optional** — could be inlined into the SwiftUI view instead.
2. New SwiftUI view `HighRotationSongsView.swift` (~40 lines, `@FetchRequest(sortDescriptors: [.init(\.playCount, order: .reverse)], predicate: NSPredicate(format: "playCount > %d", threshold))`).
3. New host VC (~30 lines, `SettingsHostVC` boilerplate).
4. Entry-point wire (~5 lines in library menu VC).

**Total: ~95 lines, 2 new files, zero schema, zero parser, zero sync, zero `LibrarySyncer` protocol touches.** This is the **floor** of the Amperfy add-a-view cost curve.

#### Medium case — "Tag an album with a user-supplied string"

**Single-attribute schema add with a user-driven write path** (as opposed to Path B above, which wrote from server data). Touches:

1. `Amperfy v50.xcdatamodel/` — new bundle with `Album.userTag: String?` attribute.
2. `.xccurrentversion` + `CoreDataMigrationVersion.swift` — v50 enum + switch case. Inferred mapping handles it.
3. `AmperfyKit/Storage/EntityWrappers/Album.swift` — `userTag` computed var bridging to `AlbumMO.userTag`.
4. SwiftUI view (or UIKit VC) presenting an edit sheet + writing via the main `viewContext`: `album.userTag = newValue; storage.main.library.saveContext()`. **No sync, no REST call, no parser edit** — this is a local-only field, not mirrored from the server. Amperfy's main context accepts direct writes from UI; the FRC-reactive pipeline handles the read side automatically.
5. Optional: `UserTaggedAlbumsFetchedResultsController` subclass for a "My Tagged Albums" view (`predicate: userTag != nil`).
6. Entry-point wire.

**Total: ~100–130 lines across ~5–6 files. Still no custom `.xcmappingmodel` — the user-tag attribute is a pure additive field.** This is the case that would have triggered the "mapping model required" overstatement from the Day 2 paragraph; in reality inferred mapping handles it just like v46–v49 did for `addedDate`, `replayGain`, `peak`, `account`, `apiType`.

#### Worst case (brief) — data-transforming / restructural migration

**Trigger:** splitting a column, merging two entities, renaming a non-renaming-identifier field, migrating a unique constraint. **Not triggered** by adding a field, adding an entity, or adding a relationship.

**Shape of the work** (reference only, no walkthrough): new `v50.xcdatamodel` + **custom** `.xcmappingmodel` in `VersionMappings/` + an `NSEntityMigrationPolicy` subclass (use `AmperfyKit/Storage/ManagedObjects/VersionMappings/MigrationPolicyV4toV5.swift` as the in-tree template — it's the only real working example of the pattern). The policy subclass overrides `createDestinationInstances(forSource:in:manager:)` and/or `endInstanceCreation(forMapping:manager:)` to emit custom Swift logic during the migration pass. **Two custom mapping models exist in the whole project across 49 versions** — V4→V5 and V10→V11 — so the frequency is roughly "once per multi-year restructure" in upstream history.

**Relevance to this spike:** for any custom feature we're plausibly shipping on the fork (new library views, new remote queries, new per-album metadata), **we are not in this case**. The worst case is reserved for schema rewrites, which is a design decision we'd opt into, not one the query layer forces on us.

### Cost curve summary — Amperfy's add-a-view cost profile

| Scenario | New files | Total lines | Schema bump? | Sync change? | LibrarySyncer protocol? |
|---|---|---|---|---|---|
| Data in schema + sync already populates + new predicate | 2 | ~70 | no | no | no |
| Data in schema but needs server-populated new sync | 2–3 | ~100–150 | no | yes | yes |
| Data not in schema (additive attribute) | 3 | ~115 | v50 inferred | 0 or reuse | 0 or reuse |
| Data not in schema (additive entity) | 4–5 | ~180 | v50 inferred | yes | yes |
| Data not in schema + restructure required | 4–6 | ~300+ | v50 + custom mapping + policy | likely | likely |

The "4 files per new query" shorthand from the Day 2 paragraph is a rough midpoint of this curve. For the kind of custom features realistically planned on this fork, we'll mostly live in rows 1–3 — the cost profile is closer to "2–3 new files per view" than "full Subsonic protocol dance per query."

---

## Brief-error pedagogical note

The Day 3 recipe brief asserted `Album.addedDate` exists per migration v46. **It doesn't** — v46 added `addedDate` to `Song`, not `Album`. This is not a criticism of the brief; it's a lesson worth encoding in this primer for any future coordinator or explorer agent working on this codebase:

**Before trusting any schema assertion ("entity X has attribute Y"), verify it against `AmperfyKit/Storage/ManagedObjects/Amperfy.xcdatamodeld/Amperfy v49.xcdatamodel/contents`.** That file is plain XML; grep for the attribute name in under a minute. `CoreDataMigrationVersion.swift` comments are hints, not specifications — they describe the *intent* of a migration at the time it shipped, and may refer to different entities than a reader assumes.

The upside of catching the gap was that Recipe A could be walked honestly with both Path A (zero schema) and Path B (schema add) side-by-side — which is a stronger recipe than the single-path walkthrough the brief originally asked for. The lesson: **schema verification is cheap; acting on an unverified schema claim is not.**

---

## Build instructions

### Canonical simulator build

```bash
cd /Users/olivier/sites/navidromClient/spike/amperfy && \
xcodebuild \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

**Do not drop `CODE_SIGNING_ALLOWED=NO`** even for simulator — even after Olivier's rebrand, the entitlements surface (historically CarPlay + Siri; now stripped) + the hard-coded `DEVELOPMENT_TEAM` can still force codesigning attempts that need a physical keychain.

- Package resolution happens automatically on first `xcodebuild` invocation; no separate `-resolvePackageDependencies` is needed.
- Build output lives under `~/Library/Developer/Xcode/DerivedData/Amperfy-<hash>/Build/Products/Debug-iphonesimulator/Amperfy.app`.

### Simulator install + launch

```bash
UDID="98708B27-338E-4D69-80F3-BDC81AA10FF6"  # iPhone 17, iOS 26.4 (change to your own UDID)
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b   # wait for first-boot data migration (~2 min cold)
xcrun simctl install "$UDID" ~/Library/Developer/Xcode/DerivedData/Amperfy-<hash>/Build/Products/Debug-iphonesimulator/Amperfy.app
xcrun simctl launch "$UDID" dev.thisolivier.amperfy
```

The bundle identifier is `dev.thisolivier.amperfy` in the working-tree rebrand (upstream was `de.familie-zimba.amperfy-music`).

### Device-build prerequisites (already applied to the working tree)

Olivier's rebrand, visible as uncommitted edits on `Amperfy.xcodeproj/project.pbxproj` and `Amperfy/Amperfy.entitlements`:

- `DEVELOPMENT_TEAM` changed from upstream `U3R6D65S8W` → `CNHB9B5GX6`.
- Bundle identifiers re-namespaced:
  - App: `dev.thisolivier.amperfy`
  - Kit: `dev.thisolivier.amperfy.AmperfyKit`
  - Tests: `dev.thisolivier.amperfy.AmperfyKitTests` (upstream `de.familie-zimba.AmpertyKitTests` typo fixed in passing)
- `Amperfy.entitlements`: `com.apple.developer.carplay-audio` and `com.apple.developer.siri` removed (both require special Apple approval that a personal team cannot sign).

**These files are in the signing agent's territory. Do not touch them from explorer work.**

---

## Test commands

Amperfy is the **only** of the three spike apps with a real test target — `AmperfyKitTests` under `AmperfyKitTests/Cases/` mirroring the kit's layout (`API/`, `Common/`, `Player/`, `Storage/`).

```bash
# Kit tests (the real suite)
xcodebuild test \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' \
  -only-testing:AmperfyKitTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

`xcodebuild -list` does not surface a dedicated test scheme, so tests run through the `Amperfy` scheme's test action. If the `Amperfy.xcscheme` test-action wiring ever drifts, check `Amperfy.xcodeproj/xcshareddata/xcschemes/Amperfy.xcscheme` for the `<TestAction>` block.

> **Note:** tests were NOT executed during Phase B exploration (per hard rule "no tests run, no builds run, no network calls"). The command above is the documented invocation, not a verified-green run.

A separate `DominantColorsTests` scheme exists — that's the DCLib SPM dependency's own suite, not ours.

---

## Code style / formatter

- **`.swiftformat`** at the repo root enforces **Google Swift Style**.
- **`BuildTools/`** contains a SwiftFormat runner as a standalone SwiftPM package:
  - `BuildTools/Package.swift` declares the SwiftFormat executable dependency.
  - `BuildTools/applyFormat.sh` is the invocation script for running it against the source tree.
- **`Helper/add-license-header.sh`** stamps the GPL-3.0 header on new files using the in-tree template.

New code should match existing style (verbose variable names, 2-space indentation, trailing commas on multi-line literals). Run `BuildTools/applyFormat.sh` before proposing any diff.

---

## Known footguns

From Days 1–3 exploration:

1. **`DownloadMO` predicate partitioning is a landmine.** Two `DownloadManager` instances share one SQL table; partition is enforced purely by each delegate's `requestPredicate`. A permissive predicate (e.g. `NSPredicate(value: true)`) on a new delegate would scoop other managers' rows. Keep every new `DownloadManagerDelegate.requestPredicate` as narrow as the delegate's scope.
2. **`LibrarySyncer` protocol changes have a 3-place ceremony tax.** Every new method on the protocol requires:
   - Implementation in `SubsonicLibrarySyncer`
   - Forwarder line in `LibrarySyncerProxy`
   - Stub in `AmpacheLibrarySyncer` (usually `throw BackendError.notImplemented` or an empty return)
   Skipping the Ampache stub breaks the build of the whole kit. Footgun discovery is fast (compile-time), but easy to forget on first iteration.
3. **Per-byte download progress is deliberately absent.** `DownloadManagerSessionExtension.swift:96-104` has `didWriteData` commented out with the note "ignore progress: don't save progress in CoreData -> huge CPU load." Any feature wanting a progress bar per row must **not** re-enable that delegate with Core Data writes — use in-memory state. See the Download manager section for the full workaround.
4. **The `V4toV5` / `V10toV11` custom mapping models are reserved for structural rewrites.** The vast majority of schema work rides `NSMappingModel.inferredMappingModel` via `CoreDataMigrationStep.swift:36-52`. Do not assume a new attribute needs a hand-written mapping model — it almost never does.
5. **Parallel Ampache stack under `AmperfyKit/Api/Ampache/`.** Only Subsonic matters for Navidrome, but the `LibrarySyncerProxy` / `BackendProxy` abstraction means every sync-layer change has two sides to touch *or* explicitly not touch. Do not wire a Navidrome-specific feature into Ampache-only code by accident — add the Ampache stub and move on.
6. **`DebugCoreData` is a real scheme,** separate from the `Amperfy` app. It's probably the fastest "look at what's in the local DB" tool for any future feature work. Worth launching via Xcode before hand-writing any Core Data inspection code.
7. **The test file is still named `AmpertyKitTests.swift`** (with the `t`) inside `AmperfyKitTests/`, even though the bundle-ID typo was fixed in pbxproj. Cosmetic; not a bug.
8. **Stale `IPHONEOS_DEPLOYMENT_TARGET = 15.0` rows** still live in `project.pbxproj` near lines 2981 and 3043, coexisting with the real `26.0` values. Doesn't break the build but will confuse tooling that reads the first match.
9. **`shouldInferMappingModelAutomatically = false` is a misdirection.** The top-level flag is false, but `CoreDataMigrationStep` manually invokes `NSMappingModel.inferredMappingModel(...)` as its fallback. Reading the flag in isolation suggests every migration needs a hand-written mapping model — reading the migration step reveals that only restructures do.
10. **Simulator first-boot data migration is slow** (~2 min cold for iOS 26.4 on this machine). Always wait on `xcrun simctl bootstatus <udid> -b` rather than racing `simctl install`.

---

## Doc corrections

Corrections to `docs/initialContext.md` that this spike surfaced:

- **"Amperfy is pure UIKit, not SwiftUI"** → **Amperfy is UIKit-first but has an in-tree SwiftUI sub-tree** under `Amperfy/SwiftUI/` (`Basics/` + `Settings/`), and SwiftUI-via-`UIHostingController` is an already-idiomatic confirmed-in-tree add-a-view path. Precedent: `Amperfy/Screens/ViewController/SettingsHostVC.swift` (shipped SwiftUI settings panel) and `LargeCurrentlyPlayingPlayerView.swift:91,99` (hosting calls). The critical plumbing — `.environment(\.managedObjectContext, appDelegate.storage.main.context)` — is already wired, so SwiftUI `@FetchRequest` works natively inside any hosted view. For the spike's add-a-view recipe, the SwiftUI-first path is recommended.
- **"Amperfy's 49 Core Data migrations imply a hand-written mapping model per feature add"** (Day 2 framing from this primer's author, now retracted) → **48 of the 49 migrations ride `NSMappingModel.inferredMappingModel` via the fallback in `CoreDataMigrationStep.swift:36-52`.** Only 2 custom `.xcmappingmodel` bundles exist (`V4→V5`, `V10→V11`), both triggered by structural rewrites. Additive feature work (new attribute, new entity, new relationship) does not need a custom mapping model or an `NSEntityMigrationPolicy` subclass. See the "Schema-extension cost profile" subsection for the full correction.
- **License framing — no change needed, just reconfirmation.** `docs/initialContext.md` correctly calls Amperfy GPL-3.0. Any redistributable fork stays GPL-3.0; personal-device builds are unrestricted.

---

_End of primer. See `spike/amperfy/.spike/NOTES.md` for the full Day 1–3 scratch, including the raw exploration notes this primer was synthesized from._
