//
//  SmartPlaylistRefresherTest.swift
//  AmperfyKitTests
//
//  Copyright (c) 2026 Olivier Butler. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

@testable import AmperfyKit
import CoreData
import XCTest

// MARK: - RECORDING_SmartPlaylistBackfillSyncer

/// A `LibrarySyncer` that records which albums the backfill decided to fetch
/// songs for, and which `getAlbumList2 type=newest` pages it asked for. All
/// other protocol methods are inert stubs.
///
/// The codebase has no shared recording mock (house convention is "define the
/// mock in the test that needs it" — see `RECORDING_PlaylistAddSyncer`), so the
/// backfill gets its own.
@MainActor
final class RECORDING_SmartPlaylistBackfillSyncer: LibrarySyncer {
  private(set) var syncedAlbumIds: [String] = []
  private(set) var newestAlbumPageOffsets: [Int] = []
  private(set) var albumListPageOffsets: [Int] = []

  /// Stands in for the server's full album listing. The test supplies the
  /// closure, which does the two things the real parser does: apply the
  /// server's current truth (`remoteSongCount`) to the local albums on that
  /// page, and report how many albums the page held so the caller can page to
  /// the end. Left nil, the listing is empty.
  var albumListPageResponder: ((_ offset: Int, _ count: Int) -> Int)?

  func sync(album: Album) async throws {
    syncedAlbumIds.append(album.id)
  }

  func syncNewestAlbums(offset: Int, count: Int) async throws {
    newestAlbumPageOffsets.append(offset)
  }

  func syncAlbumListPage(offset: Int, count: Int) async throws -> Int {
    albumListPageOffsets.append(offset)
    return albumListPageResponder?(offset, count) ?? 0
  }

  // MARK: Inert stubs

  func syncInitial(statusNotifyier: SyncCallbacks?) async throws {}
  func sync(genre: Genre) async throws {}
  func sync(artist: Artist) async throws {}
  func sync(song: Song) async throws {}
  func sync(podcast: Podcast) async throws {}
  func syncNewestPodcastEpisodes() async throws {}
  func syncRecentAlbums(offset: Int, count: Int) async throws {}
  func syncFavoriteLibraryElements() async throws {}
  func syncRadios() async throws {}
  func syncDownPlaylistsWithoutSongs() async throws {}
  func syncDown(playlist: Playlist) async throws {}
  func syncUpload(playlistToUpdateName playlist: Playlist) async throws {}
  func syncUpload(playlistToAddSongs playlist: Playlist, songs: [Song]) async throws {}
  func syncUpload(playlistToDeleteSong playlist: Playlist, index: Int) async throws {}
  func syncUpload(playlistToUpdateOrder playlist: Playlist) async throws {}
  func syncUpload(playlistIdToDelete id: String) async throws {}
  func syncDownPodcastsWithoutEpisodes() async throws {}
  func searchArtists(searchText: String) async throws {}
  func searchAlbums(searchText: String) async throws {}
  func searchSongs(searchText: String) async throws {}
  func syncMusicFolders() async throws {}
  func syncIndexes(musicFolder: MusicFolder) async throws {}
  func sync(directory: Directory) async throws {}
  func requestRandomSongs(playlist: Playlist, count: Int) async throws {}
  func requestSimilarSongs(song: Song, count: Int) async throws -> [Song] { [] }
  func requestPodcastEpisodeDelete(podcastEpisode: PodcastEpisode) async throws {}
  func syncNowPlaying(song: Song, songPosition: NowPlayingSongPosition) async throws {}
  func scrobble(song: Song, date: Date?) async throws {}
  func setRating(song: Song, rating: Int) async throws {}
  func setRating(album: Album, rating: Int) async throws {}
  func setRating(artist: Artist, rating: Int) async throws {}
  func setFavorite(song: Song, isFavorite: Bool) async throws {}
  func setFavorite(album: Album, isFavorite: Bool) async throws {}
  func setFavorite(artist: Artist, isFavorite: Bool) async throws {}
  func parseLyrics(relFilePath: URL) async throws -> LyricsList { LyricsList() }
}

// MARK: - SmartPlaylistRefresherTest

/// Covers the V1.5 addendum §3 backfill fix: the decision of WHICH albums get
/// their songs fetched must be driven by song-level facts, not by the
/// album-created ordering of `getAlbumList2 type=newest`.
@MainActor
class SmartPlaylistRefresherTest: XCTestCase {
  var coreDataHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var syncer: RECORDING_SmartPlaylistBackfillSyncer!
  var storage: CoreDataCompanion!
  var store: SmartPlaylistStore!
  var syncTracker: PlaylistItemsSyncTracker!

  let nowReference = Date(timeIntervalSince1970: 1_750_000_000)
  let dayInSeconds = 86_400.0

  override func setUp() async throws {
    coreDataHelper = CoreDataHelper()
    library = coreDataHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    syncer = RECORDING_SmartPlaylistBackfillSyncer()
    storage = CoreDataCompanion(context: testContext)
    store = SmartPlaylistStore(
      defaults: UserDefaults(suiteName: "SmartPlaylistRefresherTest-\(UUID().uuidString)")!
    )
    syncTracker = PlaylistItemsSyncTracker(
      defaults: UserDefaults(suiteName: "SmartPlaylistRefresherTracker-\(UUID().uuidString)")!
    )
    // The shared seeder inserts albums and songs of its own; the backfill picks
    // its candidates from the WHOLE library, so start from an empty one.
    removeAllSongsAndAlbums()
  }

  override func tearDown() {}

  // MARK: - Helpers

  private var testContext: NSManagedObjectContext {
    coreDataHelper.persistentContainer.viewContext
  }

  private func removeAllSongsAndAlbums() {
    let songFetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    for song in (try? testContext.fetch(songFetchRequest)) ?? [] {
      testContext.delete(song)
    }
    let albumFetchRequest: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
    for album in (try? testContext.fetch(albumFetchRequest)) ?? [] {
      testContext.delete(album)
    }
    library.saveContext()
  }

  private func makeRefresher() -> SmartPlaylistRefresher {
    SmartPlaylistRefresher(
      storage: storage,
      librarySyncer: syncer,
      account: account,
      store: store,
      playlistItemsSyncTracker: syncTracker
    )
  }

  /// An album that has been song-synced already. `newestListingIndex` places it
  /// in the `getAlbumList2 type=newest` listing (0 = absent from it, which is
  /// how an OLD album looks); `remoteSongCount` is what the server says it
  /// holds; `localSongsAddedDaysAgo` seeds the songs we actually hold.
  @discardableResult
  private func makeSyncedAlbum(
    id: String,
    newestListingIndex: Int,
    remoteSongCount: Int,
    localSongsAddedDaysAgo: [Double?]
  )
    -> Album {
    let album = library.createAlbum(account: account)
    album.id = id
    album.name = id
    album.isSongsMetaDataSynced = true
    album.remoteSongCount = remoteSongCount
    album.updateIsNewestInfo(index: newestListingIndex)
    for (songIndex, addedDaysAgo) in localSongsAddedDaysAgo.enumerated() {
      let song = library.createSong(account: account)
      song.id = "\(id)-song-\(songIndex)"
      song.title = song.id
      song.size = 1024
      song.album = album
      if let addedDaysAgo {
        song.addedDate = nowReference.addingTimeInterval(-addedDaysAgo * dayInSeconds)
      }
    }
    return album
  }

  private func refresh(
    rules: [SmartPlaylistRule],
    isOnline: Bool = true
  ) async
    -> SmartPlaylistRefreshOutcome {
    await makeRefresher().refresh(
      query: SmartPlaylistQuery(rules: rules),
      isOnline: isOnline,
      now: nowReference
    )
  }

  // MARK: - The "Joshua" shape

  /// THE bug this round fixes. Album "Joshua" was created long ago, so it never
  /// appears near the top of a newest-first album listing — but the server has
  /// since gained songs on it. The local library can see that (`remoteSongCount`
  /// exceeds the songs we hold), and the backfill must act on it.
  func testOldAlbumThatGainedSongsIsBackfilled() async {
    makeSyncedAlbum(
      id: "fresh-album",
      newestListingIndex: 1,
      remoteSongCount: 2,
      localSongsAddedDaysAgo: [1, 2]
    )
    makeSyncedAlbum(
      id: "joshua",
      newestListingIndex: 0, // old: absent from the newest listing entirely
      remoteSongCount: 12,
      localSongsAddedDaysAgo: Array(repeating: 150, count: 10)
    )
    library.saveContext()

    await refresh(rules: [.addedWithinDays(30)])

    XCTAssertTrue(syncer.syncedAlbumIds.contains("joshua"))
  }

  /// The complement: an album the server and the local library agree on, whose
  /// songs all carry added-dates, is left alone. The gained-songs scan must not
  /// turn every refresh into a full library re-sync.
  func testCompleteUpToDateAlbumIsNotResynced() async {
    makeSyncedAlbum(
      id: "settled-album",
      newestListingIndex: 0,
      remoteSongCount: 3,
      localSongsAddedDaysAgo: [200, 201, 202]
    )
    library.saveContext()

    await refresh(rules: [.addedWithinDays(30)])

    XCTAssertFalse(syncer.syncedAlbumIds.contains("settled-album"))
  }

  /// Songs whose `addedDate` never parsed (synced before the fractional-seconds
  /// fix) are indistinguishable from "no date" at query time, so their album is
  /// refetched — after the gained-songs albums, which are the stronger signal.
  func testAlbumHoldingUndatedSongsIsBackfilledAfterGainedSongsAlbums() async {
    makeSyncedAlbum(
      id: "undated-album",
      newestListingIndex: 0,
      remoteSongCount: 2,
      localSongsAddedDaysAgo: [nil, 300]
    )
    makeSyncedAlbum(
      id: "gained-album",
      newestListingIndex: 0,
      remoteSongCount: 9,
      localSongsAddedDaysAgo: [100, 101]
    )
    library.saveContext()

    await refresh(rules: [.addedWithinDays(30)])

    XCTAssertEqual(syncer.syncedAlbumIds, ["gained-album", "undated-album"])
  }

  /// An album with no local songs at all is pass 1's business (it walks the
  /// newest listing); the local scan skips it, because on a fresh install that
  /// set is the entire library.
  func testAlbumWithNoLocalSongsIsNotPickedUpByTheLocalScan() async {
    let neverSyncedAlbum = library.createAlbum(account: account)
    neverSyncedAlbum.id = "never-synced"
    neverSyncedAlbum.isSongsMetaDataSynced = false
    neverSyncedAlbum.remoteSongCount = 10
    neverSyncedAlbum.updateIsNewestInfo(index: 0)
    library.saveContext()

    await refresh(rules: [.addedWithinDays(30)])

    XCTAssertFalse(syncer.syncedAlbumIds.contains("never-synced"))
  }

  // MARK: - Album track-count refresh

  /// THE live-QA bug. The local library held `remoteSongCount = 3` for an album
  /// the server has since grown to 4 tracks. Nothing local could tell the
  /// difference — the album is old, so no `newest` page ever returns it and its
  /// count was never rewritten — so the gained-songs scan had no candidate at
  /// all and the new song stayed invisible to "added in the last 7 days"
  /// through refreshes and relaunches alike. The refresh must relearn the count
  /// from the full album listing first, which is what turns the album into a
  /// candidate.
  func testStaleAlbumTrackCountIsRefreshedSoTheGainedSongsScanSeesTheAlbum() async {
    let staleCountAlbum = makeSyncedAlbum(
      id: "stale-count-album",
      newestListingIndex: 0, // old: absent from the newest listing entirely
      remoteSongCount: 3,
      localSongsAddedDaysAgo: [200, 201, 202]
    )
    library.saveContext()

    let libraryStorage = library!
    let testAccount = account!
    syncer.albumListPageResponder = { _, _ in
      // What the parser does with the listing: the server now says 4 tracks.
      libraryStorage.getAlbum(
        for: testAccount,
        id: "stale-count-album",
        isDetailFaultResolution: false
      )?.remoteSongCount = 4
      return 1
    }

    await refresh(rules: [.addedWithinDays(7)])

    XCTAssertEqual(syncer.albumListPageOffsets, [0])
    XCTAssertEqual(staleCountAlbum.remoteSongCount, 4)
    XCTAssertTrue(syncer.syncedAlbumIds.contains("stale-count-album"))
  }

  /// The listing is paged until it runs out — and never past the cap, however
  /// many albums the server claims to have. A refresh is a spinner-blocking
  /// operation, so its request count has to be bounded.
  func testAlbumTrackCountRefreshStopsAtTheCap() async {
    // A listing that never ends: every page comes back full.
    syncer.albumListPageResponder = { _, count in count }

    await refresh(rules: [.addedWithinDays(7)])

    XCTAssertEqual(
      syncer.albumListPageOffsets.count,
      SmartPlaylistRefresher.maxAlbumTrackCountPages
    )
    XCTAssertEqual(
      syncer.albumListPageOffsets.last,
      (SmartPlaylistRefresher.maxAlbumTrackCountPages - 1)
        * SmartPlaylistRefresher.albumTrackCountPageSize
    )
  }

  /// A short page is the end of the listing, so a small library costs exactly
  /// one request.
  func testAlbumTrackCountRefreshStopsAtTheFirstShortPage() async {
    syncer.albumListPageResponder = { _, _ in 12 }

    await refresh(rules: [.addedWithinDays(7)])

    XCTAssertEqual(syncer.albumListPageOffsets, [0])
  }

  // MARK: - Newest-albums walk

  /// Pass 1 still runs and still pages the newest listing.
  func testNewestAlbumsPageIsRequested() async {
    makeSyncedAlbum(
      id: "fresh-album",
      newestListingIndex: 1,
      remoteSongCount: 1,
      localSongsAddedDaysAgo: [1]
    )
    library.saveContext()

    await refresh(rules: [.addedWithinDays(30)])

    XCTAssertEqual(syncer.newestAlbumPageOffsets.first, 0)
  }

  /// The whole backfill is skipped when nothing in the query depends on when a
  /// song was added — a refresh must not spend network on data it will not read.
  func testBackfillIsSkippedWithoutAnAddedWithinRule() async {
    makeSyncedAlbum(
      id: "joshua",
      newestListingIndex: 0,
      remoteSongCount: 12,
      localSongsAddedDaysAgo: Array(repeating: 150, count: 10)
    )
    library.saveContext()

    syncer.albumListPageResponder = { _, _ in 1 }

    let outcome = await refresh(rules: [.played(.never)])

    XCTAssertTrue(syncer.syncedAlbumIds.isEmpty)
    XCTAssertTrue(syncer.newestAlbumPageOffsets.isEmpty)
    XCTAssertTrue(syncer.albumListPageOffsets.isEmpty)
    XCTAssertEqual(outcome.albumsBackfilled, 0)
  }

  /// Offline, a refresh evaluates against whatever is already local and says so
  /// — it never reaches for the network.
  func testOfflineRefreshDoesNoSyncing() async {
    makeSyncedAlbum(
      id: "joshua",
      newestListingIndex: 0,
      remoteSongCount: 12,
      localSongsAddedDaysAgo: Array(repeating: 150, count: 10)
    )
    library.saveContext()
    syncer.albumListPageResponder = { _, _ in 1 }

    let outcome = await refresh(rules: [.addedWithinDays(30)], isOnline: false)

    XCTAssertTrue(syncer.syncedAlbumIds.isEmpty)
    XCTAssertTrue(syncer.newestAlbumPageOffsets.isEmpty)
    XCTAssertTrue(syncer.albumListPageOffsets.isEmpty)
    XCTAssertTrue(outcome.wasOfflineRefresh)
    XCTAssertTrue(outcome.state.wasOfflineRefresh)
  }

  // MARK: - Persistence

  /// The refresh is the only thing that writes the frozen result.
  func testRefreshPersistsTheFrozenResult() async {
    makeSyncedAlbum(
      id: "fresh-album",
      newestListingIndex: 1,
      remoteSongCount: 2,
      localSongsAddedDaysAgo: [1, 2]
    )
    library.saveContext()

    let outcome = await refresh(rules: [.addedWithinDays(30)])

    XCTAssertEqual(store.loadCurrentState()?.frozenSongIds, outcome.state.frozenSongIds)
    XCTAssertEqual(
      Set(outcome.state.frozenSongIds),
      ["fresh-album-song-0", "fresh-album-song-1"]
    )
  }

  /// A grouped query survives the whole refresh path, and its added-within rule
  /// inside a group still triggers the backfill.
  func testGroupedQueryWithAddedWithinRuleInsideAGroupStillBackfills() async {
    makeSyncedAlbum(
      id: "joshua",
      newestListingIndex: 0,
      remoteSongCount: 12,
      localSongsAddedDaysAgo: Array(repeating: 150, count: 10)
    )
    library.saveContext()

    let groupedQuery = SmartPlaylistQuery(items: [
      .group(SmartPlaylistRuleGroup(combinator: .any, rules: [
        .addedWithinDays(30),
        .played(.never),
      ])),
    ])
    await makeRefresher().refresh(query: groupedQuery, isOnline: true, now: nowReference)

    XCTAssertTrue(syncer.syncedAlbumIds.contains("joshua"))
    XCTAssertEqual(store.loadCurrentState()?.query, groupedQuery)
  }
}
