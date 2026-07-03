import AmperfyKit
import SwiftUI
import UIKit

// MARK: - EntityArtworkView

/// Thin `UIViewRepresentable` bridge onto `EntityImageView`
/// (`Amperfy/Screens/Common/EntityImageView.swift`) so SwiftUI deck cards get the app's existing
/// artwork rendering for free: single cover art, the existing playlist-without-art 2×2 mosaic
/// fallback, and the generated placeholder — instead of re-implementing any of that in SwiftUI
/// (design §5.2: "Playlist without art: existing Amperfy 2×2 mosaic fallback").
///
/// Deliberately renders with minimal internal corner rounding (`.verySmall`, 3pt) — the visible
/// 12pt rounding the design calls for is applied by the SwiftUI caller via
/// `.clipShape(RoundedRectangle(cornerRadius: 12))`, which needs an internal radius no larger than
/// its own to look correct.
struct EntityArtworkView: UIViewRepresentable {
  let container: PlayableContainable
  let theme: ThemePreference

  func makeUIView(context: Context) -> EntityImageView {
    let view = EntityImageView(frame: .zero)
    view.display(theme: theme, container: container, cornerRadius: .verySmall)
    return view
  }

  func updateUIView(_ uiView: EntityImageView, context: Context) {
    uiView.display(theme: theme, container: container, cornerRadius: .verySmall)
  }
}
