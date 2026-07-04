import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckCardArtworkView

/// Artwork block for one deck card: ~65% screen width, rounded 12pt, shadow. Deck v2: the like
/// button no longer overlays the artwork — it lives in the card's top-trailing corner
/// (`AuditionDeckCardView`).
struct AuditionDeckCardArtworkView: View {
  let candidate: DeckCandidate
  let container: PlayableContainable?
  let theme: ThemePreference
  let account: Account

  var body: some View {
    artwork
      .aspectRatio(1, contentMode: .fit)
      .frame(width: UIScreen.main.bounds.width * 0.65)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
  }

  @ViewBuilder
  private var artwork: some View {
    if let container {
      EntityArtworkView(container: container, theme: theme)
    } else {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.quaternary)
        .overlay {
          Image(systemName: "music.note")
            .font(.system(size: 40))
            .foregroundStyle(.secondary)
        }
    }
  }
}
