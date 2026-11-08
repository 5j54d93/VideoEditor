import CoreGraphics
import XCTest
@testable import VideoEditor

/// A zoom goes a step at a time: while one step's scroll is on its way, the
/// latest step asked for waits for it, and those in between are skipped. None
/// of it needs a window.
@MainActor
final class TimelineZoomPacingTests: XCTestCase {
    private let closer = TimelineZoomPacing.Step(scale: 200, anchor: nil)
    private let closest = TimelineZoomPacing.Step(scale: 3_600, anchor: nil)

    /// With no scroll on its way, a step goes at once.
    func testAStepGoesAtOnceWhenNothingIsLanding() {
        var pacing = TimelineZoomPacing()
        XCTAssertEqual(pacing.ask(closer), closer)
        XCTAssertNil(pacing.waiting)
    }

    /// While a step's scroll is on its way, the steps after it wait, and only
    /// the latest of them is kept.
    func testStepsWaitForTheScrollOnItsWay() {
        var pacing = TimelineZoomPacing()
        _ = pacing.scrolled(to: 1_000)
        XCTAssertNil(pacing.ask(closer))
        XCTAssertNil(pacing.ask(closest))
        XCTAssertEqual(pacing.waiting, closest)
    }

    /// The step waiting goes once the scroll view reports being where the last
    /// step went, to within the pixel it lands on; a report from anywhere
    /// else lets nothing go.
    func testTheWaitingStepGoesOnceTheScrollLands() {
        var pacing = TimelineZoomPacing()
        _ = pacing.scrolled(to: 1_000.3)
        _ = pacing.ask(closest)
        XCTAssertFalse(pacing.reached(400), "An earlier offset, reported late")
        XCTAssertNil(pacing.next())
        XCTAssertTrue(pacing.reached(1_000.5))
        XCTAssertEqual(pacing.next(), closest)
        XCTAssertNil(pacing.next(), "It goes once")
        XCTAssertNil(pacing.waiting)
    }

    /// A step asked for after the scroll lands, but before the one waiting
    /// has gone, is the latest: it goes at once and the older one is dropped,
    /// never taken after it.
    func testALaterStepOvertakesTheOneWaiting() {
        var pacing = TimelineZoomPacing()
        _ = pacing.scrolled(to: 1_000)
        _ = pacing.ask(closer)
        XCTAssertTrue(pacing.reached(1_000))
        XCTAssertEqual(pacing.ask(closest), closest)
        _ = pacing.scrolled(to: 5_000)
        XCTAssertNil(pacing.next())
        XCTAssertTrue(pacing.reached(5_000))
        XCTAssertNil(pacing.next())
    }

    /// A scroll that never reports is given up on, and the step waiting goes;
    /// giving up on an earlier one, already landed, lets nothing go early.
    func testGivingUpOnlyLetsGoOfTheLastScroll() {
        var pacing = TimelineZoomPacing()
        let first = pacing.scrolled(to: 1_000)
        XCTAssertTrue(pacing.reached(1_000))
        let second = pacing.scrolled(to: 5_000)
        _ = pacing.ask(closest)
        XCTAssertFalse(pacing.giveUp(on: first))
        XCTAssertEqual(pacing.landing, 5_000)
        XCTAssertTrue(pacing.giveUp(on: second))
        XCTAssertEqual(pacing.next(), closest)
        XCTAssertFalse(pacing.giveUp(on: second), "Nothing is landing any more")
    }

    /// Fitting the timeline, or zooming to a tail, drops the zoom: the step
    /// waiting never goes, and the next one goes at once.
    func testCancellingDropsTheZoom() {
        var pacing = TimelineZoomPacing()
        _ = pacing.scrolled(to: 1_000)
        _ = pacing.ask(closer)
        pacing.cancel()
        XCTAssertNil(pacing.next())
        XCTAssertEqual(pacing.ask(closest), closest)
    }

    /// The slider holds the playhead where it is on screen, and brings it to
    /// the middle when it is off either side.
    func testThePlayheadHoldsWhereItIsOrComesToTheMiddle() {
        let onScreen = TimelineZoomPacing.playheadAnchor(time: 10, scale: 50, offset: 200,
                                                         viewportWidth: 1_000)
        XCTAssertEqual(onScreen, .init(time: 10, viewportX: 300))
        for time in [2.0, 30] {
            XCTAssertEqual(TimelineZoomPacing.playheadAnchor(time: time, scale: 50, offset: 200,
                                                             viewportWidth: 1_000),
                           .init(time: time, viewportX: 500))
        }
    }

    /// The offset keeps the anchor where it sat on screen at the new scale,
    /// as near as the ends of the content allow.
    func testTheOffsetHoldsTheAnchorWithinTheContent() {
        let anchor = TimelineZoomPacing.Anchor(time: 10, viewportX: 300)
        XCTAssertEqual(TimelineZoomPacing.offset(holding: anchor, at: 100, maxOffset: 5_000), 700)
        XCTAssertEqual(TimelineZoomPacing.offset(holding: anchor, at: 20, maxOffset: 5_000), 0)
        XCTAssertEqual(TimelineZoomPacing.offset(holding: anchor, at: 1_000, maxOffset: 5_000), 5_000)
        XCTAssertEqual(TimelineZoomPacing.offset(holding: anchor, at: 100, maxOffset: -40), 0,
                       "Content narrower than the viewport does not scroll")
    }

    /// The slider runs from the widest view to the closest, evenly in factor,
    /// and a scale past either end sits at that end.
    func testTheSliderMapsOntoTheScales() {
        let model = EditorModel()
        XCTAssertEqual(model.timelineScale(forZoomLevel: 0), model.timelineMinPointsPerSecond)
        XCTAssertEqual(model.timelineScale(forZoomLevel: 1), model.timelineMaxPointsPerSecond,
                       accuracy: 1e-9)
        XCTAssertEqual(model.timelineScale(forZoomLevel: 1.5), model.timelineMaxPointsPerSecond,
                       accuracy: 1e-9)
        for level in [0.1, 0.5, 0.9] {
            XCTAssertEqual(model.timelineZoomLevel(forScale: model.timelineScale(forZoomLevel: level)),
                           level, accuracy: 1e-12)
        }
        XCTAssertEqual(model.timelineZoomLevel(forScale: 1), 0)
        XCTAssertEqual(model.timelineZoomLevel(forScale: 100_000), 1)
    }
}
