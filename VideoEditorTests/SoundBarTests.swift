import CoreGraphics
import XCTest
@testable import VideoEditor

/// Where a sound bar's controls sit, and what dragging them sets. None of it
/// needs a window.
@MainActor
final class SoundBarTests: XCTestCase {

    /// A bar 200 points long and 40 tall at 50 points a second: four seconds,
    /// all of them heard unless `heard` says otherwise.
    private func bar(gain: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0,
                     heard: CGFloat = 200) -> SoundBarGeometry {
        SoundBarGeometry(width: 200, height: 40, heardWidth: heard, pointsPerSecond: 50,
                         gain: gain, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// Silence at the bottom, the recording as it is halfway up, twice it at
    /// the top — four points in from either edge.
    func testTheLineRisesWithTheLevel() {
        let b = bar()
        XCTAssertEqual(b.levelY(0), 36)
        XCTAssertEqual(b.levelY(1), 20)
        XCTAssertEqual(b.levelY(2), 4)
    }

    /// The line climbs out of silence across the fade-in and falls into it
    /// across the fade-out; where two fades overlap it peaks where they cross,
    /// short of the level.
    func testTheLineFollowsTheFades() throws {
        let b = bar(fadeIn: 1, fadeOut: 2)
        XCTAssertEqual(b.envelopeY(at: 0), 36)
        XCTAssertEqual(b.envelopeY(at: 25), 28, accuracy: 1e-9, "Halfway up the fade-in")
        XCTAssertEqual(b.envelopeY(at: 75), 20)
        XCTAssertEqual(b.envelopeY(at: 150), 28, accuracy: 1e-9, "Halfway down the fade-out")
        XCTAssertEqual(b.envelopeY(at: 200), 36)

        let crossed = bar(fadeIn: 3, fadeOut: 3)
        let peak = try XCTUnwrap(crossed.envelopeCorners.min { $0.y < $1.y })
        XCTAssertEqual(peak.x, 100, accuracy: 1e-9)
        XCTAssertGreaterThan(peak.y, crossed.levelY(1), "Overlapping fades never reach the level")
    }

    /// Each handle sits at the end of its fade, in its corner when there is
    /// none; a piece outrunning the movie has its fade-out where the movie ends.
    func testHandlesSitAtTheEndsOfTheFades() {
        XCTAssertEqual(bar().handleX(.fadeIn), 4)
        XCTAssertEqual(bar().handleX(.fadeOut), 196)
        XCTAssertEqual(bar(fadeIn: 1, fadeOut: 0.5).handleX(.fadeIn), 50)
        XCTAssertEqual(bar(fadeIn: 1, fadeOut: 0.5).handleX(.fadeOut), 175)
        XCTAssertEqual(bar(fadeOut: 1, heard: 120).handleX(.fadeOut), 70,
                       "The fade-out leads into the movie's end, not the piece's")
    }

    /// Where controls overlap, the handles win, then the speaker, then the
    /// ends, then the line; the rest of the bar is the bar.
    func testZonesWinInOrder() {
        let b = bar()
        func zone(_ x: CGFloat, _ y: CGFloat, muted: Bool = false,
                  trims: Bool = true) -> SoundBarGeometry.Zone {
            b.zone(at: CGPoint(x: x, y: y), isMuted: muted, trims: trims)
        }
        XCTAssertEqual(zone(4, 5), .fadeIn, "A handle beats the trim edge in its corner")
        XCTAssertEqual(zone(196, 5), .fadeOut)
        XCTAssertEqual(zone(12, 30), .mute)
        XCTAssertEqual(zone(4, 20), .trimStart, "Below the handles the end trims")
        XCTAssertEqual(zone(197, 20), .trimEnd)
        XCTAssertEqual(zone(100, 22), .level)
        XCTAssertEqual(zone(100, 30), .body)
        XCTAssertEqual(zone(100, 20, muted: true), .body, "A muted line has nothing to set")
        XCTAssertEqual(zone(4, 5, muted: true), .fadeIn, "A muted sound keeps its fades")
        XCTAssertEqual(zone(4, 20, trims: false), .level, "A clip's own sound has no ends to trim")
    }

    /// The line keeps to the pointer in whole percents, and unity holds it for
    /// a few points on the way past; ⌘ moves it a percent a point and holds
    /// nowhere.
    func testDraggingTheLine() {
        let b = bar()
        XCTAssertEqual(b.gain(from: 1, rise: -8, fine: false), 0.5, "A quarter of the travel is half")
        XCTAssertEqual(b.gain(from: 0.9, rise: 2, fine: false), 1, "Unity holds within the detent")
        XCTAssertEqual(b.gain(from: 0.9, rise: 2, fine: true), 0.92)
        XCTAssertEqual(b.gain(from: 1, rise: 2, fine: true), 1.02, "⌘ holds nowhere")
        XCTAssertEqual(b.gain(from: 1.9, rise: 10, fine: false), 2, "No louder than twice the recording")
        XCTAssertEqual(b.gain(from: 0.1, rise: -10, fine: false), 0)
        XCTAssertEqual(b.gain(from: 0.333, rise: 0.1, fine: true), 0.33, "Whole percents")
    }

    /// A handle's fade is how far it sits from its own end, pulled onto a cut
    /// within reach, and never across the other fade.
    func testDraggingAHandle() {
        let b = bar(fadeOut: 1)
        XCTAssertEqual(b.fade(.fadeIn, handleAt: 60, snaps: []), 1.2)
        XCTAssertEqual(b.fade(.fadeIn, handleAt: 60, snaps: [64]), 1.28, "Pulled onto the cut")
        XCTAssertEqual(b.fade(.fadeIn, handleAt: 60, snaps: [80]), 1.2, "A cut out of reach")
        XCTAssertEqual(b.fade(.fadeIn, handleAt: 190, snaps: []), 3, "Stops at the fade-out")
        XCTAssertEqual(b.fade(.fadeIn, handleAt: -20, snaps: []), 0)
        XCTAssertEqual(b.fade(.fadeOut, handleAt: 100, snaps: []), 2)
        XCTAssertEqual(bar(heard: 120).fade(.fadeOut, handleAt: 95, snaps: []), 0.5,
                       "Measured from where the sound stops being heard")
    }
}
