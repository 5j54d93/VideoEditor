//
//  Thumbnailer.swift
//  VideoEditor
//
//  Extracts still frames from the source for the timeline filmstrip cells.
//  Every decode batch owns its AVAssetImageGenerator. The actor only owns the
//  caches, so an await cannot let another request change a shared generator's
//  tolerance or cancel work belonging to another clip.
//
//  Live hover/scrub preview no longer decodes stills here — it chase-seeks a
//  dedicated AVPlayer instead (see ScrubPreview.swift).
//

import AVFoundation
import CoreGraphics

actor Thumbnailer {
    struct ExactRequest: Sendable {
        let frameIndex: Int
        let time: Double
    }

    /// One filmstrip tile. The caller clamps the tolerances so the decoded frame
    /// can only come from the span this tile represents — a loose decode snaps to
    /// keyframes, and x264 places keyframes on scene changes, so an unbounded
    /// tolerance would show the next scene (or frames the cut removed) instead of
    /// what is actually at this time.
    struct StripRequest: Sendable {
        let time: Double
        let toleranceBefore: Double
        let toleranceAfter: Double
    }

    private struct GenerationRequest: Sendable {
        let id: Int
        let time: CMTime
    }

    private struct StripCacheKey: Hashable {
        let nanoseconds: Int64
        let beforeTicks: Int64
        let afterTicks: Int64
    }

    private struct ToleranceKey: Hashable {
        let beforeTicks: Int64
        let afterTicks: Int64
    }

    private let url: URL
    private var cache: [Int64: CGImage] = [:]   // key: source time in nanoseconds
    private var filmstripCache: [StripCacheKey: CGImage] = [:]
    private let cacheLimit = 300
    private let filmstripCacheLimit = 480

    init(url: URL) {
        self.url = url
    }

    /// The exact frame at `time` (decodes from the preceding keyframe). Cached.
    func exactFrame(at time: Double) async -> CGImage? {
        await exactFrames([ExactRequest(frameIndex: 0, time: time)])[0]
    }

    /// The native-resolution frame used while placing a crop boundary. Unlike
    /// `exactFrame`, this deliberately has no thumbnail-size ceiling: enlarging
    /// a 480px preview cannot reveal detail that was discarded during decode.
    func fullResolutionFrame(at time: Double) async -> CGImage? {
        let generated = await Self.generate(
            url: url,
            requests: [GenerationRequest(id: 0, time: interiorFrameTime(time))],
            maximumSize: nil,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard !Task.isCancelled else { return nil }
        return generated[0]
    }

    /// Exact frames are submitted to AVFoundation as one source-time-ordered
    /// batch. Results are keyed by the requested time rather than arrival order,
    /// so a failed or out-of-order decode can never shift later frame cells.
    func exactFrames(_ requests: [ExactRequest]) async -> [Int: CGImage] {
        var output: [Int: CGImage] = [:]
        var misses: [(request: ExactRequest, cacheKey: Int64)] = []
        misses.reserveCapacity(requests.count)

        for request in requests {
            let key = Self.nanoseconds(request.time)
            if let cached = cache[key] {
                output[request.frameIndex] = cached
            } else {
                misses.append((request, key))
            }
        }

        misses.sort {
            if $0.request.time == $1.request.time {
                return $0.request.frameIndex < $1.request.frameIndex
            }
            return $0.request.time < $1.request.time
        }
        guard !misses.isEmpty, !Task.isCancelled else { return output }

        let generationRequests = misses.map {
            GenerationRequest(id: $0.request.frameIndex,
                              time: interiorFrameTime($0.request.time))
        }
        let generated = await Self.generate(
            url: url,
            requests: generationRequests,
            maximumSize: CGSize(width: 480, height: 480),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        for miss in misses {
            guard let image = generated[miss.request.frameIndex] else { continue }
            storeExact(image, forKey: miss.cacheKey)
            output[miss.request.frameIndex] = image
        }
        return output
    }

    private func storeExact(_ image: CGImage, forKey key: Int64) {
        if cache.count >= cacheLimit {
            // Evict a slice instead of everything so a hover sweep doesn't trigger
            // a wall of re-decodes right after the cache fills.
            for staleKey in Array(cache.keys.prefix(cacheLimit / 4)) {
                cache.removeValue(forKey: staleKey)
            }
        }
        cache[key] = image
    }

    /// Approximate filmstrip tiles. Requests with the same bounded tolerances
    /// share a generator batch. Failed requests retain their slot so later
    /// thumbnails never slide away from their actual time position.
    func filmstrip(_ requests: [StripRequest]) async -> [CGImage?] {
        var output = [CGImage?](repeating: nil, count: requests.count)
        var groups: [ToleranceKey: [GenerationRequest]] = [:]
        var cacheKeys: [Int: StripCacheKey] = [:]

        for (index, request) in requests.enumerated() {
            let beforeTicks = Self.toleranceTicks(request.toleranceBefore)
            let afterTicks = Self.toleranceTicks(request.toleranceAfter)
            let key = StripCacheKey(
                nanoseconds: Self.nanoseconds(request.time),
                beforeTicks: beforeTicks,
                afterTicks: afterTicks
            )
            if let cached = filmstripCache[key] {
                output[index] = cached
                continue
            }

            let tolerance = ToleranceKey(beforeTicks: beforeTicks, afterTicks: afterTicks)
            groups[tolerance, default: []].append(
                GenerationRequest(id: index, time: interiorFrameTime(request.time))
            )
            cacheKeys[index] = key
        }

        for (tolerance, unsortedRequests) in groups {
            guard !Task.isCancelled else { return [] }
            let sortedRequests = unsortedRequests.sorted {
                if $0.time == $1.time { return $0.id < $1.id }
                return $0.time < $1.time
            }
            let generated = await Self.generate(
                url: url,
                requests: sortedRequests,
                maximumSize: CGSize(width: 240, height: 240),
                toleranceBefore: CMTime(value: tolerance.beforeTicks, timescale: 600),
                toleranceAfter: CMTime(value: tolerance.afterTicks, timescale: 600)
            )
            guard !Task.isCancelled else { return [] }

            for (index, image) in generated {
                guard let key = cacheKeys[index] else { continue }
                storeFilmstrip(image, forKey: key)
                output[index] = image
            }
        }
        return output
    }

    private func storeFilmstrip(_ image: CGImage, forKey key: StripCacheKey) {
        if filmstripCache.count >= filmstripCacheLimit {
            for staleKey in Array(filmstripCache.keys.prefix(filmstripCacheLimit / 4)) {
                filmstripCache.removeValue(forKey: staleKey)
            }
        }
        filmstripCache[key] = image
    }

    /// The generator is deliberately local to this async operation. Its Images
    /// sequence owns cancellation for this batch, while other actor calls use
    /// independent instances and cannot race its mutable configuration.
    nonisolated private static func generate(
        url: URL,
        requests: [GenerationRequest],
        maximumSize: CGSize?,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime
    ) async -> [Int: CGImage] {
        guard !requests.isEmpty, !Task.isCancelled else { return [:] }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maximumSize { generator.maximumSize = maximumSize }
        generator.requestedTimeToleranceBefore = toleranceBefore
        generator.requestedTimeToleranceAfter = toleranceAfter

        var idsByTime: [Int64: [Int]] = [:]
        for request in requests {
            idsByTime[timeKey(request.time), default: []].append(request.id)
        }

        var output: [Int: CGImage] = [:]
        for await result in generator.images(for: requests.map(\.time)) {
            guard !Task.isCancelled else { break }
            guard case let .success(requestedTime, image, _) = result,
                  let ids = idsByTime[timeKey(requestedTime)] else { continue }
            for id in ids {
                output[id] = image
            }
        }
        return output
    }

    nonisolated private static func nanoseconds(_ seconds: Double) -> Int64 {
        Int64((max(0, seconds) * 1_000_000_000).rounded())
    }

    nonisolated private static func toleranceTicks(_ seconds: Double) -> Int64 {
        Int64((max(0, seconds) * 600).rounded())
    }

    nonisolated private static func timeKey(_ time: CMTime) -> Int64 {
        Int64((time.seconds * 1_000_000_000).rounded())
    }
}
