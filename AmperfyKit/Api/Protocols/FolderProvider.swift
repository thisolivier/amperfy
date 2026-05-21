//  FolderProvider.swift
//  AmperfyKit

import CoreData
import Foundation

/// Protocol for playlist folder management.
/// Wraps PlaylistFolderStore.
public protocol FolderProvider {
  func configure(
    context: NSManagedObjectContext,
    navidromeApi: NavidromeServerApi?,
    account: AccountMO?
  )
  var folders: [PlaylistFolder] { get }
  var allFiledPlaylistIds: Set<String> { get }
  func createFolder(name: String, parent: UUID?) -> PlaylistFolder
  func renameFolder(id: UUID, to name: String)
  func deleteFolder(id: UUID)
  func addPlaylists(_ playlistIds: [String], to folderId: UUID)
  func removePlaylists(_ playlistIds: [String], from folderId: UUID)
  func movePlaylist(_ playlistId: String, from sourceFolderId: UUID, to destFolderId: UUID)
  func folder(byId id: UUID) -> PlaylistFolder?
  func syncFromServer() async throws
  func syncMemberships(playlistId: String, folderIds: [String])
}
