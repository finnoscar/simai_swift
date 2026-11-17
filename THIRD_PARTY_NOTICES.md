# Third-party notices

## Native engine origin

The parser, chart-clock motion, Canvas rendering, slide geometry, touch mapping,
judgement, score ledger, audio synthesis and playback timing were extracted from
the Airmai native Swift engine on 2026-11-17. Original source-file hashes are in
`SOURCE_PROVENANCE.json`. Package adapters expose public APIs, accept local files,
and provide a standalone playback host.

Original native source copyright notice

> Copyright (c) 2026 Finn and AirMai contributors

The original MIT permission notice is preserved in
[`LICENSES/Airmai-MIT.txt`](LICENSES/Airmai-MIT.txt).

## simai_flutter

Source reference

- Project — https://github.com/Project-Fukakai/simai_flutter
- Pinned revision — `f15acddffc6a43d0c0f74beeb91fc282fcb9bf2c`
- License — MIT

The native implementation adapts and references simai syntax, note motion, path
geometry, rendering conventions, sensor layouts and judgement/scoring rules.
The upstream copyright and permission text is preserved verbatim in
[`LICENSES/simai_flutter-MIT.txt`](LICENSES/simai_flutter-MIT.txt).

Upstream also credits Lxns-Network's `maimai-chart-engine` for TouchHold geometry,
palettes, animation timing and star rotation. Its notice and complete MIT text
are retained verbatim in
[`LICENSES/simai_flutter-THIRD_PARTY_NOTICES.md`](LICENSES/simai_flutter-THIRD_PARTY_NOTICES.md).

## Majdata JudgeAreas provenance

The exported `SimaiInputMapper` source explicitly identifies its A/B/C/D/E
sensor polygon coordinates as copied from simai_flutter's Majdata JudgeAreas
mesh port. The MajdataPlay project is distributed under GNU GPL v3.0.

- Project — https://github.com/TeamMajdata/MajdataPlay
- License — https://github.com/TeamMajdata/MajdataPlay/blob/dev/LICENSE

This package retains that source attribution and distributes the combined
framework under **GPL-3.0-only**. The complete GPLv3 text is in [`LICENSE`](LICENSE).
The retained MIT notices continue to apply to the upstream MIT material.

## Demonstration content

The example chart and its generated metronome are authored for this repository.
Host-supplied charts, songs, covers, skins and trademarks retain their respective
owners' rights. Obtain the necessary rights for media you distribute with a host.
