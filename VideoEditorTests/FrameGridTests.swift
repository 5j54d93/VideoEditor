import XCTest
@testable import VideoEditor

@MainActor
final class FrameGridTests: XCTestCase {
    func testFirstDisplayedFrameSkipsNegativePresentationTimes() {
        let grid = FrameGrid(
            times: [-2.0 / 30.0, -1.0 / 30.0, 0, 1.0 / 30.0],
            nominalFps: 30,
            fallbackDuration: 4.0 / 30.0
        )

        XCTAssertEqual(grid.firstDisplayedFrame, 2)
        XCTAssertEqual(grid.boundary(grid.firstDisplayedFrame), 0, accuracy: 1e-12)
    }

    func testContainingFrameUsesVariableFrameRateSpans() {
        let grid = FrameGrid(
            times: [0, 0.125, 0.375, 0.625],
            nominalFps: 24,
            fallbackDuration: 1
        )

        XCTAssertEqual(grid.frameIndex(containing: 0), 0)
        XCTAssertEqual(grid.frameIndex(containing: 0.124_999), 0)
        XCTAssertEqual(grid.frameIndex(containing: 0.125), 1)
        XCTAssertEqual(grid.frameIndex(containing: 0.374_999), 1)
        XCTAssertEqual(grid.frameIndex(containing: 0.5), 2)
        XCTAssertEqual(grid.frameIndex(containing: 9), 3)
    }

    func testNearestBoundaryUsesVFRBoundariesAndTiePrefersEarlierOne() {
        let grid = FrameGrid(
            times: [0, 0.125, 0.375, 0.625],
            nominalFps: 24,
            fallbackDuration: 1
        )

        XCTAssertEqual(grid.nearestBoundary(to: 0.2), 1)
        XCTAssertEqual(grid.nearestBoundary(to: 0.25), 1, "A midpoint tie must not advance the cut")
        XCTAssertEqual(grid.nearestBoundary(to: 0.36), 2)
    }

    func testEndTimeExtendsLastObservedIntervalAndIsFinalBoundary() {
        let grid = FrameGrid(
            times: [0, 0.04, 0.10],
            nominalFps: 30,
            fallbackDuration: 0.10
        )

        XCTAssertEqual(grid.endTime, 0.16, accuracy: 1e-12)
        XCTAssertEqual(grid.boundary(grid.frameCount), 0.16, accuracy: 1e-12)
        XCTAssertEqual(grid.boundary(Int.max), 0.16, accuracy: 1e-12)
        XCTAssertEqual(grid.nearestBoundary(to: grid.endTime), grid.frameCount)
    }

    func testObservedPacketEndWinsWithoutBecomingAnotherFrame() {
        let grid = FrameGrid(
            times: [0, 0.08, 0.20],
            nominalFps: 10,
            fallbackDuration: 0.35,
            observedEndTime: 0.27
        )

        XCTAssertEqual(grid.frameCount, 3)
        XCTAssertEqual(grid.endTime, 0.27, accuracy: 1e-12)
        XCTAssertEqual(grid.boundary(3), 0.27, accuracy: 1e-12)
        XCTAssertEqual(grid.time(ofFrame: 99), 0.20, accuracy: 1e-12,
                       "The exclusive packet end must not masquerade as a frame PTS")
    }

    func testSingleObservedFrameUsesNominalDurationForEndBoundary() {
        let grid = FrameGrid(times: [0.25], nominalFps: 25, fallbackDuration: 1)

        XCTAssertEqual(grid.endTime, 0.29, accuracy: 1e-12)
        XCTAssertEqual(grid.boundary(1), 0.29, accuracy: 1e-12)
    }

    func testNominalFallbackBuildsStableGridWithoutPacketTimes() {
        let grid = FrameGrid(times: [], nominalFps: 8, fallbackDuration: 0.5)

        XCTAssertEqual(grid.frameCount, 4)
        XCTAssertEqual(grid.firstDisplayedFrame, 0)
        XCTAssertEqual(grid.time(ofFrame: -1), 0, accuracy: 1e-12)
        XCTAssertEqual(grid.time(ofFrame: 3), 0.375, accuracy: 1e-12)
        XCTAssertEqual(grid.time(ofFrame: 99), 0.375, accuracy: 1e-12)
        XCTAssertEqual(grid.frameIndex(containing: 0.249_999), 1)
        XCTAssertEqual(grid.frameIndex(containing: 0.25), 2)
        XCTAssertEqual(grid.nearestBoundary(to: 0.3125), 2, "A nominal-grid tie must prefer the earlier boundary")
        XCTAssertEqual(grid.endTime, 0.5, accuracy: 1e-12)
        XCTAssertEqual(grid.boundary(grid.frameCount), 0.5, accuracy: 1e-12)
    }

    func testNominalFallbackUsesTrackDurationAtNonzeroStartTime() {
        let grid = FrameGrid(times: [], nominalFps: 25,
                             fallbackDuration: 2,
                             fallbackStartTime: 10,
                             observedEndTime: 12)

        XCTAssertEqual(grid.frameCount, 50,
                       "An absolute end timestamp must not be multiplied by fps")
        XCTAssertEqual(grid.time(ofFrame: 0), 10, accuracy: 1e-12)
        XCTAssertEqual(grid.time(ofFrame: 49), 11.96, accuracy: 1e-12)
        XCTAssertEqual(grid.endTime, 12, accuracy: 1e-12)
        XCTAssertEqual(grid.frameIndex(containing: 10.5), 12)
        XCTAssertEqual(grid.nearestBoundary(to: 12), 50)
    }

    func testNominalFallbackAlwaysContainsAtLeastOneFrame() {
        let grid = FrameGrid(times: [], nominalFps: 30, fallbackDuration: 0)

        XCTAssertEqual(grid.frameCount, 1)
        XCTAssertEqual(grid.time(ofFrame: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(grid.endTime, 1.0 / 30.0, accuracy: 1e-12)
    }
}
