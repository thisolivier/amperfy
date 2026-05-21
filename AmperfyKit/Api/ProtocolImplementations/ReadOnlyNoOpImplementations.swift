//
//  ReadOnlyNoOpImplementations.swift
//  AmperfyKit
//
//  Created by Olivier on 20.05.26.
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

import CoreData
import Foundation

// MARK: - NoOpPlayerFacade

@MainActor
public class NoOpPlayerFacade: PlayerFacade {
  public init() {}

  // MARK: Queue counts & items

  public var prevQueueCount: Int { 0 }
  public func getPrevQueueItems(from: Int, to: Int?) -> [AbstractPlayable] { [] }
  public func getAllPrevQueueItems() -> [AbstractPlayable] { [] }

  public var userQueueCount: Int { 0 }
  public func getUserQueueItems(from: Int, to: Int?) -> [AbstractPlayable] { [] }
  public func getAllUserQueueItems() -> [AbstractPlayable] { [] }

  public var nextQueueCount: Int { 0 }
  public func getNextQueueItems(from: Int, to: Int?) -> [AbstractPlayable] { [] }
  public func getAllNextQueueItems() -> [AbstractPlayable] { [] }

  // MARK: Playback state

  public var totalPlayDuration: Int { 0 }
  public var remainingPlayDuration: Int { 0 }

  private var _volume: Float = 0
  public var volume: Float {
    get { _volume }
    set { _volume = newValue }
  }

  public var isPlaying: Bool { false }

  public func getPlayable(at playerIndex: PlayerIndex) -> AbstractPlayable? { nil }
  public var currentlyPlaying: AbstractPlayable? { nil }
  public var currentMusicItem: AbstractPlayable? { nil }
  public var currentPodcastItem: AbstractPlayable? { nil }
  public var currentRadioNowPlaying: RadioNowPlayingInfo? { nil }
  public var contextName: String { "" }
  public var elapsedTime: Double { 0 }
  public var duration: Double { 0 }

  // MARK: Playback settings

  public var isShuffle: Bool { false }
  public func toggleShuffle() {}

  public var playbackRate: PlaybackRate { .one }
  public func setPlaybackRate(_: PlaybackRate) {}

  public var repeatMode: RepeatMode { .off }
  public func setRepeatMode(_: RepeatMode) {}

  private var _isOfflineMode: Bool = false
  public var isOfflineMode: Bool {
    get { _isOfflineMode }
    set { _isOfflineMode = newValue }
  }

  private var _isShouldPauseAfterFinishedPlaying: Bool = false
  public var isShouldPauseAfterFinishedPlaying: Bool {
    get { _isShouldPauseAfterFinishedPlaying }
    set { _isShouldPauseAfterFinishedPlaying = newValue }
  }

  private var _isAutoCachePlayedItems: Bool = false
  public var isAutoCachePlayedItems: Bool {
    get { _isAutoCachePlayedItems }
    set { _isAutoCachePlayedItems = newValue }
  }

  public var isPopupBarAllowedToHide: Bool { true }

  // MARK: Player mode & counts

  public var musicItemCount: Int { 0 }
  public var podcastItemCount: Int { 0 }
  public var playerMode: PlayerMode { .music }
  public var playType: PlayType? { nil }
  public var activeStreamingBitrate: StreamingMaxBitratePreference? { nil }
  public var activeTranscodingFormat: StreamingFormatPreference? { nil }
  public func setPlayerMode(_ newValue: PlayerMode) {}

  public var streamingMaxBitrates: StreamingMaxBitrates { StreamingMaxBitrates() }
  public func setStreamingMaxBitrates(to: StreamingMaxBitrates) {}

  public var streamingTranscodings: StreamingTranscodings { StreamingTranscodings() }
  public func setStreamingTranscodings(to: StreamingTranscodings) {}

  // MARK: Account

  public func logout(account: Account) {}

  // MARK: Queue mutations (no-op)

  public func insertContextQueue(playables: [AbstractPlayable]) {}
  public func appendContextQueue(playables: [AbstractPlayable]) {}
  public func insertUserQueue(playables: [AbstractPlayable]) {}
  public func appendUserQueue(playables: [AbstractPlayable]) {}
  public func insertPodcastQueue(playables: [AbstractPlayable]) {}
  public func appendPodcastQueue(playables: [AbstractPlayable]) {}
  public func removePlayable(at: PlayerIndex) {}
  public func movePlayable(from: PlayerIndex, to: PlayerIndex) {}
  public func clearUserQueue() {}
  public func clearContextQueue() {}
  public func clearQueues() {}

  // MARK: Playback controls (no-op)

  public func play() {}
  public func play(context: PlayContext) {}
  public func playShuffled(context: PlayContext) {}
  public func play(playerIndex: PlayerIndex) {}
  public func pause() {}
  public func togglePlayPause() {}
  public func stop() {}
  public func playPrevious() {}
  public func playPreviousOrReplay() {}
  public func playNext() {}
  public func skipForward(interval: Double) {}
  public func skipBackward(interval: Double) {}
  public func seek(toSecond: Double) {}

  // MARK: Audio analyzer

  public lazy var audioAnalyzer: AudioAnalyzer = .init()

  // MARK: Notifications & equalizer (no-op)

  public func addNotifier(notifier: MusicPlayable) {}
  public func updateEqualizerEnabled(isEnabled: Bool) {}
  public func updateEqualizerSetting(eqSetting: EqualizerSetting) {}
  public func updateReplayGainEnabled(isEnabled: Bool) {}
}

// MARK: - NoOpSyncCoordinator

@MainActor
public class NoOpSyncCoordinator: SyncCoordinator {
  public init() {}

  public func getLibrarySyncer(for accountInfo: AccountInfo) -> LibrarySyncer {
    fatalError("Read-only mode does not support sync")
  }

  public func resetSyncer(for accountInfo: AccountInfo) {}

  public var allActiveAccountInfos: [AccountInfo] { [] }
}

// MARK: - NoOpDownloadCoordinator

@MainActor
public class NoOpDownloadCoordinator: DownloadCoordinator {
  public init() {}

  public func getPlayableDownloader(for accountInfo: AccountInfo) -> DownloadManageable {
    fatalError("Read-only mode does not support downloads")
  }

  public func getArtworkDownloader(for accountInfo: AccountInfo) -> DownloadManageable {
    fatalError("Read-only mode does not support downloads")
  }
}

// MARK: - NoOpFolderProvider

public class NoOpFolderProvider: FolderProvider {
  public init() {}

  public func configure(
    context: NSManagedObjectContext,
    navidromeApi: NavidromeServerApi?,
    account: AccountMO?
  ) {}

  public var folders: [PlaylistFolder] { [] }
  public var allFiledPlaylistIds: Set<String> { [] }

  public func createFolder(name: String, parent: UUID?) -> PlaylistFolder {
    fatalError("Read-only mode does not support folder creation")
  }

  public func renameFolder(id: UUID, to name: String) {}
  public func deleteFolder(id: UUID) {}
  public func addPlaylists(_ playlistIds: [String], to folderId: UUID) {}
  public func removePlaylists(_ playlistIds: [String], from folderId: UUID) {}
  public func movePlaylist(
    _ playlistId: String,
    from sourceFolderId: UUID,
    to destFolderId: UUID
  ) {}
  public func folder(byId id: UUID) -> PlaylistFolder? { nil }
  public func syncFromServer() async throws {}
  public func syncMemberships(playlistId: String, folderIds: [String]) {}
}

// MARK: - NoOpNetworkMonitor

public final class NoOpNetworkMonitor: NetworkMonitorFacade, @unchecked Sendable {
  public init() {}

  public var connectionTypeChangedCB: ConnectionTypeChangedCallack?
  public var isConnectedToNetwork: Bool { false }
  public var isCellular: Bool { false }
  public var isWifiOrEthernet: Bool { false }
}
