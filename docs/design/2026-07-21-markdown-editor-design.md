# Live-styled markdown editor — design spec

**Date:** 2026-07-21 · **Status:** proposed · **Scope:** the note editor that replaces
`NoteDetailView`'s plain `TextEditor` with a live-styled UITextView (Bear/Obsidian live-preview
style — style in place as you type, storage stays plain markdown, no raw/preview mode).

Ground truth files: `ios/Command/Support/Theme.swift` (palette + typeface),
`ios/Command/Features/Notes/NoteDetailView.swift` (the editor being replaced),
`ios/Command/Features/Agent/MarkdownView.swift` (the chat block renderer whose visual language
this extends from chat bubbles to a full page). Companion code:
`ios/Command/Features/Notes/MarkdownTheme.swift` (every value below, as attributes).

---

## 0. Principles

1. **A notebook, not a README.** The system serif (New York, via the `Typeface.display` recipe)
   carries structure; the sans carries content; burnt amber is the *only* accent. If a styling
   choice would look at home on github.com, it's wrong here.
2. **The screen tells the truth about the disk.** Storage is plain markdown and the user types
   markdown, so the literal syntax characters never disappear (see §2). Styling is a lens,
   not a lie — this matters doubly because **line 1 is the note's title by convention**, and a
   convention that important must always be legible as plain text underneath.
3. **Markers either elevate or fade.** A syntax character that survives into the rendered page
   as structure — a bullet, a number, a checkbox — *becomes* the glyph (elevated to accent).
   A character that exists only for the machine — `**`, backticks, `[…](…)`, `#` — fades to a
   dimmer ink so the styled content owns the line. There is no third treatment.
4. **Chat and editor speak one language.** Where `MarkdownView` already established a voice
   (accent list markers, italic secondary quotes with an amber bar, hairline-washed inline code,
   surface-washed code blocks), the editor keeps it, grown one step for a full-page canvas.

---

## 1. Type & color scale

Reference sizes are at the **default** Dynamic Type category; every font is
`UIFontMetrics(forTextStyle: .body)`-scaled exactly like `Typeface`, so the whole scale grows
proportionally (bounded by RootView's app-wide clamp). "Span" elements carry font+color only —
they layer over their line's block attributes and never fight the paragraph for indentation.

| Element | Font | Size | Weight / traits | Color token | Line sp. | Before / after | Decoration |
|---|---|---|---|---|---|---|---|
| **Title (line 1)** | display serif | 28 | semibold | `ink` | 2 | 0 / 10 | — |
| **H1** | display serif | 24 | semibold | `ink` | 2 | 14 / 6 | — |
| **H2** | display serif | 20 | semibold | `ink` | 2 | 12 / 4 | — |
| **H3** | display serif | 17 | semibold | `ink` | 2 | 10 / 3 | — |
| **Body** | body sans | 17 | regular | `ink` | 5 | 0 / 4 | — |
| **Bold** | body sans | 17 | bold | `ink` | span | span | — |
| **Italic** | body sans | 17 | italic trait | `ink` | span | span | — |
| **Bold-italic** | body sans | 17 | bold + italic | `ink` | span | span | — |
| **Inline `code`** | mono | 15 | regular | `ink` | span | span | `hairline` background wash (matches chat) |
| **Code block (fenced)** | mono | 15 | regular | `ink` | 3 | 0 / 0¹ | `surface` background, 12pt insets, rounded corners engine-drawn |
| **Code fence lines** | mono | 12 | regular | `syntax` (dimmed) | 3 | 10 / 0 open · 0 / 10 close¹ | `surface` background, same insets |
| **Blockquote** | body sans | 16 | italic trait | `inkSecondary` | 4 | 4 / 4 | 3pt `accent` bar in a 16pt gutter (engine-drawn) |
| **Bullet item text** | body sans | 17 | regular | `ink` | 5 | 0 / 2 | hanging indent 24pt per level (L1: 0→24, L2: 24→48, L3: 48→72) |
| **Bullet marker** (`-`/`*`/`+`) | body sans | 17 | regular | `accent` | span | span | the literal char *is* the bullet |
| **Ordered item text** | body sans | 17 | regular | `ink` | 5 | 0 / 2 | same hanging indents as bullets |
| **Ordered marker** (`1.`) | body sans | 17 | semibold | `accent` | span | span | matches chat's accent numbers |
| **Task box unchecked** (`- [ ]`) | body sans | 17 | regular | `accent` | span | span | an open loop, asking to be closed |
| **Task box checked** (`- [x]`) | body sans | 17 | regular | `sage` | span | span | sage = the palette's done state |
| **Task text, checked** | body sans | 17 | regular | `inkSecondary` | 5 | 0 / 2 | strikethrough — done work visibly retires |
| **Link title** | body sans | 17 | regular | `accent` | span | span | single underline, `accent` @ 50% |
| **Strikethrough** | body sans | 17 | regular | `inkSecondary` | span | span | single strike line |
| **Horizontal rule** (`---`) | body sans | 17 | regular | `ink` @ 16% | — | 6 / 6 | +4pt letterspacing stretches the dashes toward a pencil rule |
| **Table header cells** | body sans | 15 | semibold | `ink` | 4 | 8 / 0 | `accentSoft` wash |
| **Table body cells** | body sans | 15 | regular | `ink` | 4 | 0 / 0² | pipes dimmed as syntax |
| **Table separator row** (`|---|`) | body sans | 6 | regular | `syntax` | — | 0 / 8² | tiny font collapses the row into the divider under the header |

¹ Code lines carry **no** outer spacing; the two fence lines carry it (10pt above the opening
fence, 10pt below the closing one) so the code inside stays tightly packed while the block as a
whole still breathes against surrounding prose.
² Cell rows are packed; the separator row's 8pt after gives the table its bottom margin.

Notes on specific calls:

- **Title 28 vs H1 24.** The line-1 title must outrank any `#` typed in the body — the hierarchy
  never inverts, so the note's name is always visually findable at the top. 28 (not 34/large-title
  territory) because this is a page in a notebook, not a billboard.
- **H3 at body size (17)** is deliberate: at a personal note's depth, H3 differentiates by serif +
  semibold + spacing rather than raw size, the same move Bear/Obsidian make. H4–H6 clamp to H3 —
  deeper structure in a note is abuse, and clamping keeps the scale from collapsing into noise.
- **Body 17 / 5pt leading (≈1.3 line height).** Apple-Notes-comfortable, a touch airier for the
  paper feel. 4pt paragraph-after keeps consecutive hard-wrapped lines one visual block while
  lists of thoughts don't crowd.
- **Mono at 15**, a step under body: SF Mono's large x-height shouts at 17 next to prose.
- **Blockquote keeps the chat voice** (italic, `inkSecondary`) but at 16pt — composing in 15pt
  italic (chat's reading size) is tiring, and quotes in an editor are authored, not just read.
- **Tables at 15pt** keep columns narrow; header wash is `accentSoft` exactly like the chat table.
- **The rule keeps its dashes.** Rather than hiding `---` and drawing a rect, the literal dashes
  render faint and letterspaced — they read as a light pencil rule while staying honest, editable
  text. (The engine may *additionally* overlay a hairline rect; these attributes are the fallback.)

---

## 2. Syntax-marker treatment — the policy

**Decision: always-visible, dimmed — never hidden.** Machine-only syntax characters (`#`, `**`,
`*`, `~~`, backticks, `>`, link brackets/parens/URLs, table pipes) render at all times in
`inkSecondary` at **45% opacity**, inheriting the font of the content they delimit. On the
paragraph containing the caret (the *active line*), markers firm up to **75% opacity** so precise
edits have a crisp target. Structural markers (bullets, ordered numbers, task boxes) are exempt —
they elevate to accent/sage per §1, because they survive into the rendered page.

Mechanics: `MarkdownTheme.syntaxMarkerAttributes(base:activeLine:)` takes the range's block
attributes, swaps the color, and strips decorations a marker shouldn't wear (a `~~` shouldn't
strike itself). Fonts and indents are inherited unchanged, so applying/removing the dim **never
reflows the text** — same glyph advances, same line breaks, caret never jumps.

**Why not hide markers when the cursor leaves the line (Obsidian-style)?**
1. *Zero reflow.* Hiding characters changes line breaks; text shifts vertically as the caret
   moves; the tap you aimed at lands somewhere else. In a fast-capture notes app that jank is a
   daily tax. Dimming costs no layout.
2. *The convention demands honesty.* Line 1 is the title *because it's line 1* — a user who can't
   see the raw characters can't build a correct mental model of what's stored. Storage is plain
   markdown; the screen should keep proving it.
3. *Cost.* The active-line bump is a one-paragraph restyle on selection change — cheap enough to
   run in `textViewDidChangeSelection`. True hiding requires per-line layout surgery.

**Why not full-strength markers (GitHub-style)?** Because then the page reads as source code,
not a notebook — the exact SF-everywhere/README look this app exists to avoid.

---

## 3. Editor chrome — the formatting toolbar

All icons are SF Symbols available by iOS 16 (deployment target is 17): `checklist`,
`list.bullet`, `list.number`, `bold`, `italic`, `strikethrough`, `textformat.size`,
`quote.opening`, `chevron.left.forwardslash.chevron.right`, `link`,
`keyboard.chevron.compact.down`, `increase.indent`, `decrease.indent`, `tablecells`.

**Toggle state** (caret/selection already inside the style): icon tints `accent` on a 28pt
`accentSoft` rounded-rect. **Idle:** `inkSecondary` icon, no fill. **Pressed:** 28pt
`accentSoft` fill flashes under the icon.

### iPhone — keyboard accessory strip

Above the keyboard, height 44pt + safe area. Two zones:

- **Left: horizontally scrollable formatting strip.** Order (most-used first, visible without
  scrolling): `checklist` · `list.bullet` · `list.number` ｜ `bold` · `italic` · `strikethrough` ｜
  `textformat.size` (opens a menu: Body / Heading 1 / Heading 2 / Heading 3) · `quote.opening` ·
  `chevron.left.forwardslash.chevron.right` ｜ `link`. Items are 44×44pt hit targets, 17pt icons,
  0pt gaps inside a group, 12pt gaps at group boundaries (hairline separators at 40% height).
- **Right: pinned.** A full-height hairline divider, then `keyboard.chevron.compact.down` in
  `accent`, 44×44 — always one stationary thumb-tap away, never scrolled out of reach.

Scrolling (not a fixed 8-button row) because 10 items + dismiss at 44pt exceeds a 375pt SE
screen, and clipping the trailing buttons off-screen-by-design is worse than an honest strip.
Lists-first order matches what quick capture actually is in this app: tasks and bullets.

### iPad — accessory bar + hardware keyboard

Same item set and order, non-scrolling, centered as one group with 8pt inter-item gaps, 44×44
targets, 17pt icons. With a hardware keyboard attached the bar persists at the bottom of the
screen (shortcuts remain primary; the bar is for discoverability and toggle state). When the
caret is inside a list, `increase.indent` / `decrease.indent` appear at the trailing end of the
list group.

Keyboard shortcuts (also the Mac set): `⌘B` bold, `⌘I` italic, `⇧⌘X` strikethrough, `⌘K` link,
`⇧⌘L` checklist, `⇧⌘7` bullet, `⇧⌘9` numbered (Notes parity), `⌥⌘1/2/3` Heading 1–3,
`⌥⌘Q` quote, `⌥⌘C` inline code.

### Mac Catalyst — a real toolbar

A `ToolbarItemGroup` in the window toolbar (no keyboard accessory exists here). Order:
`textformat.size` menu ｜ `bold` · `italic` · `strikethrough` ｜ `checklist` · `list.bullet` ·
`list.number` · `increase.indent` · `decrease.indent` ｜ `quote.opening` ·
`chevron.left.forwardslash.chevron.right` · `link` ｜ `tablecells` (inserts a 3×3 table
skeleton). Pointer-scale controls: 28×28pt targets, 15pt icons, 6pt corner radius, 4pt gaps.

- **Hover:** `accentSoft` fill fades in (60ms). **Pressed:** `accent` at 20% fill.
- **Toggled:** `accent` glyph on `accentSoft` fill — same language as iOS, pointer-scaled.
- Narrow windows collapse trailing groups into the toolbar's native overflow menu.

### VoiceOver

Every button: `.isButton` trait, label from this table, toggled items add "selected" to the
value. Hints say what the insertion does, not what the icon looks like.

| Icon | Label | Hint |
|---|---|---|
| checklist | Task | Inserts or toggles a checkbox line |
| list.bullet | Bulleted list | Formats the line as a bullet |
| list.number | Numbered list | Formats the line as a numbered item |
| bold | Bold | Toggles bold on the selection |
| italic | Italic | Toggles italic on the selection |
| strikethrough | Strikethrough | Toggles strikethrough on the selection |
| textformat.size | Heading | Opens heading level options |
| quote.opening | Quote | Formats the line as a block quote |
| code | Code | Toggles inline code on the selection |
| link | Insert link | Adds a link to the selection |
| increase.indent / decrease.indent | Indent / Outdent | Changes the list nesting level |
| tablecells | Insert table | Adds a three-by-three table |
| keyboard.chevron.compact.down | Dismiss keyboard | — |

---

## 4. Measurements

**Measure (max line width).** Text column caps at **640pt** — ≈68–72 characters of 17pt prose,
the comfortable reading measure. Below `640 + 2×28` the margins govern; above it the column
pins at 640 and **centers** on the paper (background is `paper` edge-to-edge; no page card —
the app stays flat notebook, not a skeuomorphic sheet). Implementation: `textContainerInset`
sides = `max(28, (editorWidth − 640) / 2)`, `lineFragmentPadding = 0` so the margins are exact.

| Form factor | Sides | Top | Bottom |
|---|---|---|---|
| iPhone | 20 | 12 | 48 (clears the accessory bar) |
| iPad / Mac, window ≤ 696pt | 28 | 16 | 48 |
| iPad / Mac, wider | `(width − 640) / 2` | 16 | 48 |

**Caret & selection.** `tintColor = accent`: the system 2pt caret renders burnt amber and the
selection highlight is the system's tint-at-~20% derived from it. Find-in-note highlights (if
added later) use `accentSoft` (12%) so search matches never masquerade as a selection.

**Indents** (from `MarkdownTheme.Metrics`): list level step 24; code inset 12; quote gutter 16
with a 3pt bar; these are the only horizontal offsets in the system.

---

## 5. Dark mode, Dynamic Type, accessibility

**Dark mode.** Every color is a trait-resolving `UIColor` mirroring Palette's sRGB triples
(light and dark variants both specified in `MarkdownTheme` — never `UIColor(Palette.x)`, which
freezes one variant). The palette was designed dark-first alongside light: ink/paper stays
≈12:1, the amber accent *brightens* in dark (to ≈6:1 on espresso paper), the code wash flips to
raised dark surface, and the hairline inline-code wash inverts (white @ 9%). No element is
specified in light-only values anywhere in this doc.

**Computed contrasts** (from the sRGB triples, WCAG formula, rounded):

| Pair | Light | Dark | Verdict |
|---|---|---|---|
| `ink` on `paper` | ≈14:1 | ≈12:1 | AAA |
| `inkSecondary` on `paper` | ≈5.4:1 | ≈5.3:1 | AA for body text |
| `accent` on `paper` | ≈4.3:1 | ≈6:1 | AA for large text/icons; links also underlined so they never rely on color alone |
| Dimmed syntax (45% `inkSecondary`) | ≈2.5:1 | ≈2.6:1 | Below AA by design — decorative affordance over literal characters; the *content* they delimit is full-contrast, and VoiceOver reads the characters verbatim |

**Dynamic Type.** All fonts `UIFontMetrics`-scaled like `Typeface`; the hierarchy scales
proportionally so it can't invert at large sizes, and RootView's app-wide `.dynamicTypeSize`
clamp bounds the accessibility extremes. Because an attributed string caches concrete font
instances, the engine re-applies `MarkdownTheme` attributes on content-size-category change
(`adjustsFontForContentSizeCategory` does not reach inside an existing text storage). Mono
scales too — code is content for accessibility purposes. Paragraph spacing values are points,
not ratios; at very large type they read proportionally tighter, which is acceptable (the
alternative — scaling spacing — explodes vertical space on long notes).

**Accessibility beyond contrast.** Toolbar labels/hints per §3. The dimmed syntax needs no
VoiceOver accommodation — it's the same literal characters VO already reads. Links should carry
a real `.link` attribute (with the destination URL) in the engine, so VO announces "link" and
rotor navigation works; `UITextView.linkTextAttributes` stays on-palette. Task lists are the
one place styling implies state — the literal `[ ]`/`[x]` is in the text, so VO users get
"left bracket x right bracket" verbatim; acceptable now, candidate for a custom rotor later.

---

## 6. Engine handoff — what attributes do vs what the engine draws

`MarkdownTheme.swift` is the complete attribute vocabulary. Three visuals are **decoration
passes** (TextKit layout manager / drawn views), not attributes, and are explicitly optional —
the design degrades gracefully without them:

1. **Blockquote bar:** 3pt `accent` rounded rect in the 16pt gutter, spanning the quote's line
   fragment rects.
2. **Code block rounding:** 10pt-radius `surface` fill behind the block's union rect (the
   per-line `surface` background in the attributes already gives the unrounded version).
3. **Table grid:** hairline column separators if desired; the header wash is already an
   attribute.

Restyle triggers the engine owes: text change (current paragraph + neighbors), selection change
(active-line marker bump only), trait change (full restyle for Dynamic Type / dark mode).
Everything else — auto-save, navbar attachments, save status, hidden-note veil — is the existing
`NoteDetailView` machinery and is untouched by this spec. The hidden-note reader deliberately
stays plain `body(17)` text under the veil; rendering hidden notes as rich markdown is a
separate decision, not bundled here.
