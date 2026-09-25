# About this fork

This is an **unofficial fork** of [sw33tLie/macshot](https://github.com/sw33tLie/macshot),
licensed like the original under the GNU GPL v3. It is not affiliated with or
endorsed by the macshot project. Official builds, releases and support live
upstream.

## What it adds (branch `video-annotations`)

Tools for marking up training videos in the Studio video editor:

- **Pause-and-annotate** — draw with the full screenshot toolkit (arrows,
  shapes, text, numbers, stamps, highlighter) over the current frame; the
  drawing becomes a timed clip that follows crop and zoom, with an optional
  freeze-frame hold.
- **Animated entrances/exits** — draw-on for lines, arrows, freehand and
  shape outlines, plus pop, slide, wipe and fade, with per-shape stagger.
- **Overlay clips** — ProRes 4444 / HEVC-with-alpha motion graphics (e.g.
  exported from Premiere or After Effects) and still images composited over
  the video.

## Building

`scripts/build-dev.sh --open` builds this checkout as **macshot Dev**
(separate bundle ID, automatic updates off) and installs it to
`/Applications`, so it can run beside an official macshot install.
