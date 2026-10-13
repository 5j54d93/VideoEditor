import Foundation
import XCTest
@testable import VideoEditor

/// The audio track's arithmetic: where clips sit, how loud a moment is, and
/// what a waveform column shows. None of it needs a window.
@MainActor
final class AudioTrackTests: XCTestCase {

    private func clip(_ start: Double, _ length: Double) -> AudioClip {
        AudioClip(url: URL(fileURLWithPath: "/fixtures/a.m4a"), audioEndTime: 100,
                  inPoint: 0, outPoint: length, timelineStart: start)
    }

    /// Overlapping sound goes to a new lane; sound that merely touches the end
    /// of another shares its lane. The order the clips arrive in is not the
    /// order they are laid out in.
    func testOverlappingSoundTakesANewLaneAndTouchingSoundDoesNot() {
        let bed = clip(0, 10), effect = clip(2, 1), another = clip(2.5, 1), next = clip(10, 5)

        let layout = AudioTrackLayout(clips: [another, next, effect, bed])

        XCTAssertEqual(layout.laneCount, 3)
        XCTAssertEqual(layout.lane(of: bed.id), 0)
        XCTAssertEqual(layout.lane(of: next.id), 0, "Starting where another ends shares its lane")
        XCTAssertEqual(layout.lane(of: effect.id), 1)
        XCTAssertEqual(layout.lane(of: another.id), 2)
        XCTAssertEqual(layout.clip(at: 2.2, lane: 1)?.id, effect.id)
        XCTAssertNil(layout.clip(at: 2.2, lane: nil), "Between lanes is bare track")
        XCTAssertEqual(layout.clips(in: 2.6...2.7, lanes: 0...2), [bed.id, effect.id, another.id])
        XCTAssertEqual(layout.clips(in: 2.6...2.7, lanes: 1...1), [effect.id])
    }

    /// The level along a clip, as the preview approximates it and the export
    /// draws it: straight lines in and out, the gain in between.
    func testGainFollowsTheFadesAsStraightLines() {
        XCTAssertEqual(audioGain(at: 0, duration: 10, gain: 1, fadeIn: 2, fadeOut: 0), 0)
        XCTAssertEqual(audioGain(at: 1, duration: 10, gain: 1, fadeIn: 2, fadeOut: 0), 0.5,
                       accuracy: 1e-12)
        XCTAssertEqual(audioGain(at: 5, duration: 10, gain: 0.8, fadeIn: 2, fadeOut: 4), 0.8,
                       accuracy: 1e-12)
        XCTAssertEqual(audioGain(at: 9, duration: 10, gain: 0.8, fadeIn: 2, fadeOut: 4), 0.2,
                       accuracy: 1e-12)
        XCTAssertEqual(audioGain(at: 5, duration: 10, gain: 0, fadeIn: 0, fadeOut: 0), 0)
        XCTAssertEqual(audioGain(at: 20, duration: 10, gain: 1, fadeIn: 0, fadeOut: 4), 0,
                       "Past the end there is nothing to hear")
    }

    /// A clip's own level is read against what the movie has room for, so a
    /// fade-out on a piece that outruns the picture happens where the picture
    /// ends — the same curve the export writes.
    func testAClipFadesIntoTheMovieEndWhenItOutrunsIt() {
        var long = clip(1, 30)
        long.fadeOut = 1
        XCTAssertEqual(long.heardDuration(movieDuration: 4), 3, accuracy: 1e-12)
        XCTAssertEqual(long.gain(at: 1.5, movieDuration: 4), 1, accuracy: 1e-12)
        XCTAssertEqual(long.gain(at: 2.5, movieDuration: 4), 0.5, accuracy: 1e-12)
        XCTAssertEqual(long.gain(at: 3.5, movieDuration: 4), 0, "Past the last frame there is nothing")
        XCTAssertEqual(long.gain(at: 2.5, movieDuration: 60), 1, accuracy: 1e-12,
                       "With room to spare the fade waits for the clip's own end")
    }

    /// A column of the waveform is as tall as the loudest bucket under it.
    func testPeaksReportTheLoudestBucketUnderAColumn() {
        let peaks = AudioPeaks(perSecond: 100, values: [0.1, 0.9, 0.2, 0.3])
        XCTAssertEqual(peaks.peak(from: 0, to: 0.02), 0.9)
        XCTAssertEqual(peaks.peak(from: 0.02, to: 0.04), 0.3)
        XCTAssertEqual(peaks.peak(from: 1, to: 2), 0, "Beyond the file is silence")
    }
}
