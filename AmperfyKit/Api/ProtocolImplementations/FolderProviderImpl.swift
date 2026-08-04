//  FolderProviderImpl.swift
//  AmperfyKit

import CoreData
import Foundation

/// Thin wrapper around PlaylistFolderStore conforming to FolderProvider.
public class FolderProviderImpl: FolderProvider {
  private let folderStore: PlaylistFolderStore

  public init(folderStore: PlaylistFolderStore) {
    self.folderStore = folderStore
  }

  public func configure(
    context: NSManagedObjectContext,
    navidromeApi: NavidromeServerApi?,
    account: AccountMO?
  ) {
    folderStore.configure(context: context, navidromeApi: navidromeApi, account: account)
  }

  public var folders: [PlaylistFolder] {
    folderStore.folders
  }

  public var allFiledPlaylistIds: Set<String> {
    folderStore.allFiledPlaylistIds
  }

  public func createFolder(name: String, parent: String?) -> PlaylistFolder {
    folderStore.createFolder(name: name, parent: parent)
  }

  public func renameFolder(id: String, to name: String) {
    folderStore.renameFolder(id: id, to: name)
  }

  public func deleteFolder(id: String) {
    folderStore.deleteFolder(id: id)
  }

  public func moveFolder(id: String, toParent newParentFolderId: String?) {
    folderStore.moveFolder(id: id, toParent: newParentFolderId)
  }

  public func addPlaylists(_ playlistIds: [String], to folderId: String) {
    folderStore.addPlaylists(playlistIds, to: folderId)
  }

  public func removePlaylists(_ playlistIds: [String], from folderId: String) {
    folderStore.removePlaylists(playlistIds, from: folderId)
  }

  public func movePlaylist(
    _ playlistId: String,
    from sourceFolderId: String,
    to destFolderId: String
  ) {
    folderStore.movePlaylist(playlistId, from: sourceFolderId, to: destFolderId)
  }

  public func unfilePlaylist(_ playlistId: String) {
    folderStore.unfilePlaylist(playlistId)
  }

  public func moveSibling(
    kind: PlaylistFolderSiblingKind,
    id siblingId: String,
    inFolder parentFolderId: String?,
    toIndex targetIndex: Int
  ) {
    folderStore.moveSibling(
      kind: kind, id: siblingId, inFolder: parentFolderId, toIndex: targetIndex
    )
  }

  public func folder(byId id: String) -> PlaylistFolder? {
    folderStore.folder(byId: id)
  }

  public func orderedSiblings(inFolder parentFolderId: String?) -> [PlaylistFolderSibling] {
    folderStore.orderedSiblings(inFolder: parentFolderId)
  }

  public func playlistSortOrders(inFolder parentFolderId: String?) -> [String: Int] {
    folderStore.playlistSortOrders(inFolder: parentFolderId)
  }

  public func syncFromServer() async throws {
    try await folderStore.syncFromServer()
  }

  public func syncMemberships(playlistId: String, folderIds: [String]) {
    folderStore.syncMemberships(playlistId: playlistId, folderIds: folderIds)
  }
}
