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

  public func createFolder(name: String, parent: UUID?) -> PlaylistFolder {
    folderStore.createFolder(name: name, parent: parent)
  }

  public func renameFolder(id: UUID, to name: String) {
    folderStore.renameFolder(id: id, to: name)
  }

  public func deleteFolder(id: UUID) {
    folderStore.deleteFolder(id: id)
  }

  public func moveFolder(id: UUID, toParent newParentFolderId: UUID?) {
    folderStore.moveFolder(id: id, toParent: newParentFolderId)
  }

  public func addPlaylists(_ playlistIds: [String], to folderId: UUID) {
    folderStore.addPlaylists(playlistIds, to: folderId)
  }

  public func removePlaylists(_ playlistIds: [String], from folderId: UUID) {
    folderStore.removePlaylists(playlistIds, from: folderId)
  }

  public func movePlaylist(
    _ playlistId: String,
    from sourceFolderId: UUID,
    to destFolderId: UUID
  ) {
    folderStore.movePlaylist(playlistId, from: sourceFolderId, to: destFolderId)
  }

  public func unfilePlaylist(_ playlistId: String) {
    folderStore.unfilePlaylist(playlistId)
  }

  public func moveSibling(
    kind: PlaylistFolderSiblingKind,
    id siblingId: String,
    inFolder parentFolderId: UUID?,
    toIndex targetIndex: Int
  ) {
    folderStore.moveSibling(
      kind: kind, id: siblingId, inFolder: parentFolderId, toIndex: targetIndex
    )
  }

  public func folder(byId id: UUID) -> PlaylistFolder? {
    folderStore.folder(byId: id)
  }

  public func orderedSiblings(inFolder parentFolderId: UUID?) -> [PlaylistFolderSibling] {
    folderStore.orderedSiblings(inFolder: parentFolderId)
  }

  public func playlistSortOrders(inFolder parentFolderId: UUID?) -> [String: Int] {
    folderStore.playlistSortOrders(inFolder: parentFolderId)
  }

  public func syncFromServer() async throws {
    try await folderStore.syncFromServer()
  }

  public func syncMemberships(playlistId: String, folderIds: [String]) {
    folderStore.syncMemberships(playlistId: playlistId, folderIds: folderIds)
  }
}
