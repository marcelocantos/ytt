<!--
  SINGLE SOURCE OF TRUTH for the YouTube-synopsis output format.

  Three parties depend on this file; none of them may restate the format
  in their own words:
    - ingest-one.sh  reads this file at runtime and appends it to the
                     `claude -p` synopsis prompt (the scheduled path).
    - the /ytt skill instructs the interactive agent to read this file
                     before composing a synopsis (the manual path).
    - `ytt build-index` (index.go) parses the artifacts this format
                     produces; its expectations are pinned in the
                     "Machine contract" section below so a format change
                     and a parser change land in the same diff.

  Edit the format in ONE place: here.
-->

# Synopsis output format

Write one Markdown file per video with exactly this structure:

```
# <video title>

Source: <youtube URL>

**TL;DR**: <one to three sentences capturing the thesis — self-contained
so a reader scanning a list of TL;DRs can decide whether to open this one.
Single line, no line breaks.>

## Synopsis

<Multi-paragraph summary covering the full content in logical order.
Depth over brevity: the reader wants to understand the video without
watching it. Preserve the speaker's framing and terminology where it
matters. Break into labelled subsections only if the video has clear
chapters. Length scales with the video — a 10-minute talk may need
~300 words, a 90-minute lecture ~1000+. Don't pad; don't truncate
substance to fit a budget.>

## Key Takeaways

<Bulleted list of the most important, actionable, or surprising points.
Each bullet stands alone as a distinct insight, not a mechanical
restatement of the synopsis. You may cite [mm:ss] timestamps when a
moment is worth pinning to.>
```

## Filename slug

The file is named `<slug>.md`, one synopsis file per video directory:

- 2–6 words, kebab-case, lowercase ASCII, ending in `.md`.
- Describes the actual subject matter — not the literal video title
  (titles are often clickbaity). Reads like a useful node label in an
  Obsidian graph view; the slug alone should hint at the topic.
- Favour the substantive topic over personalities/sensationalism.
- Must NOT begin with `transcript` (reserved for the raw transcript).

## Machine contract (do not drift without updating `ytt build-index`)

- The TL;DR line is prefixed **exactly** with `**TL;DR**: ` and lives on
  a single line. `ytt build-index` extracts the first such line; a
  missing line falls back to the first sentence of the `## Synopsis`
  section.
- The synopsis file is the single `*.md` in the video directory whose
  name does not start with `transcript`. `ytt build-index` and
  `ingest-one.sh` both locate it that way.
