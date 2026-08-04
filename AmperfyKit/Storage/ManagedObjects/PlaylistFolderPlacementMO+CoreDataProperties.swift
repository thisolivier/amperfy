import CoreData
import Foundation

extension PlaylistFolderPlacementMO {
  @nonobjc
  public class func fetchRequest() -> NSFetchRequest<PlaylistFolderPlacementMO> {
    NSFetchRequest<PlaylistFolderPlacementMO>(entityName: "PlaylistFolderPlacement")
  }

  /// Server folder id this placement files the playlist into. The empty string
  /// is the root, matching the server contract's spelling of "no folder".
  @NSManaged
  public var folderId: String
  /// Client-assigned, unnormalized ordering key within `folderId`. `nil` means
  /// "unordered", which sorts after every ordered sibling.
  @NSManaged
  public var sortOrder: NSNumber?
  @NSManaged
  public var playlist: PlaylistMO?
  @NSManaged
  public var account: AccountMO?
}

extension PlaylistFolderPlacementMO {
  /// `sortOrder` bridged to a Swift optional integer. Core Data cannot express
  /// an optional scalar, so the attribute is stored as an `NSNumber?`.
  public var sortOrderValue: Int? {
    get { sortOrder?.intValue }
    set { sortOrder = newValue.map { NSNumber(value: $0) } }
  }
}
