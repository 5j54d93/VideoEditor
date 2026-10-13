//
//  FFTools.swift
//  VideoEditor
//
//  Wraps the system ffmpeg / ffprobe binaries. Every export path is built to be
//  byte-for-byte repeatable on one CPU architecture: the same bundled toolchain,
//  source and cut points produce the same SHA-256. The fixed output profile also
//  removes core-count-dependent x264 output.
//
//  The output-side bitexact flags and metadata stripping remove volatile container
//  fields. Filter/scaler and x264 threading are pinned as part of the file format.
//  FFmpeg's native AAC encoder is repeatable within an architecture, but its
//  floating-point implementation is not byte-identical across arm64 and x86_64.
//

import Foundation
import CryptoKit

// MARK: - Probed media info

struct MediaInfo: Sendable {
    var duration: Double          // container duration (a length, not an absolute end)
    var containerStartTime: Double
    var videoEndTime: Double      // end of the final displayed video packet
    var videoStartTime: Double
    var videoDuration: Double     // video-track duration, used by the nominal fallback grid
    var fps: Double               // nominal frame rate (fallback 30 if unknown)
    var fpsRational: String       // exact rate as ffmpeg rational, e.g. "21700/869"
    var width: Int
    var height: Int
    var audioCodec: String?
    var audioStartTime: Double    // presentation start of the audio track
    /// Displayed audio-track duration after edit lists. Some containers omit it;
    /// `nil` must preserve the track rather than being interpreted as zero audio.
    var audioDuration: Double?
    var frameTimes: [Double]      // pts_time of every frame, ascending; [] if unavailable
}

// MARK: - Multi-asset assembly

/// One item on the assembly timeline, already resolved to what should be rendered.
///
/// Video trims are expressed as **frame indices**, not seconds: cutting by time on a
/// fractional-fps source (e.g. 24.9713) is fragile at frame boundaries — timebase
/// rounding can leave a stray frame from the next scene in the output. The indices
/// are positions in the source's probed per-frame pts table (`FrameGrid`), so they
/// agree with ffmpeg's own frame counting even on VFR sources or files whose first
/// frame doesn't start at t = 0.
struct AssemblyItem: Sendable {
    var url: URL
    var isImage: Bool
    var trimStartFrame: Int  // video: first kept frame (inclusive)
    var trimEndFrame: Int    // video: first dropped frame (exclusive)
    var trimStart: Double    // video: real pts where the kept range starts (audio cut)
    var trimEnd: Double      // video: real boundary where it ends (audio cut)
    var duration: Double     // display duration (video: trimEnd-trimStart; image: its duration)
    var hasAudio: Bool       // video with an audio track
    /// Absolute source timestamp which ffmpeg removes from this input when
    /// `-copyts` is absent. Audio trim bounds are translated into that local
    /// filter coordinate before being passed to `atrim`.
    var inputStartTime: Double = 0
    /// Absolute first presentation timestamp of the source audio track.
    var audioStartTime: Double = 0
    /// Absolute known source-audio end and/or explicit user cap. `nil` means
    /// unknown, so export keeps real audio through the selected video boundary.
    var audioEndTime: Double? = nil
    /// Black appended after the final real frame so the source-audio tail can
    /// play. Included in `duration`; it raises the audio ceiling by the same
    /// amount, which is the whole point of the pad.
    var padDuration: Double = 0
    /// Decoded frame size. `.zero` means probing never reported one, and the
    /// geometry chain falls back to letting ffmpeg fit at runtime.
    var sourceSize: PixelSize = .zero
    var geometry = ClipGeometry()
    /// The clip's own sound on the way out. Zero is silence — the same exact
    /// silence a clip without a track gets — and one is the recording as it
    /// is, which adds no filter at all.
    var audioGain: Double = 1
    var audioFadeIn: Double = 0
    var audioFadeOut: Double = 0
}

/// One piece of the audio track, as export sees it: a stretch of a file and
/// where on the movie it lands. Timing fields mean what `AssemblyItem`'s do.
nonisolated struct AssemblyAudio: Sendable, Equatable {
    var url: URL
    var inputStartTime: Double = 0
    var audioStartTime: Double = 0
    var audioEndTime: Double? = nil
    var trimStart: Double
    var trimEnd: Double
    var timelineStart: Double
    var gain: Double = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0

    var duration: Double { max(0, trimEnd - trimStart) }

    /// The part of the trim the file actually has sound for, or `nil` when
    /// the two never meet — a trim entirely before a late-starting track.
    var audibleRange: (start: Double, end: Double)? {
        let start = max(trimStart, audioStartTime)
        let end = min(trimEnd, audioEndTime ?? trimEnd)
        return end > start + 1e-9 ? (start, end) : nil
    }

    /// How much of the clip the movie has room for: its own length, or less
    /// when it starts near the end and outruns the picture.
    func heardDuration(movieDuration: Double) -> Double {
        min(duration, movieDuration - timelineStart)
    }

    /// `audibleRange`, cut again where the movie ends. Sound past the last
    /// frame is not in the file, so it is not in the segment either — which is
    /// also what puts a fade-out where the sound actually stops.
    func heardRange(movieDuration: Double) -> (start: Double, end: Double)? {
        guard let range = audibleRange else { return nil }
        let end = min(range.end, trimStart + heardDuration(movieDuration: movieDuration))
        return end > range.start + 1e-9 ? (range.start, end) : nil
    }
}

/// The exact integers one clip's geometry becomes on the ffmpeg command line.
/// Both optional crops are omitted from the chain when `nil`.
nonisolated struct Placement: Equatable, Sendable {
    /// Applied to the decoded frame, before scaling: the user's crop.
    var sourceCrop: PixelRect?
    var scaledSize: PixelSize
    /// Applied after scaling: trims whatever a nudge or a zoom pushed past the
    /// canvas edge, because `pad` cannot take a negative origin.
    var visibleCrop: PixelRect?
    var padOrigin: PixelOffset
    /// The picture missed the canvas entirely. The segment becomes black.
    var isFullyOffCanvas: Bool

    /// Top-left of the scaled picture on the canvas *before* the canvas edge
    /// clamps it — negative when a nudge or a zoom hangs it off the left or top.
    /// Export cannot use this (`pad` rejects a negative origin, which is why the
    /// visible crop exists) but the preview can, because it just clips.
    var origin: PixelOffset {
        guard let visibleCrop else { return padOrigin }
        return PixelOffset(x: padOrigin.x - visibleCrop.x, y: padOrigin.y - visibleCrop.y)
    }
}

/// The shared output canvas everything is scaled/padded into.
struct CanvasSpec: Sendable {
    var width: Int
    var height: Int
    var fps: String      // exact frame rate as an ffmpeg rational/number, e.g. "21700/869"
    var fpsValue: Double // numeric value of `fps`, for display and duration math

    /// A 4:2:0 chroma plane is half-resolution on both axes, so it cannot
    /// describe an odd-sized picture at all — x264 rejects the encode outright
    /// rather than rounding. 4:4:4 carries full-resolution chroma and has no
    /// such constraint, so an odd canvas is delivered there instead.
    nonisolated var hasOddDimension: Bool { width % 2 != 0 || height % 2 != 0 }

    /// The pixel format the finished stream is written in. 4:2:0 stays the
    /// default for every even canvas: it is the universally hardware-decodable
    /// format, and switching a canvas that never needed 4:4:4 would change the
    /// bytes of projects that have already been exported.
    nonisolated var deliveryPixelFormat: String { hasOddDimension ? "yuv444p" : "yuv420p" }
}

struct ExportResult: Sendable {
    var outputURL: URL
    var sha256: String
    var command: String       // human-readable command, for transparency
    var log: String
}

/// Tiny lock-guarded string box for accumulating partial lines across pipe callbacks.
private nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var v = ""
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Lock-guarded handle that lets a task-cancellation handler terminate the
/// running ffmpeg. Closes the register/cancel race: whichever comes second
/// still kills the process.
private nonisolated final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Returns false if cancellation already happened, in which case the
    /// process must not be started.
    func register(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

/// How a child tool ended, plus everything it printed on stdout+stderr.
///
/// The captured text alone cannot describe every failure. A tool the kernel
/// refuses to exec — an invalid code signature, a missing dependency — is killed
/// before it writes a single byte, so reporting only its output turns that into
/// a message with nothing after the colon. The exit status is the part that
/// always exists, and a signal is not an exit code: `terminationStatus` is the
/// signal number in that case, so the two have to be told apart.
private nonisolated struct ToolRun: Sendable {
    var status: Int32
    /// Terminated by a signal, making `status` that signal rather than an exit code.
    var killedBySignal: Bool
    var output: String

    var succeeded: Bool { status == 0 && !killedBySignal }

    /// e.g. "code 1" or "signal 9（Killed）".
    var statusLabel: String {
        guard killedBySignal else { return "code \(status)" }
        // Darwin's strsignal already appends the number ("Killed: 9"); keep the name.
        guard let raw = strsignal(status),
              let name = String(cString: raw).split(separator: ":").first,
              !name.isEmpty else { return "signal \(status)" }
        return "signal \(status)（\(name)）"
    }

    /// Never empty, even when the tool printed nothing at all.
    var failureDescription: String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return "（\(statusLabel)）\(text)" }
        // Nothing on either pipe and a signal means the tool never ran: the
        // kernel refused to exec it, which no ffprobe message can explain.
        return "以 \(statusLabel) 結束，沒有任何輸出。" +
            (killedBySignal ? "App 內附的工具可能被系統擋下執行（例如簽章無效）。" : "")
    }
}

enum FFError: LocalizedError {
    case notFound
    case probeFailed(String)
    case exportFailed(status: String, log: String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "App 內附的 ffmpeg / ffprobe 遺失或無法執行。請重新下載或安裝 VideoEditor。"
        case .probeFailed(let msg):
            return "無法讀取影片資訊：\(msg)"
        case .exportFailed(let status, let log):
            return "輸出失敗（\(status)）：\n\(log)"
        }
    }
}

// MARK: - FFTools

struct FFTools: Sendable {
    let ffmpeg: URL
    let ffprobe: URL

    /// Resolve only the tools embedded in this app. System package-manager paths
    /// are intentionally ignored so a developer machine cannot hide a broken bundle.
    static func locate(bundle: Bundle = .main,
                       fileManager: FileManager = .default) -> FFTools? {
        guard let ffmpeg = bundle.url(forAuxiliaryExecutable: "ffmpeg"),
              let ffprobe = bundle.url(forAuxiliaryExecutable: "ffprobe"),
              fileManager.isExecutableFile(atPath: ffmpeg.path),
              fileManager.isExecutableFile(atPath: ffprobe.path) else {
            return nil
        }
        return FFTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    // MARK: Probe

    /// Run ffprobe and decode the JSON report it was asked for. Both failure
    /// modes name what actually happened: the tool failing or being killed
    /// (which is the only thing left to report when it printed nothing), and
    /// output that came back but isn't the JSON we asked for.
    private nonisolated func probeJSON(_ args: [String]) async throws -> [String: Any] {
        let outcome = try await Self.run(ffprobe, args)
        guard outcome.succeeded else { throw FFError.probeFailed(outcome.failureDescription) }
        guard let data = outcome.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FFError.probeFailed("ffprobe 的輸出無法解析：\(outcome.output)")
        }
        return root
    }

    nonisolated func probe(_ url: URL) async throws -> MediaInfo {
        let args = ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path]
        let root = try await probeJSON(args)

        let streams = (root["streams"] as? [[String: Any]]) ?? []
        let format = (root["format"] as? [String: Any]) ?? [:]

        guard let v = streams.first(where: { ($0["codec_type"] as? String) == "video" }) else {
            throw FFError.probeFailed("找不到影像串流")
        }
        let a = streams.first(where: { ($0["codec_type"] as? String) == "audio" })

        let codedWidth = (v["width"] as? Int) ?? 0
        let codedHeight = (v["height"] as? Int) ?? 0
        // AVPlayer, AVAssetImageGenerator with preferred transforms, and
        // ffmpeg's default filter input all expose display-oriented pixels.
        // Keep the model on that same lattice or a portrait phone video reports
        // landscape crop coordinates and is squeezed in both preview and export.
        let dimensions = Self.displayDimensions(
            codedWidth: codedWidth, codedHeight: codedHeight, stream: v)
        let aCodec = a?["codec_name"] as? String
        let videoTiming = Self.streamTiming(v)
        let audioTiming = a.flatMap(Self.streamTiming)

        // Keep the exact rational (e.g. "21700/869" ≈ 24.9713) alongside the Double:
        // the export pipeline passes the rational to ffmpeg so a fractional-fps source
        // is never resampled to a rounded integer rate.
        let fps: Double
        let fpsRational: String
        if let s = v["avg_frame_rate"] as? String, let val = Self.parseRational(s) {
            fps = val; fpsRational = s
        } else if let s = v["r_frame_rate"] as? String, let val = Self.parseRational(s) {
            fps = val; fpsRational = s
        } else {
            fps = 30; fpsRational = "30"
        }

        var duration = Double(format["duration"] as? String ?? "") ?? 0
        if duration == 0 { duration = Double(v["duration"] as? String ?? "") ?? 0 }
        let explicitContainerStart = Self.finiteDouble(format["start_time"])

        // Packet `pts_time` is printed by ffprobe with only six decimal places.
        // Preserve the integer PTS and apply the stream time base ourselves so
        // zero-tolerance preview seeks cannot fall on the preceding frame after
        // decimal/time-scale rounding.
        let videoTimeBase = Self.parseRational(v["time_base"] as? String)
        let framePackets = (try? await framePackets(url, timeBase: videoTimeBase))
            ?? (times: [], endTime: nil)
        let videoStartTime = videoTiming?.start
            ?? Self.finiteDouble(v["start_time"])
            ?? framePackets.times.first(where: { $0 >= -1e-9 })
            ?? explicitContainerStart
            ?? 0
        let videoDuration = videoTiming?.duration
            ?? framePackets.endTime.map { max(0, $0 - videoStartTime) }
            ?? duration
        let videoEndTime = framePackets.endTime
            ?? videoTiming?.end
            ?? videoStartTime + videoDuration
        let audioStartTime = audioTiming?.start
            ?? a.flatMap { Self.finiteDouble($0["start_time"]) }
            ?? explicitContainerStart
            ?? videoStartTime
        let audioDuration = a.flatMap { Self.finiteDouble($0["duration"]) }
        let containerStartTime = explicitContainerStart
            ?? min(videoStartTime, a == nil ? videoStartTime : audioStartTime)

        return MediaInfo(duration: duration,
                         containerStartTime: containerStartTime,
                         videoEndTime: videoEndTime,
                         videoStartTime: videoStartTime,
                         videoDuration: videoDuration,
                         fps: fps, fpsRational: fpsRational,
                         width: dimensions.width, height: dimensions.height,
                         audioCodec: aCodec,
                         audioStartTime: audioStartTime,
                         audioDuration: audioDuration,
                         frameTimes: framePackets.times)
    }

    /// Display-oriented pixel dimensions of a still image. JPEG/HEIF orientation
    /// can live on the decoded frame rather than the stream; inspect one frame so
    /// NSImage, the crop lattice and FFmpeg autorotation all describe the same
    /// width/height.
    nonisolated func probeDimensions(_ url: URL) async throws -> (w: Int, h: Int) {
        let args = ["-v", "error", "-select_streams", "v:0",
                    "-read_intervals", "%+#1", "-show_streams", "-show_frames",
                    "-of", "json", url.path]
        let root = try await probeJSON(args)
        guard let s = (root["streams"] as? [[String: Any]])?.first else {
            throw FFError.probeFailed("找不到影像串流")
        }
        let codedWidth = (s["width"] as? Int) ?? 0
        let codedHeight = (s["height"] as? Int) ?? 0
        let frame = (root["frames"] as? [[String: Any]])?.first
        let dimensions = Self.displayDimensions(
            codedWidth: codedWidth, codedHeight: codedHeight,
            metadataSources: [frame, s].compactMap { $0 })
        return (dimensions.width, dimensions.height)
    }

    /// Container duration in seconds (used for audio files).
    nonisolated func probeDuration(_ url: URL) async throws -> Double {
        let args = ["-v", "error", "-show_entries", "format=duration", "-of", "json", url.path]
        let root = try await probeJSON(args)
        return Double((root["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
    }

    /// Real pts of every video packet (one per frame; display order after sorting).
    /// Packet-level, so no decode — fast even on long sources. This is the exact
    /// lattice ffmpeg's `trim` counts frames on. Returns [] when any packet lacks
    /// a numeric pts: a partial table would misalign index-based cuts, so such
    /// sources fall back to the nominal k/fps grid instead.
    private nonisolated func framePackets(
        _ url: URL, timeBase: Double?
    ) async throws -> (times: [Double], endTime: Double?) {
        guard let timeBase, timeBase.isFinite, timeBase > 0 else { return ([], nil) }
        let args = ["-v", "error", "-select_streams", "v:0",
                    "-show_entries", "packet=pts,duration", "-of", "csv=p=0", url.path]
        let outcome = try await Self.run(ffprobe, args)
        guard outcome.succeeded else { throw FFError.probeFailed(outcome.failureDescription) }
        return Self.parseFramePackets(outcome.output, timeBase: timeBase)
    }

    /// Decode ffprobe's compact packet table while retaining the packet duration
    /// of the true final sample. A missing duration does not invalidate the PTS
    /// lattice; it only makes the caller fall back to the stream duration for EOF.
    nonisolated static func parseFramePackets(
        _ out: String, timeBase: Double
    ) -> (times: [Double], endTime: Double?) {
        var times: [Double] = []
        var endTime: Double?
        var hasCompleteDurations = true
        for line in out.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = columns.first else { continue }
            let ptsText = first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ptsText.isEmpty else { continue }
            guard let pts = Int64(ptsText) else { return ([], nil) }
            let seconds = Double(pts) * timeBase
            times.append(seconds)
            guard columns.count > 1,
                  let duration = Int64(columns[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  duration > 0 else {
                hasCompleteDurations = false
                continue
            }
            endTime = max(endTime ?? -.infinity,
                          seconds + Double(duration) * timeBase)
        }
        return (times.sorted(), hasCompleteDurations ? endTime : nil)
    }

    // MARK: Geometry

    /// Source size + the user's framing + the canvas → the integers ffmpeg is
    /// told. Pure, and shared with the preview, so the two can never disagree
    /// about where a clip sits.
    ///
    /// The rounding here is copied from ffmpeg rather than chosen. `scale`'s
    /// `force_original_aspect_ratio` rescales with round-half-away-from-zero and
    /// does *not* force even dimensions; `pad`'s `(ow-iw)/2` truncates. An odd
    /// intermediate height is legal because `format=yuv420p` sits after `pad`,
    /// at canvas size. Reproducing all three exactly is what lets this replace
    /// the expression-based chain without moving a single output byte.
    nonisolated static func resolve(_ geometry: ClipGeometry,
                                    source: PixelSize,
                                    canvas: CanvasSpec) -> Placement {
        let bounds = PixelSize(width: canvas.width, height: canvas.height)
        switch geometry.framing {
        case .wholeFrame:
            // Deliberately not routed through the window arithmetic below.
            // Deriving the scaled size from a rectangle rounds differently from
            // `av_rescale`, and a project nobody has reframed has to keep
            // exporting the bytes it always did.
            return place(sourceCrop: nil, scaledSize: contained(source, in: bounds), in: bounds)
        case .window(let window):
            return resolveWindow(window, source: source, bounds: bounds)
        }
    }

    /// A user-placed window: the region of the source the canvas shows.
    ///
    /// The window is *fitted* into the canvas rather than stretched onto it, so
    /// a window whose aspect ratio differs from the canvas letterboxes instead
    /// of distorting. Under the default canvas-aspect lock the two match and it
    /// fills exactly.
    private nonisolated static func resolveWindow(_ window: PixelRect,
                                                  source: PixelSize,
                                                  bounds: PixelSize) -> Placement {
        // Only the part of the window that has pixels behind it can be cropped;
        // the rest of the window is the black the user asked for.
        let left = max(0, window.x)
        let top = max(0, window.y)
        let right = min(source.width, window.x + window.width)
        let bottom = min(source.height, window.y + window.height)
        guard window.width > 0, window.height > 0, right > left, bottom > top else {
            return Placement(sourceCrop: nil, scaledSize: bounds,
                             visibleCrop: nil, padOrigin: .zero, isFullyOffCanvas: true)
        }
        let crop = PixelRect(x: left, y: top, width: right - left, height: bottom - top)

        // One factor for both axes: the window keeps its shape, and so does the
        // picture inside it.
        var windowOnCanvas = contained(window.size, in: bounds)
        // A window locked to the canvas ratio often cannot express it exactly in
        // whole pixels — 607×1080 against 9:16 fits as 1079 wide — and the
        // leftover would be a one-pixel black hairline down one edge. Within a
        // pixel, take the canvas: 0.1% of aspect error is invisible, a black
        // line is not.
        if abs(windowOnCanvas.width - bounds.width) <= 1 {
            windowOnCanvas.width = bounds.width
        }
        if abs(windowOnCanvas.height - bounds.height) <= 1 {
            windowOnCanvas.height = bounds.height
        }
        let cropWidth = rescale(windowOnCanvas.width, crop.width, window.width)
        let cropHeight = rescale(windowOnCanvas.height, crop.height, window.height)
        let scaled = PixelSize(width: max(1, cropWidth), height: max(1, cropHeight))

        // Where the window itself sits, then where the cropped part sits in it.
        let windowOrigin = PixelOffset(x: (bounds.width - windowOnCanvas.width) / 2,
                                       y: (bounds.height - windowOnCanvas.height) / 2)
        let origin = PixelOffset(
            x: windowOrigin.x + rescale(windowOnCanvas.width, crop.x - window.x, window.width),
            y: windowOrigin.y + rescale(windowOnCanvas.height, crop.y - window.y, window.height))

        return place(sourceCrop: crop, scaledSize: scaled, at: origin, in: bounds)
    }

    /// Clip a scaled picture against the canvas. `origin` defaults to centred,
    /// which is what every automatic framing wants.
    private nonisolated static func place(sourceCrop: PixelRect?,
                                          scaledSize size: PixelSize,
                                          at origin: PixelOffset? = nil,
                                          in bounds: PixelSize) -> Placement {
        // Truncating division matches how pad evaluates `(ow-iw)/2` and casts.
        let originX = origin?.x ?? (bounds.width - size.width) / 2
        let originY = origin?.y ?? (bounds.height - size.height) / 2

        let left = max(0, originX)
        let top = max(0, originY)
        let right = min(bounds.width, originX + size.width)
        let bottom = min(bounds.height, originY + size.height)
        guard right > left, bottom > top else {
            return Placement(sourceCrop: sourceCrop, scaledSize: size,
                             visibleCrop: nil, padOrigin: .zero, isFullyOffCanvas: true)
        }

        let visible = PixelRect(x: left - originX, y: top - originY,
                                width: right - left, height: bottom - top)
        let whole = PixelRect(x: 0, y: 0, width: size.width, height: size.height)
        return Placement(sourceCrop: sourceCrop,
                         scaledSize: size,
                         visibleCrop: visible == whole ? nil : visible,
                         padOrigin: PixelOffset(x: left, y: top),
                         isFullyOffCanvas: false)
    }

    /// ffmpeg's own `force_original_aspect_ratio=decrease` arithmetic, in
    /// integers. The `increase` half went with the fill mode that used it.
    private nonisolated static func contained(_ source: PixelSize,
                                              in canvas: PixelSize) -> PixelSize {
        guard source.isUsable else { return canvas }
        let widthAtCanvasHeight = rescale(canvas.height, source.width, source.height)
        let heightAtCanvasWidth = rescale(canvas.width, source.height, source.width)
        return PixelSize(width: min(widthAtCanvasHeight, canvas.width),
                         height: min(heightAtCanvasWidth, canvas.height))
    }

    /// `av_rescale` with `AV_ROUND_NEAR_INF`: `(a·b + c/2) / c`, all integer.
    /// Doing it in Double instead would round 562.5 to 562 under the default
    /// banker's rounding, one pixel away from what ffmpeg picks.
    private nonisolated static func rescale(_ a: Int, _ b: Int, _ c: Int) -> Int {
        guard c != 0 else { return 0 }
        return (a * b + c / 2) / c
    }

    private nonisolated static func roundHalfAwayFromZero(_ x: Double) -> Int {
        Int(x.rounded(.toNearestOrAwayFromZero))
    }

    /// The picture half of one item's filter chain, from decoded frame to a
    /// canvas-sized `yuv420p` image.
    nonisolated static func geometryChain(for item: AssemblyItem,
                                          canvas: CanvasSpec) -> String {
        let W = canvas.width, H = canvas.height
        let scalerFlags = "flags=bicubic+accurate_rnd+bitexact:sws_dither=none"
        let delivery = canvas.deliveryPixelFormat

        // Without a probed frame size there is nothing to compute a fit from.
        // Hand the job back to ffmpeg's runtime expression — byte for byte what
        // every export did before geometry existed.
        guard item.sourceSize.isUsable else {
            return "scale=\(W):\(H):force_original_aspect_ratio=decrease:\(scalerFlags)," +
                   "format=yuv444p,pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2," +
                   "setsar=1,fps=\(canvas.fps),format=\(delivery)"
        }

        let placement = resolve(item.geometry, source: item.sourceSize, canvas: canvas)

        // Nothing of the picture reaches the canvas. Its scaled size may well be
        // larger than the canvas, so `pad` would reject it outright — go
        // straight to a canvas-sized frame and paint it out, keeping only the
        // segment's timing.
        guard !placement.isFullyOffCanvas else {
            return "scale=\(W):\(H):\(scalerFlags),setsar=1,fps=\(canvas.fps),format=\(delivery)," +
                   "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill"
        }

        var parts: [String] = []
        if let crop = placement.sourceCrop {
            // The editor's integer crop is exact even when a source happens to
            // decode as yuv411p/yuv410p, whose chroma grid is wider than 2px.
            // `exact=1` prevents crop from silently moving x/y or shrinking the
            // requested rectangle to that source format's subsampling factor.
            parts.append("crop=\(crop.width):\(crop.height):\(crop.x):\(crop.y):exact=1")
        }
        parts.append("scale=\(placement.scaledSize.width):\(placement.scaledSize.height):\(scalerFlags)")
        // A yuv420 frame cannot represent an odd crop origin or pad offset on
        // its subsampled chroma planes. crop/pad silently round such geometry
        // down, while CanvasStage quite correctly draws the requested integer
        // coordinate — producing a one-pixel preview/export drift. Compose on a
        // full-resolution chroma grid, then convert the even canvas back to the
        // delivery format only after every spatial operation is complete.
        let visible = placement.visibleCrop
        let canvasGridValues = [
            placement.scaledSize.width, placement.scaledSize.height,
            visible?.x ?? 0, visible?.y ?? 0,
            visible?.width ?? 0, visible?.height ?? 0,
            placement.padOrigin.x, placement.padOrigin.y,
        ]
        // Keep the ordinary all-even path free of a needless 4:2:0 → 4:4:4 →
        // 4:2:0 round trip. Full chroma is only required when one of the actual
        // canvas-grid operations needs to address an odd pixel coordinate — or
        // when the canvas itself is odd, where `pad` has an odd target and every
        // even-looking grid value would still land on a plane that cannot hold
        // it.
        if canvas.hasOddDimension || canvasGridValues.contains(where: { $0 % 2 != 0 }) {
            parts.append("format=yuv444p")
        }
        if let visible {
            parts.append("crop=\(visible.width):\(visible.height):\(visible.x):\(visible.y)")
        }
        parts.append("pad=\(W):\(H):\(placement.padOrigin.x):\(placement.padOrigin.y)")
        parts.append("setsar=1")
        parts.append("fps=\(canvas.fps)")
        parts.append("format=\(delivery)")
        return parts.joined(separator: ",")
    }

    // MARK: Export

    /// Build ffmpeg args to assemble several assets (videos + images) into one clip
    /// on a shared canvas, each clip's own audio under its picture (silence for
    /// images) and the audio track mixed over the lot. Re-encoded into the
    /// fixed, byte-repeatable-within-one-architecture output profile.
    ///
    /// A project whose track is empty and whose clips' sound is untouched
    /// produces the arguments it always did, filter for filter: every addition
    /// below is conditional on the thing it expresses, so the bytes of an old
    /// export are not moved by a feature it never used.
    nonisolated static func assembleArgs(items: [AssemblyItem], audioClips: [AssemblyAudio] = [],
                                         canvas: CanvasSpec, output: URL) -> [String] {
        let FPS = canvas.fps
        let normalizeAudio = "aresample=sample_rate=44100:out_chlayout=stereo:" +
                             "out_sample_fmt=fltp:internal_sample_fmt=s32p:" +
                             "dither_method=none:exact_rational=1"
        let audioSampleRate = 44_100.0
        let movieDuration = items.reduce(0) { $0 + $1.duration }
        let track = placedAudioClips(audioClips, movieDuration: movieDuration)

        // These values are part of the output format, not user preferences. In
        // particular, automatic filter and x264 thread counts change output bytes
        // when the same project is exported on machines with different core counts.
        // Disable FFmpeg's runtime SIMD dispatch too: the native AAC encoder can
        // otherwise choose CPU-feature-specific floating-point implementations.
        var args = ["-nostdin", "-y",
                    "-cpuflags", "0",
                    "-filter_threads", "1", "-filter_complex_threads", "1",
                    "-sws_flags", "bicubic+accurate_rnd+bitexact"]
        for it in items {
            if it.isImage {
                args += ["-framerate", FPS, "-loop", "1", "-t", fmt(it.duration),
                         "-fflags", "+bitexact", "-i", it.url.path]
            } else {
                args += ["-fflags", "+bitexact", "-i", it.url.path]
            }
        }
        // The track's files follow the clips, so a clip keeps the input index it
        // always had and an empty track changes nothing about the inputs.
        for clip in track { args += ["-fflags", "+bitexact", "-i", clip.url.path] }

        var f = ""
        for (i, it) in items.enumerated() {
            // Pad after `fit`: the black is generated at canvas size, in the
            // output pixel format, on the already-constant frame lattice, so its
            // length quantizes to whole output frames.
            let videoPad = it.padDuration > 1e-9
                ? ",tpad=stop_mode=add:stop_duration=\(fmt(it.padDuration)):color=black"
                : ""
            // Each item resolves its own crop/scale/placement, so this is no
            // longer one string shared by the whole graph.
            let fit = geometryChain(for: it, canvas: canvas)
            if it.isImage {
                f += "[\(i):v]\(fit),setpts=PTS-STARTPTS[v\(i)];"
            } else {
                f += "[\(i):v]trim=start_frame=\(it.trimStartFrame):end_frame=\(it.trimEndFrame),setpts=PTS-STARTPTS,\(fit)\(videoPad)[v\(i)];"
            }
            // The clip's own sound, or exact-length silence in its place. A
            // track turned off counts as absent: the same silence, the same bytes.
            let targetSamples = max(1, Int64(floor(it.duration * audioSampleRate + 1e-9)))
            if it.hasAudio && !it.isImage && it.audioGain > 0 {
                let sourceAudioStart = max(it.trimStart, it.audioStartTime)
                // Black appended to the picture raises the ceiling on real
                // audio by exactly its own length — otherwise the pad would
                // hold silence and preserve nothing.
                let audioCeiling = it.trimEnd + max(0, it.padDuration)
                let sourceAudioEnd = min(audioCeiling, it.audioEndTime ?? audioCeiling)
                if sourceAudioEnd > sourceAudioStart + 1e-9 {
                    // ffmpeg rebases each input by its container start when
                    // `-copyts` is absent. Trim in that input-local coordinate,
                    // then explicitly restore the audio track's offset from the
                    // selected video boundary as leading silence.
                    let localStart = sourceAudioStart - it.inputStartTime
                    let localEnd = sourceAudioEnd - it.inputStartTime
                    let leadDuration = max(0, sourceAudioStart - it.trimStart)
                    let leadSamples = max(0, Int64((leadDuration * audioSampleRate).rounded()))
                    f += "[\(i):a]atrim=start=\(fmt(localStart)):end=\(fmt(localEnd))," +
                         "asetpts=PTS-STARTPTS,\(normalizeAudio)"
                    if leadSamples > 0 {
                        // Sample units avoid adelay's millisecond default and
                        // preserve sub-millisecond source offsets.
                        f += ",adelay=\(leadSamples)S:all=1"
                    }
                    f += ",apad=whole_len=\(targetSamples)," +
                         "atrim=end_sample=\(targetSamples),asetpts=N/SR/TB" +
                         audioShaping(gain: it.audioGain, fadeIn: it.audioFadeIn,
                                      fadeOut: it.audioFadeOut, duration: it.duration) +
                         "[a\(i)];"
                } else {
                    // A real track wholly outside this video selection would
                    // produce an empty concat input. Supply an exact-length
                    // silent segment instead.
                    f += "anullsrc=channel_layout=stereo:sample_rate=44100," +
                         "atrim=end_sample=\(targetSamples),asetpts=N/SR/TB[a\(i)];"
                }
            } else {
                f += "anullsrc=channel_layout=stereo:sample_rate=44100," +
                     "atrim=end_sample=\(targetSamples),asetpts=N/SR/TB[a\(i)];"
            }
        }
        var concatIn = ""
        for i in 0..<items.count { concatIn += "[v\(i)][a\(i)]" }
        if track.isEmpty {
            f += "\(concatIn)concat=n=\(items.count):v=1:a=1[vout][aout]"
        } else {
            // The clips' sound as a bed, and every piece of the track laid over
            // it where it sits. `duration=first` ends the mix where the movie
            // ends, and `normalize=0` adds the inputs as they are: a bed stays
            // as loud as it was whether one effect lands on it or ten.
            f += "\(concatIn)concat=n=\(items.count):v=1:a=1[vout][abed];"
            var mixIn = "[abed]"
            for (k, clip) in track.enumerated() {
                f += trackSegment(clip, input: items.count + k, label: "t\(k)",
                                  normalize: normalizeAudio, sampleRate: audioSampleRate,
                                  movieDuration: movieDuration)
                mixIn += "[t\(k)]"
            }
            f += "\(mixIn)amix=inputs=\(track.count + 1):duration=first:normalize=0[aout]"
        }

        args += ["-filter_complex", f, "-map", "[vout]", "-map", "[aout]"]
        // 4:4:4 only for an odd canvas, which 4:2:0 cannot represent. It costs
        // hardware decoding and bitrate, so an even canvas never pays for it.
        args += ["-c:v", "libx264", "-preset", "medium",
                 "-crf", "18", "-pix_fmt", canvas.deliveryPixelFormat,
                 "-x264-params", "threads=1:lookahead-threads=1:deterministic=1:cpu-independent=1"]
        args += ["-c:a", "aac", "-b:a", "192k", "-aac_coder", "twoloop"]
        args += ["-map_metadata", "-1", "-map_chapters", "-1",
                 // `-fflags` is a per-file option: this occurrence deliberately
                 // sits after all inputs so it applies to the output muxer.
                 "-fflags", "+bitexact",
                 "-flags:v", "+bitexact", "-flags:a", "+bitexact",
                 "-movflags", "+faststart", output.path]
        return args
    }

    /// The track as the mixer will hear it. Clips that would contribute nothing
    /// are left out *before* they become inputs, and the rest are put in an
    /// order fixed by their content, so the same project adds the same floats
    /// in the same sequence however its clips happen to be arranged in memory.
    nonisolated static func placedAudioClips(_ clips: [AssemblyAudio],
                                             movieDuration: Double) -> [AssemblyAudio] {
        clips.filter { clip in
            clip.gain > 0 && clip.timelineStart < movieDuration - 1e-9
                && clip.heardRange(movieDuration: movieDuration) != nil
        }
        .sorted { a, b in
            if a.timelineStart != b.timelineStart { return a.timelineStart < b.timelineStart }
            if a.trimStart != b.trimStart { return a.trimStart < b.trimStart }
            return a.url.path < b.url.path
        }
    }

    /// One piece of the track: its sound cut, lengthened to exactly what the
    /// movie has room for, shaped, and then delayed to where it sits.
    private nonisolated static func trackSegment(_ clip: AssemblyAudio, input: Int, label: String,
                                                 normalize: String, sampleRate: Double,
                                                 movieDuration: Double) -> String {
        guard let range = clip.heardRange(movieDuration: movieDuration) else { return "" }
        let heard = clip.heardDuration(movieDuration: movieDuration)
        let targetSamples = max(1, Int64(floor(heard * sampleRate + 1e-9)))
        let localStart = range.start - clip.inputStartTime
        let localEnd = range.end - clip.inputStartTime
        let leadSamples = max(0, Int64(((range.start - clip.trimStart) * sampleRate).rounded()))
        var chain = "[\(input):a]atrim=start=\(fmt(localStart)):end=\(fmt(localEnd))," +
                    "asetpts=PTS-STARTPTS,\(normalize)"
        if leadSamples > 0 { chain += ",adelay=\(leadSamples)S:all=1" }
        chain += ",apad=whole_len=\(targetSamples),atrim=end_sample=\(targetSamples),asetpts=N/SR/TB"
        chain += audioShaping(gain: clip.gain, fadeIn: clip.fadeIn,
                              fadeOut: clip.fadeOut, duration: heard)
        // Placement last, after the length is fixed: the delay is part of the
        // movie's time, not of the clip's.
        let placeSamples = Int64((clip.timelineStart * sampleRate).rounded())
        if placeSamples > 0 { chain += ",adelay=\(placeSamples)S:all=1" }
        return chain + "[\(label)];"
    }

    /// Gain and fades for a segment whose timestamps already start at zero and
    /// whose length is already exactly `duration`. Nothing for a clip at unity
    /// with no fades, so an untouched clip's chain is the one it always had.
    private nonisolated static func audioShaping(gain: Double, fadeIn: Double,
                                                 fadeOut: Double, duration: Double) -> String {
        var chain = ""
        if gain != 1 { chain += ",volume=\(fmt(gain))" }
        if fadeIn > 0 {
            chain += ",afade=t=in:st=0:d=\(fmt(min(fadeIn, duration)))"
        }
        if fadeOut > 0 {
            let length = min(fadeOut, duration)
            chain += ",afade=t=out:st=\(fmt(duration - length)):d=\(fmt(length))"
        }
        return chain
    }

    nonisolated func exportAssembly(items: [AssemblyItem], audioClips: [AssemblyAudio],
                                    canvas: CanvasSpec, output: URL,
                                    onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportResult {
        // ffmpeg refuses to open an output path that is also one of its inputs
        // ("cannot edit existing files in-place"), which is exactly what happens
        // when a project is re-exported over one of its own source clips. Write a
        // sibling scratch file instead and swap it in once ffmpeg exits cleanly:
        // the sources stay readable for the whole run, and a failed or cancelled
        // export leaves whatever already sat at `output` untouched.
        let scratch = Self.scratchURL(besides: output)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var args = Self.assembleArgs(items: items, audioClips: audioClips, canvas: canvas,
                                     output: scratch)
        let outcome: ToolRun
        if let onProgress {
            // Stream machine-readable progress on stdout; stderr stays the log.
            args.insert(contentsOf: ["-progress", "pipe:1", "-stats_period", "0.2", "-nostats"], at: 1)
            let total = items.reduce(0) { $0 + $1.duration }
            outcome = try await Self.runReportingProgress(ffmpeg, args, totalDuration: total,
                                                          onProgress: onProgress)
        } else {
            outcome = try await Self.run(ffmpeg, args)
        }
        // A terminated ffmpeg exits nonzero; surface the cancellation instead
        // of a bogus export-failed error.
        try Task.checkCancellation()
        guard outcome.succeeded else {
            throw FFError.exportFailed(status: outcome.statusLabel, log: outcome.output)
        }
        try Self.install(scratch, at: output)
        let sha = try Self.sha256(of: output)
        // Report the command the user asked for, not the scratch path it ran under.
        let pretty = ([ffmpeg.lastPathComponent] +
                      args.map { $0 == scratch.path ? output.path : $0 }).joined(separator: " ")
        return ExportResult(outputURL: output, sha256: sha, command: pretty, log: outcome.output)
    }

    /// A hidden sibling of `output` — same directory, so installing it is a
    /// same-volume rename — keeping the `.mp4` extension ffmpeg muxes by.
    private nonisolated static func scratchURL(besides output: URL) -> URL {
        let base = output.deletingPathExtension().lastPathComponent
        let ext = output.pathExtension.isEmpty ? "mp4" : output.pathExtension
        return output.deletingLastPathComponent()
            .appendingPathComponent(".\(base).partial-\(UUID().uuidString).\(ext)")
    }

    /// Move `source` onto `destination`, replacing an existing file atomically.
    private nonisolated static func install(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    // MARK: - Helpers

    /// Format a time/duration with fixed precision so the argument string itself is stable.
    private nonisolated static func fmt(_ x: Double) -> String {
        String(format: "%.6f", x)
    }

    /// Stream timing after any container edit list has been applied.
    nonisolated static func streamTiming(
        _ stream: [String: Any]
    ) -> (start: Double, duration: Double, end: Double)? {
        guard let duration = finiteDouble(stream["duration"]), duration >= 0 else { return nil }
        let start = finiteDouble(stream["start_time"]) ?? 0
        return (start, duration, start + duration)
    }

    nonisolated static func finiteDouble(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let text as String: parsed = Double(text)
        case let number as NSNumber: parsed = number.doubleValue
        default: parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    /// Display size after ffmpeg's autorotation. Current ffprobe emits rotation
    /// in `side_data_list`; accept the legacy tag too for older containers.
    nonisolated static func displayDimensions(
        codedWidth: Int,
        codedHeight: Int,
        stream: [String: Any]
    ) -> (width: Int, height: Int) {
        displayDimensions(codedWidth: codedWidth, codedHeight: codedHeight,
                          metadataSources: [stream])
    }

    /// Prefer the first orientation source that actually carries a rotation.
    /// Still images commonly attach it to frame side data; movies normally put
    /// it on the stream display matrix.
    nonisolated static func displayDimensions(
        codedWidth: Int,
        codedHeight: Int,
        metadataSources: [[String: Any]]
    ) -> (width: Int, height: Int) {
        let rotation = metadataSources.lazy.compactMap { metadata -> Double? in
            let sideRotation = (metadata["side_data_list"] as? [[String: Any]])?
                .compactMap { finiteDouble($0["rotation"]) }
                .first
            let tagRotation = (metadata["tags"] as? [String: Any])
                .flatMap { finiteDouble($0["rotate"]) }
            return sideRotation ?? tagRotation
        }.first ?? 0
        // Work modulo 360 and tolerate the tiny decimal noise some matrices
        // produce. Only quarter turns swap the axes; 0/180 keep them.
        let normalized = ((rotation.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let isQuarterTurn = abs(normalized - 90) < 0.5 || abs(normalized - 270) < 0.5
        return isQuarterTurn
            ? (width: codedHeight, height: codedWidth)
            : (width: codedWidth, height: codedHeight)
    }

    private nonisolated static func parseRational(_ s: String?) -> Double? {
        guard let s, s != "0/0" else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
            return n / d
        }
        return Double(s)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)   // 1 MB
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Like `run`, but expects `-progress pipe:1` in the args: parses the key=value
    /// blocks ffmpeg writes to stdout and reports `out_time_us / totalDuration` as a
    /// 0...1 fraction. stderr is captured as the log.
    private nonisolated static func runReportingProgress(
        _ url: URL, _ args: [String], totalDuration: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ToolRun {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    proc.executableURL = url
                    proc.arguments = args
                    let progressPipe = Pipe()
                    let logPipe = Pipe()
                    proc.standardOutput = progressPipe
                    proc.standardError = logPipe
                    guard box.register(proc) else {
                        cont.resume(throwing: CancellationError())
                        return
                    }

                    let leftover = LineBuffer()
                    progressPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                        // Feed whole lines only; keep a partial trailing line for the next chunk.
                        let text = leftover.value + chunk
                        let lines = text.components(separatedBy: "\n")
                        leftover.value = lines.last ?? ""
                        for line in lines.dropLast() where line.hasPrefix("out_time_us=") {
                            if let us = Double(line.dropFirst("out_time_us=".count)), totalDuration > 0 {
                                onProgress(min(max(us / 1_000_000 / totalDuration, 0), 1))
                            }
                        }
                    }

                    do {
                        try proc.run()
                    } catch {
                        progressPipe.fileHandleForReading.readabilityHandler = nil
                        cont.resume(throwing: error)
                        return
                    }
                    let logData = logPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    progressPipe.fileHandleForReading.readabilityHandler = nil
                    if proc.terminationStatus == 0 { onProgress(1) }
                    cont.resume(returning: ToolRun(
                        status: proc.terminationStatus,
                        killedBySignal: proc.terminationReason == .uncaughtSignal,
                        output: String(data: logData, encoding: .utf8) ?? ""))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Run a binary off the main actor and capture combined stdout+stderr,
    /// alongside how it ended.
    private nonisolated static func run(_ url: URL, _ args: [String]) async throws -> ToolRun {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = url
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: ToolRun(
                    status: proc.terminationStatus,
                    killedBySignal: proc.terminationReason == .uncaughtSignal,
                    output: String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
