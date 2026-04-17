# Release 4 — Design Review (PR 17.3 Borders + PR 20 Theme Restructure / Gradient Bug + PR 21 Settings UI Cleanup)

Review date: 2026-04-15
Reviewer: designer agent
Implementer target: `spike/amperfy/` on branch `olivierMain`
Build under review: Build 38 (Release 3 shipped; gradient picker regression surfaced)

## Summary

Release 4 bundles three closely-related themeing PRs plus a cross-cutting navigation restructure:

- **PR 17.3 — Album art borders.** Configurable (color + width) borders on all album artwork, including the 4-tile playlist composite. Default off (width = 0). Plumbs from `ThemeStore` through **one** central render site: `AmperfyKit/Screens/EntityImageView.swift`. Border applies to both the `singleImage` path and the four `quadImage` tiles' outer frame. No per-cell refactor needed.
- **PR 20 — Theme settings restructure + gradient bug fix.** The Build 38 regression is a SwiftUI presentation-chain collapse: a `.sheet(item:)` + `.confirmationDialog` stack attached to an inline `ThemeSettingsSection` inside a `List` inside a `UIHostingController` inside a `.formSheet` modal. Fix = retire the sheet entirely and push to a dedicated gradient picker screen via `NavigationLink` — which is exactly what the restructure spec wants anyway. The restructure also flattens gradients to 2 stops, hoists Custom Theme to a top-level Settings row, and replaces the flat "Light Mode Colors / Dark Mode Colors" sections with two push-detail rows.
- **PR 21 — Settings UI cleanup.** Gradient injection extended to the Settings modal's host VC + SwiftUI root; Offline-mode footer promoted into the same rounded section as the toggle; Library-tab sidebar cells made transparent under any custom theme (not only gradient) so themed backgrounds flow through.

Non-material design calls made without waiting on Olivier (flagged in Risks):
- **Border color default** = system `.separator` resolved at picker open (so the default picker isn't a confusing middle-grey block). Width default = 0 so users see no change until they opt in.
- **Border width unit** = points, not pixels. Store as `Double`, expose as a stepper/slider 0–6 pt.
- **Gradient migration** — just ignore extra middle stops on decode; don't rewrite UserDefaults on migration. Simpler; a re-pick by the user cleans it naturally. Built-in presets are already 2-stop.
- **Custom Theme row style** — reuse `SettingsRow` label + disclosure indicator. No badge / no icon beyond `systemImage: "paintpalette.fill"` for parity with the other root rows.

---

## PR 17.3 — Album art borders

### Render sites

There is **one central render site** that covers both 17.3 targets:

- **`AmperfyKit/Screens/EntityImageView.swift`** — `open class EntityImageView: UIView`. Owns `singleImage: LibraryEntityImage` (single-tile path, `RoundedImage` subclass) plus `quadImage1..4: LibraryEntityImage` (4-tile path). `display(theme:container:cornerRadius:)` branches between them. Every album / artist / playlist thumbnail in the app goes through this view (loaded from `EntityImageView.xib`; the XIB is wired in every `*TableCell.xib` / `AlbumCollectionCell.xib`).
- **`AmperfyKit/Screens/RoundedImage.swift`** — base class for `LibraryEntityImage`. Already owns `layer.cornerRadius` + `layer.masksToBounds = true`. The border lives on the **same layer** as the corner radius, so the 17.3 render is additive: `layer.borderColor = ...; layer.borderWidth = ...`.

Additional render sites that use `RoundedImage` standalone (not through `EntityImageView`):
- `Amperfy/Screens/Player/MiniPlayerView.swift`, `LargeCurrentlyPlayingPlayerView.swift`, `CurrentlyPlayingTableCell.swift`, `PopupPlayer+Animations.swift`, `DirectoryTableCell.swift` — these are player-surface art views. **Olivier's spec explicitly excludes Now Playing** (per §17.2 scoping precedent); PR 17.3 says "album artwork thumbnails AND the 4-tile composite". Ship borders on `EntityImageView`'s subviews only. The Now-Playing `RoundedImage`s opt out by virtue of not living inside an `EntityImageView`.

### Data model

Add two keys to `Amperfy/ThemeStore.swift`:

```
private enum Key {
  ...
  static let albumArtBorderWidth = "amperfy.fork.theme.albumArt.borderWidth"
  static let albumArtBorderColor = "amperfy.fork.theme.albumArt.borderColor"
}

var albumArtBorderWidth: CGFloat {
  get { CGFloat(defaults.double(forKey: Key.albumArtBorderWidth)) }  // defaults 0.0
  set { defaults.set(Double(newValue), forKey: Key.albumArtBorderWidth) }
}

var albumArtBorderColor: UIColor? {   // nil = use .separator resolved per trait
  get { color(forKey: Key.albumArtBorderColor) }
  set { setColor(newValue, forKey: Key.albumArtBorderColor) }
}
```

Border is a **single global** across light/dark (one color, one width). The color picker uses `supportsOpacity: false` same as existing color rows. If Olivier later wants per-mode border colors, extend to `lightAlbumArtBorderColor` / `darkAlbumArtBorderColor` in a follow-up — not in this release (keeps the per-mode detail screen uncluttered).

### Apply pipeline

Add a method to `EntityImageView`:

```swift
public func applyArtworkBorder() {
  let width = ThemeStore.shared.isEnabled ? ThemeStore.shared.albumArtBorderWidth : 0
  let color = ThemeStore.shared.albumArtBorderColor ?? UIColor.separator
  let resolvedColor = color.resolvedColor(with: traitCollection).cgColor

  singleImage.layer.borderWidth = width
  singleImage.layer.borderColor = resolvedColor
  for quad in [quadImage1, quadImage2, quadImage3, quadImage4] {
    quad?.layer.borderWidth = width
    quad?.layer.borderColor = resolvedColor
  }
}
```

Call sites:
1. End of `loadViewFromNib()` — initial apply.
2. End of `display(theme:collection:cornerRadius:)` — re-apply after the `quadImages.forEach { $0.isHidden = true }` + display toggle (the quad tiles may be freshly recycled).
3. `traitCollectionDidChange(_:)` override — so the resolved dynamic color updates when user flips appearance mode.
4. Listener on `ThemeStore.didChangeNotification` — so changing the picker updates already-loaded views without requiring a reload (matches the HomeVC / LibraryNavigatorConfigurator observer pattern).

Because `AmperfyKit` can't `import` the Amperfy app target, read through the existing cross-module UserDefaults trick used by `UIColor.backgroundColor` in `AmperfyKit/Common/Utilities.swift` — OR add the two properties via a small `AmperfyKit` `@objc` extension on a kit-side singleton (e.g., `LibraryEntityImage.borderConfig`). Simpler: **read UserDefaults directly from `EntityImageView`** using the same key-string pattern Utilities already uses. No app-target import required.

### Settings UI

Borders live inside the per-mode detail screen added by PR 20 — specifically under a **"Artwork" subsection** inside the shared detail screen (or, cleaner, as its own section at the bottom of the root Custom Theme screen since it's mode-independent):

```
Custom Theme
  [Toggle] Custom Theme
  > Light Mode
  > Dark Mode
  > Font Family
  Album Art
    [slider 0–6 pt]  Border Width   2 pt
    [colorWell]       Border Color
  [button] Reset to Defaults
```

Width row is a `Stepper` or a compact `Slider` with a value label. Recommended: `Stepper(value: $borderWidth, in: 0...6, step: 1)` — cheaper to drive, preview is instantaneous via the theme-change notification.

---

## PR 20 — Theme settings restructure + gradient picker bug fix

### Gradient picker bug — root-cause diagnosis

**Reproduction (Build 38):** Settings modal → Display & Interaction → tap "Light Mode Gradient" preview swatch → sheet titled "Edit Light Mode Gradient" slides up for one frame, then dismisses, AND the outer Display settings modal pops back to the Settings root.

**Culprit:** a stacked SwiftUI presentation collapse. The chain is:

```
SettingsHostVC (UIViewController, .formSheet modal)
 └─ UIHostingController
     └─ SettingsView (NavigationView)
         └─ NavigationLink(.displayAndInteraction) → DisplaySettingsView
             └─ SettingsList (SwiftUI List, grouped inset)
                 └─ ThemeSettingsSection  <- inline View with .sheet(item:) + .confirmationDialog attached to a Group
                     ├─ SettingsSection(Toggle, header: "Custom Theme")
                     ├─ SettingsSection(colorRow × 4, header: "Light Mode Colors")
                     ├─ SettingsSection(colorRow × 4, header: "Dark Mode Colors")
                     └─ SettingsSection(gradientModeRow × 2 + carousel, header: "Background Gradient")
```

Specifically (see `Amperfy/SwiftUI/Settings/ThemeSettingsSection.swift:113-146`):

```swift
var body: some View {
  Group { mainContent }
    .sheet(item: $editorTarget) { target in GradientEditorView(...) }
    .confirmationDialog("Use this gradient for…", isPresented: $showHistoryActionSheet, ...) { ... }
}
```

Two compounding problems:

1. **`.sheet(item:)` attached to a `Group` of multiple `Section`s inside a `List`.** SwiftUI flattens the Group into sibling list items. The `.sheet` modifier is attached to a *transient* view identity — when the tap handler mutates `editorTarget`, the body re-evaluates; the Group may re-identify; SwiftUI tears down the presenting view's identity and the sheet dismisses mid-animation. This alone can cause the child sheet to disappear one frame after it presents.

2. **The List is rendered inside a nested `NavigationView` inside a `UIHostingController` inside a `.formSheet` modal.** When SwiftUI tears down the sheet's presenting identity during a dismiss cascade, it can propagate the dismiss up to the parent `.formSheet` host — this is the well-known "SwiftUI sheet dismisses its grandparent" bug on iOS 16/17 (still reproducible on 26.4 per Build 38 testing). The `.confirmationDialog` attached to the same Group makes it worse: SwiftUI decides which presentation to honor using view identity, and a rebuild during presentation picks the "wrong" one and dismisses both.

Corroborating evidence: Release 3 QA Bug 1 (`QA_REPORT_RELEASE_3.md`) noted the UI had diverged from the spec sketch — the toggle-based Light/Dark row design was collapsed into direct preview taps. That collapse is what pushed the `.sheet(item:)` attachment down to this awkward Group-inside-List location.

**Concrete fix:** delete the `.sheet(item:)` entirely. The PR 20 restructure **already replaces the sheet with a pushed navigation screen** — do that replacement first, and the bug vanishes as a side effect. The sheet becomes:

```
NavigationLink {
  GradientPickerScreen(
    targetStyle: .light,
    initialGradient: ThemeStore.shared.activeGradient(for: .light),
    onApply: { ... }
  )
} label: {
  HStack { [swatch] Text("Gradient") [preview] chevron }
}
```

`NavigationLink` pushes onto the **same `NavigationStack`** that hosts the per-mode detail screen — no sheet, no presentation-chain collapse, no dismiss cascade. As a bonus, the `.confirmationDialog` for "apply to Light / Dark" is no longer needed: the user is already on a mode-specific screen when they edit a gradient, so the target style is implicit.

**Secondary cleanup:** once the sheet is gone, audit `ThemeSettingsSection.swift` for any stale `.sheet` / `.confirmationDialog` on ancestor views and remove them (verify nothing further up the chain keeps a stale binding).

### Navigation restructure — flow

**Before (Build 38):**

```
Settings root
  └─ Display & Interaction
      └─ ThemeSettingsSection (inline)
          ├─ Section "Custom Theme" — toggle
          ├─ Section "Light Mode Colors" — 4 color rows, flat
          ├─ Section "Dark Mode Colors" — 4 color rows, flat
          ├─ Section "Background Gradient" — 2 preview rows + carousel + [.sheet bug]
          ├─ Section "Font" — font picker nav
          └─ Section "" — Reset button
```

**After (Release 4):**

```
Settings root                                        ← PR 20.4: Custom Theme moves here
  └─ ...
  └─ Custom Theme                                    ← new top-level row (disclosure)
       └─ CustomThemeRootView (NavigationStack child)
           ├─ Section "Custom Theme" — [Toggle]
           ├─ Section "" — [chevron row]  > Light Mode      ← pushes ModeDetailView(.light)
           │                 [chevron row]  > Dark Mode      ← pushes ModeDetailView(.dark)
           ├─ Section "Typography" — > Font Family
           ├─ Section "Album Art" (PR 17.3) — Border Width, Border Color
           └─ Section "" — [Reset to Defaults]

ModeDetailView(.light)
  ├─ Section "Colors" — Background / Heading / Body / Tint  (colorRows, unchanged)
  ├─ Section "Gradient" — > Gradient   [preview swatch] [disclosure]
  │                             └─ pushes GradientPickerScreen(.light)
  └─ (no reset — reset lives at the root screen)

GradientPickerScreen(.light)
  ├─ Section "" — [Live preview strip, 120 pt tall]
  ├─ Section "Colors" — [ColorPicker] Start Color, [ColorPicker] End Color
  ├─ Section "Direction" — inline Picker (6 directions)
  ├─ Section "Previously Used" — horizontal scroll of swatches, tap = apply immediately
  ├─ Section "" — [button] Clear Gradient (destructive; disabled if none active)
  └─ toolbar: navigationBarTitleDisplayMode(.inline), back button returns to ModeDetailView
```

Key changes vs Build 38:
- **Two-stop gradients only.** `GradientPickerScreen` has exactly two `ColorPicker` rows (Start / End). No Add / Remove controls. `ThemeGradient.maxColorCount` drops to 2 (constant both `minColorCount` and `maxColorCount` = 2). The editor code at `GradientEditorView.swift:71-98` — the `ForEach` + Add/Remove affordance — collapses to two static rows.
- **Apply & Save is implicit.** The Start/End pickers mutate the preview live; a separate "Apply" button is removed. On back-nav (pop), the final state is committed via `onDisappear` (or: each mutation calls `applyGradient(...)` immediately, which is the cleaner live-preview UX and matches how the per-mode color rows already work). Preference: **live-apply on every change**, consistent with the existing color rows.
- **"Previously Used" carousel** lives on the gradient picker screen (not on the parent), filtered to show all history regardless of which mode created the entry. Tap = apply to this mode + pop back, OR apply in-place and stay (preference: apply-in-place; user can manually pop).
- **Cancel button is just the back button.** No dedicated Cancel action — back-nav keeps the current live state (or discards, TBD — see open question Q3).

### Implementation shape

Three new SwiftUI view files (or three structs in one file — file-size guide is under 200 lines):

- **`CustomThemeRootView`** — replaces the inline `ThemeSettingsSection` as a standalone view pushed from the Settings root. Parameterised with no args; reads `ThemeStore.shared`.
- **`ModeDetailView`** — parameterised with `style: UIUserInterfaceStyle`. Contains Background/Heading/Body/Tint color rows and a gradient row (NavigationLink). Title = "Light Mode" / "Dark Mode".
- **`GradientPickerScreen`** — parameterised with `style: UIUserInterfaceStyle`. Start/End color pickers, direction picker, previously-used carousel, clear button. Title = "Light Gradient" / "Dark Gradient".

Delete `GradientEditorView.swift` outright (replaced by `GradientPickerScreen`) or keep the `GradientPreviewSwiftUIView` helper struct (it's re-used by the carousel + preview strip). Keep the helper; delete the `GradientEditorView` struct and its initialiser.

Wiring into the Settings root (`SettingsView.swift:119-143`):

```swift
SettingsSection {
  navigationLink(.whatsNew)
}

SettingsSection {
  navigationLink(.customTheme)        // ← new, PR 20.4
  navigationLink(.account)
  navigationLink(.displayAndInteraction)
  navigationLink(.library)
  ...
}
```

Add a `.customTheme` case to `NavigationTarget` (icon `paintpalette.fill`, displayName "Custom Theme", view `CustomThemeRootView()`). Remove `ThemeSettingsSection()` from `DisplaySettingsView.swift:58`.

**Deep-link / observer compatibility:** the `ThemeStore.didChangeNotification` + `applyCustomThemeAndReload` pipeline is unchanged — views and VCs already observe the store, not the SwiftUI hierarchy. No UIKit observers need to migrate. No stored UserDefaults keys rename. The only breakages are if some test or code path deep-links specifically to `NavigationTarget.displayAndInteraction` expecting the theme section there; `grep -n "\.displayAndInteraction"` shows only storyboard / navigation-target registration sites, no deep-link code. Safe.

### Two-stop migration

`ThemeGradient` already stores `colors: [String]`. Build 38 installs may have gradients with 3 or 4 stops. **Decode tolerance** in `ThemeGradient` (already Codable, tolerant of any count — see the struct comment) plus a **first-and-last reducer at read time** in `ThemeStore.activeGradient(for:)`:

```swift
func activeGradient(for style: UIUserInterfaceStyle) -> ThemeGradient? {
  let key = style == .dark ? Key.darkGradientActive : Key.lightGradientActive
  guard let stored = decodeGradient(forKey: key) else { return nil }
  return stored.reducedToTwoStops()
}

extension ThemeGradient {
  func reducedToTwoStops() -> ThemeGradient {
    guard colors.count > 2 else { return self }
    return ThemeGradient(colors: [colors.first!, colors.last!], direction: direction, id: id)
  }
}
```

Gradient history is trimmed the same way in the history getter. No one-time migration write needed; next time the user edits + saves, the canonical 2-stop form is persisted.

Update `ThemeGradient.minColorCount = 2`, `maxColorCount = 2`. `GradientTest.testBuiltInPresetsShape` asserts "all 2-4 colors" — tighten to `== 2` (all 5 built-ins are already 2-stop; no data change).

---

## PR 21 — Settings UI cleanup

### 21.1 — Gradient injection into the Settings modal

**Current state.** `SettingsHostVC.swift:71` sets `view.backgroundColor = .clear` and hosts a `UIHostingController` whose `view.backgroundColor = .clear`. The child `SettingsView` / `SettingsTabView` then renders a SwiftUI `NavigationView` / `NavigationSplitView` whose default background is a system-grouped grey. Because the hosting VC is `.formSheet`-presented **over** the main app window, the gradient that paints on `HomeVC`'s `collectionView.backgroundView` is behind the modal dim — not visible through the modal.

**Fix.** Install a `GradientBackgroundView` on `SettingsHostVC.view` itself when a gradient is active for the current trait collection. Pseudo:

```swift
// SettingsHostVC.swift — add to viewDidLoad() / viewIsAppearing
private func installThemeBackground() {
  themeBackgroundView?.removeFromSuperview()
  themeBackgroundView = nil
  let style = traitCollection.userInterfaceStyle
  if let gradient = ThemeStore.shared.resolvedGradient(for: style) {
    let bg = GradientBackgroundView(gradient: gradient)
    bg.frame = view.bounds
    bg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.insertSubview(bg, at: 0)    // behind the hostingVC.view
    themeBackgroundView = bg
  } else if let solidBg = ThemeStore.shared.dynamicBackground {
    view.backgroundColor = solidBg
  } else {
    view.backgroundColor = .systemGroupedBackground
  }
}
```

Observe `ThemeStore.didChangeNotification` in `SettingsHostVC` and re-install when theme changes (user may flip gradient on/off while Settings is open). Observe `traitCollectionDidChange` for appearance-mode swaps.

**Also required:** the SwiftUI `NavigationView` / `NavigationSplitView` inside `SettingsHostVC` will paint its own grouped-background color over the gradient unless we make it transparent. Two options:

1. Apply `UITableView.appearance(whenContainedInInstancesOf: [UIHostingController.self]).backgroundColor = .clear` from `AppDelegate.applyCustomThemeAppearance()` when a gradient is active. Already partially done for `UITableViewCell.appearance()` (`AppDelegate.swift:195-197`); extend to `UITableView.appearance()` inside hosting contexts if not already covered. **Verify first** — the existing `UITableView.appearance().backgroundColor = backgroundColor` at `AppDelegate.swift:185` sets a solid colour; when a gradient is active, this is the wrong fill. Change to match the cell logic: if `theme.isAnyGradientEnabled`, set `UITableView.appearance().backgroundColor = .clear`.
2. Add a `.scrollContentBackground(.hidden)` modifier to the SwiftUI `List` inside `SettingsView` / `SettingsTabView` / `DisplaySettingsView` / `LibrarySettingsView` etc. (iOS 16+). This is the SwiftUI-idiomatic approach and doesn't require an appearance-proxy guard. Recommended — cleaner, view-local, no global side effects.

**Preferred approach: #2** (per-list `.scrollContentBackground(.hidden)`) applied to the root `SettingsList` helper. Since `SettingsList` is a thin wrapper (confirm in `Amperfy/SwiftUI/Basics/SettingsList.swift`), add the modifier conditionally on `ThemeStore.shared.isAnyGradientEnabled || ThemeStore.shared.isEnabled`, so the themed background (gradient OR solid) shows through.

### 21.2 — Row grouping audit

Full audit of `SettingsView.swift` body (lines 80-144) and each detail screen. Adjacencies where unified-section rounding is broken or separately-styled:

| Screen | Site | Issue | Fix |
|---|---|---|---|
| SettingsView root | line 92-98 "Offline Mode" section with footer | Footer renders as an uppercase gray caption **below** the rounded toggle, not inside the rounded corners. User reads as "janky". | Drop the `footer:` arg. Add a second row inside the same `SettingsSection` containing the descriptor as a `Text(...).font(.footnote).foregroundStyle(.secondary)` row. Both rows share one rounded-inset container. |
| SettingsView root | line 100-117 "Prevent Screen Lock" section | Single row, correct. No change. | — |
| SettingsView root | line 119-132 nav-link cluster (What's New + everything else) | Two separate `SettingsSection`s adjacent (whatsNew alone, then account/display/library/etc.). Visual break looks intentional (what's new is a "new" CTA) — keep. | — |
| SettingsView root | new row `Custom Theme` (PR 20.4) — placement | Sits in the nav-link cluster alongside Account/Display/etc. | Add as a sibling inside the existing `SettingsSection {}` wrapping lines 124-132. Not its own section. |
| DisplaySettingsView | lines 83-92 "Music Player Skip Buttons" | Uses `footer:` style again (descriptor under the toggle). | Same fix as Offline Mode — inline the descriptor as a secondary-styled row inside the section. |
| DisplaySettingsView | lines 110-118 "Detailed Information" | Same footer-under-toggle pattern. | Inline descriptor row. |
| DisplaySettingsView | lines 153-168 "Disable Player Shuffle Button" | Same footer-under-toggle pattern. | Inline descriptor row. |
| LibrarySettingsView | line 170 trailing close of first `SettingsSection` (Playlists/Artists/Albums/…/Initial Sync) then lines 174-178 "Background song sync" | Two adjacent sections with `header: "Cache"` / `"Background song sync"` are correctly separated. No change. | — |
| LibrarySettingsView | lines 180-269 "Cache" section with buttons (Download / Delete) | Buttons inside the same section as stats rows. Acceptable — the destructive button visually separates itself. No change. | — |
| ArtworkSettingsView, PlayerSettingsView, SwipeSettingsView | spot-check | These use section headers and inline descriptors. Audit pass: look for any standalone `Text(...)` outside sections and move inside. | — |
| CustomThemeRootView (new) | n/a | All rows belong to explicit sections (see PR 20 flow). Reset button gets its own trailing section. | — |

**General rule** to adopt (document in implementer brief): **no free-floating `Text` between sections**; **no `footer:` argument** for descriptor text — always inline as a secondary-styled row inside the parent section. The `SettingsSection` helper is agnostic to row count, so grouping is always one-section-one-rounded-container.

### 21.3 — Library tab transparency

**Site.** `Amperfy/Screens/ViewController/LibraryNavigatorConfigurator.swift` — the `UICollectionView.CellRegistration<UICollectionViewListCell, LibraryNavigatorItem>` block at `:336-370` and `:338-401`. Cells are configured with `cell.defaultContentConfiguration()` but **no `backgroundConfiguration` is applied** — they inherit the default `sidebarPlain` list appearance which paints an opaque near-black / near-white fill.

**Fix.** Add a `UIBackgroundConfiguration.clear()` override inside the cell registration when any custom theme is active:

```swift
var backgroundConfig = UIBackgroundConfiguration.listSidebarCell()
if ThemeStore.shared.isEnabled {
  backgroundConfig.backgroundColor = .clear
  backgroundConfig.backgroundColorTransformer = nil
}
cell.backgroundConfiguration = backgroundConfig
cell.contentConfiguration = content
```

This applies to **both** `libraryItem` rows (line 340-354) and `tabItem` rows (line 355-369) — the audit showed both paths go through the same cell registration block.

Also update `handleThemeChanged` at `:147-156` to `snapshot.reconfigureItems(snapshot.itemIdentifiers)` — already present, so the reconfigure re-runs cell registration and picks up the new background config. Good.

Additional `layoutConfig` note: at `LibraryVC.swift:48` and `LibraryNavigatorConfigurator.swift:150`, `config.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemBackground`. When a **gradient** is active this needs the same `.clear` treatment the cell appearance gets — otherwise the solid `dynamicBackground` fills the collection view and hides the gradient behind. Extend the `layoutConfig` assignment to:

```swift
if ThemeStore.shared.isAnyGradientEnabled {
  config.backgroundColor = .clear
} else {
  config.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemBackground
}
```

**Gradient flow-through:** `LibraryVC` is a `KeyCommandCollectionViewController` (UIKit), not a `BasicTableViewController` descendant. Check whether `applyBackgroundSurface(to: collectionView)` is currently called — per my reading of `LibraryVC.swift`, it is **not**. That's the direct cause of the Library tab not picking up gradient today. Add `applyBackgroundSurface(to: collectionView)` in `LibraryVC.viewDidLoad()` after `super.viewDidLoad()`, and observe `ThemeStore.didChangeNotification` to re-call on theme change. Matches the pattern from `BasicTableViewController` at `:129`.

---

## Top-level Custom Theme placement (PR 20.4)

### Current location (Build 38)

`ThemeSettingsSection()` is inlined inside `DisplaySettingsView.body` at `Amperfy/SwiftUI/Settings/DisplaySettingsView.swift:58`, inside a section between the "Appearance" picker and the "Haptic Feedback" section. Users reach it via: Settings → Display & Interaction → scroll.

### New location

Top-level Settings row, added to the nav-link cluster in `SettingsView.swift` lines 124-132. Users reach it via: Settings → Custom Theme (one tap from the Settings root).

### Refactor plan

1. **Remove inline section.** Delete `ThemeSettingsSection()` from `DisplaySettingsView.swift:58`. Also remove the `import AmperfyKit`-adjacent uses of `ThemeSettingsSection` if any (grep shows only the one usage).
2. **Add NavigationTarget case.** `Amperfy/SwiftUI/Settings/NavigationTarget.swift`:
   - Add `case customTheme` (between `displayAndInteraction` and `library` ordering doesn't matter, but alphabetical preferred).
   - `displayName`: `"Custom Theme"`.
   - `icon`: `.paintpalette` — extend `UIImage+AmperfyImageAssets` if `.paintpalette` isn't wired yet; fall back to `UIImage(systemName: "paintpalette.fill")`.
   - `systemImage`: `"paintpalette.fill"`.
   - `view()`: `CustomThemeRootView()`.
3. **Wire in SettingsView.** Add `navigationLink(.customTheme)` inside the existing `SettingsSection` at `SettingsView.swift:124-132`, as the first entry (above `account`) so it's visually prominent. Alternative: give it its own section directly above that cluster so it reads as a top-level row — Olivier specified "top-level row in the Settings root screen" which is softer than "its own section". Recommend **first entry of the existing nav-link section** for visual parity with neighbours; if Olivier wants more prominence, bump to its own section with a "Look & Feel" header.
4. **Create `CustomThemeRootView`.** New file `Amperfy/SwiftUI/Settings/CustomThemeRootView.swift`. Contains the Toggle + Light/Dark nav links + Font row + Album Art section + Reset section. Reuses `ThemeStore.shared` observers — no behavioural change from the current `ThemeSettingsSection`, only structure.
5. **Create `ModeDetailView`.** New file `Amperfy/SwiftUI/Settings/ModeDetailView.swift`. Colour rows (Background / Heading / Body / Tint) + Gradient nav link.
6. **Create `GradientPickerScreen`.** New file `Amperfy/SwiftUI/Settings/GradientPickerScreen.swift`. Start / End pickers, direction picker, previously-used carousel, clear action.
7. **Delete `GradientEditorView.swift`.** Or trim it down to just the helper `GradientPreviewSwiftUIView` + `ThemeGradient.swiftUIColors` extension and rename the file accordingly.

### Observer compatibility

- `ThemeStore.didChangeNotification` observers in UIKit VCs (HomeVC, BasicTableViewController, LibraryNavigatorConfigurator, GenericDetailTableHeader, SectionHeaderView, CommonCollectionSectionHeader): **unaffected** — they listen to the store, not the SwiftUI hierarchy.
- `AppDelegate.applyCustomThemeAndReload()` calls: unchanged — still called from `applyTheme()` in the moved-around setter views.
- Deep links: `NavigationTarget` enum's stringly-typed `id` is the rawValue of the case. Adding a new case doesn't break existing deep links. No existing code deep-links to `.displayAndInteraction` specifically to find the theme section (grep confirmed).

---

## QA acceptance criteria

Numbered for the QA report. Assume Release 3 baseline is green and a fresh install path is tested separately.

### PR 17.3 — Album art borders

1. **Default off.** Fresh install, Custom Theme OFF, album grid on Home + Albums tab shows art with **no border**.
2. **Toggle on + zero width = no visible border.** Turn Custom Theme ON; border width stored = 0. Album thumbnails still show no border (zero-width is effectively no border).
3. **Set width 2 pt.** Bump Border Width stepper / slider from 0 to 2. Home tab album thumbnails (single tile) immediately show a 2-pt border in the default color. No reload / navigation required.
4. **Default border color is `.separator`.** Before picking a color, the border renders in the system separator (dynamic per light / dark appearance).
5. **Custom border color.** Open Border Color picker, pick bright red (`#FF0000`). All single-tile thumbnails show red borders. All 4-tile composite thumbnails (playlist rows) show red borders on each of the four sub-tiles.
6. **Playlist 4-tile composite.** Navigate to Playlists tab, find a playlist with >= 4 distinct songs → the row's artwork renders as a 2×2 composite. Each of the 4 tiles shows the configured border + width. No gap in the outer ring.
7. **Playlist 1-song composite.** Navigate to a playlist with a single song (or all-same-artwork) → art renders as single image (the `Set(...).count == 1` path in `EntityImageView`) → single border, no 2×2.
8. **Album detail header artwork.** Scope note: the large album-detail hero artwork is NOT an `EntityImageView` (it's in `GenericDetailTableHeader`); ensure PR 17.3 does NOT apply a border to that surface. Olivier's spec is "thumbnails + 4-tile composite", not hero images.
9. **Appearance mode flip.** With Custom Theme ON + width 2 + color = `.separator` (default), flip device appearance light→dark. Border color resolves to the dark-mode separator tint (auto). No manual intervention.
10. **Persist across launch.** Set border width = 4 + color purple. Force-quit → relaunch → thumbnails still show 4-pt purple border immediately on Home render.
11. **Reset to Defaults clears border.** Settings → Custom Theme → Reset to Defaults → confirm. Border width resets to 0. Border color resets to nil. Thumbnails return to no-border rendering.
12. **Width cap.** Stepper / slider clamps at 6 pt maximum. Can't configure values outside 0...6.

### PR 20 — Theme restructure + gradient bug

13. **Settings root shows Custom Theme row.** Top-level Settings list includes a "Custom Theme" row with `paintpalette.fill` icon and disclosure indicator. Sits near Account / Display & Interaction / Library in the same visual cluster.
14. **Tap Custom Theme pushes to detail.** Tap → SwiftUI push → CustomThemeRootView appears. Title "Custom Theme". Contains Toggle + Light Mode row + Dark Mode row + Font Family + Album Art (borders) + Reset.
15. **Light Mode push.** Tap "Light Mode" → push to ModeDetailView(.light). Shows Background / Heading / Body / Tint color pickers + a Gradient row with a preview swatch.
16. **Dark Mode push.** Same as #15 for dark.
17. **Gradient row pushes to picker (no modal).** Tap Gradient row → push to GradientPickerScreen(.light). **No sheet slides up. No modal dismiss cascade. No flicker.** Verifies the Build 38 bug is dead.
18. **Gradient picker shows Start + End only.** Two color wells (labelled "Start Color" / "End Color"). No Add Color button. No Remove Color button. Direction picker below (6 options).
19. **Live apply on picker change.** Change Start Color to bright red in the picker. Pop back to ModeDetailView → swatch preview shows red→existing. Pop back to CustomThemeRootView → no additional confirmation. Pop to Settings root → navigate to Home tab → gradient visible with red start.
20. **Previously-Used carousel on picker screen.** Scroll down on GradientPickerScreen → "Previously Used" section visible with all history swatches. Tap any → applies immediately to this mode; carousel promotes the tapped entry to position 0.
21. **Clear gradient button.** On GradientPickerScreen, tap "Clear Gradient" (destructive styling). Active gradient for this mode clears → pop back → ModeDetailView swatch shows "Not set". Home tab gradient disappears → solid background restored.
22. **Two-stop migration from Build 38.** Pre-install Build 38 with a 3-stop gradient (e.g., red / white / blue). Upgrade to Release 4 → open GradientPickerScreen. Start Color = red, End Color = blue (middle stop discarded). Home tab shows red→blue gradient.
23. **Settings modal no longer dismisses on gradient interaction.** Open Settings → Custom Theme → Light Mode → Gradient → change Start Color → pop back all the way to Home → re-enter Settings root. Modal is still alive and navigable throughout.
24. **Deep-link still works for Display & Interaction.** Display & Interaction screen still exists and opens correctly. `ThemeSettingsSection` no longer appears inside it. No dead rows or broken layout.

### PR 21 — Settings UI cleanup

25. **Offline-mode descriptor in same section.** Settings root → Offline Mode toggle + its "Songs, podcasts, and artworks…" descriptor render as ONE rounded-inset group with unified corners. No visual break between toggle row and descriptor.
26. **Music Player Skip Buttons descriptor in same section.** Same structure as #25 applied to DisplaySettingsView's Skip Buttons row.
27. **Detailed Information descriptor in same section.** Same.
28. **Disable Player Shuffle Button descriptor in same section.** Same.
29. **Gradient active → Settings modal picks it up.** Home tab has a purple gradient → open Settings modal → the Settings background is the same purple gradient. Scrolling the Settings list reveals the gradient flows behind all sections. No opaque grey surface above the gradient.
30. **Gradient active → detail screens pick it up.** Tap any Settings row (Account / Library / Custom Theme / etc.) → gradient still visible on the pushed detail screen.
31. **Solid custom background → Settings modal picks it up.** Set Custom Theme ON + no gradient + a non-default background color (e.g., light blue). Open Settings → the modal + detail screens all render on top of the light-blue surface (no grey overlay).
32. **Library tab cells transparent under gradient.** Library tab (the sidebar with Artists / Albums / Playlists / etc.) → with a gradient active, each row's background is `.clear`. Row text + icons + disclosure indicators are visible; the gradient flows edge-to-edge through the row.
33. **Library tab cells transparent under solid custom background.** Set solid custom background (no gradient) → same transparency: rows flow on top of the themed solid surface.
34. **Library tab default (theme off) unchanged.** Turn Custom Theme OFF → Library tab cells return to the default sidebarPlain appearance (opaque system fill). No regression.

### Cross-cutting

35. **Reset to Defaults zero regressions.** With Custom Theme ON, all settings populated (colors, gradient, font, border), tap Reset → isEnabled flips OFF; colors / gradient / font / border width / border color all cleared; gradient history preserved; built-in presets still present.
36. **Notification pipeline end-to-end.** Change border width in Custom Theme settings → album thumbnails reflow immediately on Home (no app restart, no navigation required). Verifies `ThemeStore.didChangeNotification` + `EntityImageView` observer wiring.

---

## Risks + open questions

### Risks

- **R1. Hosting-VC gradient install may fight the SwiftUI `NavigationSplitView` on iPad / Catalyst** (SettingsTabView path, `isForOwnWindow = true`). On iPhone, `isForOwnWindow = false` → plain `SettingsView` inside `NavigationView` — the gradient insert at `view.insertSubview(bg, at: 0)` is straightforward. On iPad / Catalyst, the split view paints its own sidebar + detail backgrounds and may obscure the gradient. **Mitigation:** verify on iPad sim during implementation; if `NavigationSplitView` is intractable, gate the gradient-in-modal work to iPhone only (Olivier's primary target).
- **R2. Border render cost on the playlist composite.** Each 4-tile playlist cell now carries 4 additional `CALayer` border draws. On older devices scrolling a long playlist list, this may show FPS impact — though `layer.borderWidth` is a trivially cheap shader. **Mitigation:** spot-check with 60 FPS instruments on an iPhone 12-class device if available. Expected to be fine.
- **R3. `.scrollContentBackground(.hidden)` behavioural spread.** Applying this modifier globally via `SettingsList` may have unintended effects on non-theme-active rendering. **Mitigation:** gate it with `.scrollContentBackground(ThemeStore.shared.isEnabled ? .hidden : .automatic)` so the vanilla-OS look is untouched when Custom Theme is off.
- **R4. The `ThemeGradient.maxColorCount = 2` change is a silent data contract tightening.** Any external caller that constructs a 3+ stop gradient via the public initialiser will be accepted at compile time but reduced to 2 stops on next read. **Mitigation:** update `ThemeGradient.swift` doc comment to call out the 2-stop invariant; update `GradientTest.testBuiltInPresetsShape` to assert `colors.count == 2`; the struct accepts arbitrary count at init time for decode robustness (kept).

### Open questions for Olivier (answer before implementer starts — but defaults below if silence)

- **Q1. Border scope — should it extend to the Now Playing hero artwork?** My read of §17.2 / §17.3 says no (PR 17.2 explicitly excluded Now Playing; 17.3 inherits). **Default: no** — borders apply only inside `EntityImageView`.
- **Q2. Gradient picker "live apply" vs "back = commit, swipe = discard".** The cleaner UX per the rest of the codebase (color pickers live-apply) suggests live-apply on each change. **Default: live-apply on every mutation.** No Cancel button; back is simply "done".
- **Q3. Previously-Used carousel tap behaviour — apply-and-stay, or apply-and-pop?** Staying lets the user iterate; popping is more "instant gratification". **Default: apply-and-stay.**
- **Q4. Album Art section placement on CustomThemeRootView.** I put it on the root (mode-independent). If Olivier wants it per-mode (so light mode can have a different border color to dark mode), it moves into ModeDetailView and the data model grows `lightAlbumArtBorderColor` / `darkAlbumArtBorderColor`. **Default: single global border config on root.**
- **Q5. Should the Gradient row on ModeDetailView show the same swatch that used to live on ThemeSettingsSection?** Yes, and the swatch's tap behaviour becomes the NavigationLink push instead of a sheet. No extra affordance. **Default: yes, push-only.**

---

*End of review. Implementer should read top-to-bottom; QA should read §QA acceptance criteria + §Risks.*
