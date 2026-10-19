# VideoEditor

![GitHub Repo stars](https://img.shields.io/github/stars/5j54d93/VideoEditor)
![GitHub repo size](https://img.shields.io/github/repo-size/5j54d93/VideoEditor)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)

A native macOS video editor built with SwiftUI that cuts on **real** frames and writes repeatable MP4s：with the same app build, sources, cut points and CPU architecture, another export produces the same SHA-256, so re-exporting on the same Mac class does not create another upload in Google Photos or iCloud. Trim, split, reorder, crop and turn, mix in stills, lay music and sound over the cut, then export through the app's own bundled FFmpeg — no Homebrew, no MacPorts, nothing to install.

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
- **Audio goes on the track**：an audio asset doesn't join the clip order — it lands on the audio track, under the playhead（double-click, or the card's + action）or wherever it is dropped on the timeline, and is mixed *with* the clips' own sound rather than swapped in for it.
- **Finder-style selection**：click, <kbd>⌘</kbd>-click and marquee-drag all work, and <kbd>⌫</kbd> removes the selected assets together with every timeline clip made from them, in one undo step.
- **Re-import is a refresh, not a duplicate**：re-importing a path you already have updates that asset in place — metadata, live playback, filmstrips, undo history and the scrub player all move to the new bytes together, so the preview can never describe a file that no longer exists.

## Frame-Accurate Timeline

The timeline **is** the output：every visible clip is part of the exported movie, in exactly this order, and trimmed-away source ranges are never drawn. The one exception is the orange source-tail mark: it is an inspection overlay, not movie time.

- **Cuts land on real frames**：trims, splits and export are all expressed as indices into the source's probed per-packet PTS table, not as seconds. Variable-frame-rate sources, fractional rates like 24.9713 fps, and files whose first frame doesn't start at t = 0 all snap to the frame you actually see — no stray frame from the next scene.
- **Picture and original audio are separate lanes**：every video clip draws its real frames above its embedded audio, including a delayed start or an early end — and says so when that audio has been muted or detached.
- **An audio track under the clips**：music, effects and detached sound sit on their own track, each piece placed at a moment of its own and heard *with* the clips' sound rather than instead of it. Overlapping pieces take separate lanes automatically — a bed of music with an effect on it is the ordinary case — so there is no lane to manage. Drag a piece to slide it（it snaps to cuts, the playhead and other pieces）, drag either end to trim it（the sound stays where it was）, <kbd>S</kbd> splits the selected piece at the playhead and <kbd>⌫</kbd> removes it. Every piece draws its waveform at the level it will be heard, fades included, with the tips of any column the gain pushes past full scale marked in orange.
- **Sound is set where it is drawn**：every bar of sound — a piece of the track or a clip's own audio — carries its own controls. A white line is its level（0–200%, the recording's own level halfway up）: drag it — it holds for a moment at 100% on the way past, and <kbd>⌘</kbd> moves it a percent a point with no hold — or <kbd>⌥</kbd>-click it back to 100%. Handles at the top corners are its fades: drag one in, and it snaps to cuts, the playhead and other sound; the two never cross, and <kbd>⌥</kbd>-clicking one removes it. The speaker at the bottom-left mutes it. A number beside the pointer says what a drag is setting while it is in hand, and each drag is one undo step. The right-click menu carries the same, for a whole selection at once. There is no settings row above the timeline any more, so the timeline no longer jumps when the selection changes.
- **Sound stops where the picture stops**：the track never lengthens the movie. A piece that outruns the last frame is drawn dimmed past it, is not in the file past it, and its fade-out leads into that cut rather than into silence nobody hears.
- **A clip's own sound is a bar like the others**：the lower part of every video clip draws its embedded audio's waveform and carries the same line, handles and speaker — its fades run across any black added to keep its tail, as the export's do — while dragging anywhere else on it still picks the clip up to reorder it. **分離原音** in the clip's menu moves that audio onto the track as a piece of its own — movable, trimmable, splittable — leaving the picture silent.
- **Heard in preview**：the track plays along with the picture, each piece on its own player started and stopped as the playhead crosses it, gain and fades included; export places every sample exactly.
- **Source tails are a diagnostic, not a chore**：when audio or the MP4 container outlives the final video sample by more than half a frame, a 2 pt orange mark sits on that boundary; hovering or selecting the clip floats a chip with the exact millisecond figure. Shorter tails are not reported at all — export already caps original audio at the final video boundary, so they can never reach the output. The chip offers three things. **放大到尾端** zooms until the tail has a real length, at which point it is drawn to scale spilling right past the boundary（capped so it can never swallow the next clip）. **忽略** simply retires the warning: it changes nothing about the exported file, which is why it is also safe to apply to every clip at once from the toolbar. **延長影像** is the one that edits — offered only for tails of 0.25 s or more, it appends real black frames（ffmpeg `tpad`）so the trailing audio survives into the movie, lengthening the clip, the timeline and the output alike. All three are undoable.
- **Zoom into individual frames**：the zoom slider（or a pinch gesture）spans 8 to 3,600 points per second and always anchors on the playhead. Once a source frame is wide enough, the overview filmstrip is replaced by exact, individually decoded frame cells — each spanning its own real duration, labelled `f1234`, with the current frame outlined in red. <kbd>⇧</kbd><kbd>Z</kbd> fits the whole movie back into the pane.
- **Split and ripple-trim at the playhead**：<kbd>S</kbd> splits the active clip in two; <kbd>Q</kbd> and <kbd>W</kbd> throw away everything to the left／right of the playhead within that clip. Both refuse to fire on a clip boundary, so a one-sided trim can never turn into an accidental whole-clip delete.
- **Reorder by dragging**：one drop surface covers the whole pane — clips, ruler, blank space — and a caret shows exactly which gap a release will land in, including the very start. Multi-selected clips travel as one ordered group even when they aren't adjacent, and the view auto-scrolls while you drag past its edge.
- **Snap-back playhead**：clicking the ruler seeks, clicking a clip seeks and selects, clicking blank space clears the selection, and pausing mid-playback snaps the playhead onto the nearest frame boundary so the next cut is exact.
- **Undo everything**：<kbd>⌘</kbd><kbd>Z</kbd> and <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Z</kbd> walk a 100-step snapshot history covering the library, the clip list, trims, order, selection and the audio track. A drag — a level line, a fade handle, a slider — is one step, however many values it sent.

## Preview & Scrubbing

- **Hover to scrub**：moving the pointer across the timeline previews the exact frame under it without touching the playhead, the selection or playback — a dedicated muted `AVPlayer` is chase-seeked, so a fast sweep stays live instead of queueing a backlog of decodes.
- **No black flash**：the scrub layer stays mounted and only fades in once it has a frame to display, so the committed preview shows through while a freshly loaded source is still decoding.
- **Exact by construction**：hover positions are quantized onto the source frame grid first, then requested with zero seek tolerance and a one-nanosecond interior bias — so the frame on screen is always the frame the model, the timeline cell and the export all agree on.
- **Stills get their own control**：selecting an image clip reveals a display-duration slider（0.2–20 s）right above the timeline.
- **Reframe in a workspace, not a corner**：double-click the preview, press <kbd>C</kbd>, or hit the crop button in the toolbar to take a region out of the source. Reframing takes the whole window: the library and the timeline lanes step aside, and the two things a crop actually needs from them come back as purpose-built rails — a filmstrip of the clip's own frames（<kbd>⌥</kbd><kbd>←</kbd>／<kbd>⌥</kbd><kbd>→</kbd>, or drag it）and a strip of every clip in the project — click one to move the crop to it, or walk them with <kbd>[</kbd>／<kbd>]</kbd>, each marked with a dot wherever a clip has already been reframed. Crop inspection decodes the current video frame at native resolution rather than enlarging a player thumbnail, with fit, 1:1 and up to 1600% zoom for precise boundaries. Past 1:1 the picture stops being filtered — magnifying shows the pixels that are there rather than a smoothed version of them — and the selection border never covers more than half a source pixel: it thins toward a hairline as the picture grows and is stroked clear of the boundary rather than across it, so every pixel inside the selection stays visible.
- **Draw the selection, don't walk it in**：dragging anywhere on the picture draws a new rectangle from scratch, the way every selection tool on the Mac does, so the framing you want takes one gesture instead of four edges walked in from the whole frame. Dragging inside the current rectangle still moves it, and the eight grips still resize it. Marching ants and small square grips mark the selection; the crosshair says where a new one will start; panning a zoomed picture is on scroll and pinch.
- **Grab the rectangle anywhere**：every edge is live along its whole length, not just at a marker — the pointer picks up a resize cursor wherever you meet it — and the corners carry a 24 pt target on top of that. Nothing is drawn on the picture to say so: a bar of white laid along the edge you are aiming at covers the very thing you are aiming with. The ratio is unconstrained by default, so all four sides simply go where they are pulled; lock it to the source's own shape or a preset from the right-hand panel when you want it held. The rectangle stops at the frame — a crop selects from the picture that exists, and cannot be dragged out into black. Edges snap to the source's own boundaries and centre lines（<kbd>⌘</kbd> suspends it）, <kbd>⌥</kbd> resizes about the centre, <kbd>⇧</kbd> inverts the ratio lock for one drag, and the mask lightens while you drag so the part being thrown away stays judgeable. **A drag always keeps the edge under the pointer**, which is also why the sizes it can reach are spaced by whatever one point covers：at the common half-size fit that is two source pixels, so dragging moves the width in twos and cannot land on an odd one. That is arithmetic, not a setting — a point cannot pick between two pixels. Precision comes from the zoom, where it costs nothing：**實際像素** makes a point a pixel, so the edge still tracks the pointer and every integer is reachable at the same time. The numbers rail takes an exact value at any zoom. <kbd>⌥</kbd> mirrors the drag onto the opposite edge, so a centred resize moves the width in twos even at 100%；an odd size comes from dragging one edge, or from typing it. <kbd>↩</kbd> commits; <kbd>esc</kbd> cancels the whole session and puts the framing back the way it was on the way in.
- **Everything else is in one panel**：ratio, exact pixel values, the resulting file size, and "套用到全部" sit down the right-hand side, so the stage itself carries nothing but the picture and the rectangle.
- **The crop is the output**：there is no canvas to set up, no fit／fill／letterbox to choose between. The file comes out exactly the size of the rectangle — crop 615 pixels wide and the file is 615 pixels wide, odd number and all（delivered in 4:4:4, see below）. With several clips the first one sets the size and the rest are fitted into it; "套用到全部" makes them match in one click.
- **Turn a clip a quarter at a time**：<kbd>R</kbd> turns 90° clockwise and <kbd>⇧</kbd><kbd>R</kbd> counterclockwise — every selected clip at once, or the one under the playhead when nothing is selected — and so do the toolbar button beside the crop, a clip's context menu and the top of the reframing panel. Quarter turns only, because those move pixels without resampling a single one. The turn comes before the crop: the rectangle is drawn on the turned picture, and a clip that is already cropped keeps exactly the same pixels when it turns, its ratio lock turning with it（16:9 becomes 9:16）. Turning the first clip turns the file — a sideways phone clip stood upright comes out portrait. The preview, the hover scrub, the filmstrips and the export sheet all draw the turned picture; frames are decoded once and turned as they are drawn, so turning never re-decodes anything. 回到整張畫面 removes the crop and leaves the turn.

## Deterministic Export

<kbd>⌘</kbd><kbd>E</kbd> opens a filename／destination sheet（remembering the last folder）, then a live progress sheet with the first frame, percentage, elapsed and estimated remaining — cancellable, and a cancelled export deletes its half-written file instead of leaving a torso behind.

Everything is normalized onto one output frame — the region the first clip keeps — at the exact rational frame rate of the fastest video, scaled, letterboxed, concatenated, and encoded with one fixed internal profile：libx264（medium, CRF 18, `yuv420p`）plus native AAC（two-loop coder, stereo 44.1 kHz, 192 kbps）. There is no hidden quality／threading setting that can silently change the file format.

Sound is the clips' own audio concatenated as a bed — each clip's level and fades applied in place — with every piece of the audio track cut to what the movie has room for, shaped（`volume`, `afade`）, delayed to its place in whole samples and summed over the bed by `amix` with normalization off, so the bed stays as loud as it was however many pieces land on it. Pieces are mixed in an order fixed by where they sit, never by how they were arranged, because floats add in order and the order is part of the bytes. Gain and fades are written only when set, which keeps an untouched project's arguments — and its bytes — exactly what they were before the track existed.

A turned clip starts its chain with ffmpeg's `transpose`（`clock`／`cclock`）or, for a half turn, `hflip,vflip` — the filters FFmpeg itself inserts to honour a display matrix, and pure pixel moves: nothing is interpolated, so a turned clip is as repeatable as an untouched one. The crop that follows is read in the turned picture's pixels, exactly the numbers the workspace showed. An upright clip gets no filter at all, which is why turning shipped without moving a byte of anything exported before it: the same unturned project, cropped to an odd 4:4:4 frame and uncropped, exports to the same SHA-256 from the builds on either side of the change.

The one thing that varies is chroma, and only because it has to：a 4:2:0 plane is half-resolution on both axes and cannot describe an odd-sized picture at all — x264 refuses the encode rather than rounding it. An odd output frame is therefore written in `yuv444p`（High 4:4:4 Predictive）, which costs bitrate and hardware decoding but delivers the size that was asked for. Every even one keeps `yuv420p` and is byte-for-byte what it always was: enabling 4:4:4 in the bundled x264 was verified not to change a single byte of 4:2:0 output.

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
| <kbd>S</kbd> | Split the active clip — or the selected piece of the audio track — at the playhead |
| <kbd>Q</kbd> <kbd>W</kbd> | Delete left／right of the playhead |
| <kbd>⌫</kbd> | Remove the selected clips and audio pieces（or library assets） |
| <kbd>⇧</kbd><kbd>Z</kbd> | Zoom the timeline to fit |
| <kbd>⌘</kbd><kbd>Z</kbd> <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Z</kbd> | Undo／redo |
| <kbd>⌘</kbd><kbd>I</kbd> | Import media |
| <kbd>⌘</kbd><kbd>E</kbd> | Export |
| <kbd>C</kbd> | Enter／leave cropping |
| <kbd>R</kbd> <kbd>⇧</kbd><kbd>R</kbd> | Turn the selected clips — or the active one — 90° clockwise／counterclockwise |

Inside the reframing workspace:

| Key | Action |
| --- | --- |
| <kbd>←</kbd> <kbd>→</kbd> <kbd>↑</kbd> <kbd>↓</kbd> | Nudge the crop 1 px（<kbd>⇧</kbd> for 10） |
| <kbd>R</kbd> <kbd>⇧</kbd><kbd>R</kbd> | Turn this clip 90° clockwise／counterclockwise, crop and all |
| <kbd>⌥</kbd><kbd>←</kbd> <kbd>⌥</kbd><kbd>→</kbd> | Previous／next frame of this clip |
| <kbd>[</kbd> <kbd>]</kbd> | Previous／next clip, without leaving |
| <kbd>↩</kbd> | Done |
| <kbd>esc</kbd> | Cancel — restores the framing from before the session |

Single-key shortcuts disable themselves while a text field has focus, so typing a filename or a timecode never triggers an edit.

## Requirements

- macOS 26.5 or later
- Xcode 26 or later to build：open `VideoEditor.xcodeproj` and run
- Nothing else — `ffmpeg` and `ffprobe` are checked in and embedded in the app bundle. To rebuild them from the pinned upstream archives, see [`Dependencies/FFmpeg/README.md`](Dependencies/FFmpeg/README.md)

## License

VideoEditor bundles the `ffmpeg` and `ffprobe` command-line programs, built from unmodified FFmpeg 8.1.2 and x264 sources and distributed under the **GNU General Public License, version 2 or later**. The exact upstream source archives are checked into [`Dependencies/FFmpeg/Sources/`](Dependencies/FFmpeg/Sources), the license texts into [`Dependencies/FFmpeg/Licenses/`](Dependencies/FFmpeg/Licenses), and the complete build recipe is [`build-macos.sh`](Dependencies/FFmpeg/build-macos.sh) — see [`NOTICE.md`](Dependencies/FFmpeg/NOTICE.md) for the full notices.

VideoEditor is not affiliated with or endorsed by either upstream project.
