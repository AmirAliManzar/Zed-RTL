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

## Scope / safety

- The patch touches **only** `direct_write.rs` (+ the `run_meta` field on
  the internal `RendererContext`).
- No changes to any other crate, no settings, no UI.
- The L2 path is guarded; LTR-only inputs never enter it.

## Files

- `patch/zed-rtl.patch` — the whole fix, `git diff` against upstream at the
  pinned commit (`UPSTREAM_REF`).
- `patch/direct_write.rs` — human-readable reference copy of the patched
  file (not used by CI).
