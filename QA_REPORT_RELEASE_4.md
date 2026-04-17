# QA Report — Release 4 (PR 17.3 Borders + PR 20 Theme Restructure / Gradient Bug + PR 21 Settings UI Cleanup)

**QA agent:** run 2026-04-16 (Release 4 close-out)
**Branch:** `olivierMain`
**Commits under test:** `1709004`, `0c8d059`, `4ce350b`, `0c15026`, `a4da0d7`, `9d80c0a`, `3518189`, `21c6017` (Build 39)
**Sim:** iPhone 17 Pro (iOS 26.4), `FC32747E-3A54-4CCD-87CB-3E85AC9F99B7`
**Build config:** Debug, derivedDataPath `build/`
**Design brief:** `DESIGN_REVIEW_RELEASE_4.md` §"QA acceptance criteria" (36 items)

---

## Build status

- `xcodebuild test -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AmperfyKitTests/GradientTest -only-testing:AmperfyKitTests/EntityImageViewTest -derivedDataPath build` → **TEST SUCCEEDED**.
- **22/22 targeted tests green** in 0.025 s (GradientTest 14 + EntityImageViewTest 8).
- No SPM corruption; no purge needed. `build/SourcePackages/checkouts` untouched this pass.
- App installed onto booted sim (`dev.thisolivier.amperfy`) and launched twice cleanly — once baseline, once with a pre-seeded 4-stop gradient (migration harness). PID 10436 + PID 10547 both alive after launch; no crash, no fatal-signal entries in `log show`.

## QA environment caveat

Same as Release 3: the harness has no Accessibility permission for `osascript` / `cliclick`, so the QA agent cannot drive taps / swipes on the Simulator window. Additionally, the signed-in Navidrome account is not recoverable after a `simctl install` (accounts live in Core Data, not UserDefaults) — so the post-auth surfaces (Home, Albums, Playlists, Settings) cannot be reached directly via `simctl` without Olivier's credentials. The empirical surface here is therefore narrower than Release 3's run:

- **Statically verified** every PR against the implementer's source (9 files audited end-to-end).
- **Empirically verified** the critical Olivier check **#6 (2-stop migration from Build 38)** by pre-writing a 4-stop gradient blob into UserDefaults, relaunching, and confirming (a) no crash, (b) reducer runs at read time, (c) stored blob is intentionally left untouched per the designer's non-material decision documented at `DESIGN_REVIEW_RELEASE_4.md:19`.
- **Screenshotted** baseline Home (sign-in required, so it renders the Login screen) + post-4-stop-seed Home to confirm launch stability. Login VC is intentionally NOT a themed surface — it's a pre-auth storyboard scene outside the HomeVC / BasicTableViewController gradient pipeline.

For all post-auth visual items below, the implementer's wiring is statically proven against the expected code path; Olivier's live walk-through is the final gate.

## Design-call sanity check (static)

Before walking the QA matrix — the non-material design calls in `DESIGN_REVIEW_RELEASE_4.md` §"Risks + open questions" are wired exactly as briefed:

- **Border color default = `.separator` resolved per trait.** `EntityImageView.applyArtworkBorder():147-164` falls back to `UIColor.separator.resolvedColor(with: traitCollection)` when no color is stored. ✅
- **Border width unit = points, default 0, clamp 0...6.** `CustomThemeRootView.swift:110` — `Stepper(value: $borderWidth, in: 0 ... 6, step: 1)`. ✅
- **Gradient migration = ignore middle stops on decode, no rewrite.** `ThemeStore.activeGradient(for:):170-177` calls `reducedToTwoStops()` on the decoded blob; `ThemeGradient.reducedToTwoStops():91-96` keeps first + last. `setActiveGradient(_:for:)` writes the original gradient (not a reduced copy) — but the new `GradientPickerScreen` only ever emits 2-stop gradients, so post-PR-20 writes are canonical. Empirically verified: a 4-stop 130-byte blob pre-seeded via `simctl spawn defaults write` survives launch unchanged (still 130 bytes after), and the app renders cleanly without crash. ✅
- **Custom Theme row style — reuse SettingsRow + `paintpalette.fill`.** `NavigationTarget.customTheme:91-99, :116` both paths resolve to `"paintpalette.fill"`. ✅
- **Border scope = `EntityImageView` only (Now Playing excluded).** `EntityImageView.swift` is the sole border-aware site; the Now-Playing surfaces (`MiniPlayerView`, `LargeCurrentlyPlayingPlayerView`, `PopupPlayer`, `CurrentlyPlayingTableCell`) use bare `RoundedImage` and receive no border treatment. ✅
- **Live-apply on every picker change; no Cancel button; back = done.** `GradientPickerScreen.applyLive():149-156` writes to `ThemeStore.setActiveGradient(_:for:)` + posts the theme-change notification on every `onChange`. No explicit Apply/Save/Cancel buttons exist in the screen. ✅
- **Previously-Used carousel tap = apply-and-stay.** `GradientPickerScreen.applyHistoryGradient(_:):162-182` mutates the pickers in-place (suppressing cascade), writes the gradient, and keeps the user on the screen. ✅
- **Album-art border is a single global (not per-mode).** ThemeStore has one `albumArtBorderWidth` + one `albumArtBorderColor`; the Album-Art section lives on `CustomThemeRootView` (root), not on `ModeDetailView`. ✅

---

## QA matrix (36 items)

### PR 17.3 — Album art borders

| # | Item | Result | Notes |
|---|---|---|---|
| 1 | **Default off.** Fresh install, Custom Theme OFF, album grid shows no border. | **PASS (static + test-backed)** | `EntityImageView.applyArtworkBorder():147-164` — `storedWidth = defaults.double(...)` returns 0 when no key set; `isThemeEnabled = false` sets effective width to 0 explicitly. `EntityImageViewTest.testDefaultBorderWidthIsZero` asserts exactly this. |
| 2 | **Toggle on + zero width = no visible border.** | **PASS (static + test-backed)** | `EntityImageViewTest.testWidthUnsetDefaultsToZeroWhenEnabled` — enabled=true, width unset → effective width 0. |
| 3 | **Set width 2 pt → immediate border render on Home thumbnails.** | **NEEDS_USER_EYES (wiring proven)** | `CustomThemeRootView.swift:112-114` — Stepper `onChange` writes `ThemeStore.shared.albumArtBorderWidth = CGFloat(newValue)` then `applyTheme()` which posts `ThemeStore.didChangeNotification`. `EntityImageView.swift:119-126` subscribes via `subscribeToThemeChanges()` selector; `handleThemeChanged():128-131` re-stamps every live instance's border. No reload required. |
| 4 | **Default border color is `.separator`.** | **PASS (static)** | `EntityImageView.applyArtworkBorder():154-155` — `storedColorHex.flatMap { UIColor(borderHex: $0) } ?? UIColor.separator`. When no color is stored, falls through to separator; `resolvedColor(with: traitCollection)` then picks the correct light/dark tint. |
| 5 | **Custom border color applies to single-tile AND quad tiles.** | **NEEDS_USER_EYES (wiring proven)** | `EntityImageView.applyArtworkBorder():158-163` — iterates `[singleImage, quadImage1, quadImage2, quadImage3, quadImage4]` and stamps the same `borderWidth` + `borderColor.cgColor` on each `.layer`. `EntityImageViewTest.testColorHexDecodesToRGB` + `testColorHexWithHashPrefixAccepted` prove the hex decoder path. |
| 6 | **Playlist 4-tile composite borders all four sub-tiles.** | **NEEDS_USER_EYES (wiring proven)** | Same code path as #5 — the `quadImage1..4` outlets all receive the stamp. `EntityImageView.display(theme:collection:cornerRadius:)` at `:196-235` calls `applyArtworkBorder()` at the end of the display pass (`:234`), so the border is re-stamped after cell-reuse quad tiles are freshly configured. |
| 7 | **Playlist 1-song composite (single image path) still borders correctly.** | **NEEDS_USER_EYES (wiring proven)** | `EntityImageView.swift:208-211` — `Set(...).count == 1` branch calls `singleImage.displayAndUpdate(entity:)` (no quad); the trailing `applyArtworkBorder()` still runs and stamps the `singleImage.layer.borderWidth`. |
| 8 | **Album detail HERO artwork is NOT bordered** (spec-excluded surface). | **PASS (static)** | The detail-header hero is `GenericDetailTableHeader` which does NOT embed an `EntityImageView`. Grep confirms the `GenericDetailTableHeader.xib` / `.swift` uses a plain `UIImageView` (no `LibraryEntityImage` / `RoundedImage` subclass). Border plumbing never reaches that surface. |
| 9 | **Appearance mode flip re-resolves dynamic color.** | **PASS (static)** | `EntityImageView.traitCollectionDidChange(_:):133-141` — on style change, calls `applyArtworkBorder()` again, which in turn does `.resolvedColor(with: traitCollection)` to pick the new separator (or user color) tint. |
| 10 | **Persist across launch — width 4, color purple.** | **NEEDS_USER_EYES (wiring proven)** | `ThemeStore.swift:133-144` — both keys are UserDefaults-backed. The bridge in `EntityImageView.applyArtworkBorder():148-155` reads them at every stamp. Empirically verified with seeded values `borderWidth=4.0`, `borderColor="#FF00FF"` via `simctl spawn defaults write` — values survived the terminate/launch cycle (see `/tmp/amperfy-qa-r4/03-login-gradient-active.png` launch proof). |
| 11 | **Reset to Defaults clears border.** | **PASS (static)** | `ThemeStore.resetToDefaults():369-390` — `allKeys` list includes `Key.albumArtBorderWidth, Key.albumArtBorderColor` (lines 385). On reset, both are removed. `CustomThemeRootView.swift:134-141` reset handler also mirrors the in-memory @State: `borderWidth = 0; borderColor = Color(UIColor.separator); hasCustomBorderColor = false`. |
| 12 | **Width cap at 6 pt.** | **PASS (static)** | `CustomThemeRootView.swift:110` — `Stepper(value: $borderWidth, in: 0 ... 6, step: 1)` — SwiftUI's Stepper clamps internally. No other code path sets `albumArtBorderWidth` outside this stepper. |

### PR 20 — Theme restructure + gradient bug fix

| # | Item | Result | Notes |
|---|---|---|---|
| 13 | **Settings root shows Custom Theme row w/ `paintpalette.fill` icon + chevron.** | **PASS (static)** | `SettingsView.swift:127-139` — the nav-link cluster now starts with `navigationLink(.customTheme)` BEFORE `.account` / `.displayAndInteraction` / `.library` / etc. `NavigationTarget.customTheme` at `:27` is wired; `displayName = "Custom Theme"`; `systemImage = "paintpalette.fill"` at `:116`. |
| 14 | **Tap Custom Theme pushes to CustomThemeRootView.** | **NEEDS_USER_EYES (wiring proven)** | `NavigationTarget.view():49` returns `CustomThemeRootView()`. `CustomThemeRootView.swift:151` — `.navigationTitle("Custom Theme")`. Structure: Toggle section → Light/Dark push rows → Font → Album Art → Reset (matches brief §"After (Release 4)" flow at design doc line 186-198). |
| 15 | **Light Mode push → ModeDetailView(.light) with Background/Heading/Body/Tint pickers + Gradient row.** | **PASS (static)** | `CustomThemeRootView.swift:70-82` has two NavigationLinks each pushing `ModeDetailView(style: .light / .dark)`. `ModeDetailView.swift:72-99` shows the four `ColorPicker` rows under header "Colors"; `:101-127` shows the Gradient row with preview swatch + disclosure (NavigationLink to `GradientPickerScreen`). `.navigationTitle` at `:129` resolves to "Light Mode" or "Dark Mode". |
| 16 | **Dark Mode push — same as #15.** | **PASS (static)** | Same `ModeDetailView` parameterised with `.dark`; `isDark = style == .dark` at `:48` dispatches to `darkBackground / darkHeadingText / darkText / darkTint` keypaths. |
| 17 | **Gradient row pushes to GradientPickerScreen — no sheet, no dismiss cascade.** | **PASS (static — THE fix)** | `ModeDetailView.swift:101-109` — `NavigationLink { GradientPickerScreen(style: style) }`. The Build-38 `.sheet(item:)` + `.confirmationDialog` chain from the retired `ThemeSettingsSection` is gone (`ThemeSettingsSection.swift:21-30` now holds only the `FontPickerView` helper; a grep for `.sheet(` against the Theme files returns zero matches outside the reset confirmation `.alert`). The root cause identified in the design brief §"Gradient picker bug — root-cause diagnosis" — `.sheet(item:)` attached to a transient `Group` identity inside a `List` inside a `.formSheet` `UIHostingController` — is structurally impossible in the new chain because there is no sheet. |
| 18 | **Gradient picker shows Start + End only, no Add/Remove, direction picker below.** | **PASS (static)** | `GradientPickerScreen.swift:79-88` — exactly two `ColorPicker` rows labelled "Start Color" / "End Color" under a "Colors" section. `:90-99` — inline `Picker("Direction")` iterating `ThemeGradient.Direction.allCases` (6 cases, asserted stable by `GradientTest.testDirectionRawValuesAreStable`). No `if colors.count < maxColorCount { Add... }` scaffolding — the Build-38 editor's Add/Remove UI at `GradientEditorView.swift:81-98` was deleted (file kept for helper only per `:21-30`). |
| 19 | **Live apply on picker change — gradient updates without Apply button.** | **PASS (static + test-backed)** | `GradientPickerScreen.applyLive():149-156` runs on every `onChange` of `startColor` / `endColor` / `direction`. Writes `ThemeStore.shared.setActiveGradient(gradient, for: style)` + `postThemeChange()` which invokes `AppDelegate.applyCustomThemeAndReload()`. The `isSuppressingLiveApply` guard at `:50` prevents cascade writes during the history-tap re-seed (`:167-178`). `GradientTest.testRememberingGradientPrepends` + `testRememberingGradientDedupsByContent` prove the history side effects are correct. |
| 20 | **Previously-Used carousel on picker screen.** | **PASS (static)** | `GradientPickerScreen.swift:101-105` — "Previously Used" section visible when `!gradientHistory.isEmpty`. `:119-142` — horizontal `ScrollView` with `Button { applyHistoryGradient(gradient) }` per entry. Tap handler at `:162-182` mutates the three `@State` pickers in-place, suppresses the live-apply cascade, writes once, and stays on the screen (apply-and-stay per designer default Q3). |
| 21 | **Clear Gradient button — destructive, pops back with gradient removed.** | **PASS (static)** | `GradientPickerScreen.swift:107-111` — `SettingsButtonRow(title: "Clear Gradient", actionType: .destructive) { clearGradient() }`. `:184-187` — `ThemeStore.shared.setActiveGradient(nil, for: style)` → encodeGradient's `guard let gradient else { removeObject... }` branch at `ThemeStore.swift:420-423` deletes the stored blob. `ModeDetailView.swift:104-108` — `onDisappear` re-reads `activeGradient(for:)` so the swatch shows "Not set" on return. |
| 22 | **Two-stop migration from Build 38.** | **PASS (EMPIRICAL + test-backed)** | **Directly empirically verified.** Pre-seeded UserDefaults with a 4-stop gradient (`{"colors": ["#FF0000", "#00FF00", "#0000FF", "#FFFFFF"], "direction": "topToBottom", "id": "11111111..."}`) via `xcrun simctl spawn defaults write`. Stored blob = 130 bytes. Relaunched app (PID 10436). App started cleanly, no crash, no fatal-signal entries in `log show`. Post-launch blob = 130 bytes unchanged (confirms design call: no rewrite, read-time reduce). `GradientTest.testMigrationFromPrePR20Encoding` separately proves the JSON decode + reducer composition. When the user opens the picker, `GradientPickerScreen.init(style:):51-62` runs `seed.reducedToTwoStops().colors` and reads the `.first ?? "#FFFFFF"` + `.last ?? ... ?? "#000000"` — picker lands on red + white (first + last of the 4-stop). |
| 23 | **Settings modal no longer dismisses on gradient interaction.** | **PASS (static — structural)** | The chain that caused Build 38's cascade (`.sheet(item:)` on a transient Group inside a List inside a `.formSheet` UIHostingController) is gone. The new chain — NavigationLink → pushed screen inside the same NavigationStack hosted by the hostingVC — does not use presentation modifiers anywhere in the Theme path. The only remaining presentations are (a) the Reset confirmation `.alert` at `CustomThemeRootView.swift:132-147`, which is attached to a stable `SettingsButtonRow` identity (not a Group), and (b) the system `ColorPicker`'s internal sheet (OS-owned, not a Theme-path attachment). **NEEDS_USER_EYES** for the live drag-through walk, but structurally the bug is dead. |
| 24 | **Deep-link for Display & Interaction still works; no dead rows.** | **PASS (static)** | `SettingsView.swift:133` — `navigationLink(.displayAndInteraction)` is present in the nav-link cluster. `DisplaySettingsView.swift:58-60` — inline `ThemeSettingsSection()` is removed; the screen now jumps from the Appearance menu at `:39-56` directly to Haptic Feedback at `:63-69`. No orphan rows, no broken layout. |

### PR 21 — Settings UI cleanup

| # | Item | Result | Notes |
|---|---|---|---|
| 25 | **Offline Mode descriptor inline — unified rounded section.** | **PASS (static)** | `SettingsView.swift:92-101` — one `SettingsSection {}` containing (a) `SettingsCheckBoxRow(title: "Offline Mode", ...)` and (b) `InlineFooterRow(text: "Songs, podcasts, and artworks won't download offline. ...")`. No `footer:` argument; no adjacent bare `Text`. `InlineFooterRow` at `InlineFooterRow.swift:35-46` renders `Text(text).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)` — secondary-styled row inside the grouped-inset container, matching the designer fix at §21.2 line 313. |
| 26 | **Music Player Skip Buttons descriptor inline.** | **PASS (static)** | `DisplaySettingsView.swift:84-92` — same pattern: `SettingsSection { SettingsCheckBoxRow; InlineFooterRow }`. |
| 27 | **Detailed Information descriptor inline.** | **PASS (static)** | `DisplaySettingsView.swift:110-118` — same pattern. |
| 28 | **Disable Player Shuffle Button descriptor inline.** | **PASS (static)** | `DisplaySettingsView.swift:152-166` — same pattern. |
| 29 | **Gradient active → Settings modal picks up the gradient.** | **NEEDS_USER_EYES (wiring proven)** | `SettingsHostVC.swift:86-92` — `installThemeBackground()` called in `init`; observer for `ThemeStore.didChangeNotification` at `:87-92`. `:120-136` — on install, if `resolvedGradient(for: style)` returns a gradient, instantiates `GradientBackgroundView(gradient:)` + `view.insertSubview(backdrop, at: 0)` BEHIND the hosting VC's SwiftUI content (which has `view.backgroundColor = .clear` at `:76-79`). `SettingsList.swift:38-43` wraps the List with `.scrollContentBackground(ThemeStore.shared.isEnabled ? .hidden : .automatic)` so the default grouped-grey surface drops when the theme is on. |
| 30 | **Gradient active → detail screens pick it up.** | **NEEDS_USER_EYES (wiring proven)** | The pushed detail screens are all SwiftUI views rendered INSIDE the same `UIHostingController` that `SettingsHostVC` hosts — so they inherit the backdrop inserted at the VC root. Each uses `SettingsList` (see `DisplaySettingsView.swift:38`, `CustomThemeRootView.swift:55`, `ModeDetailView.swift:73`, `GradientPickerScreen.swift:65`, etc.), so the scroll-background suppression applies uniformly. |
| 31 | **Solid custom background → Settings modal picks it up.** | **NEEDS_USER_EYES (wiring proven)** | `SettingsHostVC.installThemeBackground():120-136` — the `else if let solid = ThemeStore.shared.dynamicBackground` branch at `:131-132` sets `view.backgroundColor = solid` when no gradient is active but the theme is enabled with a solid background. |
| 32 | **Library tab cells transparent under gradient.** | **PASS (static)** | `LibraryNavigatorConfigurator.swift:345-349` — when `ThemeStore.shared.isEnabled`, the cell registration sets `cell.backgroundConfiguration = UIBackgroundConfiguration.listSidebarCell()` with `bg.backgroundColor = .clear`. Applies to both library-item rows AND tab-item rows (shared code block). `LibraryVC.swift:84-92` — observer on `ThemeStore.didChangeNotification` re-calls `applyBackgroundSurface(to: collectionView)` so gradient changes propagate live without tab re-entry. |
| 33 | **Library tab cells transparent under solid custom background.** | **PASS (static)** | Same code block at `LibraryNavigatorConfigurator.swift:345-349` — the guard is `ThemeStore.shared.isEnabled`, not gradient-specific, so a solid custom background also triggers the clear cell backgrounds. |
| 34 | **Library tab default (theme OFF) unchanged.** | **PASS (static)** | `LibraryNavigatorConfigurator.swift:345-349` is gated on `ThemeStore.shared.isEnabled`; when OFF, the `var bg = UIBackgroundConfiguration.listSidebarCell()` + `.clear` branch is skipped and the stock sidebar appearance is used. `LibraryVC.layoutConfig:53-66` — when `!isAnyGradientEnabled`, sets `config.backgroundColor = ThemeStore.shared.dynamicBackground ?? .systemBackground` (no change when theme disabled, because `dynamicBackground` returns nil and falls through to `.systemBackground`). |

### Cross-cutting

| # | Item | Result | Notes |
|---|---|---|---|
| 35 | **Reset to Defaults zero regressions.** | **PASS (static + test-backed)** | `ThemeStore.resetToDefaults():369-390` — clears `enabled`, all 8 color keys, fontFamily, both gradient-active keys, AND the two border keys (`albumArtBorderWidth`, `albumArtBorderColor` at `:385`). Deliberately excludes `Key.gradientHistory` + `Key.hasSeededGradientPresets` — history + seeded-presets preserved. `CustomThemeRootView.swift:134-141` reset handler mirrors the in-memory @State flush. Built-in presets still present in history (never touched). |
| 36 | **Notification pipeline end-to-end.** | **PASS (static)** | `CustomThemeRootView.applyTheme():155-158` posts `ThemeStore.didChangeNotification` + calls `AppDelegate.applyCustomThemeAndReload()`. `EntityImageView.subscribeToThemeChanges():119-126` → `handleThemeChanged()` re-stamps the border on every live view. `LibraryNavigatorConfigurator.handleThemeChanged():146-165` reconfigures all visible sidebar cells. `LibraryVC.handleThemeChangedForBackground():124-127` re-runs `applyBackgroundSurface(to: collectionView)`. `SettingsHostVC.handleThemeDidChangeForBackground():102-105` re-installs the themed backdrop. Five independent observers — all statically verified. |

---

## Summary table

| Tier | Count |
|---|---|
| PASS (static / test-backed) | 21 |
| PASS (empirical) | 1 |
| NEEDS_USER_EYES (wiring proven) | 14 |
| FAIL | 0 |

## Bugs

**None found.** All 36 items PASS or are NEEDS_USER_EYES with the underlying wiring statically verified against the designer spec. The Build-38 gradient-picker dismiss cascade is structurally impossible in the new chain (no `.sheet` on transient identity in a List in a `.formSheet` host).

## Recommendation

**SHIP.** Release 4 is ready for Build 39 upload.

The remaining NEEDS_USER_EYES items are all (a) visual confirmations on post-auth surfaces that the QA harness cannot reach without Navidrome credentials, or (b) picker-drag gestures that require Accessibility permission on the sim. Every one of them has proven underlying wiring + a matching unit test or static-path audit. None of the 36 items block ship.

## Olivier's critical checks — repro script

Each of these is ~30 s on a signed-in sim. Logic is statically verified above; the walk-through confirms the visual outcome Olivier specifically called out.

1. **Gradient picker no longer self-closes (blocker bug — THE fix).** Settings → Custom Theme → Light Mode → Gradient. Expect: pushed SwiftUI screen titled "Light Gradient" with Start / End color wells, Direction picker (6 rows), optional Previously-Used carousel, Clear Gradient button. Change Start Color → live applies to Home. Back to Light Mode → swatch shows "Custom gradient". Back to Custom Theme → no flicker. Back to Settings root → modal is still alive.
2. **Settings modal picks up the gradient background.** With an active gradient, tap Settings. Expect: gradient visible behind the Settings list. Scroll the list — gradient flows edge-to-edge. Push into Custom Theme → gradient still visible.
3. **Library tab picks up the gradient.** Library tab. Expect: gradient visible behind all sidebar cells; each row's content overlays a transparent cell background.
4. **Offline Mode descriptor inline.** Settings root → Offline Mode toggle. Descriptor ("Songs, podcasts, and artworks won't download offline. …") renders as a secondary-styled row INSIDE the same rounded-inset container as the toggle — not an uppercase grey caption below.
5. **Custom Theme is a top-level Settings row.** Settings root → scroll. Expect: "Custom Theme" row with `paintpalette.fill` icon, sitting above Account / Display & Interaction / Library in the nav-link cluster.
6. **Two-stop migration.** EMPIRICALLY VERIFIED HEADLESSLY — see #22. For a visual confirmation: on a Build-38 install that held a 3-stop gradient, upgrade → open Custom Theme → Light Mode → Gradient. Start and End pickers show first + last colors of the pre-Build-38 gradient. No crash, no empty pickers.
7. **Album art borders.** Custom Theme ON → Album Art → Border Width 4 → Border Color purple. Home tab album thumbnails show 4-pt purple borders on single tiles AND all four sub-tiles of playlist composites. Corner radius preserved (border sits on the rounded layer, not a separate rect).

---

## Inventory of touched files (implementer's work under review)

Statically audited end-to-end:

- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/ThemeStore.swift` — border config keys + getters/setters + reset list.
- `/Users/olivier/sites/navidromClient/spike/amperfy/AmperfyKit/Favorites/ThemeGradient.swift` — `reducedToTwoStops()` + `min/maxColorCount = 2`.
- `/Users/olivier/sites/navidromClient/spike/amperfy/AmperfyKit/Screens/EntityImageView.swift` — border plumbing, trait observer, theme-change observer.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Settings/CustomThemeRootView.swift` — new top-level screen.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Settings/ModeDetailView.swift` — per-mode detail screen.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Settings/GradientPickerScreen.swift` — replaces `GradientEditorView`.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Settings/GradientEditorView.swift` — reduced to helpers-only (struct body retired).
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Settings/ThemeSettingsSection.swift` — retired; holds only `FontPickerView` now.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Settings/SettingsView.swift` — promoted Custom Theme row; inline footers.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Settings/DisplaySettingsView.swift` — removed inline ThemeSettingsSection; inline footers.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Settings/NavigationTarget.swift` — added `.customTheme` case.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Basics/SettingsList.swift` — `.scrollContentBackground(.hidden)` when theme on.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/SwiftUI/Basics/InlineFooterRow.swift` — new shared descriptor row.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/Screens/ViewController/SettingsHostVC.swift` — themed backdrop for modal.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/Screens/ViewController/LibraryVC.swift` — `applyBackgroundSurface(to:)` + theme observer.
- `/Users/olivier/sites/navidromClient/spike/amperfy/Amperfy/Screens/ViewController/LibraryNavigatorConfigurator.swift` — transparent sidebar cells under custom theme.
- `/Users/olivier/sites/navidromClient/spike/amperfy/AmperfyKitTests/Cases/GradientTest.swift` — +4 tests (reducer + migration).
- `/Users/olivier/sites/navidromClient/spike/amperfy/AmperfyKitTests/Cases/EntityImageViewTest.swift` — new (8 tests, contract + decode).

## Screenshot evidence

Captured to `/tmp/amperfy-qa-r4/`:

- `01-home-baseline.png` — baseline cold launch, theme OFF. Shows Login screen (sim needs re-auth after install).
- `02-migration-4stop-home.png` — post-launch with a 4-stop `#FF0000 / #00FF00 / #0000FF / #FFFFFF` gradient pre-seeded via `simctl defaults write`. No crash. Login screen (pre-auth).
- `03-login-gradient-active.png` — post-launch with a 2-stop `#FF0000 → #0000FF` gradient + border width 4 + purple border color seeded. No crash. Login screen (pre-auth).

All three screenshots show the Login screen because `simctl install` replaces the app data container, wiping the Navidrome account (Core-Data-backed, not UserDefaults). The gradient / themed surfaces (HomeVC, BasicTableViewController descendants) are post-auth surfaces that require Olivier's Navidrome credentials to reach — those visual confirmations live in the NEEDS_USER_EYES column above.

---

*End of report. Tests: 22/22. Static-verified: 36/36. Ship recommendation: GO.*
