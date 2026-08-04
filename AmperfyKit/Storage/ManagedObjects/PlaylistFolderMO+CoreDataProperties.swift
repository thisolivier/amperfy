import CoreData
import Foundation

extension PlaylistFolderMO {
  @nonobjc
  public class func fetchRequest() -> NSFetchRequest<PlaylistFolderMO> {
    NSFetchRequest<PlaylistFolderMO>(entityName: "PlaylistFolder")
  }

  @NSManaged
  public var id: String
  @NSManaged
  public var name: String
  @NSManaged
  public var parentId: String?
  /// Client-assigned, unnormalized ordering key among this folder's siblings
  /// (folders and playlists share one ordering space per parent). `nil` means
  /// "unordered", which sorts after every ordered sibling.
  @NSManaged
  public var sortOrder: NSNumber?
  @NSManaged
  public var account: AccountMO?
  /// Legacy many-to-many membership, superseded by ``PlaylistFolderPlacementMO``.
  ///
  /// Retained in the v52 model purely so the one-time backfill can read a
  /// device's pre-v2 memberships across the migration; nothing writes to it
  /// after the backfill has run. Do not use it as a membership source.
  @NSManaged
  public var playlists: NSSet?
}

extension PlaylistFolderMO {
  /// `sortOrder` bridged to a Swift optional integer. Core Data cannot express
  /// an optional scalar, so the attribute is stored as an `NSNumber?`.
  public var sortOrderValue: Int? {
    get { sortOrder?.intValue }
    set { sortOrder = newValue.map { NSNumber(value: $0) } }
  }
}

// MARK: - Generated accessors for playlists

extension PlaylistFolderMO {
  @objc(addPlaylistsObject:)
  @NSManaged
  public func addToPlaylists(_ value: PlaylistMO)

  @objc(removePlaylistsObject:)
  @NSManaged
  public func removeFromPlaylists(_ value: PlaylistMO)

  @objc(addPlaylists:)
  @NSManaged
  public func addToPlaylists(_ values: NSSet)

  @objc(removePlaylists:)
  @NSManaged
  public func removeFromPlaylists(_ values: NSSet)
}
