import AmperfyKit
import SwiftUI

// MARK: - AuditionDeckCardView

/// One deck card (design §5.2): artwork+like, kicker/title/subtitle/evidence, the Needle Drop bar
/// fed a real fetched manifest, the audition readout, and the primary action + more menu.
///
/// `onOpen`: the "Open" menu item hook back to UIKit navigation — `AuditionDeckHostVC` is
/// responsible for dismissing the deck and pushing the real detail screen; this view only reports
/// *which* candidate was opened. `onRequestDismiss`: fired after Play / Play from start / Shuffle
/// start playback, so the host can run the same close path as the X button (`deckWillClose()` then
/// `dismiss(animated:)`).
struct AuditionDeckCardView: View {
  @ObservedObject
  var controller: AuditionDeckController
  let candidate: DeckCandidate
  let isCurrent: Bool
  /// 1-based position + total dealt candidates, for the design §7 accessibility label ("Card <i>
  /// of <n>, <kicker>, <title>") — the deck-wide "n of m" counter (§5.1) uses the same numbers.
  let position: Int
  let total: Int
  let account: Account
  let onOpen: (DeckCandidate) -> ()
  let onRequestDismiss: () -> ()

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
      AuditionDeckCardActionsView(
        auditionedTrackTitle: auditionModel.currentSlice?.title,
        onPlay: { play(startTrackId: auditionModel.auditionedTrackId) },
        onPlayFromStart: { play(startTrackId: nil) },
        onShuffle: shuffle,
        onAddToQueue: { controller.addToQueue(candidate: candidate) },
        onOpen: { onOpen(candidate) }
      )
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Card \(position) of \(total), \(DeckCandidateFormatting.kicker(for: candidate)), \(candidate.title)"
    )
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
  }

  @ViewBuilder
  private var auditionReadout: some View {
    HStack(spacing: 4) {
      Image(systemName: "music.note")
      if let slice = auditionModel.currentSlice {
        Text(DeckCandidateFormatting.auditionReadout(title: slice.title, artist: slice.artist))
          .lineLimit(1)
      } else {
        Text("Drag to needle-drop").foregroundStyle(.tertiary)
      }
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
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

  private func play(startTrackId: String?) {
    guard controller.play(candidate: candidate, startTrackId: startTrackId) else { return }
    onRequestDismiss()
  }

  private func shuffle() {
    controller.playShuffled(candidate: candidate)
    onRequestDismiss()
  }
}
