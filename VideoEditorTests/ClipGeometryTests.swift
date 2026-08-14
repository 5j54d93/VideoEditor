import Foundation
import XCTest
@testable import VideoEditor

/// The geometry resolver stands in for arithmetic ffmpeg used to do at runtime,
/// so these tests are mostly about reproducing ffmpeg exactly rather than about
/// what looks reasonable. The expected sizes in
/// `testContainFitReproducesForcedAspectRatioSizing` were measured from the
/// bundled ffmpeg build, not derived by hand.
@MainActor
final class ClipGeometryTests: XCTestCase {

    private let scalerFlags = "flags=bicubic+accurate_rnd+bitexact:sws_dither=none"

    // MARK: Sizing

    /// Measured against `scale=W:H:force_original_aspect_ratio=decrease` on the
    /// bundled ffmpeg. The 562.5 and 607.5 rows are the ones that matter: they
    /// pin round-half-away-from-zero, where Swift's default banker's rounding
    /// would land a pixel low.
    func testContainFitReproducesForcedAspectRatioSizing() {
        let cases: [(source: PixelSize, canvas: PixelSize, expected: PixelSize)] = [
            (PixelSize(width: 1920, height: 1080), PixelSize(width: 1000, height: 1000),
             PixelSize(width: 1000, height: 563)),
            (PixelSize(width: 1920, height: 1080), PixelSize(width: 1920, height: 1080),
             PixelSize(width: 1920, height: 1080)),
            (PixelSize(width: 1920, height: 1080), PixelSize(width: 1280, height: 720),
             PixelSize(width: 1280, height: 720)),
            (PixelSize(width: 1080, height: 1920), PixelSize(width: 1000, height: 1000),
             PixelSize(width: 563, height: 1000)),
            (PixelSize(width: 1080, height: 1920), PixelSize(width: 1920, height: 1080),
             PixelSize(width: 608, height: 1080)),
            (PixelSize(width: 1080, height: 1920), PixelSize(width: 1280, height: 720),
             PixelSize(width: 405, height: 720)),
            (PixelSize(width: 1234, height: 567), PixelSize(width: 1000, height: 1000),
             PixelSize(width: 1000, height: 459)),
            (PixelSize(width: 1234, height: 567), PixelSize(width: 1920, height: 1080),
             PixelSize(width: 1920, height: 882)),
            (PixelSize(width: 1234, height: 567), PixelSize(width: 1280, height: 720),
             PixelSize(width: 1280, height: 588)),
            (PixelSize(width: 641, height: 481), PixelSize(width: 1000, height: 1000),
             PixelSize(width: 1000, height: 750)),
            (PixelSize(width: 641, height: 481), PixelSize(width: 1920, height: 1080),
             PixelSize(width: 1439, height: 1080)),
            (PixelSize(width: 641, height: 481), PixelSize(width: 1280, height: 720),
             PixelSize(width: 960, height: 720)),
        ]

        for c in cases {
            let placement = FFTools.resolve(ClipGeometry(), source: c.source,
                                            canvas: canvas(c.canvas))
            XCTAssertEqual(placement.scaledSize, c.expected,
                           "\(c.source.width)×\(c.source.height) into "
                           + "\(c.canvas.width)×\(c.canvas.height)")
            XCTAssertNil(placement.visibleCrop, "contain never overflows the canvas")
            XCTAssertFalse(placement.isFullyOffCanvas)
        }
    }

    /// `pad`'s own `(oh-ih)/2` evaluates in double and truncates on the way to
    /// an int, so an odd remainder biases the picture up, not down.
    func testPadOriginTruncatesTheHalvedRemainder() {
        let placement = FFTools.resolve(ClipGeometry(),
                                        source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1000, height: 1000)))
        XCTAssertEqual(placement.scaledSize, PixelSize(width: 1000, height: 563))
        XCTAssertEqual(placement.padOrigin, PixelOffset(x: 0, y: 218))  // 437/2, not 219
    }

    // MARK: Chain shape

    func testDefaultFramingEmitsExplicitIntegersRatherThanExpressions() {
        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080)),
            canvas: canvas(PixelSize(width: 1000, height: 1000)))

        // 563 and 218 are odd, so the chain composes through full chroma and
        // converts back only after padding — a 4:2:0 frame cannot address an
        // odd row, and crop/pad would quietly round it.
        XCTAssertEqual(chain,
                       "scale=1000:563:\(scalerFlags),format=yuv444p,"
                       + "pad=1000:1000:0:218,setsar=1,fps=30,format=yuv420p")
        XCTAssertFalse(chain.contains("force_original_aspect_ratio"))
        XCTAssertFalse(chain.contains("(ow-iw)"))
    }

    /// Probing does not always report a frame size. Without one there is nothing
    /// to compute a fit from, and the chain has to stay exactly what it was
    /// before geometry existed.
    func testUnknownSourceSizeKeepsTheRuntimeFitExpression() {
        let chain = FFTools.geometryChain(for: item(source: .zero),
                                          canvas: canvas(PixelSize(width: 1920, height: 1080)))

        XCTAssertEqual(chain,
                       "scale=1920:1080:force_original_aspect_ratio=decrease:\(scalerFlags),"
                       + "format=yuv444p,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,"
                       + "setsar=1,fps=30,format=yuv420p")
    }

    /// The horizontal-source-into-vertical-canvas case, expressed the new way:
    /// a window over the middle of the source, shaped like the canvas.
    func testWindowCropsBeforeScaling() {
        var geometry = ClipGeometry()
        geometry.framing = .window(PixelRect(x: 320, y: 0, width: 1280, height: 1080))

        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080), geometry: geometry),
            canvas: canvas(PixelSize(width: 1080, height: 1920)))

        XCTAssertTrue(chain.hasPrefix("crop=1280:1080:320:0:exact=1,"), chain)
        XCTAssertTrue(chain.contains("scale=1080:911:"), chain)
    }

    // MARK: The window replaces four fields

    /// Every one of the four fields this redesign removed was describing the
    /// same rectangle. These pin that: each old concept has an equivalent window
    /// that resolves to the same placement.
    func testWindowReproducesWhatAnOffsetUsedToDo() {
        let source = PixelSize(width: 1920, height: 1080)
        let target = canvas(PixelSize(width: 1920, height: 1080))

        // Nudging the picture 100px right == moving the window 100px left.
        var geometry = ClipGeometry()
        geometry.framing = .window(PixelRect(x: -100, y: 0, width: 1920, height: 1080))
        let placement = FFTools.resolve(geometry, source: source, canvas: target)

        XCTAssertEqual(placement.padOrigin, PixelOffset(x: 100, y: 0))
        XCTAssertEqual(placement.sourceCrop,
                       PixelRect(x: 0, y: 0, width: 1820, height: 1080))
        // And it needs no second crop. The old offset scaled the whole picture
        // and then trimmed what hung over the canvas edge; a window crops the
        // source directly, so there is nothing left over to trim.
        XCTAssertNil(placement.visibleCrop)
    }

    func testWindowReproducesWhatAMagnificationUsedToDo() {
        let source = PixelSize(width: 1920, height: 1080)
        let target = canvas(PixelSize(width: 1920, height: 1080))

        // Shrinking the picture to half size == a window twice as large.
        var geometry = ClipGeometry()
        geometry.framing = .window(PixelRect(x: -960, y: -540, width: 3840, height: 2160))
        let placement = FFTools.resolve(geometry, source: source, canvas: target)

        XCTAssertEqual(placement.scaledSize, PixelSize(width: 960, height: 540))
        XCTAssertEqual(placement.padOrigin, PixelOffset(x: 480, y: 270))
    }

    func testFillFramingCoversTheCanvas() {
        var geometry = ClipGeometry()
        geometry.framing = .automatic(.fill)

        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1080, height: 1920)))

        XCTAssertEqual(placement.scaledSize, PixelSize(width: 3413, height: 1920))
        XCTAssertEqual(placement.visibleCrop,
                       PixelRect(x: 1166, y: 0, width: 1080, height: 1920))
        XCTAssertEqual(placement.padOrigin, .zero)
    }

    /// A window shaped like the canvas fills it exactly — the property the
    /// default aspect lock exists to guarantee, and the reason the rectangle on
    /// screen can be described as the output frame.
    func testCanvasShapedWindowFillsTheCanvasExactly() {
        var geometry = ClipGeometry()
        geometry.framing = .window(PixelRect(x: 420, y: 0, width: 1080, height: 1920))

        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1080, height: 1920)))
        XCTAssertNil(placement.visibleCrop)
        XCTAssertEqual(placement.padOrigin, .zero)
    }

    /// A locked window's integer dimensions often cannot express the canvas
    /// ratio exactly. The leftover must not become a black hairline.
    func testNearCanvasRatioWindowStillFillsTheCanvas() {
        var geometry = ClipGeometry()
        // 607:1080 is 9:16 as closely as whole pixels allow; it fits as 1079.
        geometry.framing = .window(PixelRect(x: 421, y: 0, width: 607, height: 1080))

        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1080, height: 1920)))

        XCTAssertEqual(placement.scaledSize, PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(placement.padOrigin, .zero)
        XCTAssertNil(placement.visibleCrop)
    }

    /// A window that is not canvas-shaped letterboxes rather than distorting.
    func testWindowOfADifferentShapeLetterboxes() {
        var geometry = ClipGeometry()
        geometry.framing = .window(PixelRect(x: 0, y: 0, width: 1080, height: 1080))

        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1920, height: 1080)))

        XCTAssertEqual(placement.scaledSize, PixelSize(width: 1080, height: 1080))
        XCTAssertEqual(placement.padOrigin, PixelOffset(x: 420, y: 0))
    }

    func testWindowClearOfTheSourceIsRejected() {
        var geometry = ClipGeometry()
        geometry.framing = .window(PixelRect(x: 5000, y: 0, width: 1080, height: 1920))

        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1080, height: 1920)))
        XCTAssertTrue(placement.isFullyOffCanvas)
    }

    // MARK: Automatic windows

    /// The rectangle a drag starts from. `fit` has to contain the whole source,
    /// `fill` has to sit inside it — both shaped like the canvas.
    func testAutomaticWindowsAreCanvasShaped() {
        let source = PixelSize(width: 1920, height: 1080)
        let portrait = PixelSize(width: 1080, height: 1920)

        let fit = ClipGeometry.automaticWindow(.fit, source: source, canvas: portrait)
        XCTAssertEqual(fit.width, 1920)
        XCTAssertEqual(fit.height, 3413)               // 1920 × 1920/1080
        XCTAssertGreaterThanOrEqual(fit.height, source.height)
        XCTAssertEqual(fit.x, 0)
        XCTAssertEqual(fit.y, (1080 - 3413) / 2)       // centred, so negative

        let fill = ClipGeometry.automaticWindow(.fill, source: source, canvas: portrait)
        XCTAssertEqual(fill.width, 608)                // 1080 × 1080/1920
        XCTAssertEqual(fill.height, 1080)
        XCTAssertLessThanOrEqual(fill.width, source.width)
    }

    /// The automatic framings stay live rather than materialising, so changing
    /// the canvas reframes instead of stranding a rectangle shaped for the old
    /// aspect ratio.
    func testAutomaticFramingFollowsTheCanvas() {
        let geometry = ClipGeometry()
        let source = PixelSize(width: 1920, height: 1080)

        let wide = FFTools.resolve(geometry, source: source,
                                   canvas: canvas(PixelSize(width: 1920, height: 1080)))
        let tall = FFTools.resolve(geometry, source: source,
                                   canvas: canvas(PixelSize(width: 1080, height: 1920)))

        XCTAssertEqual(wide.scaledSize, PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(tall.scaledSize, PixelSize(width: 1080, height: 608))
    }

    func testIdentityIsTheDefaultFraming() {
        XCTAssertTrue(ClipGeometry().isIdentity)

        var filled = ClipGeometry()
        filled.framing = .automatic(.fill)
        XCTAssertFalse(filled.isIdentity)

        var windowed = ClipGeometry()
        windowed.framing = .window(PixelRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertFalse(windowed.isIdentity)
    }

    // MARK: Clamping

    /// No chroma-grid snapping any more: composing through yuv444p made odd
    /// coordinates exact, so rounding them would only refuse precision the
    /// exporter can deliver.
    func testWindowKeepsOddCoordinates() {
        let source = PixelSize(width: 1920, height: 1080)
        let odd = PixelRect(x: 101, y: 7, width: 641, height: 361)
        XCTAssertEqual(odd.clampedWindow(in: source), odd)
    }

    func testWindowIsClampedToSomethingRenderable() {
        let source = PixelSize(width: 1920, height: 1080)

        // Degenerate sizes become renderable rather than dividing by zero.
        XCTAssertGreaterThanOrEqual(
            PixelRect(x: 0, y: 0, width: 0, height: 0).clampedWindow(in: source).width, 2)

        // Dragged clear of the frame, it is pulled back until some source shows.
        let far = PixelRect(x: 9000, y: 0, width: 200, height: 200).clampedWindow(in: source)
        XCTAssertLessThan(far.x, source.width)
        XCTAssertGreaterThan(far.x + far.width, 0)
    }

    // MARK: Handles

    /// Each handle moves only the edges it sits on. Getting this wrong is
    /// invisible until someone drags a corner and the opposite edge follows.
    func testHandlesMoveOnlyTheirOwnEdges() {
        let rect = PixelRect(x: 100, y: 100, width: 400, height: 300)

        XCTAssertEqual(CropHandle.topLeft.resize(rect, dx: 20, dy: 10, lockedAspect: nil),
                       PixelRect(x: 120, y: 110, width: 380, height: 290))
        XCTAssertEqual(CropHandle.bottomRight.resize(rect, dx: 20, dy: 10, lockedAspect: nil),
                       PixelRect(x: 100, y: 100, width: 420, height: 310))
        XCTAssertEqual(CropHandle.top.resize(rect, dx: 999, dy: 10, lockedAspect: nil),
                       PixelRect(x: 100, y: 110, width: 400, height: 290))
        XCTAssertEqual(CropHandle.left.resize(rect, dx: 20, dy: 999, lockedAspect: nil),
                       PixelRect(x: 120, y: 100, width: 380, height: 300))
    }

    /// A locked drag keeps the ratio and anchors the far corner, so the corner
    /// under the pointer is the one that moves.
    func testLockedHandleKeepsTheRatioAndTheFarCorner() {
        let rect = PixelRect(x: 100, y: 100, width: 400, height: 400)   // 1:1
        let resized = CropHandle.bottomRight.resize(rect, dx: 100, dy: 0, lockedAspect: 1)

        XCTAssertEqual(resized, PixelRect(x: 100, y: 100, width: 500, height: 500))

        // Dragging the top-left corner moves the origin, not the far edges.
        let fromTopLeft = CropHandle.topLeft.resize(rect, dx: 100, dy: 0, lockedAspect: 1)
        XCTAssertEqual(fromTopLeft.x + fromTopLeft.width, 500)
        XCTAssertEqual(fromTopLeft.y + fromTopLeft.height, 500)
        XCTAssertEqual(fromTopLeft.width, fromTopLeft.height)
    }

    func testOnlyCornersResizeWhileLocked() {
        XCTAssertEqual(CropHandle.corners.count, 4)
        XCTAssertEqual(CropHandle.allCases.count, 8)
    }

    // MARK: Helpers

    private func canvas(_ size: PixelSize) -> CanvasSpec {
        CanvasSpec(width: size.width, height: size.height, fps: "30", fpsValue: 30)
    }

    private func item(source: PixelSize, geometry: ClipGeometry = ClipGeometry()) -> AssemblyItem {
        AssemblyItem(url: URL(fileURLWithPath: "/fixtures/clip.mov"),
                     isImage: false,
                     trimStartFrame: 0, trimEndFrame: 30,
                     trimStart: 0, trimEnd: 1, duration: 1,
                     hasAudio: false,
                     sourceSize: source,
                     geometry: geometry)
    }
}
