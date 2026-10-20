import Foundation
import XCTest
@testable import VideoEditor

/// The seam between two clips is drawn, not timed: each clip's drawing stands
/// in from its own span, so the cut sits in the seam's middle and nothing that
/// maps time to x moves.
@MainActor
final class TimelineClipShapeTests: XCTestCase {
    /// Two neighbours each give half the seam, so every cut is the same 3pt
    /// gap with the cut itself in its middle.
    func testEveryCutIsAThreePointSeamWithTheCutInItsMiddle() {
        XCTAssertEqual(TimelineLaneMetrics.clipSeam, 3)
        XCTAssertEqual(TimelineLaneMetrics.clipCornerRadius, 5)
        for width in [CGFloat(12), 40, 120, 5000] {
            XCTAssertEqual(TimelineLaneMetrics.clipInset(forWidth: width) * 2, TimelineLaneMetrics.clipSeam,
                           "A \(width)pt clip gives the seam its half on each side")
        }
    }

    /// A sliver of a clip gives up less than its share, so it is never masked
    /// away: two thirds of it stay drawn, however thin.
    func testASliverOfAClipStaysVisible() {
        for width in [CGFloat(0), 0.5, 1, 3, 6, 9] {
            let inset = TimelineLaneMetrics.clipInset(forWidth: width)
            XCTAssertGreaterThanOrEqual(width - 2 * inset, width * 2 / 3 - 1e-9)
            XCTAssertGreaterThanOrEqual(inset, 0)
        }
    }
}
