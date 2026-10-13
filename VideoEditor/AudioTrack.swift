//
//  AudioTrack.swift
//  VideoEditor
//
//  The audio track's two view-side helpers: which lane each clip sits in, and
//  the waveform drawn on it. Neither needs the model, and the lane arithmetic
//  is kept out of the view so it can be asserted without a window.
//

import AVFoundation
import Foundation

// MARK: - Lanes

/// Where each audio clip sits vertically.
///
/// Clips on the track may overlap — a bed of music with an effect dropped on
/// it is the ordinary case, not the exception — and two overlapping bars drawn
/// in one lane would hide each other's edges, which are the very things a trim
/// grabs. So lanes are assigned here, not chosen by hand: earliest clip first,
/// each taking the topmost lane that is free when it starts. There is no lane
/// to manage and nothing to drag between; the track is simply as tall as it
/// needs to be.
struct AudioTrackLayout {
    struct Entry: Identifiable {
        let clip: AudioClip
        let lane: Int
        var id: AudioClip.ID { clip.id }
    }

    let entries: [Entry]
    let laneCount: Int

    init(clips: [AudioClip]) {
        // Earliest first; among clips starting together the longer one goes
        // up, so a bed keeps the top lane and the effect on it goes below.
        let ordered = clips.sorted { a, b in
            if a.timelineStart != b.timelineStart { return a.timelineStart < b.timelineStart }
            if a.duration != b.duration { return a.duration > b.duration }
            return a.id.uuidString < b.id.uuidString
        }
        var laneEnds: [Double] = []
        var entries: [Entry] = []
        entries.reserveCapacity(clips.count)
        for clip in ordered {
            let lane = laneEnds.firstIndex { $0 <= clip.timelineStart + 1e-9 } ?? laneEnds.count
            if lane == laneEnds.count {
                laneEnds.append(clip.timelineEnd)
            } else {
                laneEnds[lane] = clip.timelineEnd
            }
            entries.append(Entry(clip: clip, lane: lane))
        }
        self.entries = entries
        laneCount = laneEnds.count
    }

    func lane(of id: AudioClip.ID) -> Int? {
        entries.first { $0.id == id }?.lane
    }

    /// The clip under a point, or `nil` on bare track.
    func clip(at time: Double, lane: Int?) -> AudioClip? {
        guard let lane else { return nil }
        return entries.first {
            $0.lane == lane && time >= $0.clip.timelineStart && time < $0.clip.timelineEnd
        }?.clip
    }

    /// Every clip a marquee touches: its span crosses the time range and its
    /// lane lies within the lanes the rectangle covers.
    func clips(in times: ClosedRange<Double>, lanes: ClosedRange<Int>) -> Set<AudioClip.ID> {
        Set(entries.lazy.filter { entry in
            lanes.contains(entry.lane)
                && entry.clip.timelineStart <= times.upperBound
                && entry.clip.timelineEnd >= times.lowerBound
        }.map(\.id))
    }

    /// Moments a dragged clip may snap to: the movie's start, every cut in the
    /// picture, and the ends of every other piece of sound.
    func snapTimes(excluding id: AudioClip.ID, clipBoundaries: [Double]) -> [Double] {
        var times = clipBoundaries
        for entry in entries where entry.id != id {
            times.append(entry.clip.timelineStart)
            times.append(entry.clip.timelineEnd)
        }
        return times
    }
}

// MARK: - Waveform

/// A file's loudness over time, coarse enough to draw and small enough to keep:
/// the loudest sample in each hundredth of a second.
struct AudioPeaks: Sendable {
    let perSecond: Double
    let values: [Float]

    /// The loudest moment between two source times. A pixel column of a clip
    /// covers several buckets at low zoom and a fraction of one at high zoom;
    /// either way this is the height the column should have.
    func peak(from start: Double, to end: Double) -> Float {
        guard !values.isEmpty, end > start else { return 0 }
        let first = max(0, Int(floor(start * perSecond)))
        let last = min(values.count - 1, Int(ceil(end * perSecond)) - 1)
        guard first <= last else { return 0 }
        var loudest: Float = 0
        for index in first...last { loudest = max(loudest, values[index]) }
        return loudest
    }
}

/// Reads each file's peaks once, off the main thread, and keeps them.
///
/// Decoding a whole song to draw it is a real cost — a few seconds of CPU for
/// a long one — which is why it is paid once per file rather than once per
/// clip, and why a second clip of the same file that arrives while the first
/// is still reading waits for that read instead of starting its own.
actor AudioWaveformStore {
    static let shared = AudioWaveformStore()

    /// Buckets per second of source. 100 puts one bucket per point at 100
    /// points per second of timeline, the fine end of ordinary editing zoom.
    static let bucketsPerSecond = 100.0

    private var cache: [URL: AudioPeaks] = [:]
    private var inFlight: [URL: Task<AudioPeaks?, Never>] = [:]

    func peaks(for url: URL) async -> AudioPeaks? {
        if let known = cache[url] { return known }
        if let reading = inFlight[url] { return await reading.value }
        let reading = Task.detached(priority: .utility) {
            await Self.read(url, bucketsPerSecond: Self.bucketsPerSecond)
        }
        inFlight[url] = reading
        let result = await reading.value
        inFlight[url] = nil
        if let result { cache[url] = result }
        return result
    }

    /// Decode the first audio track to mono 16-bit PCM and keep the loudest
    /// sample of each bucket. Mono is enough: the drawing is one band, and the
    /// louder channel is what the eye would read off a pair anyway.
    nonisolated private static func read(_ url: URL, bucketsPerSecond: Double) async -> AudioPeaks? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return nil }
        let buffers = reader.outputProvider(for: output)
        do { try reader.start() } catch { return nil }

        var values: [Float] = []
        var samplesPerBucket = 0
        var filled = 0           // samples already counted into the open bucket
        var loudest: Int16 = 0   // of the open bucket
        var scratch: [Int16] = []

        // A read that fails part-way ends the loop just as the last buffer
        // does; the reader's status below is what tells the two apart.
        while let buffer = try? await buffers.next() {
            if samplesPerBucket == 0,
               let description = buffer.formatDescription,
               let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                samplesPerBucket = max(1, Int(stream.pointee.mSampleRate / bucketsPerSecond))
            }
            guard samplesPerBucket > 0, case .dataBuffer(let block) = buffer.content else { continue }
            let count = block.count / MemoryLayout<Int16>.size
            guard count > 0 else { continue }
            if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
            _ = scratch.withUnsafeMutableBytes { bytes in
                block.copyBytes(to: bytes, count: count * MemoryLayout<Int16>.size)
            }
            for index in 0..<count {
                let sample = scratch[index]
                let magnitude = sample == .min ? Int16.max : abs(sample)
                if magnitude > loudest { loudest = magnitude }
                filled += 1
                if filled == samplesPerBucket {
                    values.append(Float(loudest) / Float(Int16.max))
                    loudest = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { values.append(Float(loudest) / Float(Int16.max)) }
        guard reader.status == .completed, !values.isEmpty else { return nil }
        return AudioPeaks(perSecond: bucketsPerSecond, values: values)
    }
}
