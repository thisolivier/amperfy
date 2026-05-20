import CoreData
import Foundation

extension PlaylistFolderMO {
  @nonobjc
  public class func fetchRequest() -> NSFetchRequest<PlaylistFolderMO> {
    NSFetchRequest<PlaylistFolderMO>(entityName: "PlaylistFolder")
  }

  @NSManaged public var id: String
  @NSManaged public var name: String
  @NSManaged public var parentId: String?
  @NSManaged public var account: AccountMO?
  @NSManaged public var playlists: NSSet?
}

// MARK: - Generated accessors for playlists

extension PlaylistFolderMO {
  @objc(addPlaylistsObject:)
  @NSManaged public func addToPlaylists(_ value: PlaylistMO)

  @objc(removePlaylistsObject:)
  @NSManaged public func removeFromPlaylists(_ value: PlaylistMO)

  @objc(addPlaylists:)
  @NSManaged public func addToPlaylists(_ values: NSSet)

  @objc(removePlaylists:)
  @NSManaged public func removeFromPlaylists(_ values: NSSet)
}
