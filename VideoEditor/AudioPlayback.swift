//
//  AudioPlayback.swift
//  VideoEditor
//
//  The audio track in preview: one `AVPlayer` per clip, started and stopped as
//  the playhead crosses it.
//
//  Export places every sample exactly; this only has to sound right while
//  someone watches. On each tick of the picture's clock it compares where each
//  clip should be with where its player is: it starts the ones the playhead
//  has reached, stops the ones it has left, and re-seeks any that have
//  wandered — which happens whenever the picture jumps to another clip and
//  that clip's own player restarts from a seek.
//

import AVFoundation

@MainActor
final class AudioTrackPlayback {
    private var players: [AudioClip.ID: AVPlayer] = [:]
    private var running: Set<AudioClip.ID> = []
    /// Past this the ear notices the track and the picture coming apart.
    private let resyncTolerance = 0.12

    /// Bring every player into line with the playhead at `time`.
    func sync(clips: [AudioClip], at time: Double, playing: Bool, movieDuration: Double) {
        var present: Set<AudioClip.ID> = []
        for clip in clips {
            present.insert(clip.id)
            let offset = time - clip.timelineStart
            let audible = playing && clip.effectiveGain > 0
                && offset >= 0 && offset < clip.heardDuration(movieDuration: movieDuration)
            guard audible else { stop(clip.id); continue }

            let player = players[clip.id] ?? makePlayer(for: clip)
            let target = clip.inPoint + offset
            // The fade is approximated by moving the volume along it; the
            // export draws the same line with `afade`.
            player.volume = Float(clip.gain(at: offset, movieDuration: movieDuration))
            if !running.contains(clip.id) {
                seek(player, to: target)
                player.play()
                running.insert(clip.id)
            } else if abs(player.currentTime().seconds - target) > resyncTolerance {
                seek(player, to: target)
            }
        }
        for id in players.keys where !present.contains(id) { discard(id) }
    }

    func pauseAll() {
        for id in running { players[id]?.pause() }
        running.removeAll()
    }

    /// Drop the players of clips that no longer exist.
    func reconcile(keeping ids: Set<AudioClip.ID>) {
        for id in players.keys where !ids.contains(id) { discard(id) }
    }

    private func makePlayer(for clip: AudioClip) -> AVPlayer {
        let player = AVPlayer(url: clip.url)
        player.actionAtItemEnd = .pause
        // A local file never needs to buffer ahead; waiting would start the
        // sound late against a picture that is already moving.
        player.automaticallyWaitsToMinimizeStalling = false
        players[clip.id] = player
        return player
    }

    private func seek(_ player: AVPlayer, to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 44_100),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func stop(_ id: AudioClip.ID) {
        guard running.remove(id) != nil else { return }
        players[id]?.pause()
    }

    private func discard(_ id: AudioClip.ID) {
        stop(id)
        players[id]?.replaceCurrentItem(with: nil)
        players[id] = nil
    }
}
