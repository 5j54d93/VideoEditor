//
//  Project.swift
//  VideoEditor
//
//  The assembly project is an ordered list of ClipItems (video clips + still
//  images) plus an audio track of AudioClips laid over them. Each video item
//  carries an in/out trim; each image item carries a display duration (stored
//  as outPoint); each audio clip carries a stretch of a file and the moment it
//  starts on the output timeline.
//

import Foundation
import CoreMedia

/// MP4 edit lists and timescale conversion commonly differ by a few microseconds.
/// Absolute floor for sources whose frame rate is unknown or absurd; the
/// per-clip `tailReportingTolerance` is what actually gates the warning.
let trailingMediaTolerance = 0.001

/// Return a timestamp just inside the requested frame. Frame PTS values retain
/// the source time-base precision, but converting a `Double` back to `CMTime` can
/// still round a few nanoseconds *before* the sample. A zero-tolerance
/// AVFoundation seek would then display the preceding frame while the editor
/// model already points at the requested one.
///
/// One nanosecond is far below any practical video-frame duration, while the
/// positive bias guarantees that the seek remains on the intended side of the
/// frame boundary.
nonisolated func interiorFrameTime(_ seconds: Double) -> CMTime {
    let nanosecond = 1.0 / 1_000_000_000.0
    return CMTime(seconds: max(0, seconds) + nanosecond,
                  preferredTimescale: 1_000_000_000)
}

enum ClipKind: Equatable, Sendable { case video, image }

/// Which source track outlives the final real video sample. The two are
/// reported separately because only an audio tail carries something audible —
/// a bare container tail is a muxing artefact with nothing to preserve.
enum TailSource: Equatable, Sendable { case audio, container }

// MARK: - Frame grid

/// The real display-order frame lattice of one video source, built from the
/// probed per-packet pts table. UI snapping, preview seeks and export cut
/// indices all go through this one table, so they can never disagree about
/// where frame k sits — even on VFR sources or files whose first frame doesn't
/// start at t = 0. Sources without a usable table fall back to the nominal
/// k/fps lattice (identical behaviour for clean CFR files).
struct FrameGrid: Equatable, Sendable {
    var times: [Double]          // sorted pts of every frame; empty → nominal grid
    var nominalFps: Double
    var fallbackDuration: Double // video-track duration, sizes the nominal fallback
    var fallbackStartTime: Double = 0
    /// End of the final observed packet, when ffprobe supplied its duration.
    /// Kept separate from `times`: it is an exclusive sample boundary, not a
    /// synthetic frame start that the editor may seek to or cut on.
    var observedEndTime: Double? = nil

    private var fallbackCount: Int { max(1, Int((fallbackDuration * nominalFps).rounded())) }
    var frameCount: Int { times.isEmpty ? fallbackCount : times.count }

    /// End of the stream: one frame interval past the last frame's start.
    var endTime: Double {
        guard let last = times.last else {
            if let observedEndTime, observedEndTime.isFinite,
               observedEndTime > fallbackStartTime + 1e-9 {
                return observedEndTime
            }
            let span = fallbackDuration > 0
                ? fallbackDuration : Double(fallbackCount) / nominalFps
            return fallbackStartTime + span
        }
        if let observedEndTime, observedEndTime.isFinite,
           observedEndTime > last + 1e-9 {
            return observedEndTime
        }
        let n = times.count
        let lastInterval = n >= 2 ? max(1e-6, last - times[n - 2]) : 1.0 / nominalFps
        return last + lastInterval
    }

    /// First frame a player can show. Edit-list pre-roll frames carry negative
    /// pts: decoders emit them (so they count toward frame indices) but players
    /// never display them, so trim points must not land on them.
    var firstDisplayedFrame: Int {
        guard !times.isEmpty else {
            let first = Int(ceil(max(0, -fallbackStartTime) * nominalFps - 1e-9))
            return min(max(0, first), fallbackCount - 1)
        }
        return times.firstIndex { $0 >= -1e-9 } ?? 0
    }

    func time(ofFrame i: Int) -> Double {
        guard !times.isEmpty else {
            return fallbackStartTime
                + Double(min(max(0, i), fallbackCount - 1)) / nominalFps
        }
        return times[min(max(0, i), times.count - 1)]
    }

    /// Cut boundaries: boundary i is where frame i starts; boundary `frameCount`
    /// is the stream end. In/out points are always boundary times.
    func boundary(_ i: Int) -> Double {
        let clamped = min(max(0, i), frameCount)
        return clamped == frameCount ? endTime : time(ofFrame: clamped)
    }

    /// The frame whose span contains `t` (floor), clamped to valid frames.
    func frameIndex(containing t: Double) -> Int {
        guard !times.isEmpty else {
            let offset = t - fallbackStartTime
            return min(max(0, Int(floor(offset * nominalFps + 1e-6))),
                       fallbackCount - 1)
        }
        var low = 0, high = times.count - 1, best = 0
        // Integer packet PTS values retain the source time-base precision; only
        // cover Double round-off here, without treating the final microsecond of
        // one frame as though it already belonged to the next frame.
        let target = t + 1e-9
        while low <= high {
            let mid = (low + high) / 2
            if times[mid] <= target { best = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return best
    }

    func nearestFrame(to t: Double) -> Int {
        let i = frameIndex(containing: t)
        let j = min(i + 1, frameCount - 1)
        return abs(time(ofFrame: j) - t) < abs(t - time(ofFrame: i)) ? j : i
    }

    func nearestBoundary(to t: Double) -> Int {
        let i = frameIndex(containing: t)
        let j = min(i + 1, frameCount)
        return abs(boundary(j) - t) < abs(t - boundary(i)) ? j : i
    }
}

// MARK: - Library

enum AssetKind: Equatable, Hashable, Sendable { case video, image, audio }

/// An imported source in the media library. Probing happens once at import;
/// dragging the asset onto the timeline instantiates a ClipItem from this
/// metadata without re-probing.
struct LibraryAsset: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var kind: AssetKind
    var width: Int = 0
    var height: Int = 0
    var duration: Double = 0     // video/audio length; image: 0
    var fps: Double = 0
    var fpsRational: String = "30"
    var hasAudio: Bool = false
    var frameTimes: [Double] = []   // real pts of every frame; empty → nominal grid
    var containerStartTime: Double = 0
    var videoStartTime: Double = 0
    var videoDuration: Double = 0
    var frameEndTime: Double? = nil // exclusive end of the final real video packet
    var audioStartTime: Double = 0
    var audioDuration: Double? = nil
}

// MARK: - Canvas geometry

/// Integer pixel primitives. Every geometry value the editor holds is an exact
/// pixel count: the resolver turns them into ffmpeg arguments without a float
/// surviving the trip, which is what keeps the same project exporting the same
/// bytes.
nonisolated struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int
    static let zero = PixelSize(width: 0, height: 0)
    /// Probing can fail to report a size. Geometry falls back to letting ffmpeg
    /// work the fit out at runtime when it does.
    var isUsable: Bool { width > 0 && height > 0 }
}

nonisolated struct PixelRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var size: PixelSize { PixelSize(width: width, height: height) }

    /// Confined to the source frame: a crop selects from the picture that
    /// exists, and never reaches past its edge.
    ///
    /// The window used to be allowed outside the frame, on the grounds that the
    /// area beyond it is black and an intentional letterbox is a legitimate
    /// thing to ask for. In practice a crop rectangle that keeps going when it
    /// runs out of picture just produces black nobody wanted — there is no
    /// visible edge to stop against and no reason to want one. Letterboxing is
    /// still available, but through the framing that means it（`.fit`）and
    /// through the canvas, not by dragging a corner into the void.
    ///
    /// There is deliberately no chroma-grid snapping here any more. Odd
    /// coordinates used to be rounded away by crop/pad on a 4:2:0 frame, so the
    /// editor pre-rounded to stay honest; now that the chain composes through
    /// yuv444p whenever a coordinate is odd, snapping would only make the
    /// editor refuse precision the exporter can deliver.
    func clampedWindow(in source: PixelSize) -> PixelRect {
        guard source.isUsable else { return self }
        // At least 2px a side so a scale never divides by zero, and never
        // larger than the frame it is selecting from.
        let w = min(max(2, width), max(2, source.width))
        let h = min(max(2, height), max(2, source.height))
        return PixelRect(x: min(max(0, x), source.width - w),
                         y: min(max(0, y), source.height - h),
                         width: w, height: h)
    }

    func coversWholeFrame(of source: PixelSize) -> Bool {
        x == 0 && y == 0 && width == source.width && height == source.height
    }
}

nonisolated struct PixelOffset: Equatable, Sendable {
    var x: Int
    var y: Int
    static let zero = PixelOffset(x: 0, y: 0)
}

/// How a clip's picture is sized against the canvas, before `scale` and
/// `offset` move it.
/// A framing the canvas derives for itself, rather than one the user placed.
/// Kept live rather than materialised into a rectangle so that changing the
/// canvas reframes the clip instead of stranding a window shaped for the old
/// aspect ratio.
/// Which region of the source frame survives into the output.
///
/// One rectangle in place of what used to be four fields — a crop, a fit mode,
/// a magnification and an offset. They were all describing this rectangle's
/// position and size: cropping moves and shrinks it, magnifying makes it
/// smaller, nudging slides it.
///
/// The fit/fill modes that used to sit alongside it are gone too. They existed
/// to answer "how does this clip meet the canvas", a question that no longer
/// arises: the output frame *is* the first clip's rectangle, so cropping is the
/// only thing left to decide.
nonisolated enum ClipFraming: Equatable, Sendable {
    /// Everything. The default, and what `isCropped` reports as uncropped.
    case wholeFrame
    /// A rectangle the user placed, in pixels of the (turned) source, always
    /// inside that frame — see `PixelRect.clampedWindow`. Everything it
    /// contains is picture.
    case window(PixelRect)

    /// A window someone placed, confined to the frame — and stored as
    /// `.wholeFrame` when, confined, it turns out to be all of it.
    ///
    /// `isCropped` is read off the framing, so a full-frame rectangle stored
    /// *as* a rectangle counts as an edit: the clip rail marks the clip
    /// reframed, 回到整張畫面 offers to undo nothing, and export takes the window
    /// path, whose rounding is not the whole-frame path's — the one an untouched
    /// project is promised byte for byte. A click inside the crop rectangle is
    /// a drag that moves nothing, so this is the rectangle a click proposes.
    /// The same picture has to be the same value, and every window that is
    /// stored comes through here to make it so.
    static func placed(_ rect: PixelRect, in source: PixelSize) -> ClipFraming {
        let window = rect.clampedWindow(in: source)
        return window.coversWholeFrame(of: source) ? .wholeFrame : .window(window)
    }
}

/// How the crop rectangle's aspect ratio is constrained while dragging.
/// Free by default: a crop tool should let all four edges go where they are
/// pulled until someone asks otherwise.
nonisolated enum AspectLock: Hashable, Sendable {
    case ratio(width: Int, height: Int)
    case source
    case free
}

/// A clip's picture turned a quarter at a time, clockwise.
///
/// Quarter turns only, because they are the turns that move pixels without
/// resampling them: a turned frame holds exactly the pixels it held before,
/// just in other places. That keeps the editor's one rule intact — every
/// geometry value is an exact pixel count — and it is the whole of what a
/// sideways phone clip needs.
///
/// The turn comes first, before the crop. The window is drawn on the turned
/// picture and measured in its pixels, so "the source" in every geometry
/// function below means the source *as turned* — see
/// `ClipItem.orientedPixelSize`. Only the code that touches a decoded frame
/// (ffmpeg's chain, the players, the bitmaps) ever sees it unturned.
nonisolated enum ClipRotation: Int, CaseIterable, Sendable {
    case upright = 0
    /// A quarter turn clockwise: the picture's left edge ends up on top.
    case clockwise = 1
    case upsideDown = 2
    /// A quarter turn counterclockwise: the left edge ends up at the bottom.
    case counterclockwise = 3

    /// Clockwise in degrees, for saying how far a clip has been turned.
    var degrees: Int { rawValue * 90 }

    /// A quarter turn either way stands the picture on its side.
    var swapsAxes: Bool { rawValue % 2 == 1 }

    /// `quarterTurns` further clockwise; negative goes the other way.
    func turned(by quarterTurns: Int) -> ClipRotation {
        ClipRotation(rawValue: ((rawValue + quarterTurns) % 4 + 4) % 4) ?? .upright
    }

    /// A picture of `size` once turned.
    func turning(_ size: PixelSize) -> PixelSize {
        swapsAxes ? PixelSize(width: size.height, height: size.width) : size
    }

    /// Where `rect`, in a picture of `size`, lands once the picture is turned.
    ///
    /// Exact: the same pixels, in their new places. A rectangle inside the
    /// picture stays inside it, which is why a crop can simply go round with
    /// the picture rather than being re-derived and re-clamped.
    func turning(_ rect: PixelRect, in size: PixelSize) -> PixelRect {
        switch self {
        case .upright:
            return rect
        case .clockwise:
            return PixelRect(x: size.height - rect.y - rect.height, y: rect.x,
                             width: rect.height, height: rect.width)
        case .upsideDown:
            return PixelRect(x: size.width - rect.x - rect.width,
                             y: size.height - rect.y - rect.height,
                             width: rect.width, height: rect.height)
        case .counterclockwise:
            return PixelRect(x: rect.y, y: size.width - rect.x - rect.width,
                             width: rect.height, height: rect.width)
        }
    }
}

/// Which part of one clip's picture is kept, and which way up. The default
/// value is the editor's only historical behaviour — the whole frame, as the
/// file plays it — and `isIdentity` is how export proves nothing has moved.
nonisolated struct ClipGeometry: Equatable, Sendable {
    /// Applied before everything else: `framing` is in pixels of the turned
    /// picture.
    var rotation: ClipRotation = .upright
    var framing: ClipFraming = .wholeFrame
    /// Not part of the output: it only constrains dragging. Stored per clip so
    /// switching between clips does not silently change what a drag will do.
    var aspectLock: AspectLock = .free

    /// Neither turned nor cropped.
    var isIdentity: Bool { rotation == .upright && !isCropped }

    /// Something of the picture is cut away. The turn is not a crop: putting
    /// the whole frame back leaves it turned.
    var isCropped: Bool { framing != .wholeFrame }

    /// The rectangle the user is working with, materialising the whole frame
    /// when they first take hold of it. `source` is the picture the window is
    /// drawn on — already turned.
    ///
    /// Deliberately needs nothing but the source. The output size is derived
    /// from this rectangle, so anything that consulted the canvas here would be
    /// asking the canvas to help compute itself.
    func window(source: PixelSize) -> PixelRect {
        switch framing {
        case .window(let rect):
            return rect
        case .wholeFrame:
            return PixelRect(x: 0, y: 0,
                             width: max(1, source.width), height: max(1, source.height))
        }
    }

    /// This framing with the picture turned `quarterTurns` further clockwise.
    /// `source` is the picture *before* any turn, as the file plays it.
    ///
    /// Everything goes round together. The crop keeps the same pixels, so a
    /// clip can be cropped first and stood upright afterwards without losing
    /// the work; and a ratio lock describes that rectangle's shape, so it
    /// turns with it — 16:9 becomes 9:16 — rather than snapping the turned
    /// rectangle back to the old shape on the next drag.
    func turned(by quarterTurns: Int, source: PixelSize) -> ClipGeometry {
        let turn = ClipRotation.upright.turned(by: quarterTurns)
        guard turn != .upright else { return self }
        var result = self
        result.rotation = rotation.turned(by: quarterTurns)
        // Without a probed size there is no picture to turn the window in;
        // a window cannot have been placed against one either.
        if case .window(let rect) = framing, source.isUsable {
            result.framing = .window(turn.turning(rect, in: rotation.turning(source)))
        }
        if turn.swapsAxes, case .ratio(let width, let height) = aspectLock {
            result.aspectLock = .ratio(width: height, height: width)
        }
        return result
    }
}

struct ClipItem: Identifiable, Equatable {
    private(set) var id = UUID()
    var url: URL
    var kind: ClipKind
    var geometry = ClipGeometry()
    /// The clip's own sound as it is heard: a multiplier on the recording, and
    /// the fades the file will get at either end. Mute keeps the number, so
    /// switching the sound back on brings back the level it had.
    var audioGain: Double = 1
    var isAudioMuted = false
    var audioFadeIn: Double = 0
    var audioFadeOut: Double = 0

    var naturalWidth: Int
    var naturalHeight: Int
    var sourceDuration: Double   // video length; image: 0
    var fps: Double              // video fps; image: 0
    var fpsRational: String = "30"  // exact rate for ffmpeg (e.g. "21700/869"); image: unused
    var hasAudio: Bool
    var frameTimes: [Double] = []   // real pts of every frame; empty → nominal grid

    var inPoint: Double = 0      // video trim start; image: 0
    var outPoint: Double         // video trim end; image: display seconds
    var containerStartTime: Double = 0
    var videoStartTime: Double = 0
    var videoDuration: Double = 0
    var frameEndTime: Double? = nil
    var audioStartTime: Double = 0
    var audioDuration: Double? = nil
    /// `nil` follows the source audio-track end. A value is an independent
    /// original-audio trim made by the user; it never changes video frames.
    var audioOutPoint: Double? = nil
    /// Container duration can also exceed the video track without an audio
    /// sample causing it. This independent cap records that the user dismissed
    /// that non-frame tail; export always rebuilds the container safely.
    var containerOutPoint: Double? = nil
    /// Black video appended after the final real frame so the source-audio tail
    /// survives into the output. Unlike the two caps above this one is a real
    /// edit: it lengthens the clip's timeline span and the exported movie.
    var videoPadDuration: Double = 0

    var isImage: Bool { kind == .image }
    var name: String { url.lastPathComponent }
    /// The frame as the file plays it — display matrix applied, nothing of
    /// this clip's own geometry. What the players and decoders hand back.
    var sourcePixelSize: PixelSize { PixelSize(width: naturalWidth, height: naturalHeight) }
    /// The picture the crop is drawn on: the source, turned. Every window,
    /// clamp and ratio is in these pixels.
    var orientedPixelSize: PixelSize { geometry.rotation.turning(sourcePixelSize) }
    /// What the recording is multiplied by on the way out — nothing when there
    /// is no track, or it has been muted or detached onto the audio track.
    var effectiveAudioGain: Double { hasAudio && !isAudioMuted ? audioGain : 0 }
    /// The clip's real frame span. All source-time arithmetic uses this — the
    /// pad has no source time behind it, only black.
    var contentDuration: Double { max(0, outPoint - inPoint) }
    /// The clip's span on the output timeline, which the black pad extends.
    var displayDuration: Double { contentDuration + max(0, videoPadDuration) }
    /// FFmpeg drops empty timeline placeholders before building its concat graph.
    /// Export previews use this same predicate so their purported first frame
    /// cannot come from an item that never reaches the output file.
    var isExportable: Bool { displayDuration > 1e-3 }
    var hasVideoPad: Bool { videoPadDuration > 1e-9 }
    var effectiveFps: Double { fps > 0 ? fps : 30 }
    var frameDuration: Double { 1.0 / effectiveFps }
    /// A tail shorter than half a frame is noise, not a decision: export already
    /// caps original audio at the final video boundary so it can never reach the
    /// output, and at any usable zoom it sits far below one pixel. Reporting it
    /// only trains people to dismiss warnings without reading them.
    var tailReportingTolerance: Double {
        max(trailingMediaTolerance, 0.5 / effectiveFps)
    }

    var grid: FrameGrid {
        FrameGrid(times: frameTimes, nominalFps: effectiveFps,
                  fallbackDuration: videoDuration > 0 ? videoDuration : sourceDuration,
                  fallbackStartTime: videoStartTime,
                  observedEndTime: frameEndTime)
    }
    var sourceAudioEndTime: Double? {
        audioDuration.map { audioStartTime + max(0, $0) }
    }
    var effectiveAudioOutPoint: Double {
        guard hasAudio else { return inPoint }
        guard let sourceAudioEndTime else {
            // Unknown duration means unknown, not empty. Keep the lane over the
            // selected video range and preserve the audio track during export.
            return max(inPoint, audioOutPoint ?? outPoint)
        }
        let requested = audioOutPoint ?? sourceAudioEndTime
        return min(max(inPoint, requested), sourceAudioEndTime)
    }
    /// Source audio which survives beyond the final real video sample and the
    /// black pad, if any. This belongs to the lower audio lane; it is
    /// deliberately not a fake frame.
    var audioTailDuration: Double {
        guard !isImage, hasAudio, trimEndFrame >= grid.frameCount,
              let sourceAudioEndTime else { return 0 }
        let requested = audioOutPoint ?? sourceAudioEndTime
        let tail = max(0, min(requested, sourceAudioEndTime) - paddedOutPoint)
        return tail > tailReportingTolerance ? tail : 0
    }
    /// Where the clip's picture actually stops, black included.
    var paddedOutPoint: Double { outPoint + max(0, videoPadDuration) }
    /// How much more black would be needed for the whole audio tail to play.
    /// Only an audible tail is worth padding — black added for a bare container
    /// artefact would lengthen the movie with nothing behind it.
    var videoPadCandidate: Double { audioTailDuration }
    var sourceContainerEndTime: Double {
        containerStartTime + max(0, sourceDuration)
    }
    var effectiveContainerOutPoint: Double {
        min(max(containerStartTime, containerOutPoint ?? sourceContainerEndTime),
            sourceContainerEndTime)
    }
    var containerTailDuration: Double {
        guard !isImage, trimEndFrame >= grid.frameCount else { return 0 }
        let tail = max(0, effectiveContainerOutPoint - paddedOutPoint)
        return tail > tailReportingTolerance ? tail : 0
    }
    /// The warning spans whichever source track/container ends last.
    var trailingOverhangDuration: Double {
        max(audioTailDuration, containerTailDuration)
    }
    /// `nil` when there is nothing to report. Audio wins ties: it is the only
    /// one of the two that a pad could preserve.
    var tailSource: TailSource? {
        guard trailingOverhangDuration > 1e-9 else { return nil }
        return audioTailDuration >= containerTailDuration && audioTailDuration > 1e-9
            ? .audio : .container
    }
    /// First kept frame (inclusive), as an index into the real frame grid.
    /// In/out points are always boundary times, so the nearest boundary recovers
    /// the exact index regardless of floating-point drift.
    var trimStartFrame: Int { grid.nearestBoundary(to: inPoint) }
    /// First dropped frame (exclusive).
    var trimEndFrame: Int { grid.nearestBoundary(to: outPoint) }

    /// The same clip under a new identity, so it can stand beside the original
    /// on the timeline. A split derives its second half this way: every field
    /// carries over and only a boundary moves afterwards. Spelling the fields
    /// out in an initializer call is how the crop went missing from that half.
    func withNewIdentity() -> ClipItem {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

// MARK: - Audio track

/// The level a piece of sound plays at, `time` seconds into it: its gain, taken
/// down by whichever fade it is inside. Straight lines, because that is what
/// ffmpeg's `afade` draws by default — the preview approximates this on an
/// `AVPlayer`'s volume while the export writes the filter, and the two have
/// to describe the same curve.
nonisolated func audioGain(at time: Double, duration: Double, gain: Double,
                           fadeIn: Double, fadeOut: Double) -> Double {
    guard duration > 0, gain > 0 else { return 0 }
    var factor = 1.0
    if fadeIn > 0 { factor = min(factor, time / fadeIn) }
    if fadeOut > 0 { factor = min(factor, (duration - time) / fadeOut) }
    return gain * min(1, max(0, factor))
}

extension ClipItem {
    /// The clip's own sound as heard `offset` seconds into its span. The black
    /// pad is part of the span: the export shapes the whole of it, and the
    /// recording plays on under the black, so a fade-out on a padded clip
    /// finishes where the black does rather than where the picture does.
    func audioLevel(at offset: Double) -> Double {
        // Qualified, because inside a clip `audioGain` is the clip's own level.
        VideoEditor.audioGain(at: offset, duration: displayDuration, gain: effectiveAudioGain,
                              fadeIn: audioFadeIn, fadeOut: audioFadeOut)
    }
}

/// One piece of sound on the audio track: a stretch of a file, placed at a
/// moment on the output timeline and heard under whatever picture is there.
///
/// This is what background music became once it could be cut. The old track
/// was one file, starting at zero, replacing every clip's own sound; a clip on
/// a track can start anywhere, be trimmed and split like the picture, sit
/// beside others, and is *mixed* with the clips' sound rather than standing
/// in for it. A clip's own audio detached from its picture is one of these
/// too, pointing at the video file — which is why a clip carries the file's
/// audio timing: a detached track keeps the late start or early end it had.
struct AudioClip: Identifiable, Equatable {
    private(set) var id = UUID()
    var url: URL
    /// Absolute source timestamp ffmpeg strips from this input without
    /// `-copyts`; zero for a plain audio file.
    var containerStartTime: Double = 0
    /// Where the file's audio actually begins and ends, absolute. `nil` is an
    /// unknown end, which export treats as "through the out point".
    var audioStartTime: Double = 0
    var audioEndTime: Double? = nil
    /// The stretch of the file that plays, in source seconds.
    var inPoint: Double
    var outPoint: Double
    /// Where that stretch begins on the output timeline.
    var timelineStart: Double
    var gain: Double = 1
    var isMuted = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0

    /// Shorter than this and a clip is a click, not a sound — and the trim
    /// handles would sit on top of each other.
    static let minimumDuration = 0.05

    var duration: Double { max(0, outPoint - inPoint) }
    var timelineEnd: Double { timelineStart + duration }
    var effectiveGain: Double { isMuted ? 0 : gain }
    var name: String { url.lastPathComponent }

    /// The source seconds a trim may reach: the file's audio, and no further.
    var sourceFloor: Double { min(audioStartTime, inPoint) }
    var sourceCeiling: Double { max(audioEndTime ?? outPoint, outPoint) }

    /// How much of the clip the movie has room for: its own length, or less
    /// when it starts near the end and outruns the picture.
    func heardDuration(movieDuration: Double) -> Double {
        min(duration, movieDuration - timelineStart)
    }

    /// The level `offset` seconds in, with the fade-out leading into wherever
    /// the sound stops being heard — the clip's own end, or the movie's when
    /// that comes first. A fade into silence after the last frame would be a
    /// setting that does nothing.
    func gain(at offset: Double, movieDuration: Double) -> Double {
        audioGain(at: offset, duration: heardDuration(movieDuration: movieDuration),
                  gain: effectiveGain, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// The same sound under a new identity, so a split's second half can stand
    /// beside its first — every field rides along, as it does for a clip.
    func withNewIdentity() -> AudioClip {
        var copy = self
        copy.id = UUID()
        return copy
    }
}
