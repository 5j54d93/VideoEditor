//
//  Project.swift
//  VideoEditor
//
//  The assembly project is an ordered list of ClipItems (video clips + still
//  images) plus one optional background-audio track. Each video item carries an
//  in/out trim; each image item carries a display duration (stored as outPoint).
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

    /// Clamped to something the exporter can render: at least 2px on each side
    /// so a scale never divides by zero, and never so far outside the source
    /// that no picture survives.
    ///
    /// There is deliberately no chroma-grid snapping here any more. Odd
    /// coordinates used to be rounded away by crop/pad on a 4:2:0 frame, so the
    /// editor pre-rounded to stay honest; now that the chain composes through
    /// yuv444p whenever a coordinate is odd, snapping would only make the
    /// editor refuse precision the exporter can deliver.
    func clampedWindow(in source: PixelSize) -> PixelRect {
        guard source.isUsable else { return self }
        let w = max(2, width)
        let h = max(2, height)
        // Keep at least this much of the source inside the window, so a drag
        // that overshoots cannot produce an all-black segment.
        let margin = 8
        return PixelRect(x: min(max(x, -w + margin), source.width - margin),
                         y: min(max(y, -h + margin), source.height - margin),
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
nonisolated enum AutoFraming: Equatable, Sendable {
    case fit    // 完整放入：整張畫面進畫布，四周留黑
    case fill   // 填滿：畫布被填滿，超出的裁掉
}

/// Which region of the source frame the canvas shows.
///
/// One rectangle in place of what used to be four fields — a crop, a fit mode,
/// a magnification and an offset. They were all describing this rectangle's
/// position and size: cropping moves and shrinks it, "fill" is a particular
/// choice of it, magnifying makes it smaller, nudging slides it. Collapsing
/// them also collapses the two editing stages, because the rectangle *is* the
/// output frame — there is no longer a second picture to check the result in.
nonisolated enum ClipFraming: Equatable, Sendable {
    case automatic(AutoFraming)
    /// A rectangle the user placed, in source pixels. Deliberately allowed to
    /// extend past the source frame; outside it the picture is black, which is
    /// what "fit the whole picture" and any intentional letterbox amount to.
    case window(PixelRect)
}

/// How the crop rectangle's aspect ratio is constrained while dragging.
/// Locked to the canvas by default: a vertical edit wants "this part, filling
/// the frame", and under that lock the rectangle on screen is exactly what the
/// viewer will see.
nonisolated enum AspectLock: Hashable, Sendable {
    case canvas
    case ratio(width: Int, height: Int)
    case source
    case free
}

/// Where one clip's pixels land on the shared canvas. The default value is the
/// editor's only historical behaviour — whole source frame, contained, centred
/// — and `isIdentity` is how export proves nothing has moved.
nonisolated struct ClipGeometry: Equatable, Sendable {
    var framing: ClipFraming = .automatic(.fit)
    /// Not part of the output: it only constrains dragging. Stored per clip so
    /// switching between clips does not silently change what a drag will do.
    var aspectLock: AspectLock = .canvas

    var isIdentity: Bool { framing == .automatic(.fit) }

    /// The rectangle the user is working with, materialising an automatic
    /// framing when they first take hold of it.
    func window(source: PixelSize, canvas: PixelSize) -> PixelRect {
        switch framing {
        case .window(let rect):
            return rect
        case .automatic(let mode):
            return ClipGeometry.automaticWindow(mode, source: source, canvas: canvas)
        }
    }

    /// `fit` is the smallest canvas-shaped rectangle containing the whole
    /// source; `fill` is the largest one inside it. Both centred.
    ///
    /// Only ever used to seed a drag or to draw the rectangle — never to build
    /// export arguments. Deriving the exported size from this would round
    /// differently from `av_rescale`, and untouched projects have to keep
    /// exporting the bytes they always did.
    static func automaticWindow(_ mode: AutoFraming,
                                source: PixelSize, canvas: PixelSize) -> PixelRect {
        guard source.isUsable, canvas.isUsable else {
            return PixelRect(x: 0, y: 0, width: max(1, source.width), height: max(1, source.height))
        }
        let byWidth = PixelSize(
            width: source.width,
            height: max(1, Int((Double(source.width) * Double(canvas.height)
                                / Double(canvas.width)).rounded())))
        let byHeight = PixelSize(
            width: max(1, Int((Double(source.height) * Double(canvas.width)
                               / Double(canvas.height)).rounded())),
            height: source.height)
        // Containing the source means taking the taller/wider of the two.
        let size = mode == .fit
            ? (byWidth.height >= source.height ? byWidth : byHeight)
            : (byWidth.height <= source.height ? byWidth : byHeight)
        return PixelRect(x: (source.width - size.width) / 2,
                         y: (source.height - size.height) / 2,
                         width: size.width, height: size.height)
    }
}

/// The output canvas size. `automatic` reproduces the size derived from the
/// source clips, so a project nobody has reframed exports exactly as before.
nonisolated enum CanvasSizing: Equatable, Sendable {
    case automatic
    /// A named size from the inspector. Kept as the original `fixed` case so
    /// existing model callers continue to mean the same thing.
    case fixed(PixelSize)
    /// An explicitly editable size. This has to remain distinct even when its
    /// current numbers happen to equal a preset; otherwise choosing 自訂 from a
    /// 1920×1080 canvas immediately snaps the picker back to that preset and the
    /// width/height fields never appear.
    case custom(PixelSize)
}

struct ClipItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var kind: ClipKind
    var geometry = ClipGeometry()

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
    var sourcePixelSize: PixelSize { PixelSize(width: naturalWidth, height: naturalHeight) }
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

}
