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
  func createFolder(name: String, parent: String?) -> PlaylistFolder
  func renameFolder(id: String, to name: String)
  func deleteFolder(id: String)
  func moveFolder(id: String, toParent newParentFolderId: String?)
  func addPlaylists(_ playlistIds: [String], to folderId: String)
  func removePlaylists(_ playlistIds: [String], from folderId: String)
  func movePlaylist(_ playlistId: String, from sourceFolderId: String, to destFolderId: String)
  func unfilePlaylist(_ playlistId: String)
  func moveSibling(
    kind: PlaylistFolderSiblingKind,
    id siblingId: String,
    inFolder parentFolderId: String?,
    toIndex targetIndex: Int
  )
  func folder(byId id: String) -> PlaylistFolder?
  func orderedSiblings(inFolder parentFolderId: String?) -> [PlaylistFolderSibling]
  func playlistSortOrders(inFolder parentFolderId: String?) -> [String: Int]
  func syncFromServer() async throws
  func syncMemberships(playlistId: String, folderIds: [String])
}
