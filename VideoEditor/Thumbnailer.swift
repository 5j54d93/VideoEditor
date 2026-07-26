//
//  Thumbnailer.swift
//  VideoEditor
//
//  Extracts still frames from the source for the timeline filmstrip cells. Two
//  generators:
//   - `precise`: zero tolerance — exact cells when the timeline is zoomed to frames
//   - `fast`:    per-request bounded tolerance — quick approximate frames (for the
//                timeline filmstrip overview)
//
//  Live hover/scrub preview no longer decodes stills here — it chase-seeks a
//  dedicated AVPlayer instead (see ScrubPreview.swift).
//

import AVFoundation
import CoreGraphics

actor Thumbnailer {
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

    private struct StripCacheKey: Hashable {
        let milliseconds: Int64
        let beforeMilliseconds: Int64
        let afterMilliseconds: Int64
    }

    private let precise: AVAssetImageGenerator
    private let fast: AVAssetImageGenerator

    private var cache: [Int64: CGImage] = [:]   // key: milliseconds, precise frames only
    private var filmstripCache: [StripCacheKey: CGImage] = [:]
    private let cacheLimit = 300
    private let filmstripCacheLimit = 480

    init(url: URL) {
        let asset = AVURLAsset(url: url)

        precise = AVAssetImageGenerator(asset: asset)
        precise.appliesPreferredTrackTransform = true
        precise.requestedTimeToleranceBefore = .zero
        precise.requestedTimeToleranceAfter = .zero
        precise.maximumSize = CGSize(width: 480, height: 480)

        fast = AVAssetImageGenerator(asset: asset)
        fast.appliesPreferredTrackTransform = true
        // Tolerances are set per request from the StripRequest bounds.
        fast.maximumSize = CGSize(width: 240, height: 240)
    }

    /// The exact frame at `time` (decodes from the preceding keyframe). Cached.
    func exactFrame(at time: Double) async -> CGImage? {
        let key = Int64((time * 1000).rounded())
        if let hit = cache[key] { return hit }
        let t = interiorFrameTime(time)
        guard let (img, _) = try? await precise.image(at: t) else { return nil }
        storeExact(img, forKey: key)
        return img
    }

    private func storeExact(_ img: CGImage, forKey key: Int64) {
        if cache.count >= cacheLimit {
            // Evict a slice instead of everything so a hover sweep doesn't trigger
            // a wall of re-decodes right after the cache fills.
            for staleKey in cache.keys.prefix(cacheLimit / 4) {
                cache.removeValue(forKey: staleKey)
            }
        }
        cache[key] = img
    }

    /// Approximate filmstrip tiles. Failed requests retain their slot so later
    /// thumbnails never slide away from their actual time position.
    func filmstrip(_ requests: [StripRequest]) async -> [CGImage?] {
        var out: [CGImage?] = []
        out.reserveCapacity(requests.count)
        for r in requests {
            guard !Task.isCancelled else { return [] }
            let key = StripCacheKey(
                milliseconds: Int64((r.time * 1000).rounded()),
                beforeMilliseconds: Int64((max(0, r.toleranceBefore) * 1000).rounded()),
                afterMilliseconds: Int64((max(0, r.toleranceAfter) * 1000).rounded())
            )
            if let cached = filmstripCache[key] {
                out.append(cached)
                continue
            }
            fast.requestedTimeToleranceBefore =
                CMTime(seconds: max(0, r.toleranceBefore), preferredTimescale: 600)
            fast.requestedTimeToleranceAfter =
                CMTime(seconds: max(0, r.toleranceAfter), preferredTimescale: 600)
            let ct = interiorFrameTime(r.time)
            if let image = try? await fast.image(at: ct).image {
                if filmstripCache.count >= filmstripCacheLimit {
                    for staleKey in filmstripCache.keys.prefix(filmstripCacheLimit / 4) {
                        filmstripCache.removeValue(forKey: staleKey)
                    }
                }
                filmstripCache[key] = image
                out.append(image)
            } else {
                out.append(nil)
            }
        }
        return out
    }
}
