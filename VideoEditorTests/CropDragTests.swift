import Foundation
import XCTest
@testable import VideoEditor

/// What a drag can and cannot express.
///
/// The rectangle is stored in source pixels but dragged in screen points, and
/// the conversion between them is the whole subject here. The two things anyone
/// wants from it — the edge staying under the pointer, and every size being
/// reachable — are the same thing only at 100%. Below that a point covers
/// several source pixels and one of the two has to give; these pin which, and
/// pin that the zoom is the way back to the other.
@MainActor
final class CropDragTests: XCTestCase {

    /// Source pixels a drag of `points` produces, exactly as `dragGesture` does.
    private func delta(points: CGFloat, scale: CGFloat) -> Int {
        Int((points * StageViewport.sourcePixelsPerPoint(scale: scale)).rounded())
    }

    /// Every width a handle can be dragged to, from a whole-frame start, with a
    /// pointer that reports whole points.
    private func reachableWidths(_ handle: CropHandle, from width: Int,
                                 scale: CGFloat, fromCentre: Bool = false) -> Set<Int> {
        var widths: Set<Int> = []
        for points in stride(from: CGFloat(-40), through: 40, by: 1) {
            let moved = handle.resize(PixelRect(x: 0, y: 0, width: width, height: 1080),
                                      dx: delta(points: points, scale: scale),
                                      dy: 0, lockedAspect: nil, fromCentre: fromCentre)
            widths.insert(moved.width)
        }
        return widths
    }

    // MARK: The edge stays under the pointer

    /// The rule the mapping keeps: whatever the zoom, a point of pointer travel
    /// moves the rectangle by exactly the picture it covers, so the edge and the
    /// pointer never drift apart.
    func testOnePointMovesTheRectangleByThePictureThePointCovers() {
        XCTAssertEqual(delta(points: 10, scale: 0.5), 20)
        XCTAssertEqual(delta(points: 10, scale: 0.25), 40)
        XCTAssertEqual(delta(points: 10, scale: 1), 10)
        XCTAssertEqual(delta(points: 10, scale: 4), 3)   // 2.5 px, rounded
    }

    /// A pane can be laid out at zero width for a frame before it settles, and a
    /// scale of zero would otherwise divide.
    func testDegenerateScaleDoesNotDivideByZero() {
        XCTAssertTrue(StageViewport.sourcePixelsPerPoint(scale: 0).isFinite)
    }

    // MARK: What that costs, and where it stops costing

    /// The price of keeping the edge under the pointer, stated rather than
    /// discovered: at half size a point covers two source pixels, so the widths
    /// a drag can reach are two apart and none of them is odd. Capping the step
    /// at one pixel would reach them, and was taken out again — it moves the
    /// rectangle slower than the hand, which is worse.
    func testHalfSizeZoomReachesEverySecondWidthOnly() {
        let widths = reachableWidths(.right, from: 1920, scale: 0.5)

        XCTAssertTrue(widths.contains(1918))
        XCTAssertTrue(widths.contains(1922))
        XCTAssertFalse(widths.contains(where: { $0 % 2 != 0 }))
    }

    /// And the way back to every size, which costs nothing: at 實際像素 a point
    /// *is* a pixel, so the edge tracks the pointer and lands on every integer
    /// at the same time.
    func testActualPixelsZoomReachesEveryWidth() {
        let widths = reachableWidths(.right, from: 1920, scale: 1)

        XCTAssertTrue(widths.contains(1919))
        XCTAssertTrue(widths.contains(1921))
        XCTAssertEqual(widths.count, 81)   // -40…+40 points, every integer
    }

    /// ⌥ mirrors the drag onto the opposite edge, so the width moves in twos
    /// even at 100% — the grabbed edge follows the pointer and the opposite one
    /// answers it. An odd width comes from a single edge instead.
    func testCentredResizeMovesTheWidthInTwosByConstruction() {
        let widths = reachableWidths(.right, from: 1920, scale: 1, fromCentre: true)

        XCTAssertFalse(widths.contains(where: { $0 % 2 != 0 }))
        XCTAssertEqual(CropHandle.right.resize(PixelRect(x: 100, y: 0, width: 200, height: 100),
                                               dx: 3, dy: 0, lockedAspect: nil,
                                               fromCentre: true),
                       PixelRect(x: 97, y: 0, width: 206, height: 100))
    }

    // MARK: Chrome that follows the zoom

    /// The border thins as the picture grows: a 1pt line spans a whole source
    /// pixel the moment the picture is drawn 1:1, and the pixel it spans is the
    /// one the zoom was for.
    func testBorderNeverCoversMoreThanHalfAPixel() {
        XCTAssertEqual(StageViewport.borderWidth(pointsPerSourcePixel: 0.25), 1)
        XCTAssertEqual(StageViewport.borderWidth(pointsPerSourcePixel: 0.5), 1)
        XCTAssertEqual(StageViewport.borderWidth(pointsPerSourcePixel: 0.625), 0.8)
        XCTAssertEqual(StageViewport.borderWidth(pointsPerSourcePixel: 1), 0.5)
        XCTAssertEqual(StageViewport.borderWidth(pointsPerSourcePixel: 8), 0.5)
        XCTAssertEqual(StageViewport.borderWidth(pointsPerSourcePixel: 0), 1)
    }

    /// Half a pixel is the promise up to 1:1; past it the hairline floor takes
    /// over and the drawing has to move clear of the boundary instead, which is
    /// what the outset stroke in `outline` is for.
    func testBorderIsAtMostHalfAPixelUntilTheHairlineFloor() {
        for scale in stride(from: 0.2, through: 1.0, by: 0.05) {
            let width = StageViewport.borderWidth(pointsPerSourcePixel: CGFloat(scale))
            XCTAssertLessThanOrEqual(width * CGFloat(scale), 0.5 + 1e-9, "at \(scale)")
        }
    }

    /// Grain tracks the zoom from 1:1 up rather than snapping to real pixels at
    /// some threshold along the way: magnifying shows the pixels that exist,
    /// reducing filters them.
    func testMagnifyingShowsRealPixelsFromOneToOneUp() {
        XCTAssertFalse(StageViewport.usesNearestNeighbour(pointsPerSourcePixel: 0.5))
        XCTAssertTrue(StageViewport.usesNearestNeighbour(pointsPerSourcePixel: 1))
        XCTAssertTrue(StageViewport.usesNearestNeighbour(pointsPerSourcePixel: 2))
    }

    // MARK: The letterbox against the selection border

    /// The canvas outline must never run along the selection border. It used to
    /// draw its whole rectangle, two sides of which lie exactly on the border —
    /// a fixed 1pt dashed line over the border's own hairline dashes, out of
    /// step with them, which filled in their gaps and read as a solid rule at
    /// twice the width. Zooming made it worse: only the border thins.
    func testLetterboxNeverDrawsAlongTheSelectionBorder() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        for letterbox in [CGRect(x: 33, y: 100, width: 533, height: 300),   // wider
                          CGRect(x: 100, y: 50, width: 400, height: 400)] { // taller
            for (a, b) in LetterboxOutline.segments(of: letterbox, around: window) {
                let onBorder = (a.x == b.x && (a.x == window.minX || a.x == window.maxX)
                                && max(a.y, b.y) > window.minY && min(a.y, b.y) < window.maxY)
                    || (a.y == b.y && (a.y == window.minY || a.y == window.maxY)
                        && max(a.x, b.x) > window.minX && min(a.x, b.x) < window.maxX)
                XCTAssertFalse(onBorder, "\(a)–\(b) lies on the border of \(window)")
            }
        }
    }

    /// What is left still describes the whole letterbox: both of the sides that
    /// stand clear, and the stubs of the two shared ones that reach past the
    /// window. Dropping those stubs would leave the canvas edge unclosed.
    func testLetterboxStillDrawsEverythingClearOfTheWindow() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let wider = LetterboxOutline.segments(of: CGRect(x: 0, y: 100, width: 600, height: 300),
                                              around: window)
        XCTAssertEqual(wider.count, 6)
        // the two full sides, then a stub either side of the window on each end
        XCTAssertTrue(wider.contains { $0.0 == CGPoint(x: 0, y: 100) && $0.1 == CGPoint(x: 0, y: 400) })
        XCTAssertTrue(wider.contains { $0.0 == CGPoint(x: 0, y: 100) && $0.1 == CGPoint(x: 100, y: 100) })
        XCTAssertTrue(wider.contains { $0.0 == CGPoint(x: 500, y: 400) && $0.1 == CGPoint(x: 600, y: 400) })

        let taller = LetterboxOutline.segments(of: CGRect(x: 100, y: 0, width: 400, height: 500),
                                               around: window)
        XCTAssertEqual(taller.count, 6)
        XCTAssertTrue(taller.contains { $0.0 == CGPoint(x: 100, y: 0) && $0.1 == CGPoint(x: 500, y: 0) })
        XCTAssertTrue(taller.contains { $0.0 == CGPoint(x: 100, y: 0) && $0.1 == CGPoint(x: 100, y: 100) })
        XCTAssertTrue(taller.contains { $0.0 == CGPoint(x: 500, y: 400) && $0.1 == CGPoint(x: 500, y: 500) })
    }

    // MARK: Drawing a new rectangle

    /// A picture drawn 1:1 and centred in a 1000×800 pane, which is what the
    /// stage hands the marquee.
    private let picture = CGRect(x: 40, y: 30, width: 1920, height: 1080)
    private let source = PixelSize(width: 1920, height: 1080)

    private func marquee(_ start: CGPoint, _ end: CGPoint,
                         scale: CGFloat = 1, aspect: Double? = nil) -> PixelRect {
        CropMarquee.rect(from: start, to: end, picture: picture, scale: scale,
                         source: source, aspect: aspect)
    }

    func testMarqueeIsTheRectangleBetweenTheTwoPoints() {
        XCTAssertEqual(marquee(CGPoint(x: 140, y: 130), CGPoint(x: 440, y: 330)),
                       PixelRect(x: 100, y: 100, width: 300, height: 200))
    }

    /// Dragging up and to the left describes the same rectangle as dragging down
    /// and to the right across it — the anchor is wherever the press landed, not
    /// the top-left corner.
    func testMarqueeNormalisesABackwardsDrag() {
        XCTAssertEqual(marquee(CGPoint(x: 440, y: 330), CGPoint(x: 140, y: 130)),
                       PixelRect(x: 100, y: 100, width: 300, height: 200))
    }

    /// A selection comes out of the picture that exists, so a drag that runs off
    /// the edge stops at the edge rather than describing black.
    func testMarqueeStopsAtTheEdgeOfThePicture() {
        let rect = marquee(CGPoint(x: 1000, y: 500), CGPoint(x: 4000, y: 3000))

        XCTAssertEqual(rect, PixelRect(x: 960, y: 470, width: 960, height: 610))
        XCTAssertEqual(rect.x + rect.width, source.width)
        XCTAssertEqual(rect.y + rect.height, source.height)
    }

    /// The odd sizes the whole exercise is about. Drawn at 100%, a marquee lands
    /// on exactly the pixels the hand described, odd ones included — no edge is
    /// being walked in from a rectangle that started even.
    func testMarqueeReachesOddSizesDirectly() {
        let rect = marquee(CGPoint(x: 140, y: 130), CGPoint(x: 755, y: 951))

        XCTAssertEqual(rect.width, 615)
        XCTAssertEqual(rect.height, 821)
    }

    /// Below 100% the marquee is subject to the same zoom resolution as any
    /// other drag — but it reaches a given size in one gesture rather than four,
    /// and the rail is there for the exact value.
    func testMarqueeConvertsOutOfAZoomedOutStage() {
        XCTAssertEqual(marquee(CGPoint(x: 40, y: 30), CGPoint(x: 240, y: 130), scale: 0.5),
                       PixelRect(x: 0, y: 0, width: 400, height: 200))
    }

    func testMarqueeHoldsALockedRatio() {
        let rect = marquee(CGPoint(x: 140, y: 130), CGPoint(x: 1040, y: 330), aspect: 16.0 / 9)

        XCTAssertEqual(rect, PixelRect(x: 100, y: 100, width: 900, height: 506))
    }

    /// Running a locked drag into an edge has to shorten both axes together.
    /// Clamping them independently would hold the anchor and quietly squash the
    /// ratio the lock exists to keep.
    func testLockedMarqueeKeepsItsRatioAtTheEdge() {
        let rect = marquee(CGPoint(x: 40, y: 800), CGPoint(x: 1960, y: 1200), aspect: 1)

        XCTAssertEqual(rect.width, rect.height)
        XCTAssertEqual(rect.height, 1080 - 770)
    }

    // MARK: Reaching an odd output

    /// The point of all of it: an odd width dragged by hand survives into the
    /// window the exporter is handed, unrounded — nothing downstream re-rounds
    /// it to an even one.
    func testAnOddDraggedWidthSurvivesClamping() {
        let source = PixelSize(width: 1920, height: 1080)
        let dragged = CropHandle.right.resize(
            PixelRect(x: 0, y: 0, width: 1920, height: 1080),
            dx: delta(points: -1, scale: 1), dy: 0, lockedAspect: nil)

        XCTAssertEqual(dragged.width, 1919)
        XCTAssertEqual(dragged.clampedWindow(in: source).width, 1919)
    }
}
