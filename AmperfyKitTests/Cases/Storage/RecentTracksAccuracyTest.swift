//
//  RecentTracksAccuracyTest.swift
//  AmperfyKitTests
//
//  Regression tests for the Recently Added Tracks accuracy epic:
//  - S1: concurrent syncs must never create duplicate SongMO entities for one
//        server song (shared serialized background context in
//        AsyncCoreDataAccessWrapper).
//  - S2: server-side deletions must be detected (songCount change clears
//        isSongsMetaDataSynced; vanished newest albums get verified) and
//        server-deleted songs must be hidden unless locally cached.
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

// MARK: - SPY_LibrarySyncer

/// LibrarySyncer mock that records `sync(album:)` calls, can throw from them,
/// and runs a configurable action when `syncNewestAlbums` is called (to simulate
/// server-side changes to the newest-albums window).
@MainActor
final class SPY_LibrarySyncer: LibrarySyncer {
  var syncedAlbums = [Album]()
  var albumSyncError: Error?
  var albumSyncErrorAlbumIds = Set<String>()
  var onSyncNewestAlbums: (() -> ())?

  func syncInitial(statusNotifyier: SyncCallbacks?) async throws {}
  func sync(genre: Genre) async throws {}
  func sync(artist: Artist) async throws {}
  func sync(album: Album) async throws {
    syncedAlbums.append(album)
    if let albumSyncError, albumSyncErrorAlbumIds.contains(album.id) { throw albumSyncError }
  }

  func sync(song: Song) async throws {}
  func sync(podcast: Podcast) async throws {}
  func syncNewestPodcastEpisodes() async throws {}
  func syncNewestAlbums(offset: Int, count: Int) async throws {
    onSyncNewestAlbums?()
  }

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

// MARK: - RecentTracksAccuracyTest

@MainActor
class RecentTracksAccuracyTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var context: NSManagedObjectContext!
  var library: LibraryStorage!
  var account: Account!
  var storage: PersistentStorage!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    context = cdHelper.createInMemoryManagedObjectContext()
    cdHelper.clearContext(context: context)
    library = LibraryStorage(context: context)
    account = library.getAccount(info: TestAccountInfo.create1())
    library.saveContext()
    storage = PersistentStorage(
      coreDataManager: MOCK_CoreDataManager(persistentContainer: cdHelper.persistentContainer)
    )
  }

  private func fetchSongMOs(id: String) -> [SongMO] {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "id == %@", id)
    return (try? context.fetch(fetchRequest)) ?? []
  }

  // MARK: S1 — duplicate entity creation

  /// Reproduces the production race: several concurrent sync operations each run the
  /// parser's create-if-missing pattern (prefetch by id, create when the prefetch
  /// misses) for the SAME new server song. With per-operation background contexts this
  /// created one SongMO per operation (the transient triplicate in Recently Added);
  /// with the shared serialized context exactly one entity must exist afterwards.
  func testConcurrentCreateIfMissingProducesSingleSongEntity() async throws {
    let songId = "s1-battle-song-id"
    let accountInfo = TestAccountInfo.create1()
    let asyncWrapper = storage.async

    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
      for taskIndex in 0 ..< 8 {
        taskGroup.addTask {
          try await asyncWrapper.perform { asyncCompanion in
            let accountAsync = asyncCompanion.library.getAccount(info: accountInfo)
            var prefetchIDs = LibraryStorage.PrefetchIdContainer()
            prefetchIDs.songIDs = [songId]
            let prefetch = asyncCompanion.library.getElements(
              account: accountAsync,
              prefetchIDs: prefetchIDs
            )
            if prefetch.prefetchedSongDict[songId] == nil {
              let song = asyncCompanion.library.createSong(account: accountAsync)
              song.id = songId
              song.title = "Battle Song \(taskIndex)"
            }
          }
        }
      }
      try await taskGroup.waitForAll()
    }

    XCTAssertEqual(
      fetchSongMOs(id: songId).count,
      1,
      "Concurrent create-if-missing operations must never produce duplicate SongMO rows"
    )
  }

  /// Distinct song ids created concurrently must all survive (serialization must not
  /// swallow or merge unrelated creations).
  func testConcurrentCreationOfDistinctSongsKeepsAll() async throws {
    let accountInfo = TestAccountInfo.create1()
    let asyncWrapper = storage.async
    let songIds = (0 ..< 6).map { "distinct-song-\($0)" }

    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
      for songId in songIds {
        taskGroup.addTask {
          try await asyncWrapper.perform { asyncCompanion in
            let accountAsync = asyncCompanion.library.getAccount(info: accountInfo)
            var prefetchIDs = LibraryStorage.PrefetchIdContainer()
            prefetchIDs.songIDs = [songId]
            let prefetch = asyncCompanion.library.getElements(
              account: accountAsync,
              prefetchIDs: prefetchIDs
            )
            if prefetch.prefetchedSongDict[songId] == nil {
              let song = asyncCompanion.library.createSong(account: accountAsync)
              song.id = songId
              song.title = songId
            }
          }
        }
      }
      try await taskGroup.waitForAll()
    }

    for songId in songIds {
      XCTAssertEqual(fetchSongMOs(id: songId).count, 1, "Song \(songId) must exist exactly once")
    }
  }

  // MARK: S2 — songCount change clears isSongsMetaDataSynced

  private func parseAlbums(xmlData: Data) {
    let idParserDelegate = SsIDsParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    let idParser = XMLParser(data: xmlData)
    idParser.delegate = idParserDelegate
    idParser.parse()
    let prefetch = library.getElements(
      account: account,
      prefetchIDs: idParserDelegate.prefetchIDs
    )
    let parserDelegate = SsAlbumParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor(), prefetch: prefetch, account: account,
      library: library,
      parseNotifier: nil
    )
    let parser = XMLParser(data: xmlData)
    parser.delegate = parserDelegate
    parser.parse()
  }

  func testAlbumParseWithChangedSongCountClearsSongsMetaDataSyncedFlag() throws {
    let xmlData = getTestFileData(name: "artist_example_1")
    parseAlbums(xmlData: xmlData)

    guard let album = library.getAlbum(
      for: account,
      id: "11047",
      isDetailFaultResolution: false
    ) else {
      XCTFail("Fixture album 11047 was not parsed")
      return
    }
    let serverSongCount = album.remoteSongCount
    XCTAssertGreaterThan(serverSongCount, 0)

    // Same song count as server: an already-synced album stays synced.
    album.isSongsMetaDataSynced = true
    parseAlbums(xmlData: xmlData)
    XCTAssertTrue(
      album.isSongsMetaDataSynced,
      "Unchanged songCount must not force a song re-sync"
    )

    // Server-side song set changed (e.g. a track deleted via an admin tool):
    // the local record disagrees with the parsed songCount, so the album must be
    // flagged for a song-level re-sync (which prunes removed songs).
    album.remoteSongCount = serverSongCount + 1
    parseAlbums(xmlData: xmlData)
    XCTAssertFalse(
      album.isSongsMetaDataSynced,
      "Changed songCount must clear isSongsMetaDataSynced so deletions get pruned"
    )
  }

  // MARK: S2 — server-deleted song visibility

  func testServerDeletedUncachedSongIsHiddenAndCachedSongSurvives() throws {
    let album = library.createAlbum(account: account)
    album.id = "visibility-album"
    album.name = "Visibility Album"
    album.remoteStatus = .available

    let song = library.createSong(account: account)
    song.id = "visibility-song"
    song.title = "Visibility Song"
    song.size = 1234
    song.album = album
    library.saveContext()

    let fetchVisibleSongIds: () -> Set<String> = {
      let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      fetchRequest.predicate = SongMO.excludeServerDeleteUncachedSongsFetchPredicate
      let visibleSongs = (try? self.context.fetch(fetchRequest)) ?? []
      return Set(visibleSongs.compactMap { $0.id })
    }

    // Baseline: available song is visible and available to the user.
    XCTAssertTrue(song.isAvailableToUser())
    XCTAssertTrue(fetchVisibleSongIds().contains(song.id))

    // Server-side deletion detected (song remoteStatus flipped), no local cache:
    // the song must disappear from library queries and be unavailable.
    song.remoteStatus = .deleted
    library.saveContext()
    XCTAssertFalse(song.isAvailableToUser())
    XCTAssertFalse(fetchVisibleSongIds().contains(song.id))

    // Locally cached: deliberate design — a cached song survives server-side
    // deletion (visible + playable from cache) until its cache is cleared.
    song.relFilePath = URL(string: "cached/visibility-song.mp3")
    library.saveContext()
    XCTAssertTrue(song.isAvailableToUser())
    XCTAssertTrue(fetchVisibleSongIds().contains(song.id))

    // Cache cleared: the ghost entry must vanish.
    song.relFilePath = nil
    library.saveContext()
    XCTAssertFalse(song.isAvailableToUser())
    XCTAssertFalse(fetchVisibleSongIds().contains(song.id))
  }

  // MARK: S2 — newest-window sync verifies vanished albums and re-syncs flagged ones

  func testSyncNewestLibraryElementsVerifiesVanishedAlbumsAndFlaggedAlbums() async throws {
    let stayingAlbum = library.createAlbum(account: account)
    stayingAlbum.id = "staying-album"
    stayingAlbum.name = "Staying Album"
    stayingAlbum.updateIsNewestInfo(index: 1)
    // Flagged for song re-sync (e.g. songCount changed on a previous album parse):
    stayingAlbum.isSongsMetaDataSynced = false

    let vanishingAlbum = library.createAlbum(account: account)
    vanishingAlbum.id = "vanishing-album"
    vanishingAlbum.name = "Vanishing Album"
    vanishingAlbum.updateIsNewestInfo(index: 2)
    vanishingAlbum.isSongsMetaDataSynced = true
    library.saveContext()

    let spySyncer = SPY_LibrarySyncer()
    // Simulate the server no longer listing the vanishing album among the newest:
    spySyncer.onSyncNewestAlbums = {
      vanishingAlbum.markAsNotNewAnymore()
    }
    // sync(album:) throwing for the vanished album (e.g. the "album no longer
    // available" report) must not abort the newest-elements sync.
    spySyncer.albumSyncError = BackendError.notSupported
    spySyncer.albumSyncErrorAlbumIds = ["vanishing-album"]

    let autoDownloadSyncer = AutoDownloadLibrarySyncer(
      storage: storage,
      account: account,
      librarySyncer: spySyncer,
      playableDownloadManager: MOCK_SongDownloader()
    )
    try await autoDownloadSyncer.syncNewestLibraryElements()

    let syncedAlbumIds = Set(spySyncer.syncedAlbums.map { $0.id })
    XCTAssertTrue(
      syncedAlbumIds.contains("vanishing-album"),
      "An album that vanished from the newest window must be verified via sync(album:)"
    )
    XCTAssertTrue(
      syncedAlbumIds.contains("staying-album"),
      "An album still in the newest window with isSongsMetaDataSynced == false must be re-synced"
    )
  }

  /// A pre-existing ghost: a visible song whose album is NOT in the server's newest
  /// window anymore (deleted server-side before this client could watch it vanish).
  /// The Recently-Added-surface verification must re-verify its album via
  /// sync(album:) — and only once per app session.
  func testSyncNewestLibraryElementsVerifiesAlbumsBackingRecentlyAddedSongs() async throws {
    let ghostAlbum = library.createAlbum(account: account)
    ghostAlbum.id = "ghost-album"
    ghostAlbum.name = "Ghost Album"
    ghostAlbum.isSongsMetaDataSynced = true
    // Not flagged newest: the server's newest window does not vouch for it.

    let ghostSong = library.createSong(account: account)
    ghostSong.id = "ghost-song"
    ghostSong.title = "Ghost Song"
    ghostSong.size = 1234
    ghostSong.album = ghostAlbum
    ghostSong.addedDate = Date()
    library.saveContext()

    let spySyncer = SPY_LibrarySyncer()
    let autoDownloadSyncer = AutoDownloadLibrarySyncer(
      storage: storage,
      account: account,
      librarySyncer: spySyncer,
      playableDownloadManager: MOCK_SongDownloader()
    )

    try await autoDownloadSyncer.syncNewestLibraryElements()
    XCTAssertEqual(
      spySyncer.syncedAlbums.filter { $0.id == "ghost-album" }.count,
      1,
      "The album backing a recently added, unvouched song must be verified"
    )

    try await autoDownloadSyncer.syncNewestLibraryElements()
    XCTAssertEqual(
      spySyncer.syncedAlbums.filter { $0.id == "ghost-album" }.count,
      1,
      "Surface verification must run at most once per album per app session"
    )
  }
}
