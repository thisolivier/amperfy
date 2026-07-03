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
        // The artwork lives in an .overlay of Color.clear rather than directly in
        // the ZStack: .aspectRatio(.fill) makes the image REPORT its filled size
        // (e.g. 730×730 for a square cover on a 402×730 screen) and .clipped()
        // only clips drawing, not layout — so a direct child inflates the whole
        // deck's root ZStack and every card in it. Overlay content never
        // affects the base's layout size. Seen live during the solo QA round.
        Color.clear
          .overlay(
            EntityArtworkView(container: container, theme: theme)
              .aspectRatio(contentMode: .fill)
              .blur(radius: 60)
          )
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
