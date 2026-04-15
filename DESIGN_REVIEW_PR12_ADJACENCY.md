# Design Review: PR 12 — Track Adjacency Engine

**Reviewer:** Designer Agent
**Date:** 2026-04-12
**Status:** Pre-implementation review
**Inputs:** BACKLOG.md PR 12 spec, PlaylistItemMO data model, Playlist entity wrapper, Olivier's scoring weights

---

## 1. Scoring Weight Analysis

### 1.1 The proposed weights

| Signal | Weight | Per-context |
|--------|--------|-------------|
| Same playlist co-membership | 0.5 | Per playlist |
| Same album co-membership | 1.5 | Per album (once) |
| Adjacent ±1 in playlist | 3.0 | Per playlist (additive with co-membership) |
| Adjacent ±2 in playlist | 2.0 | Per playlist (additive with co-membership) |

### 1.2 Worked examples with realistic data

**Scenario A: Two tracks adjacent in 3 playlists, same album.**
Score = 3 x (0.5 + 3.0) + 1.5 = **12.0**

**Scenario B: Two tracks in the same playlist but 10 positions apart, same album.**
Score = 1 x 0.5 + 1.5 = **2.0**

**Scenario C: Two tracks in the same playlist but 10 positions apart, different albums.**
Score = 1 x 0.5 = **0.5**

**Scenario D: Two tracks in 8 different playlists but never adjacent, no shared album.**
Score = 8 x 0.5 = **4.0**

**Scenario E: Two tracks adjacent in 1 playlist, no shared album.**
Score = 1 x 3.5 = **3.5**

### 1.3 Assessment

The weights produce the right **ordering** in nearly all cases:

- A (12.0) >> D (4.0) — repeated adjacency + album crushes mere co-occurrence. Correct.
- E (3.5) > D (4.0) — a single adjacency is slightly outweighed by 8 co-memberships. This is **borderline but acceptable**. A track that's been deliberately placed next to another one is a strong signal, but a track that appears in 8 of the same playlists is genuinely related too. The ordering here is defensible either way.
- B (2.0) < E (3.5) — same-album distant pair is weaker than cross-album adjacent pair. Correct — adjacency captures curatorial intent that mere album membership doesn't.

**Recommendation: The weights are sound. Ship as proposed.** The 6:1 ratio of ±1 adjacency (3.0) to co-membership (0.5) correctly reflects that placement is a much stronger signal than mere co-occurrence. The album bonus (1.5) is right — it's meaningful but doesn't dominate.

One nuance to watch: the album bonus is applied **once** per album, while playlist co-membership is applied **per playlist**. This means for a track pair that shares an album AND appears in 10 playlists, the album signal (1.5) is dwarfed by the playlist signal (10 x 0.5 = 5.0). This is correct — we don't want album membership to overshadow playlist curation.

### 1.4 Ratio check: ±1 vs ±2

The current ratio is 3.0 / 2.0 = 1.5x. This means being one position closer is 50% more valuable. For a curated playlist, the immediate neighbor is indeed more intentional than the one-removed neighbor (which could simply be a transitional track). The 1.5x ratio is moderate and appropriate. A sharper drop-off (e.g., 3.0 / 1.0 = 3x) would under-weight ±2 neighbors, which are still very relevant in playlist curation.

---

## 2. Decay Factor for Long Playlists

### 2.1 The question

Should a 200-track "All My Music" dump playlist contribute the same co-membership weight as a carefully curated 20-track mood playlist?

### 2.2 Analysis

**The problem with no decay:** A 200-track playlist generates C(200,2) = 19,900 co-membership pairs, each scoring 0.5. In a library with 50 playlists where most are 20-30 tracks, one 200-track mega-playlist would generate more co-membership pairs than all other playlists combined. This dilutes the signal — two tracks sharing a 200-track dump playlist are NOT as meaningfully related as two tracks sharing a 15-track vibe playlist.

**However, adjacency is already naturally resistant.** The ±1 and ±2 bonuses only affect 4 neighbors per track regardless of playlist length. A 200-track playlist generates the same number of adjacency pairs per track as a 20-track playlist. The adjacency signal is already "local" by definition.

The decay concern is specifically about **co-membership** dilution.

### 2.3 Recommendation: Apply a playlist-length normalization to co-membership only

Scale the co-membership weight by `1 / log2(playlistLength)`:

| Playlist length | Raw co-membership | Normalized co-membership |
|-----------------|-------------------|--------------------------|
| 10 tracks | 0.5 | 0.5 / log2(10) = **0.15** |
| 20 tracks | 0.5 | 0.5 / log2(20) = **0.12** |
| 50 tracks | 0.5 | 0.5 / log2(50) = **0.09** |
| 200 tracks | 0.5 | 0.5 / log2(200) = **0.065** |

Wait — this actually penalizes the sweet-spot playlists (10-30 tracks) too much. Let me reconsider.

**Revised recommendation: Simple length cap, not a continuous decay.**

Apply a **threshold**: playlists longer than 100 tracks get their co-membership weight halved (0.25 instead of 0.5). Playlists of 100 tracks or fewer use the full 0.5.

Rationale:
- Most curated playlists are 15-60 tracks. These should get full weight.
- Playlists over 100 tracks are typically dumps, compilations, or "liked songs" collections where co-membership is a weaker signal.
- A binary threshold is simpler to implement and reason about than a continuous function.
- The adjacency weights (±1, ±2) are NOT reduced — position-based proximity is meaningful regardless of playlist length.

**If the implementer prefers simplicity:** Skip the decay entirely for Phase 1. The adjacency weights already dominate the scoring (3.0/2.0 vs 0.5), so co-membership dilution from long playlists won't dramatically affect the top-N results. The threshold can be added in a follow-up if real-world results show dump playlists are polluting the scores. **I lean toward shipping without decay and iterating.**

---

## 3. "Continue the Vibe" — Full Similarity vs Adjacency-Only

### 3.1 The question

When auto-queuing tracks after a playlist ends, should the algorithm use the full similarity score (co-membership + adjacency + album) or only the adjacency component (±1 and ±2 scores)?

### 3.2 Analysis

**Case for adjacency-only:**
- The use case is "continue the mood." Adjacency captures sequential mood flow — the tracks a curator placed before/after the seed tracks.
- Co-membership adds noise: two tracks can share a playlist because they're by the same artist, not because they sound similar.
- Album membership adds noise: an album's tracks are related by artist, but adjacent tracks in track-list order often aren't mood-related (e.g., an upbeat track followed by a ballad).

**Case for full similarity:**
- The spec correctly notes that adjacency naturally dominates because the seed tracks are the last 3-5 played — their ±1/±2 neighbors in other playlists produce the highest individual scores.
- Co-membership provides useful fallback: if a seed track only appears in 1 playlist, adjacency alone yields few candidates. Co-membership broadens the pool.
- Album membership is a genuine signal for "more of this artist/album" which users often want when a playlist ends.

### 3.3 Recommendation: Full similarity, but with adjacency-weighted ranking

Use the full score for candidate selection (wider pool), but **sort the results by adjacency score first, then by full score as tiebreaker**. This prioritizes tracks that were sequentially placed near the seed tracks in other playlists, while still falling back to co-membership/album signals when adjacency data is sparse.

**Concretely:**

```
candidates = allTracksWithScore(relativeTo: seedTracks)
    .filter { !alreadyPlayed.contains($0) }
    .sorted {
        // Primary: adjacency-only score (±1 + ±2 components)
        // Secondary: full score (adjacency + co-membership + album)
        ($0.adjacencyScore, $0.fullScore) > ($1.adjacencyScore, $1.fullScore)
    }
    .prefix(queueSize)
```

This requires the `TrackAdjacencyStore` to store adjacency and co-membership scores separately (or at least be able to decompose them). This is a Phase 1 data model consideration.

**Data model implication for Phase 1:** Instead of storing a single `Float` per `SongPair`, store a struct:

```swift
struct SimilarityScore {
    var adjacency: Float  // sum of ±1 and ±2 bonuses across all playlists
    var coMembership: Float  // sum of co-membership weights across all playlists
    var album: Float  // 1.5 if same album, 0 otherwise
    var total: Float { adjacency + coMembership + album }
}
```

This adds negligible memory overhead (3 floats vs 1) and keeps the door open for Phase 4's ranking strategy without rework. **Strongly recommend including this in Phase 1.**

---

## 4. Phase 2 UI — "More Like This"

### 4.1 Where it should live

**Primary surface: Context menu action** — "Related Tracks" in the song's `...` menu, pushing a dedicated list view.

**Rationale:**
- The song detail view (now playing screen) is already dense with controls, lyrics, and metadata. Adding a section there risks overwhelming the primary playback UI.
- A context menu action is discoverable (it's where all song actions live) and non-intrusive.
- Apple Music's "Create Station" and Spotify's "Go to Song Radio" both live in the context menu, not inline.

**Secondary surface (nice-to-have):** A "Related" section at the bottom of the Now Playing screen, below lyrics. This would show 3-5 tracks with artwork thumbnails. Tapping one queues it next. This is Phase 2 stretch — ship the context menu first.

### 4.2 "Related Tracks" view spec

```
┌──────────────────────────────────────────┐
│  ← Related Tracks                        │
│                                          │
│  Based on your playlist curation         │  ← subtitle explaining the source
├──────────────────────────────────────────┤
│  🎵 Track A — Artist                     │
│     In 4 playlists near "Seed Track"     │  ← source info
│                                          │
│  🎵 Track B — Artist                     │
│     In 3 playlists near "Seed Track"     │
│     Same album                           │  ← album badge when applicable
│                                          │
│  🎵 Track C — Artist                     │
│     In 2 playlists with "Seed Track"     │  ← co-membership only (no adjacency)
│  ...                                     │
└──────────────────────────────────────────┘
```

**Design details:**
- Show top 20 related tracks, sorted by full similarity score.
- Each row shows: track title, artist name, and a human-readable source line.
- Source line phrasing:
  - If adjacency score > 0: "In N playlists near '[seed]'" (N = number of playlists where they're ±1/±2)
  - If only co-membership: "In N playlists with '[seed]'"
  - If same album: append "Same album" badge
- Long-press a row → standard song context menu (play, queue, add to playlist, etc.)
- Tapping a row → plays the track and queues the rest of the related list after it.

**Empty state:** "Not enough playlist data to find related tracks. Add this song to more playlists to improve suggestions." — This is critical because a track that only appears in 1 playlist or 0 playlists will have no meaningful adjacency data.

### 4.3 Minimum data threshold

Only show "Related Tracks" in the context menu when the track has at least 1 scored pair with `total >= 2.0`. This prevents showing weak/meaningless results for tracks with no playlist history. The threshold means the track must either:
- Be adjacent to something in at least 1 playlist (3.5 >= 2.0), or
- Share an album with something (1.5 — just below threshold, so album-only isn't enough), or
- Be in 4+ playlists with something (4 x 0.5 = 2.0)

This feels right — you need real curation data before the feature adds value.

---

## 5. Edge Cases

### 5.1 Single-song playlists

A playlist with 1 track generates zero co-membership pairs and zero adjacency pairs. It contributes nothing to the model. **No special handling needed** — the iteration loop `for each pair within ±2 window` naturally produces nothing.

### 5.2 Two-song playlists

Two tracks in a 2-track playlist are ±1 adjacent. Score: 0.5 (co-membership) + 3.0 (adjacency) = 3.5. This is a strong signal, which is correct — a 2-track playlist is an extremely intentional curation.

### 5.3 Duplicate tracks within a playlist

Navidrome allows adding the same track multiple times to a playlist. If Track A appears at positions 3 and 15 in the same playlist:
- Position 3 generates adjacency pairs with positions 1, 2, 4, 5.
- Position 15 generates adjacency pairs with positions 13, 14, 16, 17.
- Track A has TWO co-membership entries with every other track in the playlist.

**Recommendation:** Deduplicate before scoring. When iterating a playlist's items, if a track ID appears multiple times, use only the **first occurrence**. This prevents inflated scores from repeated tracks. The deduplication is per-playlist — the same track appearing once in each of 5 playlists is fine (5 legitimate co-memberships).

**Implementation:** When building the ordered track list for a playlist, filter to unique song IDs while preserving order.

### 5.4 Albums with 1 track

A single-track album generates zero album co-membership pairs (no other tracks to pair with). **No special handling needed.**

### 5.5 Tracks with no playlist membership

Tracks that don't appear in any user playlist have zero adjacency/co-membership scores. They may still have album scores (paired with other tracks on the same album). "More Like This" for such a track would show only album-mates, which is low-value. The minimum data threshold in 4.3 handles this — "Related Tracks" won't appear for tracks with insufficient data.

### 5.6 Podcast episodes

The `PlaylistItemMO.playable` relationship points to `AbstractPlayableMO`, which includes podcast episodes. Playlists can technically contain podcast episodes (though this is unusual in Navidrome). **Recommendation:** Filter to songs only (`SongMO`) when building the adjacency model. Podcast episodes have different similarity semantics.

### 5.7 Smart playlists / auto-generated playlists

Navidrome generates auto-playlists (e.g., "Most Played", "Recently Added"). These playlists reflect algorithmic ordering, not curatorial intent. Including them inflates co-membership scores between tracks that happen to share listening patterns rather than mood similarity.

**Recommendation:** Exclude playlists that match the patterns filtered in the "In Playlists" feature (build 20 — empty names, auto-generated). Additionally, consider excluding playlists flagged as `isSmartPlaylist` in the data model. Only user-curated playlists should feed the model.

### 5.8 Memory footprint

For a library with ~50 playlists x ~30 tracks = ~1,500 total playlist items:
- Unique track pairs in a 30-track playlist: C(30,2) = 435 co-membership pairs.
- Across 50 playlists: up to 50 x 435 = 21,750 entries (with significant overlap).
- In practice, with ~5,000 unique songs, the maximum unique pairs is C(5000,2) = ~12.5M, but only pairs that actually share a playlist/album get entries.
- Realistic estimate: 10,000-50,000 unique scored pairs.
- At ~20 bytes per entry (two 8-byte IDs + one 4-byte float, or 12 bytes for the split struct), that's 200KB-1MB. Comfortable for in-memory storage.

**No memory concern for Olivier's library scale.** For much larger libraries (1000+ playlists), the JSON persistence becomes important to avoid recompute.

### 5.9 Computation time

Per playlist: iterate N items, for each compute ±2 window pairs = ~4N operations. Across 50 playlists: 50 x 4 x 30 = 6,000 dictionary inserts. Plus album co-membership: iterate all albums, for each compute pairwise = C(albumSize, 2). For 500 albums averaging 10 tracks: 500 x 45 = 22,500.

Total: ~28,500 dictionary operations. On modern iOS hardware, this completes in <100ms. **Safe to run on main thread at launch**, though a background queue is cleaner.

---

## 6. QA Acceptance Criteria — Phase 1

Phase 1 is the scoring model only (`TrackAdjacencyStore`). No UI. Tests are the primary validation.

### Unit tests (`TrackAdjacencyScoreTest`)

| # | Test | Pass condition |
|---|------|---------------|
| 1 | Two tracks at ±1 in a single playlist | Score = 3.5 (0.5 co-membership + 3.0 adjacency) |
| 2 | Two tracks at ±2 in a single playlist | Score = 2.5 (0.5 co-membership + 2.0 adjacency) |
| 3 | Two tracks in same playlist, distance > 2 | Score = 0.5 (co-membership only) |
| 4 | Two tracks in same album, no shared playlist | Score = 1.5 (album bonus only) |
| 5 | Two tracks at ±1 in playlist AND same album | Score = 3.5 + 1.5 = 5.0 |
| 6 | Two tracks at ±1 in 3 playlists, same album | Score = 3 x 3.5 + 1.5 = 12.0 |
| 7 | Symmetry: score(A, B) == score(B, A) | Scores are identical regardless of query order |
| 8 | Two tracks with no shared context | Score = 0.0 (or nil / not present in dictionary) |
| 9 | Single-track playlist | Generates zero pairs. No crash. |
| 10 | Duplicate track in same playlist | Only first occurrence is scored. No double-counting. |
| 11 | Smart playlists excluded | Tracks in `isSmartPlaylist` playlists contribute zero to scores. |

### Integration behavior

| # | Test | Pass condition |
|---|------|---------------|
| 12 | Compute on empty library | Store initializes with zero pairs. No crash. |
| 13 | Compute on library with 1 playlist (10 tracks) | Produces expected pair count: 10 x 4 adjacency pairs + C(10,2) = 45 co-membership pairs (many overlapping). Verify total unique pair count is correct. |
| 14 | Album bonus counted once per album | Two tracks sharing an album AND appearing in 5 playlists: album bonus = 1.5 (not 5 x 1.5). |
| 15 | Score decomposition | `SimilarityScore.adjacency`, `.coMembership`, and `.album` are stored separately and sum to `.total`. |
| 16 | Top-N query | `topRelated(for: trackId, limit: 10)` returns the 10 highest-scoring pairs, sorted descending. |
| 17 | Invalidation on playlist change | After a playlist is modified (track added/removed), the store is flagged as stale. Recompute produces updated scores. |
| 18 | JSON persistence round-trip | Store serializes to JSON, deserializes back, scores match. |

### Performance

| # | Test | Pass condition |
|---|------|---------------|
| 19 | Compute time for 50 playlists x 30 tracks | Completes in < 500ms on device (iPhone 12 or newer). |
| 20 | Memory footprint | Peak memory during computation < 5MB for the test dataset. |

---

## 7. Recommendations

### Phase 1 implementation recommendations

1. **Store decomposed scores from day 1.** Use a `SimilarityScore` struct with separate `adjacency`, `coMembership`, and `album` fields. This costs almost nothing now and prevents a rework for Phase 4's ranking strategy. See section 3.3.

2. **Exclude smart playlists.** Filter `isSmartPlaylist == true` playlists out before scoring. Auto-generated playlists don't reflect curatorial intent.

3. **Deduplicate tracks per playlist.** Use first-occurrence-only when a track appears multiple times in the same playlist. See section 5.3.

4. **Filter to songs only.** Exclude podcast episodes from the adjacency model. They have different semantics.

5. **Skip the decay factor for Phase 1.** Ship without playlist-length normalization. The adjacency weights already dominate. Add a length threshold later if dump playlists pollute real-world results.

6. **Background compute.** Although the math completes in <100ms for Olivier's library, run on a background queue and post a notification when ready. This is future-proofing for larger libraries and avoids any main-thread jank during launch.

7. **Expose a `hasData(for: trackId)` API.** Phase 2 needs this to decide whether to show "Related Tracks" in the context menu. Return `true` if any pair involving this track has `total >= 2.0`.

### Phase ordering recommendation

The spec's 1-2-3-4 ordering is correct. Phase 1 is pure foundation. Phase 2 ("More Like This") is the most visible payoff — it proves the model works and gives Olivier something to evaluate. Phase 3 (clustering) is analytically interesting but less user-visible. Phase 4 ("Continue the Vibe") is the highest-value feature but depends on getting the scoring right.

**Recommendation:** Ship Phase 1 + Phase 2 together in one PR. Phase 1 alone has no user-visible output, so shipping it in isolation means a TestFlight build with no way for Olivier to evaluate whether the model is producing good results. Bundling Phase 2 lets him browse "Related Tracks" and judge quality immediately.

### Items for Olivier's input

1. **Smart playlist exclusion.** The recommendation is to exclude them. Does Olivier have any user-curated playlists that Navidrome flags as "smart"? If so, we'd need a different filter.

2. **"Continue the Vibe" opt-in.** Phase 4 auto-queues tracks after a playlist ends. This should be an opt-in setting (OFF by default), not automatic. Some users want silence after a playlist finishes. **Recommend adding this to the spec.**

3. **Phase 2 result count.** The review suggests top 20 for "Related Tracks". Does Olivier want more, fewer, or a different number? 20 feels like a good "quick browse" size, but preferences vary.
