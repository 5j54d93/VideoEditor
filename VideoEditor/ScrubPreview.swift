//
//  ScrubPreview.swift
//  VideoEditor
//
//  Real-time scrub preview. Instead of decoding a still per pointer position
//  (AVAssetImageGenerator re-walks a whole GOP each time and trails the pointer
//  by one decode), a dedicated muted AVPlayer is chase-seeked. Hover locations
//  are already quantized onto the source frame grid, so this player requests one
//  exact frame per changed target and coalesces faster pointer updates.
//
//  This player is entirely separate from the committed playback player, so
//  hovering never moves the timeline playhead or selection.
//

import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class ScrubPreviewPlayer {
    let player: AVPlayer = {
        let p = AVPlayer()
        p.actionAtItemEnd = .pause
        p.isMuted = true
        p.volume = 0
        // Scrubbing only ever seeks a paused player; don't let it defer seeks
        // waiting for buffer to build up.
        p.automaticallyWaitsToMinimizeStalling = false
        return p
    }()

    private var assets: [URL: AVURLAsset] = [:]
    private var currentURL: URL?

    // Chase-seek state. Only one seek is ever in flight; a newer target replaces
    // the pending one, so a fast sweep never queues a backlog of seeks. The
    // generation counter is what detects "a newer target arrived mid-seek".
    private var isSeeking = false
    private var requestedGeneration = 0
    private var chaseTime: CMTime = .invalid
    private var lastRequestedTime: CMTime = .invalid
    private var sourceGeneration = 0

    private var readyRetryTask: Task<Void, Never>?

    /// Point the scrub player at a source. A no-op when it is already loaded, so
    /// scrubbing within one clip never reloads the item (and never re-fades).
    func prepare(url: URL) {
        guard currentURL != url else { return }
        sourceGeneration &+= 1
        player.currentItem?.cancelPendingSeeks()
        currentURL = url
        readyRetryTask?.cancel(); readyRetryTask = nil
        isSeeking = false
        chaseTime = .invalid
        lastRequestedTime = .invalid
        let asset = assets[url] ?? {
            let a = AVURLAsset(url: url)
            assets[url] = a
            return a
        }()
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    }

    /// Follow the pointer with one exact request per snapped source frame.
    /// `onContinuousHover` can fire many times while the pointer remains in the
    /// same frame cell; deduping here prevents those callbacks from repeatedly
    /// repainting a paused player.
    func scrub(to sourceTime: Double) {
        let time = interiorFrameTime(sourceTime)
        guard !lastRequestedTime.isValid || CMTimeCompare(lastRequestedTime, time) != 0 else {
            return
        }
        lastRequestedTime = time
        seek(to: time)
    }

    /// Stop following. The last frame stays on screen, so the overlay can fade
    /// out over the committed preview without a black flash.
    func end() {
        readyRetryTask?.cancel()
        readyRetryTask = nil
        // Re-entering the timeline should issue a fresh request even if the
        // pointer returns to the same cell before a previously pending seek ran.
        lastRequestedTime = .invalid
    }

    /// Drop a cached source (its file was re-imported/removed). The item reloads
    /// on the next hover.
    func invalidate(url: URL) {
        assets.removeValue(forKey: url)
        guard currentURL == url else { return }
        clearCurrentSource()
    }

    /// Keep the scrub cache bounded by sources the current project can still
    /// reference. Undo may restore an evicted URL later; preparing it again is
    /// cheaper and safer than retaining every asset opened during the app's life.
    func reconcile(keeping urls: Set<URL>) {
        let staleURLs = assets.keys.filter { !urls.contains($0) }
        for url in staleURLs { assets.removeValue(forKey: url) }
        guard let currentURL, !urls.contains(currentURL) else { return }
        clearCurrentSource()
    }

    private func clearCurrentSource() {
        sourceGeneration &+= 1
        player.currentItem?.cancelPendingSeeks()
        currentURL = nil
        readyRetryTask?.cancel(); readyRetryTask = nil
        isSeeking = false
        chaseTime = .invalid
        lastRequestedTime = .invalid
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Chase-seek core

    private func seek(to time: CMTime) {
        chaseTime = time
        requestedGeneration &+= 1
        if !isSeeking { startSeek() }
    }

    private func startSeek() {
        guard chaseTime.isValid else { return }
        guard let item = player.currentItem, item.status == .readyToPlay else {
            scheduleReadyRetry()
            return
        }
        isSeeking = true
        let generation = requestedGeneration
        let source = sourceGeneration
        player.seek(to: chaseTime, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            // AVPlayer calls this on an arbitrary queue; hop back to the main actor.
            guard let owner = self else { return }
            Task { @MainActor in
                guard owner.sourceGeneration == source,
                      owner.player.currentItem === item else { return }
                owner.isSeeking = false
                if owner.requestedGeneration != generation { owner.startSeek() }
            }
        }
    }

    /// A freshly replaced item needs a moment to become `.readyToPlay`. Poll
    /// briefly, then fire the pending seek. Cancelled when a new source loads.
    private func scheduleReadyRetry() {
        guard readyRetryTask == nil else { return }
        let source = sourceGeneration
        readyRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(30))
                } catch {
                    return
                }
                guard let self, self.sourceGeneration == source else { return }
                guard let item = self.player.currentItem else { self.readyRetryTask = nil; return }
                switch item.status {
                case .readyToPlay:
                    self.readyRetryTask = nil
                    if !self.isSeeking { self.startSeek() }
                    return
                case .failed:
                    self.readyRetryTask = nil
                    return
                default:
                    continue
                }
            }
        }
    }
}

/// Hosts the scrub player's `AVPlayerLayer` and fades it in only once it has a
/// frame to show. While a freshly-loaded item is still decoding, the layer is
/// transparent so the committed preview shows through instead of a black flash.
struct ScrubPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    /// `.resize` when the caller has already sized this view to the picture's
    /// exact aspect — inside the canvas stage, letting the layer letterbox again
    /// would inset the frame within its own placement.
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> ScrubPlayerNSView {
        ScrubPlayerNSView(player: player, videoGravity: videoGravity)
    }

    func updateNSView(_ view: ScrubPlayerNSView, context: Context) {
        view.setPlayer(player)
        view.setVideoGravity(videoGravity)
    }
}

final class ScrubPlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?

    init(player: AVPlayer, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.opacity = 0                        // fades in when the frame is ready
        playerLayer.videoGravity = videoGravity
        playerLayer.player = player
        layer?.addSublayer(playerLayer)
        observeReadiness()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPlayer(_ player: AVPlayer) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
        observeReadiness()
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        guard playerLayer.videoGravity != gravity else { return }
        playerLayer.videoGravity = gravity
    }

    private func observeReadiness() {
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self] layer, change in
            let ready = change.newValue ?? layer.isReadyForDisplay
            DispatchQueue.main.async {
                guard let root = self?.layer else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(ready ? 0.1 : 0)
                root.opacity = ready ? 1 : 0
                CATransaction.commit()
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
