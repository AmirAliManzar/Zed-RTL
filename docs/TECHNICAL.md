# How the fix works (technical)

The bug is entirely inside Zed's Windows text-shaping code:
`crates/gpui_windows/src/direct_write.rs` — the DirectWrite text renderer
(`IDWriteTextRenderer` implementation).

Everything else (macOS CoreText path, the editor's buffer, etc.) is fine.

## The two problems

### 1. Glyphs inside an RTL run come back in logical order

When DirectWrite calls `DrawGlyphRun` for a run with an odd `bidiLevel`
(RTL), the glyph array is returned in **logical** (typing) order — e.g.
`سلام` arrives as glyphs `س ل ا م`. The original Zed code assigned each
glyph an increasing x as it arrived, so the word was drawn **mirrored**
(letters disconnected/backwards for RTL readers).

**Fix:** collect glyph data into a temporary `Vec<TempGlyph>` that also
stores each glyph's source index, `advance`, and offsets. After collecting,
if the run is RTL (`(bidiLevel & 1) == 1`), sort by **descending source
index** — this is the correct visual (left-to-right) order for a
right-to-left run — and only then assign positions. The `advanceOffset`
is negated for RTL runs because, after reversal, offsets that were along
the leftward advance direction must flip.

A stable `sort_by_key(Reverse(index))` also preserves intra-cluster order
(combining marks stay attached to their base glyph), which plain
`Vec::reverse()` would break.

### 2. Runs themselves are laid out in logical order (Unicode L2)

DirectWrite hands each *run* to `DrawGlyphRun` in **logical order** as well:
for `سلام خوبی؟` you get `[سلام][space][خوبی؟]`. Laying them out
left-to-right in that order means a Persian reader (reading right-to-left)
sees `خوبی؟ سلام` — words in the wrong order.

**Fix:** during shaping we now record, per run,
`run_meta: Vec<(bidi_level, start_x, end_x)>`. After the whole line is
shaped, if **any** run has an odd bidi level, we implement **Unicode
Bidirectional Algorithm rule L2**:

```
for level in (min_odd ..= max_level).rev():
    reverse every contiguous sequence of runs with level >= level
```

then recompute the runs' x positions left-to-right along the new visual
order (each glyph is shifted by `new_run_start - old_run_start`).

Properties:
- **Pure LTR lines** contain no odd level → the block is skipped entirely
  → **zero behavior change** for English/normal code.
- **Pure RTL lines** → the whole run sequence is reversed → reads correctly.
- **Mixed lines** (`hello سلام`, or Persian with embedded English) → only
  the RTL segments reverse, embedded LTR content stays in order, nesting
  handled by the descending-level loop.

This matches what CoreText gives Zed on macOS (runs in visual order with
absolute positions), so the rest of Zed's layout/hit-testing code sees the
shape it was written for.

### 3. Caret position and hit-testing broke for RTL runs

`LineLayout` (in `crates/gpui/src/text_system/line_layout.rs`) answers three
questions the editor needs for the caret and mouse: `x_for_index` (where to
draw the caret), `index_for_x` / `closest_index_for_x` (which character was
clicked / which boundary is nearest). All three assumed glyphs are stored in
**logical** order (ascending source index, ascending x). Fixes 1 and 2 store
RTL runs in **visual** order, so for RTL text the caret stopped moving
correctly and clicks landed one character off.

**Fix:** `LineLayout` now builds an explicit list of *caret stops* — for every
character boundary in the line, the x coordinate where the caret belongs:

- Runs are stored in visual order and tile the line; each run's *logical*
  span `[start, end)` is derived from the other runs' start indices (no
  source text needed).
- RTL runs are recognized via a new `ShapedRun::is_rtl` field, which the
  Windows shaper sets from DirectWrite's own `bidiLevel`. This is exact even
  for a **single-glyph RTL run** (one Persian letter between English words),
  which has no index descent to infer the direction from.
- Glyphs that share a source index (a base character + its combining marks,
  or a ligature) are grouped into one **cluster**, and the cluster's left
  edge is the caret boundary. The caret never stops between a base and its
  marks — matching VS Code.
- For an LTR run, a cluster's left edge is the caret position *before* its
  character; for an RTL run it is the caret *after* its character.
- The two *outer* stops of a run (before its first character, after its
  last) depend on context: an RTL run that starts the line has its
  "before-first-character" caret at the run's **right** edge (RTL reading
  begins on the right), but when another run precedes it the caret sits at
  the run's **left** edge (the boundary with that run); symmetrically for
  the run's last character. This is what makes mixed lines like `aبb`
  behave like VS Code.
- When an LTR run and an RTL run share a boundary byte index, the LTR run's
  stop wins (it marks the true visual segment boundary).

`x_for_index`, `index_for_x`, `closest_index_for_x` and `font_id_for_index`
are rewritten on top of these stops. Code paths with **no RTL run** keep the
original O(n) early-return scan, so LTR-only lines are byte-for-byte
unchanged.

Unit tests (`text_system::line_layout::tests`) cover pure-LTR, pure-RTL,
LTR-then-RTL, RTL-then-LTR, a single-glyph RTL run embedded in LTR text, a
lone RTL character, and an RTL run carrying a combining mark.

## Scope / safety

- The core fix is in `direct_write.rs` (rendering fixes 1 & 2) and
  `crates/gpui/src/text_system/line_layout.rs` (caret fix 3).
- Fix 3 adds one field, `ShapedRun::is_rtl: bool`, so the patch also touches
  the other places that construct a `ShapedRun` (the editor's run-splitting
  code and the macOS/Linux/Web/test shapers), setting it to `false` there.
  Windows behaviour is unchanged on those paths (they already produce
  logical-order runs); the field only carries the direction the Windows
  shaper already knew.
- The L2 path is guarded; LTR-only inputs never enter it.

## Files

- `patch/zed-rtl.patch` — the whole fix, `git diff` against upstream at the
  pinned commit (`UPSTREAM_REF`):
  `crates/gpui_windows/src/direct_write.rs` (rendering fixes 1 & 2),
  `crates/gpui/src/text_system/line_layout.rs` (caret fix 3), plus the
  `is_rtl` field additions in `crates/gpui/src/platform.rs`,
  `crates/gpui/src/text_system/line.rs`, `crates/gpui_macos`,
  `crates/gpui_wgpu` and `crates/gpui_web`.
- `patch/direct_write.rs` — human-readable reference copy of the patched
  Windows shaper (not used by CI).
