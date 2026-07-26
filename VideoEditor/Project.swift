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
    var fallbackDuration: Double // container duration, sizes the nominal fallback

    private var fallbackCount: Int { max(1, Int((fallbackDuration * nominalFps).rounded())) }
    var frameCount: Int { times.isEmpty ? fallbackCount : times.count }

    /// End of the stream: one frame interval past the last frame's start.
    var endTime: Double {
        guard let last = times.last else { return Double(fallbackCount) / nominalFps }
        let n = times.count
        let lastInterval = n >= 2 ? max(1e-6, last - times[n - 2]) : 1.0 / nominalFps
        return last + lastInterval
    }

    /// First frame a player can show. Edit-list pre-roll frames carry negative
    /// pts: decoders emit them (so they count toward frame indices) but players
    /// never display them, so trim points must not land on them.
    var firstDisplayedFrame: Int {
        guard !times.isEmpty else { return 0 }
        return times.firstIndex { $0 >= -1e-9 } ?? 0
    }

    func time(ofFrame i: Int) -> Double {
        guard !times.isEmpty else {
            return Double(min(max(0, i), fallbackCount - 1)) / nominalFps
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
            return min(max(0, Int(floor(t * nominalFps + 1e-6))), fallbackCount - 1)
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
    var keyframes: [Double] = [0]
    var frameTimes: [Double] = []   // real pts of every frame; empty → nominal grid
}

struct ClipItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var kind: ClipKind

    var naturalWidth: Int
    var naturalHeight: Int
    var sourceDuration: Double   // video length; image: 0
    var fps: Double              // video fps; image: 0
    var fpsRational: String = "30"  // exact rate for ffmpeg (e.g. "21700/869"); image: unused
    var hasAudio: Bool
    var keyframes: [Double] = [0]
    var frameTimes: [Double] = []   // real pts of every frame; empty → nominal grid

    var inPoint: Double = 0      // video trim start; image: 0
    var outPoint: Double         // video trim end; image: display seconds

    var isImage: Bool { kind == .image }
    var displayDuration: Double { max(0, outPoint - inPoint) }
    var effectiveFps: Double { fps > 0 ? fps : 30 }
    var frameDuration: Double { 1.0 / effectiveFps }

    var grid: FrameGrid {
        FrameGrid(times: frameTimes, nominalFps: effectiveFps, fallbackDuration: sourceDuration)
    }
    /// First kept frame (inclusive), as an index into the real frame grid.
    /// In/out points are always boundary times, so the nearest boundary recovers
    /// the exact index regardless of floating-point drift.
    var trimStartFrame: Int { grid.nearestBoundary(to: inPoint) }
    /// First dropped frame (exclusive).
    var trimEndFrame: Int { grid.nearestBoundary(to: outPoint) }

    /// Largest keyframe at or before `t` (for lossless-friendly cuts).
    func keyframe(atOrBefore t: Double) -> Double {
        var best = 0.0
        for k in keyframes { if k <= t + 1e-6 { best = k } else { break } }
        return best
    }
}
