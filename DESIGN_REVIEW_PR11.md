# Design Review: PR 11 — Custom Styling Phase 2

**Reviewer:** Designer Agent
**Date:** 2026-04-12
**Status:** Pre-implementation review
**Inputs:** BACKLOG.md (PR 7/F.4), STYLING_RESEARCH.md, current Settings UI, UtilitiesExtensions.swift, MiniPlayerView.swift

---

## 1. Interaction Design

### 1.1 Settings Navigation

The new "Appearance" section lives inside **Settings > Display & Interaction** (`DisplaySettingsView.swift`), which already owns the System/Light/Dark picker. This avoids adding a new top-level NavigationTarget and keeps all visual customization in one place.

**Revised section layout for DisplaySettingsView:**

```
Display & Interaction
  ┌─────────────────────────────────────────┐
  │ Appearance          [System / Light / Dark] │  ← existing
  ├─────────────────────────────────────────┤
  │ Custom Theme               [Toggle OFF] │  ← NEW master toggle
  │                                         │
  │   (when ON, the following appear:)      │
  │                                         │
  │ ── Light Mode Colors ──                 │
  │   Background        [Color swatch ●]    │
  │   Text              [Color swatch ●]    │
  │   Tint              [Color swatch ●]    │
  │                                         │
  │ ── Dark Mode Colors ──                  │
  │   Background        [Color swatch ●]    │
  │   Text              [Color swatch ●]    │
  │   Tint              [Color swatch ●]    │
  │                                         │
  │ ── Font ──                              │
  │   Font Family       [System Default ▾]  │
  │                                         │
  │ [Reset to Defaults]                     │  ← destructive style button
  ├─────────────────────────────────────────┤
  │ Haptic Feedback            [Toggle]     │  ← existing
  │ ...remaining existing rows...           │
  └─────────────────────────────────────────┘
```

**Design decisions:**
- The master toggle, all pickers, and Reset button form a single `SettingsSection` that collapses to just the toggle row when OFF. This makes the feature feel lightweight when unused.
- Color swatches show the current selected color as a filled circle (SwiftUI `Circle().fill(color).frame(width: 24, height: 24)`) inside a `SettingsRow`. Tapping the row opens `UIColorPickerViewController`.
- Section headers "Light Mode Colors" / "Dark Mode Colors" / "Font" use the standard iOS grouped-table section header style (uppercase gray text).

### 1.2 Flow: User enables custom theme and picks colors

1. User navigates to **Settings > Display & Interaction**.
2. User toggles **Custom Theme** ON.
3. The six color picker rows and font picker animate in (SwiftUI `withAnimation` on the conditional section).
4. Each color swatch defaults to the **current stock Amperfy color** for that slot (e.g., light background = `.systemBackground` resolved in light mode). This means the moment the toggle flips ON, the app looks identical — no jarring change.
5. User taps a color row (e.g., "Light > Background").
6. iOS presents `UIColorPickerViewController` as a sheet. The picker supports: color wheel, spectrum slider, RGB sliders, hex input, opacity slider, and an eyedropper.
7. **Opacity:** The alpha slider should be disabled or hidden. Background/text/tint with partial transparency creates layering artifacts. Implementation: set `supportsAlpha = false` on the picker.
8. User selects a color and dismisses the picker (tap outside or swipe down).
9. The swatch updates immediately. The app's UI updates **live** — `ThemeStore` posts `didChangeNotification`, the `UIAppearance` proxy re-applies, and the root window's view hierarchy reloads.
10. The color persists to UserDefaults immediately on selection (no "Save" button).

### 1.3 Flow: User disables custom theme

1. User toggles **Custom Theme** OFF.
2. The color/font picker rows animate out.
3. `ThemeStore.isEnabled` flips to `false`. The `UtilitiesExtensions` color helpers return stock system colors. `UIAppearance` proxies reset to defaults.
4. The app's appearance reverts to stock Amperfy immediately.
5. **Stored colors are NOT cleared.** If the user toggles back ON, their previous selections are restored. Only "Reset to Defaults" clears stored values.

### 1.4 Flow: User picks a custom font family

1. With Custom Theme ON, user taps the **Font Family** row.
2. A picker presents a list of available system font families (`UIFont.familyNames`, sorted alphabetically), plus "System Default" at the top.
3. Presentation: use a navigation push to a selection list (consistent with other Amperfy picker patterns), not an inline wheel picker — the font list is too long for a wheel.
4. Each row shows the font family name **rendered in that font** for preview (e.g., "Georgia" shown in Georgia).
5. User taps a family. The selection saves immediately and the row pops back.
6. The custom font applies via `UIFontMetrics` to preserve Dynamic Type scaling.

### 1.5 How color pickers work (UIColorPickerViewController)

- Presented as a **page sheet** (default iOS behavior). On iPad, it appears as a popover if presented from a bar button; from a table row, it will be a sheet.
- The delegate callback `colorPickerViewControllerDidSelectColor(_:)` fires on each color change (live updates). `colorPickerViewControllerDidFinish(_:)` fires on dismiss.
- **Recommendation:** Update the swatch preview on every `didSelectColor` callback (live preview in the settings row), but only post the `ThemeStore.didChangeNotification` on `didFinish` to avoid rapid full-app reloads while the user is dragging the color wheel. This prevents performance issues and visual flashing during color exploration.

### 1.6 What "Reset to Defaults" does step by step

1. User taps "Reset to Defaults" button (styled with `.destructive` role).
2. A confirmation alert appears: **"Reset Theme?"** / "This will clear all custom colors and fonts and restore the default appearance." / [Cancel] [Reset]
3. On confirm:
   - `ThemeStore` clears all 6 color keys + font family key from UserDefaults.
   - `ThemeStore.isEnabled` set to `false`.
   - `didChangeNotification` fires.
   - App restores stock Amperfy colors and system font.
   - The toggle animates to OFF; picker rows animate out.

### 1.7 How the theme applies across the app

**Mechanism (per research Option A):**

1. **UtilitiesExtensions color helpers** (`Color.label`, `Color.systemBackground`, etc.) check `ThemeStore.shared.isEnabled`. If true, return the user's custom color for the current `userInterfaceStyle`. If false, return the stock system color.
2. **UIAppearance proxy** in `AppDelegate` sets `UINavigationBar.appearance().barTintColor`, `UITabBar.appearance().barTintColor`, `UITableView.appearance().backgroundColor`, etc. These cover system chrome globally.
3. **Manual wiring** in `MiniPlayerView`, `PlayableTableCell`, and `PlayerControlView` — these views subscribe to `ThemeStore.didChangeNotification` and re-apply colors from the store.
4. **Window reload:** After appearance proxy changes, iterate all connected scenes' windows and call `window.rootViewController?.view.setNeedsLayout()` + reload. This is the same pattern as `setAppAppearanceMode(style:)` in `AppDelegate.swift:376-386`.

**Visible flash:** There will be a brief visual refresh when the theme applies. This is acceptable — it's the same behavior as switching System/Light/Dark in the existing Appearance picker. The flash only occurs on theme change, not during normal use.

### 1.8 Dark/light mode interaction

The user customizes **both** light and dark color sets independently. The active set is determined by `UITraitCollection.userInterfaceStyle` at runtime.

**Scenario: User is in dark mode and customizes light mode colors.**
- The light mode color swatches update to show the user's selections.
- The app's current appearance does NOT change (it's using the dark set).
- When the user switches to light mode (via the Appearance picker or system settings), the custom light colors take effect.
- The swatches always show the stored color regardless of current mode — this is a configuration screen, not a live preview per-mode.

**Scenario: User has Appearance set to "System" and the OS switches modes.**
- `traitCollectionDidChange` fires. The `UtilitiesExtensions` helpers re-resolve, returning the correct set (light or dark) from `ThemeStore`. SwiftUI views update automatically via the environment. UIKit views that set colors in `viewWillAppear` or via notification re-apply.

---

## 2. Edge Cases & UX Flags

### 2.1 Unreadable color combinations

**Issue:** User sets background and text to the same (or very similar) color, making text invisible.

**Recommendation:** Do NOT block the user from choosing any color — that's patronizing and complex to implement. Instead:
- Show a **non-blocking warning banner** at the top of the color section when the contrast ratio between bg and text (for either mode) falls below WCAG AA threshold (4.5:1 for normal text). Message: "Low contrast between background and text — some content may be hard to read."
- This is informational only. The user can dismiss or ignore it.
- **Implementation cost:** ~15 LOC for a contrast ratio helper + conditional banner. Worth including.

### 2.2 Invisible tint (tint matches background)

**Issue:** Tint color matching background makes buttons invisible.

**Same approach as 2.1:** Extend the warning to also check tint-vs-background contrast. Message: "Tint color is very close to background — buttons may be hard to see."

### 2.3 Navigation bar / tab bar / status bar

- **Navigation bar:** Covered by `UIAppearance` proxy. `barTintColor` = custom bg, `titleTextAttributes` foreground = custom text, `tintColor` = custom tint (for back button/icons).
- **Tab bar:** Same pattern. `barTintColor` = custom bg, `tintColor` = custom tint, `unselectedItemTintColor` = custom text with reduced opacity.
- **Status bar:** iOS auto-selects light/dark status bar content based on `userInterfaceStyle`. If the user sets a dark background in light mode, the status bar text (black) becomes hard to read. **Flag:** This is a known iOS limitation. The fix (`preferredStatusBarStyle` override) requires per-VC changes and is not worth the complexity. Document as a known limitation.

### 2.4 Mini-player overlay

`MiniPlayerView.swift:847-852` hardcodes text colors based on `traitCollection.userInterfaceStyle` (white/lightGray for dark, black/darkGray for light). The overlay background at line 43 is hardcoded to `black.withAlphaComponent(0.4)`.

**Action required:** The manual theming pass for MiniPlayerView must replace these hardcoded colors with `ThemeStore` lookups. The overlay background should use custom bg with alpha, not hardcoded black.

### 2.5 Third-party views that may not respect the theme

- **MarqueeLabel** (line 29-47 of UtilitiesExtensions.swift): Inherits text color from its superview. Should pick up theme colors automatically — no action needed.
- **UIColorPickerViewController** itself: System-provided, always uses system colors. This is fine — it's a modal that should look like a system sheet.
- **UIAlertController**: System-provided, will NOT adopt custom colors. Acceptable — alerts should look standard.
- **Share sheet / activity view controller**: System-provided, unthemed. Acceptable.
- **Web views** (if any for X-Callback URL docs): Will not adopt theme. Acceptable.

### 2.6 Font family + Dynamic Type interaction

- Custom fonts MUST use `UIFontMetrics.default.scaledFont(for:)` to preserve Dynamic Type sizing.
- **Risk:** Some font families have very different metrics (x-height, ascender, descender) than the system font. This can cause clipping in fixed-height cells (e.g., `PlayableTableCell` with constrained row heights).
- **Mitigation:** The font picker should include a "Preview" that shows a sample string at the body text size. If clipping issues arise post-launch, the fix is to cap the available font list to families with compatible metrics — but this is a v2 concern, not a blocker.

### 2.7 Accessibility concerns

- **VoiceOver:** Color picker rows need accessibility labels (e.g., "Light mode background color, currently blue"). The color swatch should convey the current color name via `accessibilityValue`.
- **Reduce Transparency / Increase Contrast:** These iOS accessibility settings may conflict with custom colors. The theme should respect `UIAccessibility.isReduceTransparencyEnabled` by not applying semi-transparent backgrounds. Since we're disabling alpha in the picker (1.5 above), this is mostly covered.
- **Bold Text:** The system Bold Text accessibility setting should take precedence over custom font family — `UIFontMetrics` handles this automatically when used correctly.

### 2.8 App launch timing

- `ThemeStore` reads from UserDefaults synchronously on `init`. The `UIAppearance` proxy must be set in `AppDelegate.application(_:didFinishLaunchingWithOptions:)` BEFORE the first window is created, or there will be a flash of stock colors on every launch.
- The `SceneDelegate.scene(_:willConnectTo:options:)` call at line 126 already restores appearance mode — the theme restoration should slot in at the same point.

### 2.9 Migration / backwards compatibility

- If the user updates from a build without custom theming to one with it, all UserDefaults keys are absent → `ThemeStore.isEnabled` defaults to `false` → stock appearance. Clean zero-state.
- If the user downgrades (unlikely in TestFlight but possible), the orphaned UserDefaults keys are harmless — they're never read by the old build.

---

## 3. QA Acceptance Criteria

Each item is a concrete pass/fail test.

### Toggle behavior

| # | Test | Pass condition |
|---|------|---------------|
| 1 | Toggle Custom Theme ON | Color picker rows and font picker animate in. App appearance unchanged (defaults match stock). |
| 2 | Toggle Custom Theme OFF | Picker rows animate out. App reverts to stock Amperfy colors immediately. |
| 3 | Toggle ON → change colors → toggle OFF → toggle ON | Previously selected colors are restored (not cleared). |

### Color pickers (6 total)

| # | Test | Pass condition |
|---|------|---------------|
| 4 | Tap Light Background swatch | UIColorPickerViewController presents as sheet. Alpha slider is hidden/disabled. |
| 5 | Select a light background color | Swatch updates. If currently in light mode, app background updates on picker dismiss. |
| 6 | Tap Light Text swatch and select color | Text color changes across labels in light mode. |
| 7 | Tap Light Tint swatch and select color | Tint color changes on nav bar back buttons, tab bar icons, and interactive elements in light mode. |
| 8 | Tap Dark Background swatch and select color | Background changes when in dark mode. |
| 9 | Tap Dark Text swatch and select color | Text color changes when in dark mode. |
| 10 | Tap Dark Tint swatch and select color | Tint changes when in dark mode. |

### Reset to defaults

| # | Test | Pass condition |
|---|------|---------------|
| 11 | Tap "Reset to Defaults" | Confirmation alert appears with Cancel and Reset options. |
| 12 | Confirm Reset | Toggle flips OFF. All swatches revert to stock colors. App restores stock appearance. Font reverts to System Default. |
| 13 | Cancel Reset | No changes. Toggle remains ON. Colors unchanged. |

### Persistence

| # | Test | Pass condition |
|---|------|---------------|
| 14 | Set custom colors → kill app → relaunch | Custom colors are applied on launch with no flash of stock colors. Toggle is ON. |
| 15 | Set custom colors → toggle OFF → kill app → relaunch | Stock colors on launch. Toggle is OFF. |

### Dark/light mode switching

| # | Test | Pass condition |
|---|------|---------------|
| 16 | Custom theme ON, Appearance = System. Switch iOS dark mode in Control Center. | App switches to the dark custom color set smoothly. |
| 17 | Custom theme ON, switch Appearance from Light to Dark in Settings | App switches from light custom set to dark custom set. |
| 18 | Customize light colors only (leave dark at defaults), switch to dark mode | Dark mode shows stock dark colors (the defaults). |

### Font family

| # | Test | Pass condition |
|---|------|---------------|
| 19 | Tap Font Family row | Navigation pushes to a font list. "System Default" is at top. Each font name rendered in its own font. |
| 20 | Select a custom font (e.g., Georgia) | Font applies across all text in the app. Dynamic Type sizes preserved. |
| 21 | Select "System Default" | App returns to system font. |

### Visual verification across screens

| # | Test | Pass condition |
|---|------|---------------|
| 22 | With custom theme ON, check **Home tab** | Background, text, and tint colors match custom selections. |
| 23 | Check **Albums tab** (list + grid views) | Colors applied consistently. Album titles, artist subtitles use custom text color. |
| 24 | Check **Now Playing / Player screen** | Player chrome (controls, labels, slider) uses custom tint and text colors. Background uses custom bg. |
| 25 | Check **Settings screen** | Settings rows, section headers, toggle tints all reflect custom colors. |
| 26 | Check **Mini-player** | Title, subtitle, control buttons reflect custom text/tint. Background reflects custom bg. |
| 27 | Check **Navigation bars and tab bar** | Bar backgrounds use custom bg. Titles and icons use custom text/tint. |

### Regression (stock appearance)

| # | Test | Pass condition |
|---|------|---------------|
| 28 | Fresh install (no UserDefaults) | Custom Theme toggle is OFF. No custom appearance section visible beyond the toggle. App looks identical to stock Amperfy. |
| 29 | Toggle OFF after customization | Every screen matches stock Amperfy appearance pixel-for-pixel. No lingering custom colors. |
| 30 | Existing Appearance picker (System/Light/Dark) still works | Switching modes works regardless of Custom Theme toggle state. |

---

## 4. Recommendations

### Spec changes to suggest before implementation

1. **Add confirmation alert to Reset** (not in spec). Destructive actions need a speed bump. Cost: ~5 LOC.

2. **Defer theme application to picker dismiss, not live** (design decision in 1.5 above). Live-updating the full app on every color wheel drag will cause frame drops. Update the swatch live, but post the notification only on dismiss.

3. **Disable alpha in color pickers** (not in spec). Semi-transparent bg/text/tint creates layering bugs. Set `supportsAlpha = false`. Cost: 1 line per picker.

4. **Populate default swatch values from stock colors** (not in spec). When the toggle flips ON for the first time, pre-populate all 6 stored colors with the resolved stock values. This means the user starts from "what the app looks like now" and adjusts, rather than starting from an undefined state.

5. **Contrast warning banner** (new, not in spec). Low-effort, high-value guardrail. ~15 LOC. Non-blocking — just informational.

### Priority ordering (if scope needs trimming)

If the implementation exceeds the ~400 LOC budget, cut in this order (last = cut first):

1. **Must ship:** Master toggle, ThemeStore, 6 color pickers, UtilitiesExtensions injection, UIAppearance proxy, Reset to Defaults, persistence. (~300 LOC)
2. **Should ship:** Manual theming for MiniPlayerView + PlayerControlView + PlayableTableCell. (~80 LOC) Without this, the three heaviest custom views won't theme — but 80% of the app will.
3. **Nice to have:** Font family picker. (~40 LOC) Purely additive. Can land in a follow-up PR.
4. **Nice to have:** Contrast warning banner. (~15 LOC) Polish item. Can land in follow-up.

### Items to flag to team lead for Olivier's input

1. **Status bar readability.** If the user picks a dark background in light mode, the black status bar text becomes hard to read. Fixing this requires per-VC `preferredStatusBarStyle` overrides (~30 files). Recommend documenting as a known limitation rather than fixing. **Does Olivier consider this acceptable?**

2. **Mini-player overlay opacity.** The mini-player overlay is currently `black.withAlphaComponent(0.4)`. Should custom bg replace this? Or should the overlay remain a fixed translucent black to ensure artwork readability underneath? **Olivier's preference needed** — this is a taste call, not a technical one.

3. **Font list curation.** iOS exposes ~80 font families. Some are unusable for a music app UI (e.g., Zapfino, Symbol). Should we curate the list to ~15-20 readable families, or show all and let the user choose? **Recommendation:** Show all, sort alphabetically, with "System Default" pinned at top. Curating is opinionated and adds maintenance burden.
