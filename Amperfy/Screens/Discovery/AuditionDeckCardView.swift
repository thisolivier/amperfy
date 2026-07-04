import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckCardView

/// One Deck v2 card: a rounded-corner card on the page's theme surface holding artwork,
/// kicker/title/subtitle/evidence, and the Needle Drop bar. The like button sits in the card's
/// top-trailing corner. The whole card is one tap target — tapping it opens the collection
/// (`onOpen`; the host pushes the detail onto the same stack, deck stays alive beneath). All
/// v1 playback controls (Play button, ··· menu) are gone: playing happens after opening.
struct AuditionDeckCardView: View {
  @ObservedObject
  var controller: AuditionDeckController
  let candidate: DeckCandidate
  let isCurrent: Bool
  /// 1-based position + total dealt candidates, for the design §7 accessibility label ("Card <i>
  /// of <n>, <kicker>, <title>").
  let position: Int
  let total: Int
  let account: Account
  let onOpen: (DeckCandidate) -> ()

  @StateObject
  private var auditionModel = AuditionDeckCardAuditionModel()
  @State
  private var autoAuditionTrigger = false
  @AppStorage("amperfy.fork.discovery.autoplayPreviews")
  private var autoplayPreviews = true

  private var container: PlayableContainable? { controller.resolveEntity(candidate) }
  private var theme: ThemePreference {
    appDelegate.storage.settings.accounts.getSetting(account.info).read.themePreference
  }

  var body: some View {
    VStack(spacing: 20) {
      AuditionDeckCardArtworkView(
        candidate: candidate, container: container, theme: theme, account: account
      )
      AuditionDeckCardInfoView(candidate: candidate)
      needleDropSection
    }
    .padding(20)
    .padding(.top, 8)
    .frame(maxWidth: .infinity)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(alignment: .topTrailing) {
      AuditionDeckLikeButton(
        collectionId: candidate.collectionId,
        kind: candidate.kind,
        account: account
      )
      .padding(6)
    }
    .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .onTapGesture { onOpen(candidate) }
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Card \(position) of \(total), \(DeckCandidateFormatting.kicker(for: candidate)), \(candidate.title)"
    )
    .accessibilityHint("Opens this \(candidate.kind == .album ? "album" : "playlist")")
    .accessibilityAddTraits(.isButton)
    .task(id: candidate.collectionId) {
      await auditionModel.load(
        candidateId: candidate.collectionId, kind: candidate.kind,
        account: account, audio: controller.audio
      )
    }
    .onChange(of: isCurrent) { _, becameCurrent in handleCurrentChange(becameCurrent) }
    // The deck's FIRST card is current from the moment it exists, so
    // `.onChange(of: isCurrent)` never fires for it and it sat silent —
    // the opening moment of the experience (design §5.3's auto-audition)
    // only worked for swiped-to cards. Run the same settle path on
    // appearance when already current.
    .onAppear { if isCurrent { handleCurrentChange(true) } }
    .onDisappear {
      controller.audio.releaseSpritePlayer(
        for: candidate.collectionId, currentCandidateId: controller.scrollPositionId
      )
    }
  }

  private var needleDropSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      // `.id(...)` forces SwiftUI to rebuild `NeedleDropBar`'s `@StateObject` controller whenever
      // `availability` changes case (Loading -> Unavailable/Ready, or a retried fetch's
      // Unavailable -> Ready) instead of freezing at whatever snapshot existed when the bar was
      // first constructed while the fetch in `.task(id:)` above was still in flight — see
      // `NeedleDropBar`'s doc comment and `NeedleDropSpriteAvailability.identityKey`.
      NeedleDropBar(
        availability: auditionModel.availability,
        spritePlayer: auditionModel.spritePlayer,
        autoAuditionTrigger: autoAuditionTrigger
      )
      .id(auditionModel.availability.identityKey)
      auditionReadout
    }
    // The bar's white segment capsules are frozen work (Needle Drop HALT) and assume a dark
    // surface — give them one without forcing the page dark: a card-side dark inset strip.
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      Color.black.opacity(0.55),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
  }

  @ViewBuilder
  private var auditionReadout: some View {
    HStack(spacing: 4) {
      Image(systemName: "music.note")
      if let slice = auditionModel.currentSlice {
        Text(DeckCandidateFormatting.auditionReadout(title: slice.title, artist: slice.artist))
          .lineLimit(1)
      } else {
        Text("Drag to needle-drop").foregroundStyle(Color.white.opacity(0.5))
      }
    }
    .font(.footnote)
    .foregroundStyle(Color.white.opacity(0.8))
  }

  private func handleCurrentChange(_ becameCurrent: Bool) {
    guard becameCurrent else {
      autoAuditionTrigger = false
      return
    }
    controller.audio.stopAllSpritePlayers(except: candidate.collectionId)
    Task {
      await auditionModel.retryOnceIfNeeded(
        candidateId: candidate.collectionId, kind: candidate.kind,
        account: account, audio: controller.audio
      )
    }
    guard autoplayPreviews else { return }
    Task {
      // Design §5.3: "after a 400ms settle delay, start Riding from slice 1."
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard controller.scrollPositionId == candidate.collectionId else { return }
      autoAuditionTrigger = true
    }
  }
}
