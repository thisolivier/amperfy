# Design Review — Release 5 (PR 17.5 Styling Presets)

**Branch:** `olivierMain`
**Build baseline:** 40 (post Release 4)
**Spec:** `BACKLOG.md` §17.5
**Reviewer:** designer agent (2026-04-15)

---

## Summary

PR 17.5 adds user-saveable theme presets on top of the Release 4 theme
restructure. Users can snapshot the current styling configuration, name it
(optionally), and load any saved snapshot back later. Presets are persistent,
unbounded, and backed by a single JSON blob in `UserDefaults` — same pattern
as the rest of `ThemeStore`.

**Key call:** one preset = **one full theme state** (both modes + globals),
not a per-mode scope. The backlog line about "independent entries" is about
letting the user save multiple variants to pick between; it is not a claim
that light-only and dark-only presets are separately addressable. Rationale
below.

This review covers scope, data model, UX flow, naming/rename/delete, first-
launch behaviour, QA acceptance criteria, and material risks. It does NOT
specify code changes — the implementer is expected to follow the shape
described and surface decisions where this doc flags them.

---

## Preset scope decision — full-state, not mode-scoped

The backlog says:

> Light mode and dark mode configurations save to the **same preset list**
> as independent entries — each can load any existing preset independently.

Two readings are possible:

1. **Full-state preset (CHOSEN).** A preset captures the complete theme
   (both modes' colors + both gradients + font + border globals). Both
   "light mode" and "dark mode" actions pull from the same list. The
   "independent entries" phrase means the user can build multiple full-
   state variants ("Sunset", "Paper", "Night") and swap between them;
   "independent" here means independent of any prior mode context.
2. **Mode-scoped preset.** Each preset captures one mode's state only
   (background / heading / body / tint / gradient for that mode).
   The list contains mixed light and dark entries. The user chooses a
   light preset for the light mode slot and a dark preset for the dark
   mode slot.

**Decision: reading 1 (full-state).** Rationale:

- The spec literal — "A preset captures **all** styling state: font,
  gradient, border settings, heading color, body text color, **and any
  other styling properties**" — reads as a whole-theme snapshot, not a
  mode slice. Font and border are global; splitting a preset by mode
  would either duplicate globals on both sides (weird) or strand them
  at neither side (broken).
- The mental model users bring to themes on iOS (App icon, iOS Shortcut
  themes, WhatsApp wallpapers, Reeder themes) is a whole-look gesture,
  not a one-half-at-a-time gesture.
- Release 4 already binds globals (font, border) at the root level of
  `CustomThemeRootView` and colors at `ModeDetailView`. A full-state
  preset captures this neatly; a mode-scoped preset would need a third
  "Globals" scope.
- "Each can load any existing preset independently" reads cleanly under
  full-state too: Olivier's intent is probably that the light-mode detail
  screen has a "Load Preset" affordance that applies only to light, and
  the dark-mode detail screen has its own that applies only to dark —
  the **same full-state preset** can be partially applied from either
  side. This gives users the flexibility of reading 2 while keeping the
  data model of reading 1.

To honour the "independent" flexibility while staying full-state, the
UX offers **three load targets** (see UX section):

- Load full preset (root screen) — applies every field.
- Load light slice (from light mode screen) — applies only the light-mode
  colors + light gradient from the chosen preset. Globals untouched.
- Load dark slice (from dark mode screen) — applies only the dark-mode
  colors + dark gradient from the chosen preset. Globals untouched.

This is the cleanest synthesis of the two readings and the one I
recommend shipping.

**Open question (flagged):** Olivier to confirm he is OK with a full-state
preset as the storage unit, with partial-apply from the mode detail
screens as the "independent" affordance. If he genuinely wanted mode-
scoped presets, the data model and UX both change shape and this review
needs a rewrite.

---

## Data model

Add one file, `Amperfy/StylingPresetStore.swift`, peer to `ThemeStore.swift`
(same pattern, same UserDefaults backing, same notification hook).

### Struct shape

```
StylingPreset (Codable, Equatable, Identifiable, Sendable)
├── id: UUID                       // stable identity, dedup key
├── name: String?                  // nil => auto-labelled at display time
├── createdAt: Date                // sort key (newest-first default)
├── schemaVersion: Int             // start at 1; bump when we change shape
└── config: StylingPresetConfig
    ├── fontFamily: String?        // nil => system default
    ├── borderWidthPoints: Double  // 0...6 clamp at UI; 0 = off
    ├── borderColorHex: String?    // nil => "separator" fallback
    ├── light: ModeSlice
    └── dark:  ModeSlice

ModeSlice (Codable, Equatable, Sendable)
├── backgroundHex:  String?        // nil => system fallback on load
├── headingHex:     String?
├── bodyHex:        String?
├── tintHex:        String?
└── gradient:       ThemeGradient? // nil => no gradient for this mode
```

Rationale:

- **Hex strings, not UIColor directly.** Matches how `ThemeStore` already
  persists colors (see `Key.lightBackground` and `color(forKey:)`). Keeps
  JSON human-readable and avoids the Data/archiving dance.
- **Optional hexes.** A user may have created a preset before setting, say,
  a heading color — we preserve "not set" rather than forcing a concrete
  color into the snapshot. On load, nil fields fall back through the same
  path as `populateDefaultsIfNeeded` semantics.
- **`ThemeGradient` reused.** It's already `Codable`, `Equatable`, and
  lives in AmperfyKit. `reducedToTwoStops()` on decode keeps presets
  consistent with the PR 20 two-stop world.
- **Gradient history is NOT captured.** History is palette curation; a
  preset is a configuration. Loading a preset doesn't merge histories;
  it also doesn't clear the current history. (Stated explicitly so QA
  can verify.)
- **`schemaVersion` up front.** Cheap future-proofing. If we add, say,
  per-mode border color later, we bump to 2 and add a decode fallback.
- **`isEnabled` is NOT captured.** Loading a preset doesn't toggle the
  custom theme on or off. If the theme is off when a preset loads, the
  values write through but the app keeps looking stock until the user
  flips the master switch. Matches how Release 4's color pickers already
  behave.

### Storage

```
Key.presets = "amperfy.fork.theme.presets"
  -> JSON-encoded [StylingPreset], sorted newest-first at read time.
```

One blob. Not Core Data. Reasons:

- `UserDefaults` JSON is what every other ThemeStore knob uses.
- Presets are tiny (<1KB each). An unbounded list hitting hundreds would
  still fit comfortably; the soft cap mentioned in risks below addresses
  the pathological case.
- No Core Data migration headache. No entity additions to the `.xcdatamodel`.
- Versionable per-struct via `schemaVersion`.

### Store API surface (no code yet — just contract)

- `presets: [StylingPreset]` — read-only public view, newest first.
- `savePreset(name: String?) -> StylingPreset` — snapshots current
  `ThemeStore` state, assigns auto-label if `name == nil`, appends, returns
  the stored entity.
- `loadFullPreset(_ preset: StylingPreset)` — writes every field back into
  `ThemeStore`, fires change notification once at the end (not per field,
  to avoid visible flicker).
- `loadLightSlice(from preset: StylingPreset)` — applies light-mode colors
  and light gradient only.
- `loadDarkSlice(from preset: StylingPreset)` — applies dark-mode colors
  and dark gradient only.
- `renamePreset(_ preset: StylingPreset, to name: String?)` — updates the
  entry in-place. `nil` reverts to auto-label.
- `deletePreset(_ preset: StylingPreset)` — removes by id.
- `autoLabel(for preset: StylingPreset, index: Int) -> String` — display
  helper. See Naming section.

---

## UX flow

### Nav sketch (Release 5 additions in bold)

```
Settings
└── Custom Theme                    (CustomThemeRootView)
    ├── [Toggle] Custom Theme
    ├── Light Mode                  -> ModeDetailView(.light)
    │   ├── Background / Heading / Body / Tint
    │   ├── Gradient                -> GradientPickerScreen(.light)
    │   └── **Load Preset (Light only)**   -> PresetPickerView(scope: .lightSlice)
    ├── Dark Mode                   -> ModeDetailView(.dark)
    │   └── (mirror of Light)
    ├── Typography / Font Family    -> FontPickerView
    ├── Album Art / Border          (width + color)
    ├── **Presets**                                   <-- new section
    │   ├── **Save Current as Preset** (button)      -> name prompt sheet
    │   └── **Load Preset** (row)                    -> PresetPickerView(scope: .full)
    └── Reset to Defaults
```

### Save flow

Triggered by the **Save Current as Preset** button in the new Presets
section on `CustomThemeRootView`.

1. Tap presents a `.alert` (or a small sheet) titled **"Save Preset"** with:
   - a `TextField` prefilled empty, placeholder text **"Preset N"** where N
     is the next auto-label index,
   - **"Save"** primary button,
   - **"Cancel"** secondary button.
2. If the user types a name and taps Save, the preset is stored with
   `name = that string (trimmed)`.
3. If the user leaves the field empty and taps Save, the preset is stored
   with `name = nil`. Display falls back to the auto-label — computed live
   from the entry's position in the newest-first list (see Naming).
4. Cancel closes the alert; no preset saved.
5. A subtle toast or the screen state change (new row appears in Presets
   list) is sufficient confirmation — no modal success message.

Design note: an alert text field is cheap in SwiftUI (`.alert` with
`TextField` inside). If that feels constrained, a dedicated sheet is fine
— doesn't materially change the design.

### Load flow (full preset, from root)

Tap the **Load Preset** row on `CustomThemeRootView`. Push
`PresetPickerView(scope: .full)`.

`PresetPickerView` is a `List` of `PresetRow`s. Each row shows:

```
┌───────────────────────────────────────────────────┐
│ [light swatch] [dark swatch]  Preset Name         │
│                               2 hours ago · 2-stop│
└───────────────────────────────────────────────────┘
```

- **Swatches** on the leading edge preview the preset. Two small pill
  swatches (light bg color over light gradient if present; dark bg over
  dark gradient if present). Cheap signal of "what does this one look
  like". Implementation shares `GradientPreviewSwiftUIView`.
- **Name** is the user-provided name, or the auto-label ("Preset 3")
  computed on the fly.
- **Secondary line** shows a relative `createdAt` and any informative
  tag (e.g. "gradient" if either mode has one, "solid" otherwise). Keep
  it light — this is a picker, not a detail view.
- **Tap row** -> apply full preset (all fields) and pop the screen. Fires
  `ThemeStore.postChangeNotification` once so the app redraws.
- **Swipe-to-delete** on the row deletes the preset after a one-tap
  confirmation alert. Matches the playlist-folder delete affordance
  (PR 18) — users know this gesture.
- **Context menu / long-press** on the row exposes **Rename** and
  **Delete**. Rename presents the same alert+TextField as Save, prefilled
  with the current name (auto-label or user-given).

Empty state: the picker screen shows `Text("No presets yet. Save your
current theme from the Custom Theme screen.")` centred in the list area.
No button — the affordance is one screen back, and pushing the user back
automatically would be surprising. A plain empty state is honest.

### Load flow (mode slice, from ModeDetailView)

On each `ModeDetailView(.light)` and `ModeDetailView(.dark)`, add a new
**Presets** section at the bottom (above nothing — it's the last section):

- Row **"Load From Preset"** -> pushes `PresetPickerView(scope: .lightSlice)`
  or `.darkSlice`.
- The picker itself is identical; the scope only changes what the tap
  handler applies. Row subtitle mutates: "Applies light-mode colors +
  gradient only" / same for dark. This is the clearest way to signal
  that globals are left alone.

No "Save light slice" action. Saving is a full-state gesture — you save
the whole theme, then partially apply. This keeps the preset list small
and its contents consistent.

### Rename / delete (reprise)

- **Rename** from row context menu OR swipe-leading "Rename" action.
  Presents alert+TextField prefilled. Save writes; blank reverts to auto.
- **Delete** from row context menu OR swipe-trailing "Delete" action.
  One-tap confirmation alert *"Delete preset '<name>'? This cannot be
  undone."*. Two buttons: Delete (destructive) / Cancel.

No multi-select, no "Delete All" — out of scope. A user wanting to clear
everything can use Reset to Defaults (which this review does NOT propose
to extend — see Risks).

---

## Naming, rename, delete mechanics

### Auto-labels

When `name == nil`, display shows `"Preset \(autoIndex)"` where `autoIndex`
is **the number of presets in the list at creation time + 1** at store
time, written onto the preset once and stable afterwards.

Why stable and not dynamic:

- Dynamic labelling (recomputing "Preset N" from current position on every
  read) means deleting Preset 2 renames Preset 3 to Preset 2 silently,
  which is confusing when the user is reading the list.
- Stable labelling burns the index at save time. Users see "Preset 1,
  Preset 3, Preset 5" after deletes — that's honest and matches how
  most "Untitled N" systems behave.

Implementation detail for the implementer: at save time, compute
`maxIndexInExistingAutoLabels + 1` (scan the list for names matching the
"Preset N" regex — both nil names and name-is-exactly-"Preset N" — then
take max+1). This avoids collisions with earlier auto labels even after
deletes.

### Rename

Rename writes a new `name` value (non-empty, trimmed) to the preset and
saves. Renaming to empty string stores `nil`, re-activating the auto-label
display.

Duplicate names are allowed. Users can absolutely have two "Sunset"
entries. The id keeps them distinct; that's enough.

### Delete

Per-row; with one-tap confirmation. No undo (consistent with
`PlaylistFolderStore.deleteFolder`). If implementer wants to add a
5-second undo banner later, fine, but out of scope.

---

## First-launch state + optional auto-capture

**Default state: empty list.** No seed presets.

Why not seed:

- Unlike gradient history (5 starter gradients were seeded because the
  carousel looks broken when empty and users need inspiration), the
  preset list is an explicit user action. An empty state with a helpful
  hint message is the right signal: "you haven't saved anything yet".
- The built-in gradient carousel ALREADY gives users a curated starting
  palette. Duplicating that as "Stock / Night / Paper" presets is noise.
- Seeded full-state presets would need to define sane values for all 8
  colors, font, border — a lot of opinion to bake in. Better zero than
  wrong.

**Optional: auto-capture current config on first Release 5 launch.**

Proposed, flagged for Olivier's sign-off:

- If, on first launch after Release 5 install, `ThemeStore.isEnabled == true`
  AND the user has configured at least one non-default field (any color,
  font, gradient, border), automatically save a preset named
  **"My Theme (auto-saved)"** to the list.
- A one-shot `UserDefaults` flag prevents re-saving on subsequent launches.
- Purpose: give upgrading users a safety net. They experiment with the
  new preset feature, save a "Sunset", load it, realise they preferred
  their old setup, tap the auto-saved entry to revert.

**Default call: DO this auto-capture.** Cheap, high-value, reversible (user
can delete it). If Olivier wants to skip, flip the flag off in the
implementer brief and the first-launch state is simply empty.

---

## QA acceptance criteria

Numbered so the QA agent can check each off.

### Save

1. **Save with name.** From a clean `CustomThemeRootView`, modify light
   background to red, dark tint to purple, font to Helvetica, border to
   3pt. Tap **Save Current as Preset**, type "Red Theme", Save.
   A new row appears in the Presets list with name "Red Theme", a light
   swatch showing red, and a dark swatch showing the current dark bg.
2. **Save without name (auto-label).** Modify any single color. Tap Save,
   leave the name field empty, Save. New row appears labelled "Preset 1"
   (or next integer if others exist).
3. **Save multiple unnamed.** Save three configs without names. List
   shows "Preset 1", "Preset 2", "Preset 3" in newest-first order.
4. **Save captures every field.** Save a preset with a distinctive value
   in each slot (all 8 colors unique, font custom, border 5pt magenta,
   both gradients set). Reset to Defaults. Load the preset. Every field
   matches pre-reset state. Explicit checks required on: light bg, light
   heading, light body, light tint, light gradient, dark bg, dark heading,
   dark body, dark tint, dark gradient, font family, border width, border
   color.

### Load — full

5. **Load full preset from root.** Modify current state to something
   distinctive ("current state"). Save as "Baseline". Modify again to
   something different. Load "Baseline" from the root Load Preset flow.
   Every field reverts to Baseline.
6. **Load applies once, not per-field flicker.** Watch the screen during
   Load; the UI transitions once, not 13 times. (Subjective; QA notes
   any perceptible flicker.)
7. **Load preset when theme disabled.** Disable custom theme. Load a
   preset. Preset values are written to ThemeStore but the app shows
   stock appearance. Re-enabling reveals the preset's configuration.

### Load — mode slice

8. **Load light slice.** Save preset "A" with yellow light bg and green
   dark bg. Modify to orange light / blue dark. From Light Mode screen,
   tap Load From Preset, choose "A". Light bg becomes yellow; dark bg
   stays blue (not green); font/border unchanged.
9. **Load dark slice (mirror).** Same setup, from Dark Mode screen.
   Dark bg becomes green; light bg stays orange.
10. **Slice does not touch globals.** Save preset with font Helvetica.
    Change font to Courier. Load light slice from that preset. Font
    remains Courier (globals untouched).

### Rename / delete

11. **Rename via context menu.** Long-press a preset row, choose
    Rename, enter new name, save. Row label updates immediately.
12. **Rename to empty reverts to auto-label.** Rename a named preset to
    empty string. Row now shows its auto-label (stable integer).
13. **Duplicate names allowed.** Rename two presets to the same name;
    both save without error.
14. **Delete via swipe.** Swipe a row trailing, confirm Delete. Row
    removed.
15. **Delete via context menu.** Long-press, Delete, confirm. Row
    removed.
16. **Deleted preset does not reappear on relaunch.** Delete, quit app
    via app switcher, relaunch, row is still gone.

### Auto-label behaviour

17. **Auto-label is stable after delete.** Save three unnamed presets
    (Preset 1, 2, 3). Delete Preset 2. The remaining rows still display
    "Preset 1" and "Preset 3" (not "Preset 1" and "Preset 2").
18. **New auto-label bumps max.** After (17), save a new unnamed preset.
    It becomes "Preset 4".

### Persistence + migration

19. **Presets survive relaunch.** Save two presets. Kill app. Relaunch.
    Both are still there.
20. **Presets survive Reset to Defaults.** Save a preset. Tap Reset to
    Defaults. Preset list is NOT cleared (see Risks — Olivier may want
    to revisit this).
21. **Auto-capture on first Release 5 launch** (if implemented). Install
    Release 5 over a Release 4 build where theme was enabled with custom
    colors. On first launch, the list contains one entry named
    "My Theme (auto-saved)". On second launch, no new auto-capture
    happens.
22. **Empty-state message.** Brand-new install, open Load Preset. Shows
    empty-state hint text, no rows.

### Picker UX

23. **Swatches render.** Both light and dark swatches render a visible
    color; gradient-having presets show the gradient preview.
24. **Newest-first sort.** Save A, then B, then C. Picker shows C, B, A
    in that order.
25. **Tap-to-apply pops back.** Tapping a row applies and pops back to
    the previous screen (root or mode detail depending on scope).

---

## Risks + open questions

### Material (needs Olivier's call)

1. **Scope interpretation.** Full-state vs mode-scoped. This review picks
   full-state with partial-apply affordances. If Olivier reads the spec
   as mode-scoped, rework needed. **Please confirm before implementer
   starts.**
2. **Reset to Defaults — does it clear presets?** Current `ThemeStore.resetToDefaults()`
   clears color state but preserves gradient history (see lines 369-390).
   Analogous call: Reset should preserve the preset list too — users
   curate presets, and losing the whole library from a Reset tap would
   be punishing. This review recommends: **Reset clears active state
   only; presets AND gradient history are preserved**. Olivier to confirm
   or override.
3. **Auto-capture on Release 5 first launch.** This review recommends
   doing it (safety net for users upgrading from Release 4). Olivier
   to confirm or veto.

### Non-material (best-judgement calls made)

- **Unbounded preset count.** Spec says no hard limit. Adding a soft
  cap (e.g., 50) to avoid `UserDefaults` bloat would be premature —
  the JSON is small and a user with 50 themes is deeply engaged. If it
  becomes an issue, add `StylingPreset.softCap` later with a trim-by-
  oldest rule, like `ThemeGradient.historySoftCap`.
- **Naming conflict strategy.** Duplicates allowed. Simpler and matches
  iOS precedent (playlists, folders, Photos albums all allow duplicates).
- **Undo after delete.** Not included. Matches `PlaylistFolderStore`
  behaviour; can be added in a later PR if users complain.
- **Import / export JSON.** Out of scope. Tempting for sharing themes
  between friends — a future PR.
- **Preset thumbnails as live screenshots.** Out of scope. Swatches are
  cheap and sufficient.
- **Sort order.** Newest-first at store level; no UI toggle to re-sort.
  A user with strong opinions can rename in a way that encodes sort
  intent. A sort picker is overkill for Release 5.
- **Accessibility audit.** Alert + TextField + swipe actions are all
  standard UIKit/SwiftUI affordances with built-in VoiceOver support.
  QA should spot-check but no custom a11y work required.

### Implementer notes (not questions, just flags)

- Reuse `ThemeStore.postChangeNotification()` + `applyCustomThemeAndReload()`
  pattern that `CustomThemeRootView` and `ModeDetailView` already use.
  Fire ONCE at end of load, not per field, or UIKit will re-render 13
  times.
- `ThemeGradient.reducedToTwoStops()` should be applied on decode of
  stored preset gradients (same as `ThemeStore.activeGradient(for:)`
  does). Keeps presets consistent with the 2-stop world even if a beta
  tester had a pre-PR-20 install and somehow saved a 3-stop preset.
- `StylingPresetStore` should fire its own `didChangeNotification` when
  the list mutates — the picker view listens and refreshes rather than
  reloading from defaults on every appear.
- Keep auto-label index computation in one place (`autoLabel(for:index:)`)
  to avoid divergence between save-time and display-time logic.

---

## One-screen summary for the implementer

- One preset = one full theme snapshot. JSON blob in UserDefaults.
- New `StylingPresetStore` + `StylingPreset` / `StylingPresetConfig` /
  `ModeSlice` Codable structs.
- UI: Presets section at bottom of `CustomThemeRootView` (Save + Load
  Full). Load Preset section at bottom of each `ModeDetailView` (Load
  Slice only).
- New `PresetPickerView(scope:)` — list of rows with swatches, newest-
  first, tap-to-apply, swipe/context menu for rename + delete.
- Auto-label "Preset N" stable post-save.
- Empty by default; optional auto-capture on Release 5 first launch
  (pending Olivier confirmation).
- Reset to Defaults preserves presets (pending Olivier confirmation).
- 25 QA acceptance checks listed above.
