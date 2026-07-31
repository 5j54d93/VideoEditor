# VideoEditor

![GitHub Repo stars](https://img.shields.io/github/stars/5j54d93/VideoEditor)
![GitHub repo size](https://img.shields.io/github/repo-size/5j54d93/VideoEditor)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)

A native macOS video editor built with SwiftUI that cuts on **real** frames and writes repeatable MP4s：with the same app build, sources, cut points and CPU architecture, another export produces the same SHA-256, so re-exporting on the same Mac class does not create another upload in Google Photos or iCloud. Trim, split, reorder, mix in stills and background music, then export through the app's own bundled FFmpeg — no Homebrew, no MacPorts, nothing to install.

## Overview

1. [**Media Library**](https://github.com/5j54d93/VideoEditor#media-library)
2. [**Frame-Accurate Timeline**](https://github.com/5j54d93/VideoEditor#frame-accurate-timeline)
3. [**Preview & Scrubbing**](https://github.com/5j54d93/VideoEditor#preview--scrubbing)
4. [**Deterministic Export**](https://github.com/5j54d93/VideoEditor#deterministic-export)
5. [**Under the Hood**](https://github.com/5j54d93/VideoEditor#under-the-hood)
6. [**Keyboard Shortcuts**](https://github.com/5j54d93/VideoEditor#keyboard-shortcuts)
7. [**Requirements**](https://github.com/5j54d93/VideoEditor#requirements)
8. [**License**](https://github.com/5j54d93/VideoEditor#license)

## Media Library

Drop videos, images and audio files anywhere in the window — or press <kbd>⌘</kbd><kbd>I</kbd> — and they land in the left sidebar as a card grid with thumbnails, duration badges and vitals.

- **Probed once**：every file is inspected on import（dimensions, exact frame rate, per-frame timestamps）, so dragging the same asset onto the timeline ten times never re-probes it.
- **Search and filter**：filter by name, or narrow the grid to videos／images／audio only.
- **Drag or double-click**：drag a card onto the timeline to insert it at the caret, or double-click to append it to the end.
- **Audio is background music**：an audio asset doesn't become a clip — it becomes the movie's music track（overriding the clips' own audio）, marked with a 背景音樂 badge on its card.
- **Finder-style selection**：click, <kbd>⌘</kbd>-click and marquee-drag all work, and <kbd>⌫</kbd> removes the selected assets together with every timeline clip made from them, in one undo step.
- **Re-import is a refresh, not a duplicate**：re-importing a path you already have updates that asset in place — metadata, live playback, filmstrips, undo history and the scrub player all move to the new bytes together, so the preview can never describe a file that no longer exists.

## Frame-Accurate Timeline

The timeline **is** the output：every visible clip is part of the exported movie, in exactly this order, and trimmed-away source ranges are never drawn.

- **Cuts land on real frames**：trims, splits and export are all expressed as indices into the source's probed per-packet PTS table, not as seconds. Variable-frame-rate sources, fractional rates like 24.9713 fps, and files whose first frame doesn't start at t = 0 all snap to the frame you actually see — no stray frame from the next scene.
- **Zoom into individual frames**：the zoom slider（or a pinch gesture）spans 8 to 3,600 points per second and always anchors on the playhead. Once a source frame is wide enough, the overview filmstrip is replaced by exact, individually decoded frame cells — each spanning its own real duration, labelled `f1234`, with the current frame outlined in red. <kbd>⇧</kbd><kbd>Z</kbd> fits the whole movie back into the pane.
- **Split and ripple-trim at the playhead**：<kbd>S</kbd> splits the active clip in two; <kbd>Q</kbd> and <kbd>W</kbd> throw away everything to the left／right of the playhead within that clip. Both refuse to fire on a clip boundary, so a one-sided trim can never turn into an accidental whole-clip delete.
- **Reorder by dragging**：one drop surface covers the whole pane — clips, ruler, blank space — and a caret shows exactly which gap a release will land in, including the very start. Multi-selected clips travel as one ordered group even when they aren't adjacent, and the view auto-scrolls while you drag past its edge.
- **Snap-back playhead**：clicking the ruler seeks, clicking a clip seeks and selects, clicking blank space clears the selection, and pausing mid-playback snaps the playhead onto the nearest frame boundary so the next cut is exact.
- **Undo everything**：<kbd>⌘</kbd><kbd>Z</kbd> and <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Z</kbd> walk a 100-step snapshot history covering the library, the clip list, trims, order, selection and the music track.

## Preview & Scrubbing

- **Hover to scrub**：moving the pointer across the timeline previews the exact frame under it without touching the playhead, the selection or playback — a dedicated muted `AVPlayer` is chase-seeked, so a fast sweep stays live instead of queueing a backlog of decodes.
- **No black flash**：the scrub layer stays mounted and only fades in once it has a frame to display, so the committed preview shows through while a freshly loaded source is still decoding.
- **Exact by construction**：hover positions are quantized onto the source frame grid first, then requested with zero seek tolerance and a one-nanosecond interior bias — so the frame on screen is always the frame the model, the timeline cell and the export all agree on.
- **Stills get their own control**：selecting an image clip reveals a display-duration slider（0.2–20 s）right above the timeline.

## Deterministic Export

<kbd>⌘</kbd><kbd>E</kbd> opens a filename／destination sheet（remembering the last folder）, then a live progress sheet with the first frame, percentage, elapsed and estimated remaining — cancellable, and a cancelled export deletes its half-written file instead of leaving a torso behind.

Everything is normalized onto one shared canvas — the largest dimensions among the clips, at the exact rational frame rate of the fastest video — scaled, letterboxed, concatenated, and encoded with one fixed internal profile：libx264（medium, CRF 18, `yuv420p`）plus native AAC（two-loop coder, stereo 44.1 kHz, 192 kbps）. There is no hidden quality／threading setting that can silently change the file format.

Reproducibility is enforced at every variable stage：FFmpeg-native CPU-feature dispatch is disabled, the filter graph runs on one worker, scaling uses accurate bitexact rounding with dithering disabled, audio resampling uses a fixed signed-32-bit internal format, and x264 is always pinned to one frame thread and one lookahead thread with deterministic／CPU-independent mode enabled. This trades a modest amount of export speed for same-architecture stability across machines. Output-side `-fflags +bitexact -flags +bitexact -map_metadata -1 -map_chapters -1` selects bitexact codec／muxer paths and removes volatile timestamps and inherited metadata; `-movflags +faststart` remains web-ready. A SHA-256 of the finished file is computed on every run.

The guarantee is intentionally scoped to the **same bundled toolchain and CPU architecture**. In a raw-input validation of the shipped Universal 2 binary, the H.264 elementary stream was byte-identical between arm64 and x86_64 after these changes, but FFmpeg's native AAC encoder still produced different bytes across the two architectures even with fixed resampling, coder, sample format, AAC tools and CPU flags. The app keeps AAC for normal MP4／Apple-platform compatibility, so a whole-file SHA match across arm64 and x86_64 is not promised.

## Under the Hood

- **`FrameGrid`**：one lattice, built from the probed per-packet PTS table, that UI snapping, preview seeks and export cut indices all consult — so they can never disagree about where frame *k* sits. Edit-list pre-roll frames（negative PTS: decoded, but never displayed）are excluded from trim points, and sources without a usable table fall back to the nominal *k*／fps grid with identical behaviour on clean CFR files.
- **Bundled Universal 2 FFmpeg**：`ffmpeg` and `ffprobe` 8.1.2 with x264, built for arm64 + x86_64 by [`Dependencies/FFmpeg/build-macos.sh`](Dependencies/FFmpeg/build-macos.sh), checksum-verified, `lipo`-merged and rejected if they reference any non-system dynamic library. The app resolves **only** its own embedded copies, so a developer machine's Homebrew build can never silently stand in for the shipped one.
- **SwiftUI + Observation**：a single `@Observable` `EditorModel` on the main actor, with `async`／`await` throughout and every `ffmpeg`／`ffprobe` invocation off the main thread. Export progress is parsed from ffmpeg's own `-progress pipe:1` stream, and task cancellation terminates the process through a lock-guarded box that closes the register／cancel race.
- **Frame decoding that stays out of the way**：filmstrip tiles decode with per-tile bounded tolerances（an unbounded decode snaps to a keyframe, and x264 puts keyframes on scene changes, which would show the *next* scene）, while exact cells submit every visible cache miss as one source-time-ordered AVFoundation batch. Both caches evict a slice at a time so a hover sweep never triggers a wall of re-decodes.
- **Zero third-party Swift dependencies**：SwiftUI, AVFoundation／AVKit, CryptoKit, Observation and Synchronization only.
- **繁體中文 UI**.

## Keyboard Shortcuts

| Key | Action |
| --- | --- |
| <kbd>Space</kbd> | Play／pause |
| <kbd>←</kbd> <kbd>→</kbd> | Step one frame |
| <kbd>⇧</kbd><kbd>←</kbd> <kbd>⇧</kbd><kbd>→</kbd> | Step ten frames |
| <kbd>S</kbd> | Split the active clip at the playhead |
| <kbd>Q</kbd> <kbd>W</kbd> | Delete left／right of the playhead |
| <kbd>⌫</kbd> | Remove the selected clips（or library assets） |
| <kbd>⇧</kbd><kbd>Z</kbd> | Zoom the timeline to fit |
| <kbd>⌘</kbd><kbd>Z</kbd> <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Z</kbd> | Undo／redo |
| <kbd>⌘</kbd><kbd>I</kbd> | Import media |
| <kbd>⌘</kbd><kbd>E</kbd> | Export |

Single-key shortcuts disable themselves while a text field has focus, so typing a filename or a timecode never triggers an edit.

## Requirements

- macOS 26.5 or later
- Xcode 26 or later to build：open `VideoEditor.xcodeproj` and run
- Nothing else — `ffmpeg` and `ffprobe` are checked in and embedded in the app bundle. To rebuild them from the pinned upstream archives, see [`Dependencies/FFmpeg/README.md`](Dependencies/FFmpeg/README.md)

## License

VideoEditor bundles the `ffmpeg` and `ffprobe` command-line programs, built from unmodified FFmpeg 8.1.2 and x264 sources and distributed under the **GNU General Public License, version 2 or later**. The exact upstream source archives are checked into [`Dependencies/FFmpeg/Sources/`](Dependencies/FFmpeg/Sources), the license texts into [`Dependencies/FFmpeg/Licenses/`](Dependencies/FFmpeg/Licenses), and the complete build recipe is [`build-macos.sh`](Dependencies/FFmpeg/build-macos.sh) — see [`NOTICE.md`](Dependencies/FFmpeg/NOTICE.md) for the full notices.

VideoEditor is not affiliated with or endorsed by either upstream project.
