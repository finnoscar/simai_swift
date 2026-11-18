# Changelog

## 0.2.1 — 2026-11-18

- Parse compact chords such as `15` as separate notes on the same beat, with independent input and scores.
- Preserve both legs and the authored timing of explicit center turns such as `3-C-2[4:1]`. The guide star and input route now agree, and a shortcut that misses C cannot clear the slide.
- Honor backtick notation (for example, ``1`5``) without applying ordinary EACH styling or changing note timing and scoring.
- Compare the revised parser and slide judgement against Airmai's engine in the source parity check.

## 0.2.0 — 2026-11-18

- Add Airmai’s preview timeline to `SimaiPlayerView` and expose `SimaiPreviewTimeline` for custom hosts.
- Display note-type density, measure, and source notation. Seek by tapping or dragging, with playback resuming only if it was playing before the drag.
- Verify authored offsets, zero-adjustment defaults, and pause/scrub/resume; add a read-only source parity check for maintainers.

## 0.1.0 — 2026-11-17

- Extract the native Swift simai parser, Canvas renderer, touch input and judgement engine as a Swift Package.
- Expose public models, settings, rendering, touch, scoring and event-stream APIs.
- Add local-file iOS playback and a SwiftUI preview/gameplay host.
- Provide a standalone iPhone/iPad demonstration with generated audio and an original chart.
- Include public API tests and native gameplay/audio regressions.
- Preserve upstream notices and publish the combined framework under GPLv3.

This is an initial framework release. Public APIs may change before 1.0.
