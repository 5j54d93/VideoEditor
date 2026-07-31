//
//  FFTools.swift
//  VideoEditor
//
//  Wraps the system ffmpeg / ffprobe binaries. Every export path is built to be
//  byte-for-byte deterministic: the same source + same cut points always produce
//  a file with the same SHA-256, so re-uploading to Google Photos dedupes.
//
//  The determinism trick: `-fflags +bitexact -flags +bitexact -map_metadata -1`
//  strips the wall-clock creation_time, encoder version strings and random UUIDs
//  that normal editors (CapCut, default ffmpeg) embed on every export.
//

import Foundation
import CryptoKit

// MARK: - Probed media info

struct MediaInfo: Sendable {
    var duration: Double          // seconds
    var fps: Double               // nominal frame rate (fallback 30 if unknown)
    var fpsRational: String       // exact rate as ffmpeg rational, e.g. "21700/869"
    var width: Int
    var height: Int
    var audioCodec: String?
    var frameTimes: [Double]      // pts_time of every frame, ascending; [] if unavailable
}

// MARK: - Export configuration

enum ExportMode: String, CaseIterable, Sendable {
    case losslessCopy   // stream copy, start snapped to a keyframe — lossless, fast
    case reencode       // frame-accurate libx264 re-encode — exact frame, lossy
}

struct ExportSettings: Sendable {
    var mode: ExportMode = .losslessCopy
    var crf: Int = 18
    var preset: String = "medium"
    var strictSingleThread: Bool = false   // force x264 threads=1 for max reproducibility
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
private final class LineBuffer: @unchecked Sendable {
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
private final class ProcessBox: @unchecked Sendable {
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

        // Packet `pts_time` is printed by ffprobe with only six decimal places.
        // Preserve the integer PTS and apply the stream time base ourselves so
        // zero-tolerance preview seeks cannot fall on the preceding frame after
        // decimal/time-scale rounding.
        let videoTimeBase = Self.parseRational(v["time_base"] as? String)
        let frameTimes = (try? await framePacketTimes(url, timeBase: videoTimeBase)) ?? []

        return MediaInfo(duration: duration, fps: fps, fpsRational: fpsRational,
                         width: width, height: height,
                         audioCodec: aCodec, frameTimes: frameTimes)
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
    private nonisolated func framePacketTimes(_ url: URL,
                                              timeBase: Double?) async throws -> [Double] {
        guard let timeBase, timeBase.isFinite, timeBase > 0 else { return [] }
        let args = ["-v", "error", "-select_streams", "v:0",
                    "-show_entries", "packet=pts", "-of", "csv=p=0", url.path]
        let (code, out) = try await Self.run(ffprobe, args)
        guard code == 0 else { throw FFError.probeFailed(out) }
        var times: [Double] = []
        for line in out.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: CharacterSet(charactersIn: ", \r"))
            guard !text.isEmpty else { continue }
            guard let pts = Int64(text) else { return [] }
            times.append(Double(pts) * timeBase)
        }
        return times.sorted()
    }

    // MARK: Export

    /// Build ffmpeg args to assemble several assets (videos + images) into one clip
    /// on a shared canvas, with either a background-music track (overriding original
    /// audio) or each item's own audio (silence for images). Re-encoded, bitexact →
    /// byte-deterministic.
    static func assembleArgs(items: [AssemblyItem], audioURL: URL?, canvas: CanvasSpec,
                             output: URL, settings: ExportSettings) -> [String] {
        let W = canvas.width, H = canvas.height, FPS = canvas.fps
        let fit = "scale=\(W):\(H):force_original_aspect_ratio=decrease," +
                  "pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(FPS),format=yuv420p"
        let useOriginalAudio = (audioURL == nil)

        var args = ["-nostdin", "-y", "-fflags", "+bitexact"]
        for it in items {
            if it.isImage {
                args += ["-framerate", FPS, "-loop", "1", "-t", fmt(it.duration), "-i", it.url.path]
            } else {
                args += ["-i", it.url.path]
            }
        }
        let musicIndex = items.count
        if let audioURL { args += ["-i", audioURL.path] }

        var f = ""
        for (i, it) in items.enumerated() {
            if it.isImage {
                f += "[\(i):v]\(fit),setpts=PTS-STARTPTS[v\(i)];"
            } else {
                f += "[\(i):v]trim=start_frame=\(it.trimStartFrame):end_frame=\(it.trimEndFrame),setpts=PTS-STARTPTS,\(fit)[v\(i)];"
            }
            if useOriginalAudio {
                if it.hasAudio && !it.isImage {
                    f += "[\(i):a]atrim=start=\(fmt(it.trimStart)):end=\(fmt(it.trimEnd)),asetpts=PTS-STARTPTS,aresample=44100[a\(i)];"
                } else {
                    f += "anullsrc=channel_layout=stereo:sample_rate=44100,atrim=0:\(fmt(it.duration)),asetpts=PTS-STARTPTS[a\(i)];"
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
            f += "[\(musicIndex):a]aresample=44100,apad,atrim=0:\(fmt(total)),asetpts=PTS-STARTPTS[aout]"
        }

        args += ["-filter_complex", f, "-map", "[vout]", "-map", "[aout]"]
        args += ["-c:v", "libx264", "-preset", settings.preset,
                 "-crf", String(settings.crf), "-pix_fmt", "yuv420p"]
        if settings.strictSingleThread { args += ["-x264-params", "threads=1"] }
        args += ["-c:a", "aac", "-b:a", "192k"]
        args += ["-map_metadata", "-1", "-map_chapters", "-1",
                 "-flags", "+bitexact", "-movflags", "+faststart", output.path]
        return args
    }

    nonisolated func exportAssembly(items: [AssemblyItem], audioURL: URL?, canvas: CanvasSpec,
                                    output: URL, settings: ExportSettings,
                                    onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportResult {
        var args = Self.assembleArgs(items: items, audioURL: audioURL, canvas: canvas,
                                     output: output, settings: settings)
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
        let sha = try Self.sha256(of: output)
        let pretty = ([ffmpeg.lastPathComponent] + args).joined(separator: " ")
        return ExportResult(outputURL: output, sha256: sha, command: pretty, log: log)
    }

    // MARK: - Helpers

    /// Format a time/duration with fixed precision so the argument string itself is stable.
    private static func fmt(_ x: Double) -> String {
        String(format: "%.6f", x)
    }

    private static func parseRational(_ s: String?) -> Double? {
        guard let s, s != "0/0" else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
            return n / d
        }
        return Double(s)
    }

    static func sha256(of url: URL) throws -> String {
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
    private static func runReportingProgress(_ url: URL, _ args: [String], totalDuration: Double,
                                             onProgress: @escaping @Sendable (Double) -> Void)
        async throws -> (Int32, String) {
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
    private static func run(_ url: URL, _ args: [String]) async throws -> (Int32, String) {
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
