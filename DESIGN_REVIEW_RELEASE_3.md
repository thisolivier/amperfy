# Release 3 — Design Review (PR 17.2 Gradient Backgrounds + BUG-1 Fix)

Review date: 2026-04-15
Reviewer: designer agent
Implementer target: `spike/amperfy/` on branch `olivierMain`

## Summary

Release 3 adds a gradient background option to two surfaces: the **main app background** (every root-tab VC's scrolling surface) and the **album detail view**. Now Playing is explicitly out of scope. Gradients are defined as "2+ colors + a direction"; users pick from built-in presets or previously-used gradients. Light and dark each get an independent gradient (mirrors the PR 17.4 tier model). Everything plumbs through `ThemeStore` under the existing `amperfy.fork.theme.*` key namespace; storage is JSON in `UserDefaults`. The release also rolls in **BUG-1** from Release 1 QA — call `populateDefaultsIfNeeded()` from `AppDelegate.applyCustomThemeAppearance()` so pre-17.4 installs with a stored `lightText` but no `lightHeadingText` stop showing `.label` in the Heading picker.

The hard design call: **`.backgroundColor` resolves to a flat `UIColor` via `UIColor.backgroundColor` in `AmperfyKit/Common/Utilities.swift:378`**. A gradient cannot fit through that accessor — it's a `UIColor`, not a layer — and every VC in the app sets `tableView.backgroundColor = .backgroundColor`. The design decouples the two: when the user picks a **solid** background, everything continues through `.backgroundColor` unchanged. When the user picks a **gradient**, the scroll-view's `backgroundColor` is set to `.clear` and a `GradientBackgroundView` (a thin `UIView` owning a `CAGradientLayer`) is installed as `tableView.backgroundView` / `collectionView.backgroundView`. One shared helper + one theme-change notification handler per VC base class makes this uniform.

---

## Injection sites

### Main app background — every root/library VC's scrolling surface

Amperfy has no UIWindow-level background paint and no UIAppearance proxy for `UIView.appearance().backgroundColor` (the existing code deliberately avoids that because it crashes on system views — see comment at `Amperfy/AppDelegate.swift:223`). Instead, every VC sets its own `tableView.backgroundColor = .backgroundColor`. The canonical call site is the static accessor:

- **`AmperfyKit/Common/Utilities.swift:378`** — `public static var backgroundColor: UIColor { ... }`. Reads `amperfy.fork.theme.light.bg` / `dark.bg` directly from `UserDefaults` (cross-module trick to keep the kit free of app-layer imports). Returns a dynamic `UIColor` that resolves per trait collection.

Every table-based VC calls `.backgroundColor` in `viewDidLoad()`. Representative (not exhaustive) call sites:

- `Amperfy/Screens/ViewController/AlbumDetailVC.swift:100` — the subject of the secondary gradient target, see below.
- `Amperfy/Screens/ViewController/AlbumsVC.swift:209`
- `Amperfy/Screens/ViewController/ArtistsVC.swift:175`
- `Amperfy/Screens/ViewController/ArtistDetailVC.swift:70`
- `Amperfy/Screens/ViewController/PlaylistsVC.swift:143`
- `Amperfy/Screens/ViewController/PlaylistDetailVC.swift:151`
- `Amperfy/Screens/ViewController/SongsVC.swift:70`
- `Amperfy/Screens/ViewController/DownloadsVC.swift:59`
- `Amperfy/Screens/ViewController/SearchVC.swift:161`
- Full list: grep `\.backgroundColor = \.backgroundColor` in `Amperfy/Screens/ViewController/` — 29 hits in total.

The **HomeVC is already the odd one out**: `Amperfy/Screens/ViewController/HomeVC.swift:115` and `:184` set `collectionView.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemBackground` directly (not via the `.backgroundColor` accessor), and it already observes `ThemeStore.didChangeNotification` to re-apply (`:107-110` + `:113-118`). **HomeVC is the right prior-art pattern to copy for gradient support.**

**Injection strategy.** Add a new helper `applyBackgroundSurface(to scrollView: UIScrollView, in traitCollection: UITraitCollection)` on `ThemeStore` (or a tiny free function on the app target) with shape:

```
if gradient is enabled for style {
  scrollView.backgroundColor = .clear
  let gradientView = GradientBackgroundView(gradient: resolvedGradient)
  scrollView.backgroundView = gradientView   // tableView or collectionView
} else {
  scrollView.backgroundView = nil
  scrollView.backgroundColor = .backgroundColor   // today's path
}
```

Every VC that currently sets `tableView.backgroundColor = .backgroundColor` swaps that one line for `applyBackgroundSurface(to: tableView, ...)`. That's a mechanical ~29-site rewrite on the Amperfy target. **No `AmperfyKit` edit required** — the existing `.backgroundColor` accessor keeps working as the fallback when the user hasn't enabled a gradient.

Wire each VC's base class (or each VC individually if the base class is awkward) to `ThemeStore.didChangeNotification` — copy HomeVC's observer pattern at `HomeVC.swift:105-110`. On notification, re-call `applyBackgroundSurface(...)`.

**Why not paint the window.** Painting `UIWindow.backgroundColor` once at AppDelegate is tempting but doesn't reach the tableView/collectionView, which paint their own opaque background over the window. Reaching "the main app background" genuinely does mean per-scrollview. This matches HomeVC's existing shape and stays consistent with PR 7 / 17.4's per-scrollview approach.

### Album detail background

**`Amperfy/Screens/ViewController/AlbumDetailVC.swift:100`** sets `tableView.backgroundColor = .backgroundColor`. The album detail view is a `UITableViewController` (via `SingleSnapshotFetchedResultsTableViewController<SongMO>`, see `Amperfy/Screens/ViewController/TableViewHelper/SingleSnapshotFetchedResultsTableViewController.swift`). The surface that needs the gradient is:

- The `tableView` fills the full view bounds (standard UITableViewController wiring).
- The `GenericDetailTableHeader` (see `Amperfy/Screens/View/GenericDetailTableHeader.swift`) is installed as the table's header view and already draws opaque over its own section — the gradient will show between the header's bottom edge and the first row's opaque background, and between/below rows only if the cells have `.clear` backgrounds.

**Decision on album-detail-specific vs shared gradient.** Backlog §17.2 says "main app background and album detail view" as two separately-scoped targets. Two reasonable interpretations:

1. **Same gradient applies to both** (one stored gradient, painted on the main app background AND under album detail).
2. **Album detail gets its own gradient choice**, distinct from the main app background.

Recommendation: **(1) — same gradient, two surfaces.** Reasons: (a) the user picks one visual style for their library; having the album detail magically swap looks chaotic, (b) the "previously used" list stays simple (one axis of history), (c) shipping a second gradient picker roughly doubles the settings UI surface area for marginal additional expression. This is a non-material decision from the backlog spec — flagging for Olivier only so the call is visible. If Olivier disagrees, bump to (2) with a second gradient slot in `ThemeStore` (`albumDetailGradient`) and a second picker row.

**Secondary consideration — album art overlay.** `GenericDetailTableHeader` also holds the large album-artwork image. The gradient should paint *behind* the artwork (full-width behind the entire table header area), not *under only the cells*. Using `tableView.backgroundView` achieves this automatically: the backgroundView sits behind the header AND the cells. If the implementer discovers that `UITableViewHeaderFooterView` opaque backgrounds obscure the gradient at the top, they may need to additionally set the generic detail header's own background to `.clear` — verify during implementation, not expected to be an issue based on the current XIB (which relies on system background).

### Surfaces that should NOT get the gradient (out of scope)

- `LargeCurrentlyPlayingPlayerView` — Now Playing, explicitly out of scope per backlog §17.2.
- `MiniPlayerView` — miniplayer overlay. Keep solid so it remains readable above the gradient.
- `PopupPlayerVC` — the animated-gradient popup player is already its own independent gradient system (see `Amperfy/Screens/Basics/AnimatedGradientLayer.swift`). Do not touch. (Notable: `AnimatedGradientLayer` is currently orphan code — only referenced by `project.pbxproj`. We could conceivably reuse its `CAGradientLayer` wrapper for our `GradientBackgroundView`, but it's over-specified for our case. **Recommendation: write a new, simpler `GradientBackgroundView` from scratch** — ~40 lines — rather than bend the animated one. The animated one is kept in the tree in case the popup player resurfaces.)
- Settings / SwiftUI screens — out of scope; they live in `SettingsHostVC` in a separate scene.
- Login / Sync / Update VCs — out of scope; appear pre-library-load.

---

## Gradient data model

### `Gradient` struct

New file `Amperfy/Gradient.swift`:

```swift
struct Gradient: Codable, Equatable, Hashable {
  enum Direction: String, Codable, CaseIterable {
    case topToBottom          // 0,0 -> 0,1
    case bottomToTop          // 0,1 -> 0,0
    case leftToRight          // 0,0 -> 1,0
    case rightToLeft          // 1,0 -> 0,0
    case topLeftToBottomRight // 0,0 -> 1,1
    case topRightToBottomLeft // 1,0 -> 0,1
  }

  let colors: [String]        // hex strings, same format as ThemeStore's other colors
  let direction: Direction
  let id: UUID                // stable identity for "previously used" dedup + list rows
}
```

**Why hex strings, not UIColor:** matches the existing `ThemeStore` persistence pattern (hex via `UIColor.hexString` / `UIColor(hex:)`), keeps `Codable` trivial, and avoids `UIColor` archiving traps.

**Minimum colors = 2, maximum = 4.** Per backlog spec "two or more colors". A hard cap of 4 keeps the UI simple (4 color wells + 1 direction picker fits a single settings row easily) and avoids performance / visual mush. Document the cap in a UI constraint; don't enforce at the struct level (keeps `Codable` flexible).

**`id: UUID`** — needed because the same `(colors, direction)` combo can legitimately appear twice in "previously used" if the user creates, modifies, and re-creates the exact same gradient. Using UUID keyed identity is cleaner than `Equatable` for list dedup. We still de-dup *content-equal* gradients at insertion time to keep the history clean (see storage below).

### Storage keys

Extend `ThemeStore.Key`:

```swift
enum Key {
  // ...existing...
  static let gradientEnabledLight = "amperfy.fork.theme.light.gradient.enabled"
  static let gradientEnabledDark = "amperfy.fork.theme.dark.gradient.enabled"
  static let activeGradientLight = "amperfy.fork.theme.light.gradient.active"   // JSON-encoded Gradient
  static let activeGradientDark = "amperfy.fork.theme.dark.gradient.active"     // JSON-encoded Gradient
  static let gradientHistory = "amperfy.fork.theme.gradient.history"            // JSON-encoded [Gradient]
}
```

**Light / dark split** matches backgrounds, heading/body text, and tint — the existing pattern. The user can enable gradient in light mode but keep dark mode on a solid background, or set two completely different gradients.

**Single shared history.** One `[Gradient]` array across light and dark — a user who creates a gradient in light mode will see it available when they switch to dark. This matches user mental-model better than separate histories, and avoids doubling persistence weight.

### ThemeStore accessors

```swift
// Enable flags
var lightGradientEnabled: Bool { get set }
var darkGradientEnabled: Bool { get set }

// Active gradient per style
var lightActiveGradient: Gradient? { get set }   // JSON-encoded under .activeGradientLight
var darkActiveGradient: Gradient? { get set }

// History
var gradientHistory: [Gradient] { get set }      // JSON-encoded under .gradientHistory

// Resolved
func resolvedGradient(for style: UIUserInterfaceStyle) -> Gradient? {
  guard isEnabled else { return nil }
  let enabled = style == .dark ? darkGradientEnabled : lightGradientEnabled
  guard enabled else { return nil }
  return style == .dark ? darkActiveGradient : lightActiveGradient
}

// History management
func rememberGradient(_ gradient: Gradient) {
  var history = gradientHistory
  // de-dup by content: if a gradient with identical colors+direction exists,
  // promote it to the front instead of adding a duplicate
  history.removeAll { $0.colors == gradient.colors && $0.direction == gradient.direction }
  history.insert(gradient, at: 0)
  // Soft cap at 20 — protects against UserDefaults bloat if the user experiments a lot
  if history.count > 20 { history = Array(history.prefix(20)) }
  gradientHistory = history
}
```

### Rendering

New file `Amperfy/GradientBackgroundView.swift` (~40 lines):

```swift
final class GradientBackgroundView: UIView {
  override static var layerClass: AnyClass { CAGradientLayer.self }
  var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

  init(gradient: Gradient) {
    super.init(frame: .zero)
    apply(gradient: gradient)
  }
  required init?(coder: NSCoder) { fatalError() }

  func apply(gradient: Gradient) {
    gradientLayer.colors = gradient.colors.compactMap { UIColor(hex: $0)?.cgColor }
    let (start, end) = points(for: gradient.direction)
    gradientLayer.startPoint = start
    gradientLayer.endPoint = end
  }

  private func points(for direction: Gradient.Direction) -> (CGPoint, CGPoint) {
    switch direction {
    case .topToBottom:          return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
    case .bottomToTop:          return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
    case .leftToRight:          return (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
    case .rightToLeft:          return (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
    case .topLeftToBottomRight: return (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
    case .topRightToBottomLeft: return (CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))
    }
  }
}
```

**CAGradientLayer is the right choice.** Cheap (GPU-composited), automatic resize via `layerClass` override, no per-frame CPU cost. Already used in-tree by `AnimatedGradientLayer` — idiomatic pattern. A SwiftUI `LinearGradient` would require wrapping in a `UIHostingController` per-VC (painful) or a `UIViewRepresentable` — extra ceremony for no benefit.

---

## Settings UX shape

### Placement in `ThemeSettingsSection.swift`

Add a new SettingsSection between "Light Mode Colors" / "Dark Mode Colors" color rows and the existing "Font" section. **Do not add it inside the existing color sections** — the gradient is conceptually a *replacement* for the solid background color, not an additional color in the same tier. Putting it in its own section makes the "gradient OR solid, per mode" toggle visible.

### Layout sketch

```
Custom Theme                                           [toggle]

Light Mode Colors
  Background                                           [color well]
  Heading Color                                        [color well]
  Body Color                                           [color well]
  Tint                                                 [color well]

Dark Mode Colors
  Background                                           [color well]
  Heading Color                                        [color well]
  Body Color                                           [color well]
  Tint                                                 [color well]

Background Gradient
  Use Gradient (Light)                                 [toggle]
    └── if ON:  [preview swatch, 44pt tall, tappable]  →  opens GradientEditorSheet (light)
  Use Gradient (Dark)                                  [toggle]
    └── if ON:  [preview swatch, 44pt tall, tappable]  →  opens GradientEditorSheet (dark)

  Previously Used                                      [horizontal carousel of swatches]
                                                        Tap swatch = apply to whichever mode
                                                        is currently being configured;
                                                        long-press = "Apply to Light" /
                                                        "Apply to Dark" menu

Font
  Font Family                                          [disclosure] → FontPickerView

Reset to Defaults                                      [destructive]
```

### Why toggles per mode

Matches the conceptual question: "in this mode, do I want a gradient or a solid color?" If the toggle is off, the solid "Background" row in the Light/Dark color section is the active background. If on, the gradient is the active background. This avoids the "delete gradient" gesture (user just flips the toggle off) and gives a clean fallback to the solid color without losing it.

The solid `Background` color well stays in the mode-specific color section even when the gradient toggle is on — it's dormant state, restored on toggle-off. **Don't hide the solid Background row when gradient is enabled** — hiding state is disorienting; keeping it visible lets the user see both current settings.

### Gradient editor sheet (new SwiftUI view `GradientEditorView`)

Presented as a `.sheet` from the Light/Dark preview rows. Shape:

```
┌─ Edit Gradient ─────────────────────  [Done] ──┐
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │                                           │  │
│  │       [large live preview, 120pt tall]   │  │
│  │                                           │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  Colors                                         │
│  Color 1    [color well]   [remove, if >2]     │
│  Color 2    [color well]   [remove, if >2]     │
│  Color 3    [color well]   [remove]             │
│  [+ Add Color]  (disabled if already 4)        │
│                                                 │
│  Direction                                      │
│  [Picker: Top-to-Bottom / Bottom-to-Top /      │
│   Left-to-Right / Right-to-Left /              │
│   Diagonal ↘ / Diagonal ↙]                     │
│                                                 │
│  [Apply & Save]  ← writes to ThemeStore,        │
│                    appends to history,          │
│                    dismisses sheet              │
└─────────────────────────────────────────────────┘
```

**Preview updates live** as color wells / direction change. This is the payoff for CAGradientLayer — a `GradientBackgroundView` inside the sheet re-applies on every `onChange`. The "Apply & Save" button commits to `ThemeStore` AND calls `rememberGradient(...)` in one step; dismiss reverts preview-only edits without saving (classic sheet dismiss semantics).

**Apply auto-adds to history** per backlog spec: "When a user creates/selects a gradient, it is saved to the 'previously used' list automatically." Dedup is handled by `rememberGradient`.

### Previously-used carousel

Horizontal `ScrollView(.horizontal)` of 60×60pt gradient swatches. Each swatch renders its gradient inline (a `GradientBackgroundView` wrapped for SwiftUI, or a `Canvas` drawing two gradient stops). Tap = apply to the "currently active configuration target" (we need a convention for which mode — Light or Dark — the tap applies to). Cleanest: **most-recent-edited mode wins**. Alternative: long-press for a context menu ("Apply to Light", "Apply to Dark"). Ship both: tap = apply to the mode of whichever preview row the user most recently opened (or falls back to current system appearance); long-press = explicit menu.

Non-material decision flagged for the open questions list: *does the backlog's "previously used" need to survive theme-reset?* Recommendation: **yes, history is orthogonal to active state** — `resetToDefaults()` clears active gradients but keeps the history list. This is ergonomic: a user who experiments, resets, experiments again doesn't lose their palette. If Olivier wants history to clear on reset, flip one line.

### SwiftUI binding plumbing

Add `@State` mirrors to `ThemeSettingsSection`:

```swift
@State private var lightGradientEnabled: Bool = ThemeStore.shared.lightGradientEnabled
@State private var darkGradientEnabled: Bool = ThemeStore.shared.darkGradientEnabled
@State private var lightActiveGradient: Gradient? = ThemeStore.shared.lightActiveGradient
@State private var darkActiveGradient: Gradient? = ThemeStore.shared.darkActiveGradient
@State private var gradientHistory: [Gradient] = ThemeStore.shared.gradientHistory
@State private var editingGradient: (mode: UIUserInterfaceStyle, gradient: Gradient)?  // sheet trigger
```

`.onChange` for each writes through to `ThemeStore` + calls `applyTheme()` (existing helper at `ThemeSettingsSection.swift:220`), which posts `ThemeStore.didChangeNotification` and calls `appDelegate.applyCustomThemeAndReload()`. The notification observers in HomeVC and the new ones added to the base-class / per-VC wiring pick up the change and re-install the gradient view.

---

## Built-in presets recommendation

**Five presets.** Keep the list short to avoid a "which preset?" paralysis and lean on the gradient editor for power users.

Presets are seeded into `gradientHistory` on first launch (only if history is empty — detect with an `hasSeededPresets` flag or just by checking `gradientHistory.isEmpty`). They appear alongside user-created gradients in the same carousel; they're not second-class citizens and can be deleted/overwritten in history.

| # | Name (internal) | Colors | Direction | Mood |
|---|-----------------|--------|-----------|------|
| 1 | Sunset | `#FF6B6B`, `#FFD93D` | topToBottom | Warm, vivid |
| 2 | Ocean | `#1A2980`, `#26D0CE` | topToBottom | Cool, calming |
| 3 | Midnight | `#232526`, `#414345` | topToBottom | Dark-mode friendly, subtle |
| 4 | Meadow | `#56ab2f`, `#a8e063` | topLeftToBottomRight | Fresh, diagonal |
| 5 | Paper | `#F5F7FA`, `#C3CFE2` | topToBottom | Light-mode friendly, subtle |

**Rationale.** Covers two obvious dark-mode-friendly options (Midnight, Ocean), two light-mode-friendly (Paper, Meadow), one statement option (Sunset). Every preset uses exactly 2 colors — users who want more complexity hit the editor.

Store presets in code as `Gradient` static constants under `Gradient.builtInPresets: [Gradient]`, seeded on first launch via a one-shot call at app startup (`applicationDidFinishLaunching` or lazy on first settings-screen open).

---

## BUG-1 fix plan

**Symptom:** a user with `amperfy.fork.theme.enabled = true` and `amperfy.fork.theme.light.text = <value>` stored (from pre-17.4 Release 1 install path) but `amperfy.fork.theme.light.headingText` absent sees the Heading Color picker default to `.label` instead of the migration value. Runtime fallback works (because `dynamicHeadingText` at `ThemeStore.swift:159-167` falls through `heading ?? body ?? .label`), but the picker display in Settings is wrong because `populateDefaultsIfNeeded()` is only called on the enabled-toggle OFF→ON transition (`ThemeSettingsSection.swift:106-108`), not on app launch.

**Fix.** Extend `AppDelegate.applyCustomThemeAppearance()` to call `populateDefaultsIfNeeded()` at the top, when `theme.isEnabled` is true:

```swift
func applyCustomThemeAppearance() {
  let theme = ThemeStore.shared
  guard theme.isEnabled else {
    // existing reset branch unchanged
    ...
    return
  }
  theme.populateDefaultsIfNeeded()   // NEW: BUG-1 fix
  if let backgroundColor = theme.dynamicBackground { ... }
  ...
}
```

Location: `Amperfy/AppDelegate.swift:141` (the start of `applyCustomThemeAppearance`, just after the `guard theme.isEnabled` block exits the reset path, line ~169/170).

**Why it's safe:**

1. `populateDefaultsIfNeeded()` is idempotent — every mutation is gated by a nil check (`if lightHeadingText == nil { ... }`). Repeated calls on a fully-populated store do nothing.
2. It's called *after* the `guard` returns on disabled theme, so it only runs when the theme is actually active. A user who never enabled the theme won't get surprise UserDefaults writes.
3. `applyCustomThemeAppearance()` is called from `configureDefaultNavigationBarStyle()` (`AppDelegate.swift:138`) during app launch, so the migration runs before any settings UI is rendered.

**QA verification:** see criterion 17 below — simulate pre-17.4 state, launch on 17.5 build, open Settings, verify Heading picker shows the body-tier color (not `.label`).

---

## QA acceptance criteria

Test server: any Navidrome or Subsonic account with at least 10 albums, mix of cached and uncached. Fresh install for tests 1, 15, 17; existing theme state for tests 2-14, 16, 18.

### Built-in presets + carousel

1. **First-launch seed.** Install fresh (delete app first), open → Settings → Appearance. Scroll to "Background Gradient" section. "Previously Used" carousel shows 5 preset gradients in the documented order (Sunset, Ocean, Midnight, Meadow, Paper).

2. **Preset tap applies to Light.** With `Use Gradient (Light)` toggle OFF, tap the Sunset preset swatch. Expected: toggle flips ON, light mode active gradient = Sunset, main app background (Home tab, Albums tab) renders the Sunset gradient.

3. **Preset tap applies to Dark.** Switch system to Dark Mode (Settings.app → Display & Brightness → Dark). Back to app → Settings → Appearance. Tap the Midnight preset. Dark mode active gradient = Midnight; main app + album detail now render Midnight.

4. **Long-press mode menu.** Long-press any preset swatch in the carousel. Context menu offers "Apply to Light" and "Apply to Dark". Select one, verify the corresponding mode's active gradient updates.

### Main app background coverage

5. **Home tab gradient.** Enable a distinct gradient (e.g., Sunset) in light mode. Open Home tab. Gradient paints behind all sections (Random Albums, Recently Played Albums, etc.). Cells/album-art thumbnails render normally over the gradient.

6. **Albums tab gradient.** Navigate to Albums tab. Full tableView surface (or collection view in grid mode) shows the gradient. Scrolling does not reveal solid-color "gap" artifacts.

7. **Artists / Playlists / Genres / Podcasts / Radios / Downloads / Search.** Each tab/view paints the gradient edge-to-edge. No VC regressions where `.backgroundColor` was replaced but the observer wasn't wired.

8. **Nested VCs.** Push ArtistDetail from Artists tab, PlaylistDetail from Playlists tab. Both render the gradient.

### Album detail surface

9. **Album detail background.** Tap into any album from Albums tab. `GenericDetailTableHeader` sits on top of the gradient; table rows sit on top of the gradient (cells use opaque or semi-opaque default backgrounds — verify legibility, not a cell-background bug).

10. **Album detail gradient matches main app.** Given the "same gradient, two surfaces" design call: the gradient visible in Home + Albums is identical to the one under Album Detail. If Olivier opted for separate gradients, this test inverts.

### Gradient editor

11. **Open editor via preview tap.** Settings → Appearance → Background Gradient → tap the `Use Gradient (Light)` preview swatch while the toggle is ON. Gradient editor sheet opens. Shows current active gradient's colors (2-4 wells) and direction picker.

12. **Live preview.** Change Color 1's well to red. Preview updates live (no "Apply" required to see the change).

13. **Add / remove color.** Tap `+ Add Color`. A third color well appears. Tap its remove button. Back to 2 colors. Remove button is hidden/disabled when `colors.count == 2`. Add button is disabled when `colors.count == 4`.

14. **Apply & Save adds to history.** With an edited gradient, tap Apply & Save. Sheet dismisses, `Use Gradient` preview shows the new gradient, and the Previously Used carousel now has the new gradient prepended (5 presets + 1 new = 6 swatches).

15. **History dedup.** Edit a gradient to the exact colors + direction of the Sunset preset. Apply & Save. The Sunset preset moves to the front of the carousel; no second Sunset entry appears.

### Toggle behavior

16. **Gradient toggle OFF = solid background restored.** Flip `Use Gradient (Light)` OFF. Main app, Album Detail revert to the solid background color from the "Background" row. No "ghost" gradient remains visible.

### BUG-1 fix verification

17. **Pre-17.4 migration in picker.** Simulate a pre-Release 1 (pre-17.4) user via `xcrun simctl defaults`:
    ```
    xcrun simctl spawn <UDID> defaults write dev.thisolivier.amperfy amperfy.fork.theme.enabled -bool YES
    xcrun simctl spawn <UDID> defaults write dev.thisolivier.amperfy amperfy.fork.theme.light.text '#228B22'
    # NOT writing amperfy.fork.theme.light.headingText
    ```
    Cold-launch the Release 3 build. Open Settings → Appearance. Expected: Heading Color well shows green (`#228B22`), matching the body text color — NOT the `.label` gray it showed pre-fix. Runtime rendering on Home/detail headings is also green (existing 17.4 behaviour; regression check).

### Reset + contrast

18. **Reset to Defaults clears gradient state but keeps history.** With a custom gradient active and a non-empty history carousel, tap Reset. Confirm. Expected: theme toggle OFF, gradient enabled flags OFF, active gradients cleared, solid colors cleared. Re-enable custom theme — `Use Gradient (Light/Dark)` toggles are OFF, but the Previously Used carousel **still shows the 5 presets + any user-created history entries**. (Non-material decision locked here; see Open Questions if this needs reversing.)

19. **Contrast warning under gradient.** Set a gradient whose dominant colors are near-white (e.g., Paper) and set Body Color to a light gray. Existing contrast warning surfaces ("Light: low body/background contrast"). **Nuance:** the warning compares against the solid `Background` color, not a weighted average of gradient stops — flag as known limitation in the open questions. A more faithful check would sample gradient midpoints, but that's scope creep for PR 17.2.

20. **Theme disabled = gradient off.** Flip `Custom Theme` master toggle OFF. Main app + album detail revert to stock `.systemBackground` immediately (no relaunch). Re-enable master toggle: stored gradient state restored as it was.

21. **Across-launch persistence.** With light/dark gradients both set and Use Gradient toggles both ON, kill + relaunch. Both gradients still active, carousel still populated.

---

## Risks

1. **Text contrast over gradients.** A gradient spans a luminance range; the body-text color that contrasts fine at one end may wash out at the other. The PR 17.4 contrast warning only checks against the solid `Background` color — under a gradient it's checking against a dormant value. Mitigation: flag in open questions, ship with the existing contrast check, defer gradient-aware contrast to Release 4 or 5. Realistically, the built-in presets are chosen to be mid-luminance and users picking custom gradients self-select for legibility.

2. **Album art legibility.** Album thumbnails on Home and Albums tab now render against a potentially-bright gradient. Mitigation: album thumbnails have inherent opaque backgrounds (the artwork image itself); this is a visual-polish concern, not a correctness issue. The PR 17.3 album art borders (Release 4) will incidentally mitigate this by adding a crisp visual boundary between thumbnail and gradient.

3. **Cell background opacity.** `UITableViewCell.appearance().backgroundColor` is set to `theme.dynamicBackground` at `AppDelegate.swift:174`. When a gradient is enabled, this means cells still paint themselves with a solid color on top of the gradient — the gradient only shows at the gaps between cells (typically zero gap). **This makes the gradient visually invisible unless we do additional work.** Two fixes:
   - **Fix A (recommended):** when a gradient is enabled for the active style, set `UITableViewCell.appearance().backgroundColor = .clear` and `UICollectionViewCell.appearance().backgroundColor = .clear`. The gradient shows through everywhere. Risk: system-drawn separators, swipe actions, and selection highlights may look different on a transparent cell. Manual QA verification required.
   - **Fix B:** accept the "gradient only shows at edges" visual and treat the Background color and gradient as nearly interchangeable. This is probably not what Olivier wants since it defeats the feature.
   Recommendation: **Fix A** with a QA pass on selection highlight / swipe actions on at least Albums tab, Playlists tab, and Album Detail. If anything looks broken, fall back to per-cell-type overrides.

4. **Orthogonal-scrolling section on Home.** Home uses a compositional layout with `orthogonalScrollingBehavior = .continuous` (see `HomeVC.swift:153`). Each orthogonal section creates an internal horizontal scroll view. The gradient `backgroundView` applies to the outer collectionView only, which is correct — the horizontal scrollers are child scroll views and will be transparent by default. Low-risk but verify on manual QA.

5. **Performance.** `CAGradientLayer` is GPU-composited and cheap. No concern for 2-4 color stops and static positions. No animation = no per-frame work. Setting `tableView.backgroundView = <custom UIView>` is standard UIKit and does not affect scrolling throughput.

6. **Trait collection changes.** When user toggles light↔dark system-wide, `applyCustomThemeAppearance()` re-runs via `applyCustomThemeAndReload()` from some paths but not all. HomeVC's notification observer handles theme-change notifications; VCs that receive the gradient injection via `applyBackgroundSurface(...)` need the same observer wiring. The implementer must audit: does every gradient-injected VC observe `ThemeStore.didChangeNotification` AND `UITraitCollection` changes (via `traitCollectionDidChange` or `registerForTraitChanges`)? Worst case: user switches system to dark but gradient stays on the light one until the VC is re-created. Not a correctness bug but a polish bug.

7. **Many-file mechanical edit.** 29 VCs set `.backgroundColor` directly. Missing one means that VC shows a solid background when the gradient is enabled. Mitigation: a grep audit during implementation + a QA pass walking every tab.

8. **History list unbounded growth.** Without the 20-entry soft cap in `rememberGradient`, a user editing heavily could accumulate hundreds of history entries. The soft cap defends `UserDefaults` size (UserDefaults isn't sized for arbitrary growth). At 20 entries × ~100 bytes JSON each = 2 KB. Comfortable.

9. **`Codable` for `Gradient` over UserDefaults.** UserDefaults stores `Data`; we JSON-encode the Gradient. On decode failure (corrupted defaults, future schema migration), fall back to nil with a log. Implementer must not `try!` the decode path.

---

## Open questions

1. **Same gradient on main app + album detail, or separate?** Designer call: **same** (one gradient slot per mode, applied to both surfaces). Rationale in "Album detail background" above. If Olivier wants two independent gradient slots, it doubles the settings UI and roughly doubles the implementation complexity — flag before starting.

2. **Does Reset to Defaults clear the Previously Used history?** Designer call: **no, keep history across reset** — history is a lightweight palette the user has curated, orthogonal to the active theme state. Reset = clear *active* state only. If Olivier disagrees, flip one line in `resetToDefaults()` to also clear `.gradientHistory`.

3. **Contrast warning under gradient — accept limitation?** The existing check compares text color against the solid `Background` color (still stored even when gradient is active). Under a gradient the check is misleading. Designer call: **accept the limitation for PR 17.2**, document it in the QA report, revisit in Release 5 (presets) or a dedicated contrast pass. Alternative: compute contrast against the *average* of gradient stops — cheap but still approximate.

4. **Cell background when gradient is enabled — `.clear` globally?** (See Risk 3.) Designer call: **yes, clear cell backgrounds when gradient is enabled**, with manual QA on selection highlight / swipe actions. If anything breaks, narrow the fix to a whitelist of cell types. Olivier: confirm this is the right trade-off vs keeping cells opaque and losing the gradient visually.

5. **Maximum colors — 4 or higher?** Designer call: **4**. Keeps the editor UI manageable and the preview readable. Olivier: confirm, or request higher / lower cap.

6. **Preset list — 5 presets as listed, or adjust the palette?** The names and colors above are a designer starting point. Olivier may want to tweak names ("Midnight" vs "Dusk"), colors, or swap one preset out entirely. Low-cost to change; no structural impact.

7. **Where does tapping a preset in the carousel apply — mode-aware or last-active-mode?** Designer call: **tap applies to the mode of whichever preview row the user most recently opened** (or current system appearance on first tap after launch); long-press opens an explicit "Apply to Light / Apply to Dark" menu. This covers both casual and explicit users. Confirm this UX is clear enough or whether it needs simplifying.
