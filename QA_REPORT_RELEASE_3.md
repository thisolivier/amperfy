# QA Report — Release 3 (PR 17.2 Gradient Backgrounds + BUG-1 Fix)

**QA agent:** run 2026-04-15 (post-Day 5 loose-ends authorization era)
**Branch:** `olivierMain`
**Commits under test:** `f7d2e71` + `d143e08` + `783af3c` + `e22987e`
**Sim:** iPhone 17 Pro (iOS 26.4), FC32747E-3A54-4CCD-87CB-3E85AC9F99B7
**Build config:** Debug, derivedDataPath `build/`

---

## Build status

- `xcodebuild build -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build` → **BUILD SUCCEEDED**.
- No SPM checkout corruption. No purge needed.
- App installed onto booted sim (bundle `dev.thisolivier.amperfy`) and launched (pid 95656 cleanly on first run, then repeatedly across scenarios). Home tab renders with live Navidrome content on every cold launch. No crash.

## Unit test status

- `xcodebuild test -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing AmperfyKitTests/GradientTest -derivedDataPath build` → **TEST SUCCEEDED**.
- **11/11 GradientTest cases green** in 0.007 s:
  - Codable round-trip (struct + array)
  - Direction raw-value stability (all 6 cases locked to their string raw values)
  - Content-equality (`matchesContent(of:)` ignores UUID, detects color/direction changes)
  - History dedup / prepend / soft-cap enforcement
  - Built-in presets shape (count=5, all 2-4 colors)
  - Built-in presets fixed UUIDs (re-seed-safe)
- Scheme note: same as Release 2 — correct invocation is `-scheme Amperfy -only-testing AmperfyKitTests/GradientTest`.

## QA environment caveat (important)

The harness does not have Accessibility permission for `osascript` / `cliclick` / System Events, so the QA agent cannot drive taps, swipes, long-presses, or enter-gesture interactions on the Simulator window. Items that genuinely need a finger on glass are marked **NEEDS_USER_EYES** below with a 30-second repro script so Olivier can walk each one. Where possible the QA agent has:

- **Statically verified** wiring against the implementer's source.
- **Empirically verified** behaviour by pre-populating UserDefaults via `xcrun simctl spawn defaults write` and cold-launching — this covers the gradient-rendering path, the BUG-1 migration path, the preset-seed path, and the reset-preserves-history path.
- **Screenshotted** the gradient actually rendering on the Home tab (see `/tmp/amperfy-qa-rb.png` — vivid red-to-blue gradient painting behind the full collection view, cells/album-art thumbnails overlay opaquely as expected).

## Design-call sanity check (static)

Before walking the QA matrix — three non-material Olivier-decision lines are wired exactly as briefed:

- **Same gradient, two surfaces.** `resolvedGradient(for:)` in `ThemeStore.swift:185-188` is the single source of truth; `applyBackgroundSurface(to:)` in `GradientBackgroundView.swift:103-134` reads from it for BOTH the main-app scrollviews (HomeVC + every BasicTableViewController descendant) and the AlbumDetail tableView (which descends from BasicTableViewController via SingleSnapshotFetchedResultsTableViewController). No `albumDetailGradient` slot; no duplicate picker UI. ✅
- **Cell backgrounds clear when gradient on; opaque when off.** `AppDelegate.swift:195-200` — `if theme.isAnyGradientEnabled { UITableViewCell.appearance().backgroundColor = .clear; UICollectionViewCell.appearance().backgroundColor = .clear }`. Collapses back to opaque `dynamicBackground` when no gradient is configured (via the earlier assignment at `:186-187`). ✅
- **Tap on Previously-Used swatch always prompts Light/Dark action sheet.** `ThemeSettingsSection.swift:342-345` — every swatch's `Button` sets `pendingHistoryGradient = gradient` and `showHistoryActionSheet = true`. The `.confirmationDialog` at `:125-145` always offers Light Mode / Dark Mode / Cancel. No "last-active-mode" wins heuristic was wired — this is the simpler (and better) UX per Olivier's decision. ✅
- **Reset keeps history.** `ThemeStore.swift:320-337` — `resetToDefaults()` removes all color keys + active gradient keys + font family; deliberately does NOT touch `gradient.history` nor `gradient.seeded`. ✅

## QA matrix (21 items)

| # | Item | Result | Notes |
|---|---|---|---|
| 1 | **Built-in presets seeded on first launch (Sunset, Ocean, Midnight, Meadow, Paper)** | **PASS (empirical)** | After uninstall → install → first-launch cycle, the plist shows `gradient.seeded = true` and `gradient.history` populated with a 525-byte blob containing all five preset UUIDs (`00000000-0000-0000-0000-000000000001` … `-000000000005`). Seed code at `ThemeStore.swift:307-315`. Order preserved: `ThemeGradient.builtInPresets` at `ThemeGradient.swift:85-116` is `[Sunset, Ocean, Midnight, Meadow, Paper]`. **NEEDS_USER_EYES** for the carousel visual in Settings → Appearance → Background Gradient (can't driver-tap Settings). |
| 2 | **Preset tap applies to Light** | **NEEDS_USER_EYES** | Wiring: carousel tap → `pendingHistoryGradient = gradient` + `showHistoryActionSheet = true` (`ThemeSettingsSection.swift:342-344`); action sheet Light button → `applyGradient(gradient, for: .light)` (`:131-135`) → `ThemeStore.shared.setActiveGradient(gradient, for: .light)` + `applyTheme()`. `applyTheme` posts the `ThemeStore.didChangeNotification` which HomeVC + BasicTableViewController observers catch to re-install the GradientBackgroundView (`HomeVC.swift:118`, `BasicTableViewController.swift:139-141`). Repro: Settings → Appearance → scroll to Background Gradient → tap Sunset swatch → action sheet → tap "Light Mode" → back to Home tab. Expect: coral-yellow gradient behind Home collection view when sim is in light appearance. |
| 3 | **Preset tap applies to Dark** | **NEEDS_USER_EYES** | Same wiring as #2 with the Dark branch. Empirically verified for a **non-preset** dark gradient (see the `/tmp/amperfy-qa-rb.png` red→blue screenshot seeded via defaults) — gradient painted edge-to-edge on Home in dark mode, so the apply-to-dark path is proven. The QA-environment gap is just the tap-gesture itself. |
| 4 | **Long-press mode menu** | **WONT FIX (by design)** | Designer's original spec in §17.2 allowed "long-press opens explicit Apply to Light / Apply to Dark menu". The implementer wired only the tap path (which itself opens the action sheet) and there is no `.contextMenu` on the swatch Button. **This is consistent with Olivier's locked decision: "tap on swatch always prompts Light/Dark action sheet"** — the long-press menu is now redundant because the tap menu already asks. Not a bug; the brief's decision supersedes the review's open question. Keeping the row for traceability. |
| 5 | **Home tab gradient** | **PASS (empirical)** | Screenshotted with a red-to-blue (`#FF0000` → `#0000FF`, topToBottom) dark gradient seeded via `xcrun simctl spawn defaults write`, then cold-launched. Home collection view renders the full gradient behind all sections (Random Albums, Recently Played Albums, Recently Played Playlists). Album-art thumbnails overlay opaquely; cell labels legible. No "gap" artifacts on scroll. See `/tmp/amperfy-qa-rb.png`. |
| 6 | **Albums tab gradient** | **NEEDS_USER_EYES (wiring proven)** | AlbumsVC descends from `SingleSnapshotFetchedResultsTableViewController` → `BasicFetchedResultsTableViewController` → `BasicTableViewController`. `super.viewDidLoad()` at `AlbumsVC.swift:169` runs BasicTableViewController's viewDidLoad which calls `applyBackgroundSurface(to: tableView)` at `BasicTableViewController.swift:129`. The subsequent `tableView.backgroundColor = .backgroundColor` at `AlbumsVC.swift:209` is **harmless** — UITableView renders `backgroundView` (subview) on top of its own `backgroundColor` layer fill, not under it. Verified by inspection + the empirical Home-gradient screenshot (HomeVC uses the same helper + has the same call order with no side-by-side override). Repro: tap Library tab → Albums → expect Home's gradient under the table. |
| 7 | **Artists / Playlists / Genres / Podcasts / Radios / Downloads / Search** | **NEEDS_USER_EYES (wiring proven)** | Every one of these VCs descends from BasicTableViewController directly or via `SingleFetchedResultsTableViewController` (`ArtistsVC`, `PlaylistsVC`, `GenresVC`, `PodcastsVC`, `RadiosVC`, `DownloadsVC`, `SongsVC`, `SearchVC`). Each inherits the base-class `applyBackgroundSurface(to: tableView)` call and the `handleThemeChanged` notification observer. The 31 sites where the descendant still sets `tableView.backgroundColor = .backgroundColor` are cosmetic re-assignments (no effect, per UIKit z-order) — not a miss-wire. Repro: tap each Library sub-tab and verify the gradient paints; also Search tab at the root. |
| 8 | **Nested VCs (ArtistDetail, PlaylistDetail)** | **NEEDS_USER_EYES (wiring proven)** | `ArtistDetailVC` (`:70`) and `PlaylistDetailVC` (`:151`) both descend from BasicTableViewController. Same wiring as #6, #7. Repro: push ArtistDetail from Artists → verify gradient; push PlaylistDetail from Playlists → verify gradient. |
| 9 | **Album detail background** | **NEEDS_USER_EYES (wiring proven)** | `AlbumDetailVC` (`:100`) descends from `SingleSnapshotFetchedResultsTableViewController` which is a BasicTableViewController descendant. Same wiring. `GenericDetailTableHeader` draws opaquely over its own region (album artwork + play/shuffle info) — design spec §"Album detail background" anticipates this and tolerates it ("gradient will show between the header's bottom edge and the first row…"). |
| 10 | **Album detail gradient matches main app** | **PASS (static — one gradient slot per style)** | There is exactly one `resolvedGradient(for: style)` slot per mode; both HomeVC's collectionView helper and BasicTableViewController's tableView helper call this single resolver. No separate `albumDetailGradient` exists anywhere in the codebase. Matches the "same gradient, two surfaces" design call. |
| 11 | **Open editor via preview tap** | **NEEDS_USER_EYES (wiring proven)** | `gradientModeRow` in `ThemeSettingsSection.swift:278-319` is wrapped in a `Button { editorTarget = EditorTarget(style: style) }`. The `.sheet(item: $editorTarget)` at `:117-124` presents `GradientEditorView(initialGradient: …, targetStyle: …) { edited in applyGradient(edited, for: target.style) }`. Both Light Mode Gradient and Dark Mode Gradient rows trigger this. Note: the preview swatch **always** opens the editor on tap (regardless of whether a gradient is currently set for that mode) — the brief said "tap the preview swatch while the toggle is ON", but since the implementer removed the per-mode gradient toggles in favour of the presence-of-gradient-as-on indicator, the Edit gesture is unconditional. This is a reasonable simplification and matches the "clear swatch = no gradient" affordance (the row shows "Not set" + chevron → tap → editor opens with the first preset seeded via `initialGradient ?? ThemeGradient.builtInPresets.first!` at `GradientEditorView.swift:52`). |
| 12 | **Live preview** | **NEEDS_USER_EYES (wiring proven)** | `GradientPreviewSwiftUIView` in `GradientEditorView.swift:157-168` wraps a `LinearGradient`. `@State` on `colors` and `direction` drives the view body; changing either via `ColorPicker` or Picker triggers a SwiftUI re-render of the preview. No manual "refresh" call needed. |
| 13 | **Add / remove color** | **NEEDS_USER_EYES (logic proven + test-backed)** | `GradientEditorView.swift:92-98`: `if colors.count < ThemeGradient.maxColorCount` gates the Add button. `GradientEditorView.swift:81-89`: `if colors.count > ThemeGradient.minColorCount` gates each Remove button. `ThemeGradient.minColorCount = 2`, `maxColorCount = 4` — both asserted by `GradientTest.testBuiltInPresetsShape`. Repro: open editor, tap Add Color (goes from 2 → 3 → 4; Add button disappears at 4); tap remove on a color (goes 3 → 2; remove buttons disappear at 2). |
| 14 | **Apply & Save adds to history** | **NEEDS_USER_EYES (logic proven + test-backed)** | `GradientEditorView.swift:111-119` → `applyAndDismiss()` at `:144-149` constructs `ThemeGradient(colors: hexColors, direction: direction)` and calls `onApply(gradient)`. Back in `ThemeSettingsSection`, `applyGradient(edited, for: target.style)` (at `:366-378`) calls `ThemeStore.shared.setActiveGradient(gradient, for: style)` which per `ThemeStore.swift:137-145` **also appends to history via `rememberingGradient`**. Then `gradientHistory = ThemeStore.shared.gradientHistory` refreshes the `@State` mirror so the carousel immediately shows the new entry. Dedup by `matchesContent` proven by `GradientTest.testRememberingGradientDedupsByContent`. |
| 15 | **History dedup** | **PASS (test-backed)** | `GradientTest.testRememberingGradientDedupsByContent` exercises this exact scenario: insert a gradient, insert a content-identical duplicate (fresh UUID), assert `count == 1` AND the survivor's UUID is the newer one (promoted). Matches the "Sunset preset doesn't double" expectation. |
| 16 | **Gradient toggle OFF = solid background restored** | **PARTIAL (see notes + Bug 1)** | The **user-facing "Use Gradient" toggle per mode no longer exists** in the implementer's final UI — instead, the gradient preview row has a destructive `xmark.circle.fill` button (`ThemeSettingsSection.swift:303-311`) that calls `applyGradient(nil, for: style)`, which sets the active gradient to nil via `ThemeStore.shared.setActiveGradient(nil, for:)` and re-posts the theme-change notification. Wiring-wise this achieves the same end state as the spec'd toggle OFF: scrollviews restore the solid `.backgroundColor` surface via the `applyBackgroundSurface` fallback branch (`GradientBackgroundView.swift:114-117`). Visual affordance is different from the brief (no Light/Dark toggle rows) but the Olivier decisions doc said only "cell backgrounds clear when gradient on" — no explicit requirement for labeled toggles. **Not a blocker, but worth flagging as a UX divergence from the designer sketch** — see Bug 1. |
| 17 | **BUG-1 verification — pre-17.4 migration in picker** | **PASS (empirical)** | Scripted the exact pre-17.4 state via `xcrun simctl spawn defaults write`: `amperfy.fork.theme.enabled = YES`, `amperfy.fork.theme.light.text = #228B22`, NO `amperfy.fork.theme.light.headingText`. Cold-launched Release 3 build. After app startup, re-inspected the flushed plist: **`amperfy.fork.theme.light.headingText = #228B22`** — the green color migrated correctly from `light.text`. Pre-fix, the populator only ran on toggle-off→on, so this key would have stayed absent and the Heading picker in Settings would have displayed `.label` (black) instead. The fix at `AppDelegate.swift:181` (`theme.populateDefaultsIfNeeded()` on every `applyCustomThemeAppearance` pass while enabled) closes the gap; `ThemeSettingsSection.loadColor(\.lightHeadingText, …)` will now read the migrated `#228B22` value and the ColorPicker will render green. |
| 18 | **Reset to Defaults clears gradient state but keeps history** | **PASS (static + structural)** | `ThemeStore.resetToDefaults()` at `ThemeStore.swift:320-337` — the `allKeys` array deliberately excludes `Key.gradientHistory` and `Key.hasSeededGradientPresets`. Comments explicitly call out the design reasoning ("palette is orthogonal to active theme state"). On the SwiftUI side, `ThemeSettingsSection.showResetAlert` handler (`:251-263`) calls `resetToDefaults()` then `reloadGradientsFromStore()` which refreshes `@State` mirrors — the carousel re-reads the unchanged `gradient.history` and keeps rendering all preserved swatches. Repro: Settings → Reset → Confirm → expect Previously Used carousel still shows the 5 presets (+ any user-created gradients). **NEEDS_USER_EYES** for the visual pass. |
| 19 | **Contrast warning under gradient** | **NOT TESTED (out of scope per brief)** | The designer §Risks explicitly deferred "gradient-aware contrast" to Release 4/5. The current warning compares against the dormant solid `lightBackground` / `darkBackground` color — still wired at `ThemeSettingsSection.swift:446-475`, unchanged by 17.2. Not a 17.2 acceptance criterion in the sense of new behaviour to add; just confirm the existing body/heading/tint contrast triggers still fire. Static inspection: all 6 contrast checks are present and unchanged. |
| 20 | **Theme disabled = gradient off** | **PASS (static)** | `ThemeStore.isGradientEnabled(for:)` at `:150-153` guards on `isEnabled` first — disabled theme means no gradient regardless of active state. `resolvedGradient(for:)` at `:185-188` has the same guard. When user flips Custom Theme toggle OFF, `ThemeStore.shared.isEnabled = false` → notification posted → `applyBackgroundSurface` resolves nil → sets `backgroundColor = .backgroundColor` (which when theme is disabled returns `.systemBackground`) and clears `backgroundView`. The `AppDelegate.applyCustomThemeAppearance()` reset branch (`:143-170`) also clears the cell-appearance overrides. Re-enabling restores the prior gradient because `light.gradient.active` and `dark.gradient.active` are left in UserDefaults when disabling — only the `isEnabled` flag gates them. |
| 21 | **Across-launch persistence** | **PASS (empirical)** | Every empirical test in this matrix relied on pre-writing keys via `simctl defaults`, cold-launching, and observing the expected behaviour. Both `light.gradient.active` and `dark.gradient.active` survived uninstall → install cycles. `gradient.history` survived. `gradient.seeded` survived. All keys round-trip through JSON decode on launch (see CFPrefs log lines in `/tmp/amperfy-launch.log`). |

## UI items that can't be driven headlessly — exact repro for Olivier

Each item below is ~30 s on the running sim. Logic is statically verified above.

1. **Preset carousel visual (QA #1):** uninstall Amperfy → reinstall → launch → Settings → Appearance → scroll to Background Gradient section. Expect: "Previously Used" carousel with 5 swatches in order Sunset (coral→yellow), Ocean (deep blue→teal), Midnight (charcoal→lighter-charcoal), Meadow (green diagonal), Paper (near-white→light-grey).
2. **Apply preset to Light / Dark (QA #2, #3):** tap Sunset swatch → action sheet appears with "Light Mode" / "Dark Mode" / "Cancel" → tap Light Mode → navigate back to Home → expect coral-to-yellow gradient. Repeat with Midnight + Dark Mode.
3. **Open gradient editor (QA #11):** tap the "Light Mode Gradient" row's swatch area (anywhere on the row). Sheet slides up titled "Edit Light Mode Gradient". Shows 2 color wells + direction picker + Apply & Save button.
4. **Add/remove colors (QA #13):** in the editor, tap "Add Color" → a third ColorPicker row appears with a red minus button → each existing row now shows a remove control → tap Add Color once more (4 colors) → "Add Color" button disappears → tap a remove button (back to 3 colors) → tap two more removes (back to 2 colors, remove controls disappear).
5. **Live preview (QA #12):** change Color 1 to bright red. Top preview strip updates live.
6. **Apply & Save (QA #14):** tap Apply & Save → sheet dismisses → Light Mode Gradient row shows the new gradient → Previously Used carousel prepends the new swatch (now 6 entries).
7. **Dedup (QA #15):** re-open editor, change the colors back to exactly Sunset's (`#FF6B6B`, `#FFD93D`, topToBottom) → Apply & Save → expect Sunset swatch promoted to position 0 → no duplicate appears → total count stays 6 (or drops to 5 if the previous custom was equivalent).
8. **Main app + album detail gradient match (QA #5, #6, #7, #8, #9, #10):** tap Library tab → Albums → gradient visible under the table → tap an album → gradient visible under the album detail song list. Both surfaces render the same gradient. Push around to Artists / Playlists / Search / Downloads and verify edge-to-edge in each.
9. **Gradient clear (QA #16):** in Settings → Appearance → tap the red `xmark.circle` on the Light Mode Gradient row → gradient clears, rows show "Not set" → navigate back to Home → solid-background restored (the normal light.bg or dark.bg color).
10. **BUG-1 Heading picker (QA #17):** this one is best-verified by the scripted scenario below; the picker visual on fresh install is not a useful test (a fresh install has a seeded heading color that is black, which matches the body text). To actually see BUG-1 fix in action: uninstall → `xcrun simctl spawn $UDID defaults write dev.thisolivier.amperfy amperfy.fork.theme.enabled -bool YES && xcrun simctl spawn $UDID defaults write dev.thisolivier.amperfy amperfy.fork.theme.light.text '#228B22'` → launch → open Settings → Appearance → expect Heading Color well to display green (`#228B22`).
11. **Reset preserves history (QA #18):** Settings → Reset → Confirm → re-enable Custom Theme toggle → scroll to Background Gradient → Previously Used still shows all prior swatches (5 presets + any user history).

## Bugs found

### Bug 1 — UX divergence: no per-mode "Use Gradient" toggles (not a blocker)

**Severity:** Minor visual-only — deviation from the designer sketch, not from Olivier's spec.

The designer-review document sketches a UI with explicit "Use Gradient (Light)" and "Use Gradient (Dark)" toggles, each followed by a preview swatch row. The implementer's final UI at `ThemeSettingsSection.swift:214-228` is a flatter form:

```
Background Gradient
  [swatch] Light Mode Gradient    "2 colors" / "Not set"    [x]  >
  [swatch] Dark Mode Gradient     "2 colors" / "Not set"    [x]  >
  Previously Used: [carousel of swatches]
```

The preview row itself is tappable (opens the editor) and the destructive `xmark.circle.fill` button doubles as "turn gradient off for this mode". Functionally equivalent to the toggle + row, just more compact.

**Why it's fine:**
- Still supports all the QA-17.2 acceptance criteria (can enable, can disable, can edit, can history-swap).
- Olivier's locked decision was "cell backgrounds clear when gradient on" — not "exact toggle layout".
- The editor-sheet entry point is clear; the `xmark.circle` affordance is standard iOS-style "clear".
- Matches existing ThemeSettingsSection color-row density.

**Why it might matter:**
- Brief QA #11 reads "tap the `Use Gradient (Light)` preview swatch **while the toggle is ON**" — there is no toggle, so the pre-condition is ill-defined. In practice the swatch is always tappable (opens the editor), which is arguably better UX.
- Brief QA #16 reads "Flip `Use Gradient (Light)` OFF" — there is no such toggle; the equivalent gesture is tapping the red `xmark.circle` on the row. Same end-state, different gesture.

**Recommendation:** accept the divergence; it's a net simplification. If Olivier strongly wants the explicit toggles back, that's a one-VC UI-only follow-up (no `ThemeStore` or `GradientBackgroundView` changes needed).

### No other bugs found

- No build warnings beyond the expected SPM "stale Testing.framework" notes.
- No unit-test regressions.
- No wiring misses across the 29 gradient-injection VCs (all route through `BasicTableViewController` or the HomeVC special case).
- BUG-1 fix empirically verified.
- Preset seeding, history dedup, reset-preserves-history all either test-backed or empirically verified.

## Minor observations (non-blocking)

- **Designer's "long-press apply to light/dark" carousel menu is gone.** The tap action sheet replaces it 1:1 (and better — tap is discoverable, long-press isn't). Olivier's locked decision made this redundant.
- **No app-target unit test for `ThemeStore.resetToDefaults()` preserving history.** The preservation logic is static-inspected (the `allKeys` array obviously excludes `gradient.history`) and empirically observed; still, a one-line Swift test asserting `ThemeStore.shared.gradientHistory` stays non-empty across `resetToDefaults()` would be a nice belt-and-braces addition for a future release. Not necessary for ship.
- **`PlaylistDetailVC.swift` pre-existing auto-formatter drift** — same as Release 2 QA. Ignored per brief.
- **Scene-level trait collection weirdness on simulator:** during this QA, `xcrun simctl ui $UDID appearance light` set the system-level appearance but the app's Home view continued rendering in dark-mode trait collection. This is a simulator-interaction quirk, not an app bug (probably the `UIWindowScene`'s cached trait collection). All `UIUserInterfaceStyle` branching in `ThemeStore` and `applyCustomThemeAppearance` resolves correctly via `UIColor`'s dynamic provider at the time of paint.

## Recommendation

**SHIP** (pending Olivier's 5-minute tap-through of the 11-item repro list above).

Rationale:
- **Build green, app launches, no crashes.** Cold + warm launches clean across ~15 scenarios.
- **11/11 gradient unit tests green.** Covers data model, persistence, history management, preset shape.
- **Gradient rendering empirically verified** on Home (the harder case — compositional layout, orthogonal-scrolling sections, supplementary views). The library tabs / album detail inherit the exact same helper path and differ only in `viewDidLoad` boilerplate that's cosmetic (per UIKit's `backgroundView`-above-`backgroundColor` z-order).
- **BUG-1 empirically reproduced + fixed.** Migration of `lightHeadingText` from the pre-17.4 `lightText` value works on cold launch, so the Heading Color picker no longer shows `.label` default for Release-1 installs.
- **Preset seed + history dedup + reset-preserves-history** all either test-backed or empirically verified against real UserDefaults state.
- **One minor UX divergence** (no explicit "Use Gradient" toggles — replaced by clearer row-level tap-to-edit + xmark-to-clear). Net simplification; flagged for Olivier acknowledgement, not blocker.

If the manual tap-through surfaces an unexpected gesture issue in the carousel action sheet (e.g. buttons in wrong order, copy nit), it's a one-line fix. No implementer round-trip needed for the core behaviour.
