# Release 1 — Design Review (PR 16 + PR 17.1 + PR 17.4)

Review date: 2026-04-15
Reviewer: designer agent
Implementer target: `spike/amperfy/`

## Summary

Release 1 bundles three low-risk follow-ups on top of PR 7 (custom styling) and the complete-albums predicate from PR 1. PR 16 tightens Home's "Random Albums" section so it only draws from whole albums and gently favours unplayed picks. PR 17.1 plugs a font-propagation gap: `UIFont.themed` is already applied to nav bar titles and section-header proxies in `AppDelegate.applyCustomThemeAppearance()`, but two programmatically-built heading labels bypass it — `SectionHeaderView.titleLabel` (Home widget headers) and `GenericDetailTableHeader.titleLabel` (album/artist/playlist/podcast/genre detail). PR 17.4 splits the single text color into a heading tier and a body tier, with the heading tier driving the same three surfaces where the font now lands. All three changes sit at the app layer — no `AmperfyKit/` edits required.

---

## PR 16 — UX notes + risks

### Where "Random Albums" actually surfaces
The section is user-facing on the **Home tab** (`HomeSection.randomAlbums`, iterable via `HomeVC` collection view). The header is a `SectionHeaderView` with a visible refresh button (`refreshRandomAlbumsSection()` on `HomeVC.swift:312`). The section is driven by `HomeManager.updateRandomAlbums(isOfflineMode:)` at `HomeManager.swift:367`, which calls `LibraryStorage.getRandomAlbums(for:count:onlyCached:)` at `LibraryStorage.swift:1389`.

A second, unrelated "pick 5 random displayed albums and shuffle" action exists in `AlbumsCommonVCInteractions.handleHeaderShuffle()` (line 533) — that is the Albums-tab shuffle button, NOT the Home section. **Do not touch that path in PR 16.** Backlog §16 scopes to the Home random albums section (and, by extension, CarPlay's "Play Random Albums" action at `CarPlayCommonListExtension.triggerPlayRandomAlbums`).

### UX impact of the weighting
The weighting is invisible to the user directly — there is no badge, label, or ordering hint. The felt effect is "I see more stuff I haven't played" over repeated refreshes. The QA acceptance must therefore verify the *rules* (whole-albums only, no duplicates in a single set, pool composition) rather than observed bias, which is statistical and won't be detectable in a single sim session.

### Implementation shape
The cleanest home for this is a new helper method on `LibraryStorage` (e.g., `getRandomWholeAlbums(for:count:onlyCached:)`) that:
1. Fetches all AlbumMO matching the existing account/cached predicates AND `WholeAlbumPredicates.wholeAlbum(minSongCount: 3)`.
2. Materialises candidates, computing `unplayedCount` per album (count of `songs` where `playCount == 0`).
3. Duplicates each album in the pool when `unplayedCount > remoteSongCount / 2`.
4. Shuffles, deduplicates by album identifier (keep first occurrence), takes first N.

Update callers: `HomeManager.updateRandomAlbums` and the CarPlay triggers so the new behaviour reaches both surfaces.

**Implementer choice point:** the existing `getRandomAlbums` uses a Core-Data-level `[randomPick: count]` extension on fetched MOs. Weighted selection requires materialising album wrappers (to call `.songs` / `.playCount`), so PR 16 moves weighting out of the fetch-extension and into Swift-level. Acceptable — this is ~20–50 albums max in practice, not a scale concern.

### Risks
- **Unplayed = `playCount == 0`?** Confirmed: `AbstractLibraryEntity.playCount` is the stored count; zero means never played. Safe.
- **Partial libraries:** if fewer than N whole albums exist, return what's available — do not relax the predicate. Matches the existing semantics of the complete-albums filter on Albums tab.
- **remoteSongCount == 0 edge case:** there's a known bug (memory: `remoteSongCount=0` on some Navidrome syncs). Filtering through `wholeAlbum(minSongCount: 3)` already excludes those, so the weighting pass never sees them. No extra guard needed.
- **CarPlay behaviour:** `triggerPlayRandomAlbums` flattens 5 random albums into a single queue. Applying the whole-album filter here is a correctness win (no more one-song "albums" getting queued), but Olivier should confirm the CarPlay path counts as in-scope for PR 16 — see Open Questions.

---

## PR 17.1 — Heading audit

Terminology: "heading" per Olivier = widget headings, detail-view title labels, and nav bar / VC titles. "Body" = everything else.

### Already covered by the existing PR 7 wiring (keep as-is)
- **Nav bar title + large title** — `AppDelegate.applyCustomThemeAppearance()` sets `UINavigationBar.appearance().titleTextAttributes` and `largeTitleTextAttributes` to `UIFont.themed(style: .headline / .largeTitle)` when `theme.fontFamily != nil`. Lines 180–208 of `Amperfy/AppDelegate.swift`.
- **`UITableViewHeaderFooterView` labels** — same AppDelegate pass applies `UIFont.themed(style: .headline)` via `UILabel.appearance(whenContainedInInstancesOf:)`. This covers default grouped-table section headers (e.g., in Settings, Playlists tab sections).
- **`CommonCollectionSectionHeader.titleLabel`** — already calls `UIFont.themed(style: .headline)` directly in `display(title:)` at `Amperfy/Screens/View/Collection/CommonCollectionSectionHeader.swift:36`. Used by Albums grid / various collection views.

### Heading sites that currently MISS the custom font (fix in PR 17.1)

1. **`SectionHeaderView.titleLabel`** — `Amperfy/Screens/ViewController/HomeVC.swift:478–539`.
   - This is the Home-tab widget header ("Random Albums", "Recently Played Albums", "Favourite Albums", "Recently Added Tracks", etc.).
   - Font is hard-coded at line 493: `UIFont.preferredFont(forTextStyle: .title3).withWeight(.semibold)`.
   - Fix: when applying `title` (line 534) or in a new `applyTheme()` pass, set `titleLabel.font = UIFont.themed(style: .title3)` (or the equivalent with the `.semibold` trait preserved — see risk below). `textColor` is already themed at line 537, so mirror the pattern.

2. **`GenericDetailTableHeader.titleLabel`** — `Amperfy/Screens/View/GenericDetailTableHeader.swift`.
   - This is the large in-content heading ("Album Name" / "Artist Name" / "Playlist Name") used by **AlbumDetailVC, ArtistDetailVC, PlaylistDetailVC, PlaylistEditVC, GenreDetailVC, PodcastDetailVC** (all call `GenericDetailTableHeader.createTableHeader(configuration:)`).
   - Font comes from the XIB (`GenericDetailTableHeader.xib`). `prepare(configuration:)` at line 104 does not set a font. `subtitleLabel.textColor = .tintColor` is set but no font or colour for the title.
   - Fix: in `prepare(configuration:)`, set `titleLabel.font = UIFont.themed(style: .title1)` (or `.title2` — match whatever the XIB currently renders at). Also apply the heading color (see PR 17.4).

3. **`GenericDetailTableHeader.nameTextField`** — same file, line 43. This is the editable title shown while renaming a playlist. For visual consistency the custom font should also apply here. Low stakes (only visible during rename), but include to avoid an ugly font-swap mid-edit.

### Non-obvious things flagged
- **`UINavigationBar.appearance()` vs per-VC overrides:** Amperfy uses the appearance proxy path, not per-VC `titleTextAttributes`. Good — the AppDelegate pass reaches everything. But `applyCustomThemeAppearance()` only re-runs when the theme toggle flips; already-loaded nav bars keep their old titleTextAttributes until a reload. `applyCustomThemeAndReload()` (line 224) handles this. The implementer should confirm that path is called after font OR heading-color changes (not just on toggle).
- **`largeTitleTextAttributes` uses `.largeTitle`; `titleTextAttributes` uses `.headline`.** Keep those text styles — that's the iOS convention. Don't unify them.
- **Miniplayer titles** — `MiniPlayerView.swift:720` hard-codes `systemFont(ofSize:)` values. Per backlog §17.1 scope ("widget headings, detail headings, nav titles"), Miniplayer is *not* on the heading list. Treat miniplayer as body-tier for 17.4 purposes. Flag in Open Questions if Olivier actually wants it headed.
- **NowPlaying (`LargeCurrentlyPlayingPlayerView`)** — explicitly NOT a heading site per backlog scope. Leave alone.
- **XIB-defined fonts vs code-set fonts.** `GenericDetailTableHeader.titleLabel`'s XIB font is whatever Interface Builder has — the code override in `prepare()` will win, so there's no race. Same for `SectionHeaderView` which is fully programmatic.

---

## PR 17.4 — Settings screen shape + defaults

### New ThemeStore surface
Extend `ThemeStore` with a second text-color pair per interface style. Proposed keys (following the existing `amperfy.fork.theme.*` convention):

- `amperfy.fork.theme.light.headingText` / `amperfy.fork.theme.dark.headingText`
- Rename or alias the existing `light.text` / `dark.text` as the **body** text. Do not break the existing keys — if the stored text color predates 17.4, migrate it to both tiers on first read so users who already configured a custom color don't see a regression. (Simplest: on `populateDefaultsIfNeeded()`, if heading is nil but body is set, copy body → heading.)

New resolved accessors:
- `dynamicHeadingText: UIColor?` — sibling to the existing `dynamicText`.
- `headingTextColor(for style: UIUserInterfaceStyle) -> UIColor?` — sibling to `textColor(for:)`.

Rename conceptually (not as a source rename — keep `dynamicText` to avoid a big diff): `dynamicText` now means *body* color. Audit all existing call sites and split them:

**Call sites that should switch to `dynamicHeadingText`** (these back the three PR 17.1 heading surfaces + what the AppDelegate proxy drives for headings):
- `AppDelegate.swift:177–208` — where `textColor` drives `UINavigationBar.titleTextAttributes`, `largeTitleTextAttributes`, and the `UITableViewHeaderFooterView` label appearance. These are headings.
- `HomeVC.swift:537` — `SectionHeaderView.titleLabel.textColor`.
- Add to `GenericDetailTableHeader.prepare()` (new line) — `titleLabel.textColor = ThemeStore.shared.dynamicHeadingText ?? .label`.
- Add to `CommonCollectionSectionHeader.display(title:)` (new line alongside the existing font line at `:36`) — `titleLabel.textColor = ThemeStore.shared.dynamicHeadingText ?? .label`. (Currently no color is set there, relying on XIB / .label; bring it under the heading tier for consistency.)

**Call sites that REMAIN on `dynamicText` (body tier):**
- `AppDelegate.swift:189–193` — `UILabel.appearance(whenContainedInInstancesOf: [UITableViewCell.self / UICollectionViewCell.self])` — these are cell body labels.
- `PlayableTableCell.swift:476–477` (primary + secondary) — song cells in lists.
- `AlbumCollectionCell.swift:80–82` — album grid cells (title + subtitle). Note: "titleLabel" here is the album title *inside a cell*, NOT a widget heading. Keep on body tier, matching the existing behaviour.
- `PlaylistFolderContentsVC.swift:468 / 477 / 213` — list cell labels, count labels.
- `LargeCurrentlyPlayingPlayerView.swift:422–423` — player labels (not in heading scope).
- `MiniPlayerView.swift:851–865` — miniplayer.
- `PlayerControlView.swift` — playback controls.
- `LibraryNavigatorConfigurator.swift:364 / 417` — sidebar item labels. (These are nav items, but they render as cell-style rows, so body tier is correct.)
- SwiftUI `UtilitiesExtensions.swift:67/72` — the `Color.primary` / `Color.secondary` overrides for SwiftUI screens (Settings). Settings body should be body-tier; the Settings *nav bar title* is already covered by the UINavigationBar appearance proxy.

### Settings screen layout

Edit `Amperfy/SwiftUI/Settings/ThemeSettingsSection.swift` — the existing "Light Mode Colors" and "Dark Mode Colors" sections each have three rows (Background / Text / Tint). Replace the single "Text" row with two rows, in this order:

```
Light Mode Colors
  Background
  Heading Color          <-- new
  Body Color             <-- renamed from "Text"
  Tint

Dark Mode Colors
  Background
  Heading Color          <-- new
  Body Color             <-- renamed from "Text"
  Tint
```

Rationale for order: visual grouping follows layering — background sits behind everything, headings are the most prominent text layer, body is the most common text, tint is accents. Placing Heading above Body also matches reading order in the UI (heading is "bigger" / "first").

### Defaults

- **Heading color default:** mirror the existing Text default — `UIColor.label` resolved for light/dark respectively. (Same path as `populateDefaultsIfNeeded()` already uses.)
- **Body color default:** unchanged — still `UIColor.label` resolved per style.
- **Migration:** if `lightText` / `darkText` exists (from a user who configured PR 7 before 17.4 shipped), copy that value into both `lightHeadingText` and `lightText` on first read — the user's prior choice becomes both tiers, no surprise regression. Same for dark.

### Contrast warning
`updateContrastWarning()` currently checks text vs background. Extend to check **both** heading-text vs background AND body-text vs background. Two separate warnings if both fail, one if only one fails. Keep the 4.5 threshold (WCAG AA for normal text).

### Reset behaviour
`resetToDefaults()` should clear all six color keys plus the font family — i.e., add `lightHeadingText` / `darkHeadingText` to the `allKeys` list in `ThemeStore.resetToDefaults()`.

---

## QA acceptance criteria

All test steps assume a test server with at least 20 whole albums (3+ songs each), at least 3 albums with 0 plays, and at least 3 albums with some plays. If the reference library isn't stocked, sim-reset and resync before running.

### PR 16 — Random Albums
1. **Whole-albums filter, online mode.** Home tab → "Random Albums" section → swipe/refresh button → pull a set. None of the visible albums should have fewer than 3 tracks. Tap into each shown album and confirm song count ≥ 3 on the detail header.
2. **Whole-albums filter, offline mode.** Toggle offline mode. Refresh Random Albums. Same check — no sub-3-track albums. (Offline mode passes `onlyCached: true`; ensure both branches honour the predicate.)
3. **Dedup guarantee.** Tap refresh 5 times in a row. Within each single refresh result, no album appears twice.
4. **CarPlay path (if in scope — see Open Questions).** Launch CarPlay simulator, Library tab → "Albums" (Play Random Albums) → confirm queued songs all come from ≥ 3-track albums.
5. **Empty-library-safe.** On an account with zero whole albums (e.g., after wiping), the Random Albums section is empty or hidden; no crash.
6. **Unit test (AmperfyKit or app-layer tests).** Seed a fixture library: 3 albums with all tracks played (playCount > 0), 3 albums with > 50% unplayed, 3 albums with = 50% unplayed, 3 albums with < 50% unplayed. Call the new helper 100 times, aggregate. Verify: (a) the >50%-unplayed albums appear roughly 2× as often as the others, (b) no single result set contains duplicates, (c) 50%-unplayed and <50%-unplayed appear at parity (boundary is "more than half", strict).

### PR 17.1 — Font propagation
7. **Toggle custom theme ON, pick a visually distinctive font** (e.g., "Courier New" or "Georgia"). Navigate through:
   - Home tab: all section headers (Random Albums, Recently Played Albums, Favourite Albums, Recently Added Tracks) render in the custom font.
   - Albums tab: push into an album detail. The large title ("Album Name") at the top of the detail screen renders in the custom font.
   - Artists tab: push into an artist detail. Same check on the artist name heading.
   - Playlists tab: push into a playlist detail. Same check on the playlist name heading.
   - Nav bar titles on every tab render in the custom font (large title + compact title).
8. **Theme toggle OFF.** All of the above revert to system font with no relaunch.
9. **Font persists across relaunch.** Kill + reopen. Headings still render in the custom font.
10. **Settings screen nav title** (e.g., "Settings", "Appearance") renders in the custom font — regression check that the existing nav-bar pass still works after the PR 17.1 additions.
11. **Body text regression.** Playlist list cells, album grid cell titles, song row titles in an album detail all still render (heading change must not have bled the heading font into body — unless PR 17.4 landed first, in which case body uses its own tier).

### PR 17.4 — Two-tier colour
12. **Pickers present.** Settings → Appearance → Light Mode Colors: rows in order Background / Heading Color / Body Color / Tint. Same under Dark Mode Colors. Both heading rows use `UIColorPicker` like the existing rows.
13. **Heading-only change.** Set heading color to red (distinct from body color, which stays stock). Verify:
    - Home section titles render red.
    - Album/artist/playlist detail titles render red.
    - Nav bar titles + large titles render red.
    - Body text (list cells, song rows, metadata) does NOT render red — stays on body color.
14. **Body-only change.** Reset heading, change body to blue. Verify body text renders blue; headings stay on the heading default.
15. **Both tiers independent.** Heading = red, body = blue. Nav bar title is red, song rows are blue, on every screen from test 7.
16. **Light/dark independence.** Configure different heading colors for light and dark. Toggle system appearance — heading color should swap without relaunch. Same for body.
17. **Migration from pre-17.4 theme.** Simulate a user on an older build: pre-populate UserDefaults with `amperfy.fork.theme.light.text = <green>`, open app on the 17.4 build. On first render, both heading and body should be green (migration copied the old single color into both tiers). No crash, no nil-picker UI.
18. **Reset to Defaults.** Settings → Reset → confirm. All 8 color values clear, theme toggle OFF, UI returns to stock. Re-enable theme → pickers show system defaults, not the pre-reset values.
19. **Contrast warning.** Set heading color to match background (e.g., both white in light mode). The amber warning text should surface. Same for body.

---

## Open questions for Olivier

1. **Is the CarPlay "Play Random Albums" action in scope for PR 16?** Backlog §16 says "random albums feature" generically. The Home tab section is the primary surface; CarPlay's batch-play is secondary. Recommend including it for consistency (same filter + weighting), but flagging because it's a different UX (no visible "album list", just a queue). If Olivier wants CarPlay kept on the old unfiltered behaviour, PR 16 should leave `triggerPlayRandomAlbums` alone.

2. **Is Miniplayer a "heading" site for PR 17.1/17.4?** Backlog §17.1 lists "widget headings, album/artist/playlist detail headings, nav bar titles" — Miniplayer isn't on that list. Current designer call: treat Miniplayer as body-tier (status quo). Confirm.

3. **NowPlaying view (`LargeCurrentlyPlayingPlayerView`) track title** — same question, and same call: body-tier, out of scope for headings. Confirm.

4. **`AlbumCollectionCell.titleLabel` (album name inside a grid cell) — heading or body?** It's the album's *title text* but it's inside a cell, rendered at body size, flowing through the per-cell code path (not the heading appearance proxy). Current designer call: body tier. If Olivier thinks "any album title" is a heading, we'd need a third tier or redraw the boundary. Flagging because the naming collision could confuse.

5. **Font style for `SectionHeaderView` titles.** Currently hard-coded as `.title3 semibold`. `UIFont.themed(style:)` picks up the text style but loses the `.semibold` weight — scaled custom fonts don't honour UIKit weight traits cleanly. Options: (a) accept weight loss when custom font is on (simplest); (b) try `UIFontMetrics.scaledFont(for: UIFont(name:size:).withTraits(.semibold))` (fragile, font-family dependent); (c) store the raw custom font face name the user picks and use it directly without weight fiddling. Recommend (a) for Release 1 and revisit in Release 4 (presets) if users complain.

6. **Do we ship tests for PR 17.1 / 17.4?** The theme system is visual-only. A `ThemeStoreTest` extension for the new headingText keys + migration round-trip is cheap (~30 LOC). Recommend yes for the UserDefaults layer, manual QA for the visual pass. Confirm.
