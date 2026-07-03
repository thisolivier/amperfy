import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckBackgroundView

/// Blurred, crossfading current-card artwork background (design §5.1): `Image` scaled to fill,
/// `.blur(radius: 60)`, overlaid `Color.black.opacity(0.45)`, crossfading between cards via
/// `.animation(.easeInOut(duration: 0.3))` on the identity-driving `container`.
struct AuditionDeckBackgroundView: View {
  let container: PlayableContainable?
  let theme: ThemePreference

  var body: some View {
    ZStack {
      Color.black
      if let container {
        EntityArtworkView(container: container, theme: theme)
          .aspectRatio(contentMode: .fill)
          .blur(radius: 60)
          .clipped()
          .id(container.id)
          .transition(.opacity)
      }
      Color.black.opacity(0.45)
    }
    .animation(.easeInOut(duration: 0.3), value: container?.id)
    .ignoresSafeArea()
  }
}
