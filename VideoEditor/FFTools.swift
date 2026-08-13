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
}

/// The shared output canvas everything is scaled/padded into.
struct CanvasSpec: Sendable {
    var width: Int
    var height: Int
    var fps: String      // exact frame rate as an ffmpeg rational/number, e.g. "21700/869"
    var fpsValue: Double // numeric value of `fps`, for display and duration math
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

enum FFError: LocalizedError {
    case notFound
    case probeFailed(String)
    case exportFailed(code: Int32, log: String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "App 內附的 ffmpeg / ffprobe 遺失或無法執行。請重新下載或安裝 VideoEditor。"
        case .probeFailed(let msg):
            return "無法讀取影片資訊：\(msg)"
        case .exportFailed(let code, let log):
            return "輸出失敗（code \(code)）：\n\(log)"
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

    nonisolated func probe(_ url: URL) async throws -> MediaInfo {
        let args = ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path]
        let (code, out) = try await Self.run(ffprobe, args)
        guard code == 0, let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FFError.probeFailed(out)
        }

        let streams = (root["streams"] as? [[String: Any]]) ?? []
        let format = (root["format"] as? [String: Any]) ?? [:]

        guard let v = streams.first(where: { ($0["codec_type"] as? String) == "video" }) else {
            throw FFError.probeFailed("找不到影像串流")
        }
        let a = streams.first(where: { ($0["codec_type"] as? String) == "audio" })

        let width = (v["width"] as? Int) ?? 0
        let height = (v["height"] as? Int) ?? 0
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
                         width: width, height: height,
                         audioCodec: aCodec,
                         audioStartTime: audioStartTime,
                         audioDuration: audioDuration,
                         frameTimes: framePackets.times)
    }

    /// Just the pixel dimensions of the first video stream (used for still images).
    nonisolated func probeDimensions(_ url: URL) async throws -> (w: Int, h: Int) {
        let args = ["-v", "error", "-select_streams", "v:0",
                    "-show_entries", "stream=width,height", "-of", "json", url.path]
        let (code, out) = try await Self.run(ffprobe, args)
        guard code == 0, let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = (root["streams"] as? [[String: Any]])?.first else {
            throw FFError.probeFailed(out)
        }
        return ((s["width"] as? Int) ?? 0, (s["height"] as? Int) ?? 0)
    }

    /// Container duration in seconds (used for audio files).
    nonisolated func probeDuration(_ url: URL) async throws -> Double {
        let args = ["-v", "error", "-show_entries", "format=duration", "-of", "json", url.path]
        let (code, out) = try await Self.run(ffprobe, args)
        guard code == 0, let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FFError.probeFailed(out)
        }
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
        let (code, out) = try await Self.run(ffprobe, args)
        guard code == 0 else { throw FFError.probeFailed(out) }
        return Self.parseFramePackets(out, timeBase: timeBase)
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

    // MARK: Export

    /// Build ffmpeg args to assemble several assets (videos + images) into one clip
    /// on a shared canvas, with either a background-music track (overriding original
    /// audio) or each item's own audio (silence for images). Re-encoded into the
    /// fixed, byte-repeatable-within-one-architecture output profile.
    nonisolated static func assembleArgs(items: [AssemblyItem], audioURL: URL?, canvas: CanvasSpec,
                                         output: URL) -> [String] {
        let W = canvas.width, H = canvas.height, FPS = canvas.fps
        let fit = "scale=\(W):\(H):force_original_aspect_ratio=decrease:" +
                  "flags=bicubic+accurate_rnd+bitexact:sws_dither=none," +
                  "pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(FPS),format=yuv420p"
        let normalizeAudio = "aresample=sample_rate=44100:out_chlayout=stereo:" +
                             "out_sample_fmt=fltp:internal_sample_fmt=s32p:" +
                             "dither_method=none:exact_rational=1"
        let audioSampleRate = 44_100.0
        let useOriginalAudio = (audioURL == nil)

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
        let musicIndex = items.count
        if let audioURL { args += ["-fflags", "+bitexact", "-i", audioURL.path] }

        var f = ""
        for (i, it) in items.enumerated() {
            // Pad after `fit`: the black is generated at canvas size, in the
            // output pixel format, on the already-constant frame lattice, so its
            // length quantizes to whole output frames.
            let videoPad = it.padDuration > 1e-9
                ? ",tpad=stop_mode=add:stop_duration=\(fmt(it.padDuration)):color=black"
                : ""
            if it.isImage {
                f += "[\(i):v]\(fit),setpts=PTS-STARTPTS[v\(i)];"
            } else {
                f += "[\(i):v]trim=start_frame=\(it.trimStartFrame):end_frame=\(it.trimEndFrame),setpts=PTS-STARTPTS,\(fit)\(videoPad)[v\(i)];"
            }
            if useOriginalAudio {
                if it.hasAudio && !it.isImage {
                    let sourceAudioStart = max(it.trimStart, it.audioStartTime)
                    // Black appended to the picture raises the ceiling on real
                    // audio by exactly its own length — otherwise the pad would
                    // hold silence and preserve nothing.
                    let audioCeiling = it.trimEnd + max(0, it.padDuration)
                    let sourceAudioEnd = min(audioCeiling, it.audioEndTime ?? audioCeiling)
                    let targetSamples = max(1, Int64(floor(it.duration * audioSampleRate + 1e-9)))
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
                             "atrim=end_sample=\(targetSamples),asetpts=N/SR/TB[a\(i)];"
                    } else {
                        // A real track wholly outside this video selection would
                        // produce an empty concat input. Supply an exact-length
                        // silent segment instead.
                        f += "anullsrc=channel_layout=stereo:sample_rate=44100," +
                             "atrim=end_sample=\(targetSamples),asetpts=N/SR/TB[a\(i)];"
                    }
                } else {
                    let targetSamples = max(1, Int64(floor(it.duration * audioSampleRate + 1e-9)))
                    f += "anullsrc=channel_layout=stereo:sample_rate=44100," +
                         "atrim=end_sample=\(targetSamples),asetpts=N/SR/TB[a\(i)];"
                }
            }
        }
        var concatIn = ""
        for i in 0..<items.count {
            concatIn += "[v\(i)]"
            if useOriginalAudio { concatIn += "[a\(i)]" }
        }
        if useOriginalAudio {
            f += "\(concatIn)concat=n=\(items.count):v=1:a=1[vout][aout]"
        } else {
            let total = items.reduce(0) { $0 + $1.duration }
            f += "\(concatIn)concat=n=\(items.count):v=1:a=0[vout];"
            f += "[\(musicIndex):a]\(normalizeAudio),apad,atrim=0:\(fmt(total)),asetpts=PTS-STARTPTS[aout]"
        }

        args += ["-filter_complex", f, "-map", "[vout]", "-map", "[aout]"]
        args += ["-c:v", "libx264", "-preset", "medium",
                 "-crf", "18", "-pix_fmt", "yuv420p",
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

    nonisolated func exportAssembly(items: [AssemblyItem], audioURL: URL?, canvas: CanvasSpec,
                                    output: URL,
                                    onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportResult {
        // ffmpeg refuses to open an output path that is also one of its inputs
        // ("cannot edit existing files in-place"), which is exactly what happens
        // when a project is re-exported over one of its own source clips. Write a
        // sibling scratch file instead and swap it in once ffmpeg exits cleanly:
        // the sources stay readable for the whole run, and a failed or cancelled
        // export leaves whatever already sat at `output` untouched.
        let scratch = Self.scratchURL(besides: output)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var args = Self.assembleArgs(items: items, audioURL: audioURL, canvas: canvas,
                                     output: scratch)
        let code: Int32, log: String
        if let onProgress {
            // Stream machine-readable progress on stdout; stderr stays the log.
            args.insert(contentsOf: ["-progress", "pipe:1", "-stats_period", "0.2", "-nostats"], at: 1)
            let total = items.reduce(0) { $0 + $1.duration }
            (code, log) = try await Self.runReportingProgress(ffmpeg, args, totalDuration: total,
                                                              onProgress: onProgress)
        } else {
            (code, log) = try await Self.run(ffmpeg, args)
        }
        // A terminated ffmpeg exits nonzero; surface the cancellation instead
        // of a bogus export-failed error.
        try Task.checkCancellation()
        guard code == 0 else { throw FFError.exportFailed(code: code, log: log) }
        try Self.install(scratch, at: output)
        let sha = try Self.sha256(of: output)
        // Report the command the user asked for, not the scratch path it ran under.
        let pretty = ([ffmpeg.lastPathComponent] +
                      args.map { $0 == scratch.path ? output.path : $0 }).joined(separator: " ")
        return ExportResult(outputURL: output, sha256: sha, command: pretty, log: log)
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
    ) async throws -> (Int32, String) {
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
                    let text = String(data: logData, encoding: .utf8) ?? ""
                    cont.resume(returning: (proc.terminationStatus, text))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Run a binary off the main actor and capture combined stdout+stderr.
    private nonisolated static func run(_ url: URL, _ args: [String]) async throws -> (Int32, String) {
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
                let text = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus, text))
            }
        }
    }
}
