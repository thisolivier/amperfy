import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckCardInfoView

/// Kicker / title / subtitle / evidence line block (design §5.2), all sourced straight off
/// `DeckCandidate` — the data layer already flattens title/subtitle/trackCount/duration/year onto
/// the candidate, so this view has no entity resolution to do, only formatting
/// (`DeckCandidateFormatting`).
struct AuditionDeckCardInfoView: View {
  let candidate: DeckCandidate

  var body: some View {
    VStack(spacing: 6) {
      Text(DeckCandidateFormatting.kicker(for: candidate))
        .font(.caption)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)

      Text(candidate.title)
        .font(.title2.bold())
        .lineLimit(2)
        .multilineTextAlignment(.center)

      if let subtitle = candidate.subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Text(DeckCandidateFormatting.evidenceLine(for: candidate.provenance))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .multilineTextAlignment(.center)
    .accessibilityElement(children: .combine)
  }
}
