import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckCardArtworkView

/// Artwork block for one deck card (design §5.2): ~65% screen width, rounded 12pt, shadow, with
/// the like button overlaid top-trailing, offset (8, −8) outward. The heart control itself is
/// `AuditionDeckLikeButton` (the blend-panel/entry-points agent's file — found already built,
/// self-contained, and explicitly documented as droppable into this exact spot) rather than a
/// second implementation here.
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
      .overlay(alignment: .topTrailing) {
        AuditionDeckLikeButton(
          collectionId: candidate.collectionId,
          kind: candidate.kind,
          account: account
        )
        .offset(x: 8, y: -8)
      }
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
