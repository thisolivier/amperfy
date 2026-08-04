import CoreData
import Foundation

/// One playlist-in-folder edge.
///
/// The v2 server contract models organization as *placements* rather than as a
/// folder-to-playlist set: a playlist may sit in several folders at once, each
/// placement carrying its own `sortOrder` within that folder. A playlist with no
/// placement at all is implicitly at the root, unordered.
@objc(PlaylistFolderPlacementMO)
public class PlaylistFolderPlacementMO: NSManagedObject {}
