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

    func testIdentityGeometryEmitsExplicitIntegersRatherThanExpressions() {
        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080)),
            canvas: canvas(PixelSize(width: 1000, height: 1000)))

        XCTAssertEqual(chain,
                       "scale=1000:563:\(scalerFlags),"
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
                       + "pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p")
    }

    /// The horizontal-source-into-vertical-canvas case: crop acts on source
    /// pixels and therefore has to precede the scale.
    func testSourceCropAppliesBeforeScaling() {
        var geometry = ClipGeometry()
        geometry.sourceCrop = PixelRect(x: 320, y: 0, width: 1280, height: 1080)

        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080), geometry: geometry),
            canvas: canvas(PixelSize(width: 1080, height: 1920)))

        XCTAssertEqual(chain,
                       "crop=1280:1080:320:0,scale=1080:911:\(scalerFlags),"
                       + "pad=1080:1920:0:504,setsar=1,fps=30,format=yuv420p")
    }

    // MARK: Overflow

    func testCoverTrimsWhatOverflowsTheCanvas() {
        var geometry = ClipGeometry()
        geometry.fit = .cover

        let target = canvas(PixelSize(width: 1080, height: 1920))
        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: target)

        XCTAssertEqual(placement.scaledSize, PixelSize(width: 3413, height: 1920))
        XCTAssertEqual(placement.visibleCrop,
                       PixelRect(x: 1166, y: 0, width: 1080, height: 1920))
        XCTAssertEqual(placement.padOrigin, .zero)

        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080), geometry: geometry),
            canvas: target)
        // The trim has to sit between the scale and the pad: pad cannot take a
        // negative origin, which is the whole reason the second crop exists.
        XCTAssertEqual(chain,
                       "scale=3413:1920:\(scalerFlags),crop=1080:1920:1166:0,"
                       + "pad=1080:1920:0:0,setsar=1,fps=30,format=yuv420p")
    }

    func testOffsetPastTheEdgeTrimsRatherThanPaddingNegative() {
        var geometry = ClipGeometry()
        geometry.offset = PixelOffset(x: 100, y: 0)

        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1920, height: 1080)))

        XCTAssertEqual(placement.visibleCrop,
                       PixelRect(x: 0, y: 0, width: 1820, height: 1080))
        XCTAssertEqual(placement.padOrigin, PixelOffset(x: 100, y: 0))
        XCTAssertFalse(placement.isFullyOffCanvas)
    }

    func testPictureNudgedClearOfTheCanvasBecomesBlack() {
        var geometry = ClipGeometry()
        geometry.offset = PixelOffset(x: 5000, y: 0)

        let target = canvas(PixelSize(width: 1920, height: 1080))
        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: target)
        XCTAssertTrue(placement.isFullyOffCanvas)

        // A scaled picture wider than the canvas would make pad fail outright,
        // so this path must not go through pad at all.
        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080), geometry: geometry),
            canvas: target)
        XCTAssertEqual(chain,
                       "scale=1920:1080:\(scalerFlags),setsar=1,fps=30,format=yuv420p,"
                       + "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill")
    }

    // MARK: Scale

    func testScaleMultipliesTheFittedSizeAndRecentres() {
        var geometry = ClipGeometry()
        geometry.scale = 0.5

        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1920, height: 1080)))

        XCTAssertEqual(placement.scaledSize, PixelSize(width: 960, height: 540))
        XCTAssertEqual(placement.padOrigin, PixelOffset(x: 480, y: 270))
        XCTAssertNil(placement.visibleCrop)
    }

    func testIdentityGeometryIsRecognised() {
        XCTAssertTrue(ClipGeometry().isIdentity)

        var moved = ClipGeometry()
        moved.offset = PixelOffset(x: 1, y: 0)
        XCTAssertFalse(moved.isIdentity)

        var cropped = ClipGeometry()
        cropped.sourceCrop = PixelRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertFalse(cropped.isIdentity)
    }

    // MARK: Crop snapping

    /// ffmpeg rounds an odd crop offset down to the chroma grid without saying
    /// so, so the editor has to land there first or its numbers describe a frame
    /// the export never makes.
    func testCropSnapsOntoTheChromaGrid() {
        let source = PixelSize(width: 1920, height: 1080)
        let snapped = PixelRect(x: 3, y: 5, width: 641, height: 481)
            .snappedToChromaGrid(in: source)

        XCTAssertEqual(snapped, PixelRect(x: 2, y: 4, width: 640, height: 480))
    }

    func testCropIsClampedInsideTheSourceFrame() {
        let source = PixelSize(width: 1920, height: 1080)

        // Larger than the frame: pinned to the frame, not silently accepted.
        XCTAssertEqual(PixelRect(x: 0, y: 0, width: 4000, height: 4000)
                        .snappedToChromaGrid(in: source),
                       PixelRect(x: 0, y: 0, width: 1920, height: 1080))

        // Pushed off the right edge: slid back in, keeping the requested size.
        XCTAssertEqual(PixelRect(x: 1900, y: 0, width: 400, height: 200)
                        .snappedToChromaGrid(in: source),
                       PixelRect(x: 1520, y: 0, width: 400, height: 200))

        XCTAssertNil(PixelRect(x: 0, y: 0, width: 10, height: 10)
                        .snappedToChromaGrid(in: .zero))
    }

    /// An odd-sized source cannot be cropped to its full frame on the chroma
    /// grid, and that near-miss is a real crop — collapsing it to "no crop"
    /// would hand ffmpeg the odd dimension back.
    func testOddSourceCroppedToItsEvenLimitStaysACrop() {
        let source = PixelSize(width: 641, height: 481)
        let snapped = PixelRect(x: 0, y: 0, width: 641, height: 481)
            .snappedToChromaGrid(in: source)

        XCTAssertEqual(snapped, PixelRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertFalse(try XCTUnwrap(snapped).coversWholeFrame(of: source))
        XCTAssertTrue(PixelRect(x: 0, y: 0, width: 641, height: 481)
                        .coversWholeFrame(of: source))
    }

    // MARK: Preview placement

    /// The preview draws from the unclamped origin and lets the canvas clip;
    /// export cannot, because pad rejects a negative origin. The two have to
    /// describe the same picture.
    func testUnclampedOriginTracksTheVisibleCrop() {
        var geometry = ClipGeometry()
        geometry.offset = PixelOffset(x: -300, y: 0)

        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1920, height: 1080)))

        XCTAssertEqual(placement.padOrigin, .zero)
        XCTAssertEqual(placement.visibleCrop,
                       PixelRect(x: 300, y: 0, width: 1620, height: 1080))
        XCTAssertEqual(placement.origin, PixelOffset(x: -300, y: 0))
    }

    func testOriginMatchesPadOriginWhenNothingOverflows() {
        let placement = FFTools.resolve(ClipGeometry(),
                                        source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1000, height: 1000)))
        XCTAssertNil(placement.visibleCrop)
        XCTAssertEqual(placement.origin, placement.padOrigin)
    }

    // MARK: Preview agrees with export

    /// The invariant Phase 2 exists to hold: the region of the source the
    /// preview leaves visible inside the canvas is the region ffmpeg keeps.
    /// Checked by mapping the preview's picture rect back into canvas pixels and
    /// intersecting it with the canvas, then comparing against the placement.
    func testPreviewPictureLandsWhereExportPutsIt() {
        let source = PixelSize(width: 1920, height: 1080)
        let target = canvas(PixelSize(width: 1080, height: 1920))

        var geometry = ClipGeometry()
        geometry.sourceCrop = PixelRect(x: 320, y: 0, width: 1280, height: 1080)
        let placement = FFTools.resolve(geometry, source: source, canvas: target)

        // One display point per canvas pixel keeps the comparison exact; the
        // real view uses whatever fits the pane.
        let frame = try! XCTUnwrap(CanvasStageLayout.sourceFrame(
            placement: placement, sourceSize: source, pointsPerCanvasPixel: 1))

        // Where the kept region of the source lands, in canvas pixels.
        let zoom = CGFloat(placement.scaledSize.width) / 1280
        let cropOnCanvas = CGRect(x: frame.minX + 320 * zoom, y: frame.minY,
                                  width: 1280 * zoom, height: 1080 * zoom)
        let visible = cropOnCanvas.intersection(
            CGRect(x: 0, y: 0, width: 1080, height: 1920))

        XCTAssertEqual(visible.minX, Double(placement.padOrigin.x), accuracy: 0.5)
        XCTAssertEqual(visible.minY, Double(placement.padOrigin.y), accuracy: 0.5)
        XCTAssertEqual(visible.width, Double(placement.scaledSize.width), accuracy: 0.5)
        XCTAssertEqual(visible.height, Double(placement.scaledSize.height), accuracy: 0.5)
    }

    /// An overflowing placement is where the two halves could most easily
    /// disagree: export trims with a second crop, the preview just lets the
    /// canvas clip.
    func testPreviewClipsExactlyWhatExportTrims() {
        let source = PixelSize(width: 1920, height: 1080)
        let target = canvas(PixelSize(width: 1920, height: 1080))

        var geometry = ClipGeometry()
        geometry.offset = PixelOffset(x: -300, y: 0)
        let placement = FFTools.resolve(geometry, source: source, canvas: target)

        let frame = try! XCTUnwrap(CanvasStageLayout.sourceFrame(
            placement: placement, sourceSize: source, pointsPerCanvasPixel: 1))
        let visible = frame.intersection(CGRect(x: 0, y: 0, width: 1920, height: 1080))

        let trimmed = try! XCTUnwrap(placement.visibleCrop)
        XCTAssertEqual(visible.width, Double(trimmed.width), accuracy: 0.5)
        XCTAssertEqual(visible.minX, Double(placement.padOrigin.x), accuracy: 0.5)
    }

    func testFullyOffCanvasDrawsNothing() {
        var geometry = ClipGeometry()
        geometry.offset = PixelOffset(x: 5000, y: 0)
        let placement = FFTools.resolve(geometry, source: PixelSize(width: 1920, height: 1080),
                                        canvas: canvas(PixelSize(width: 1920, height: 1080)))

        XCTAssertNil(CanvasStageLayout.sourceFrame(
            placement: placement, sourceSize: PixelSize(width: 1920, height: 1080),
            pointsPerCanvasPixel: 1))
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
