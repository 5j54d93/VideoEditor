import Foundation
import QuartzCore
import XCTest
@testable import VideoEditor

/// Quarter turns. The property everything here leans on: a turn moves pixels
/// without resampling them, so the model's arithmetic, the preview's transforms
/// and ffmpeg's `transpose` can all be held to the same exact mapping — and a
/// crop can go round with its picture instead of being re-derived.
@MainActor
final class RotationTests: XCTestCase {

    private let scalerFlags = "flags=bicubic+accurate_rnd+bitexact:sws_dither=none"

    // MARK: The arithmetic

    func testAQuarterTurnStandsThePictureOnItsSide() {
        let size = PixelSize(width: 1920, height: 1080)
        XCTAssertEqual(ClipRotation.upright.turning(size), size)
        XCTAssertEqual(ClipRotation.clockwise.turning(size), PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(ClipRotation.upsideDown.turning(size), size)
        XCTAssertEqual(ClipRotation.counterclockwise.turning(size),
                       PixelSize(width: 1080, height: 1920))
    }

    func testTurnsWrapBothWays() {
        XCTAssertEqual(ClipRotation.upright.turned(by: 1), .clockwise)
        XCTAssertEqual(ClipRotation.upright.turned(by: -1), .counterclockwise)
        XCTAssertEqual(ClipRotation.counterclockwise.turned(by: 1), .upright)
        XCTAssertEqual(ClipRotation.clockwise.turned(by: 2), .counterclockwise)
        XCTAssertEqual(ClipRotation.upsideDown.turned(by: -6), .upright)
        for rotation in ClipRotation.allCases {
            XCTAssertEqual(rotation.turned(by: 4), rotation)
            XCTAssertEqual(rotation.turned(by: -4), rotation)
        }
    }

    /// Every pixel of a rectangle lands inside the turned rectangle, and the
    /// turned rectangle holds nothing else — checked pixel by pixel against
    /// the clockwise mapping `transpose=clock` applies, (x, y) → (H−1−y, x).
    func testATurnedRectangleHoldsExactlyTheSamePixels() {
        let size = PixelSize(width: 7, height: 4)
        let rect = PixelRect(x: 1, y: 1, width: 3, height: 2)
        let pixels = (rect.y..<rect.y + rect.height).flatMap { y in
            (rect.x..<rect.x + rect.width).map { x in (x, y) }
        }
        let mappings: [(ClipRotation, (Int, Int) -> (Int, Int))] = [
            (.upright, { x, y in (x, y) }),
            (.clockwise, { x, y in (size.height - 1 - y, x) }),
            (.upsideDown, { x, y in (size.width - 1 - x, size.height - 1 - y) }),
            (.counterclockwise, { x, y in (y, size.width - 1 - x) }),
        ]
        for (rotation, map) in mappings {
            let turned = rotation.turning(rect, in: size)
            let moved = pixels.map(map)
            XCTAssertEqual(turned.width * turned.height, moved.count, "\(rotation)")
            for (x, y) in moved {
                XCTAssertTrue((turned.x..<turned.x + turned.width).contains(x)
                              && (turned.y..<turned.y + turned.height).contains(y),
                              "\(rotation): (\(x), \(y)) fell outside \(turned)")
            }
        }
    }

    /// The preview turns its pictures with a matrix rather than with the
    /// model's integers. The two have to agree, or a turned crop would be drawn
    /// a pixel away from where export cuts it.
    func testThePreviewTransformPutsPixelsWhereTheModelDoes() {
        let size = PixelSize(width: 7, height: 4)
        let rect = PixelRect(x: 1, y: 1, width: 3, height: 2)
        for rotation in ClipRotation.allCases {
            let transform = rotation.placingTransform(
                for: CGSize(width: size.width, height: size.height))
            let drawn = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                .applying(transform)
            let turned = rotation.turning(rect, in: size)
            XCTAssertEqual(drawn, CGRect(x: turned.x, y: turned.y,
                                         width: turned.width, height: turned.height),
                           "\(rotation)")
            // Exactly on the axes: anything else is a resample, not a move.
            XCTAssertTrue([transform.a, transform.b, transform.c, transform.d]
                .allSatisfy { $0 == 0 || abs($0) == 1 }, "\(rotation)")
        }
    }

    /// A turned player layer covers the box it is given exactly, whichever way
    /// its view's y points.
    func testATurnedLayerCoversItsBoundsExactly() {
        let bounds = CGRect(x: 0, y: 0, width: 90, height: 160)
        for rotation in ClipRotation.allCases {
            for flipped in [false, true] {
                let layer = CALayer()
                layer.fill(bounds, turnedBy: rotation, flipped: flipped)
                XCTAssertEqual(layer.frame, bounds, "\(rotation), flipped: \(flipped)")
                XCTAssertEqual(layer.bounds.size, rotation.swapsAxes
                               ? CGSize(width: 160, height: 90) : bounds.size)
            }
        }
        // Clockwise is a negative angle under AppKit's upward y, positive
        // under a flipped one.
        let upward = CALayer(), downward = CALayer()
        upward.fill(bounds, turnedBy: .clockwise, flipped: false)
        downward.fill(bounds, turnedBy: .clockwise, flipped: true)
        XCTAssertEqual(upward.affineTransform(),
                       CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0))
        XCTAssertEqual(downward.affineTransform(),
                       CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))
    }

    // MARK: The filter chain

    /// The turn goes first, so the crop that follows is read in the turned
    /// picture's pixels — exactly the numbers the stage showed.
    func testAClockwiseTurnTransposesBeforeTheCrop() {
        var geometry = ClipGeometry(rotation: .clockwise)
        geometry.framing = .window(PixelRect(x: 0, y: 420, width: 1080, height: 1080))
        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080), geometry: geometry),
            canvas: canvas(PixelSize(width: 1080, height: 1080)))

        XCTAssertEqual(chain, "transpose=clock,crop=1080:1080:0:420:exact=1,"
                       + "scale=1080:1080:\(scalerFlags),pad=1080:1080:0:0,"
                       + "setsar=1,fps=30,format=yuv420p")
    }

    /// Uncropped, the turned picture is what fills the canvas: a landscape
    /// source stood upright fits a portrait frame without a letterbox.
    func testATurnedWholeFrameFillsATurnedCanvas() {
        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080),
                      geometry: ClipGeometry(rotation: .counterclockwise)),
            canvas: canvas(PixelSize(width: 1080, height: 1920)))

        XCTAssertEqual(chain, "transpose=cclock,scale=1080:1920:\(scalerFlags),"
                       + "pad=1080:1920:0:0,setsar=1,fps=30,format=yuv420p")
    }

    /// `rotate` would resample; two flips only move pixels.
    func testAHalfTurnFlipsRatherThanResampling() {
        let chain = FFTools.geometryChain(
            for: item(source: PixelSize(width: 1920, height: 1080),
                      geometry: ClipGeometry(rotation: .upsideDown)),
            canvas: canvas(PixelSize(width: 1920, height: 1080)))

        XCTAssertTrue(chain.hasPrefix("hflip,vflip,scale=1920:1080:"), chain)
        XCTAssertFalse(chain.contains("rotate"), chain)
        XCTAssertFalse(chain.contains("transpose"), chain)
    }

    /// An upright clip gets no filter at all — not even a no-op one — so the
    /// chain, and the bytes, of everything exported before rotation existed
    /// stay exactly what they were.
    func testAnUprightClipsChainHasNoTurnInIt() {
        let source = PixelSize(width: 1920, height: 1080)
        var geometry = ClipGeometry()
        geometry.framing = .window(PixelRect(x: 300, y: 40, width: 615, height: 820))
        for sourceSize in [source, .zero] {
            let chain = FFTools.geometryChain(
                for: item(source: sourceSize, geometry: geometry),
                canvas: canvas(PixelSize(width: 615, height: 820)))
            XCTAssertFalse(chain.contains("transpose"), chain)
            XCTAssertFalse(chain.contains("flip"), chain)
        }
        XCTAssertNil(FFTools.rotationFilter(.upright))
    }

    /// Without a probed size the fit falls back to ffmpeg's own expression,
    /// and the turn still has to come before it.
    func testATurnedClipWithoutAProbedSizeStillTurns() {
        let chain = FFTools.geometryChain(
            for: item(source: .zero, geometry: ClipGeometry(rotation: .clockwise)),
            canvas: canvas(PixelSize(width: 1080, height: 1920)))

        XCTAssertTrue(chain.hasPrefix("transpose=clock,scale=1080:1920:"
                                      + "force_original_aspect_ratio=decrease"), chain)
    }

    // MARK: The model

    /// Turning the clip that sets the output size turns the file: a sideways
    /// phone clip stood upright comes out portrait.
    func testTurningTheFirstClipTurnsTheOutput() throws {
        let (model, id) = stillModel()
        model.rotateItems([id], by: 1)

        XCTAssertEqual(model.items[0].geometry.rotation, .clockwise)
        XCTAssertEqual(model.items[0].orientedPixelSize, PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(model.canvas.width, 1080)
        XCTAssertEqual(model.canvas.height, 1920)
        let placement = try XCTUnwrap(model.placement(for: model.items[0]))
        XCTAssertNil(placement.sourceCrop, "Turning is not cropping")
        XCTAssertEqual(placement.scaledSize, PixelSize(width: 1080, height: 1920))

        model.undo()
        XCTAssertEqual(model.items[0].geometry.rotation, .upright)
        XCTAssertEqual(model.canvas.width, 1920)
    }

    /// The crop keeps the same pixels through a turn, so cropping first and
    /// standing the clip upright afterwards loses nothing.
    func testTheCropGoesRoundWithThePicture() {
        let (model, id) = stillModel()
        let crop = PixelRect(x: 300, y: 40, width: 615, height: 820)
        model.setFraming(.window(crop), for: id)

        model.rotateItems([id], by: 1)
        XCTAssertEqual(model.window(for: model.items[0]),
                       PixelRect(x: 1080 - 40 - 820, y: 300, width: 820, height: 615))
        XCTAssertEqual(model.canvas.width, 820)
        XCTAssertEqual(model.canvas.height, 615)

        model.rotateItems([id], by: 1)
        XCTAssertEqual(model.window(for: model.items[0]),
                       PixelRect(x: 1920 - 300 - 615, y: 1080 - 40 - 820,
                                 width: 615, height: 820))

        model.rotateItems([id], by: -2)
        XCTAssertEqual(model.window(for: model.items[0]), crop,
                       "Turned there and back, the crop is the one that was drawn")
        XCTAssertEqual(model.items[0].geometry.rotation, .upright)
    }

    /// A ratio lock describes the rectangle's shape, so it turns with it rather
    /// than snapping the turned rectangle back to the old shape on the next drag.
    func testARatioLockTurnsWithItsRectangle() throws {
        let (model, id) = stillModel()
        model.setAspectLock(.ratio(width: 16, height: 9), for: id)
        model.rotateItems([id], by: 1)
        XCTAssertEqual(model.items[0].geometry.aspectLock, .ratio(width: 9, height: 16))
        model.rotateItems([id], by: 2)
        XCTAssertEqual(model.items[0].geometry.aspectLock, .ratio(width: 9, height: 16),
                       "A half turn keeps the shape")

        // Locked to the source, it follows the source as it stands.
        model.setAspectLock(.source, for: id)
        let aspect = try XCTUnwrap(model.lockedAspect(for: model.items[0]))
        XCTAssertEqual(aspect, 1080.0 / 1920.0, accuracy: 1e-12)
    }

    /// R with a selection turns all of it, as one step.
    func testTurningASelectionIsOneUndoStep() {
        let (model, ids) = twoStillModel()
        model.selectedIDs = Set(ids)
        model.rotate(by: 1)
        XCTAssertEqual(model.items.map(\.geometry.rotation), [.clockwise, .clockwise])

        model.undo()
        XCTAssertEqual(model.items.map(\.geometry.rotation), [.upright, .upright])
    }

    /// With nothing selected, R turns the clip the preview is showing.
    func testWithNothingSelectedTheActiveClipTurns() {
        let (model, ids) = twoStillModel()
        model.selectItem(ids[1])
        model.clearSelection()
        model.rotate(by: -1)
        XCTAssertEqual(model.items.map(\.geometry.rotation), [.upright, .counterclockwise])
    }

    /// In the workspace R turns the clip being reframed, whatever the timeline
    /// had selected underneath.
    func testInTheWorkspaceOnlyTheReframedClipTurns() {
        let (model, ids) = twoStillModel()
        model.selectItem(ids[0])
        model.beginGeometryEditing()
        model.selectedIDs = Set(ids)
        XCTAssertEqual(model.rotationTargets, [ids[0]])
        model.rotate(by: 1)
        XCTAssertEqual(model.items.map(\.geometry.rotation), [.clockwise, .upright])
    }

    /// 取消 throws a turn away like any other change made in the session.
    func testCancellingTheWorkspaceTakesTheTurnBack() {
        let (model, id) = stillModel()
        model.beginGeometryEditing()
        model.rotateItems([id], by: 1)
        model.setFraming(.window(PixelRect(x: 10, y: 10, width: 500, height: 500)), for: id)

        model.cancelGeometryEditing()
        XCTAssertTrue(model.items[0].geometry.isIdentity)
        model.undo()
        XCTAssertTrue(model.items.isEmpty, "The insert must be the only step left behind")
    }

    /// 回到整張畫面 removes the crop and nothing else.
    func testPuttingTheWholeFrameBackKeepsTheTurn() {
        let (model, id) = stillModel()
        model.rotateItems([id], by: 1)
        model.setFraming(.window(PixelRect(x: 10, y: 10, width: 500, height: 500)), for: id)
        XCTAssertTrue(model.items[0].geometry.isCropped)

        model.resetGeometry(for: id)
        XCTAssertFalse(model.items[0].geometry.isCropped)
        XCTAssertEqual(model.items[0].geometry.rotation, .clockwise)
        XCTAssertFalse(model.items[0].geometry.isIdentity, "Turned is still an edit")
        XCTAssertEqual(model.canvas.width, 1080)
    }

    /// A turn is a real edit to the clip rail and to export, but zero of them
    /// is not an edit at all.
    func testAFullTurnIsNotAnEdit() {
        let (model, id) = stillModel()
        model.rotateItems([id], by: 4)
        model.rotateItems([id], by: 0)
        model.rotateItems([], by: 1)
        model.undo()
        XCTAssertTrue(model.items.isEmpty, "Nothing turned, so nothing was recorded")
    }

    /// 套用到全部 copies the turn with the crop: the window is in pixels of the
    /// turned picture and would mean something else on an unturned one.
    func testApplyingToAllCarriesTheTurn() {
        let large = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/large.png"),
                                 kind: .image, width: 1920, height: 1080)
        let small = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/small.png"),
                                 kind: .image, width: 1280, height: 720)
        let model = EditorModel()
        model.library = [large, small]
        model.insertLibraryAsset(large.id)
        model.insertLibraryAsset(small.id)
        let first = model.items[0].id
        model.rotateItems([first], by: 1)
        model.setFraming(.window(PixelRect(x: 0, y: 200, width: 1080, height: 1080)), for: first)

        model.applyGeometryToAllItems(from: first)

        XCTAssertEqual(model.items[1].geometry.rotation, .clockwise)
        XCTAssertEqual(model.window(for: model.items[1]),
                       PixelRect(x: 0, y: 200, width: 720, height: 1080),
                       "Clamped inside the second clip's own turned frame, 720×1280")
    }

    /// A turn mid-drag lands what the hand had placed — in the frame it was
    /// placed in — and lets the rest of the drag go, its coordinates belonging
    /// to a picture that has just turned under it.
    func testATurnMidDragKeepsWhatWasPlacedAndDropsTheRest() {
        let (model, id) = stillModel()
        model.beginGeometryEditing()
        let placed = PixelRect(x: 100, y: 50, width: 800, height: 600)
        model.beginGeometryGesture(for: id)
        model.previewFraming(placed, for: id)

        model.rotateItems([id], by: 1)
        XCTAssertNil(model.geometryDraft)
        let turned = ClipRotation.clockwise.turning(placed, in: PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(model.window(for: model.items[0]), turned)

        model.previewFraming(PixelRect(x: 0, y: 0, width: 10, height: 10), for: id)
        XCTAssertNil(model.geometryDraft, "The rest of the drag must not land anywhere")
        model.endGeometryGesture()
        XCTAssertEqual(model.window(for: model.items[0]), turned)

        model.undo()
        XCTAssertEqual(model.items[0].geometry.rotation, .upright)
        XCTAssertEqual(model.window(for: model.items[0]), placed,
                       "The drag is its own step, under the turn")
    }

    /// A split is a cut, not a fresh import: both halves stay turned.
    func testBothHalvesOfASplitStayTurned() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/split-turn.mp4"),
            kind: .video, width: 1920, height: 1080,
            duration: 1, fps: 25, fpsRational: "25",
            hasAudio: false, frameTimes: [0, 0.5, 0.96], frameEndTime: 1)
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        model.rotateItems([model.items[0].id], by: 1)

        model.seekTimeline(to: 0.5)
        model.splitAtPlayhead()

        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.items.map(\.geometry.rotation), [.clockwise, .clockwise])
    }

    // MARK: On the way out

    /// Export is handed the frame as decoded plus the turn, and the chain does
    /// the turning — never a pre-turned size the filter graph would disagree with.
    func testExportCarriesTheTurnAndTheDecodedSize() throws {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/sideways.mp4"),
            kind: .video, width: 1920, height: 1080,
            duration: 1, fps: 25, fpsRational: "25",
            hasAudio: false, frameTimes: [0, 0.5, 0.96], frameEndTime: 1)
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        model.rotateItems([model.items[0].id], by: 1)

        let exported = try XCTUnwrap(model.assemblyItemsForExport().first)
        XCTAssertEqual(exported.sourceSize, PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(exported.geometry.rotation, .clockwise)

        let args = FFTools.assembleArgs(items: [exported], canvas: model.canvas,
                                        output: URL(fileURLWithPath: "/exports/upright.mp4"))
        let filter = try XCTUnwrap(args.firstIndex(of: "-filter_complex").map { args[$0 + 1] })
        XCTAssertTrue(filter.contains("setpts=PTS-STARTPTS,transpose=clock,scale=1080:1920:"),
                      filter)
    }

    /// The export sheet's first frame is drawn the way the file will have it.
    func testTheExportPreviewDescribesTheTurnedPicture() throws {
        let (model, id) = stillModel()
        model.rotateItems([id], by: -1)

        let preview = try XCTUnwrap(ExportPreviewDescriptor.first(in: model.items,
                                                                  canvas: model.canvas))
        XCTAssertEqual(preview.rotation, .counterclockwise)
        XCTAssertEqual(preview.sourceSize, PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(preview.placement?.scaledSize, PixelSize(width: 1080, height: 1920))
    }

    // MARK: Helpers

    /// A 1920×1080 still on the timeline.
    private func stillModel() -> (EditorModel, ClipItem.ID) {
        let image = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/still.png"),
                                 kind: .image, width: 1920, height: 1080)
        let model = EditorModel()
        model.library = [image]
        model.insertLibraryAsset(image.id)
        return (model, model.items[0].id)
    }

    private func twoStillModel() -> (EditorModel, [ClipItem.ID]) {
        let first = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/first.png"),
                                 kind: .image, width: 1920, height: 1080)
        let second = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/second.png"),
                                  kind: .image, width: 1920, height: 1080)
        let model = EditorModel()
        model.library = [first, second]
        model.insertLibraryAsset(first.id)
        model.insertLibraryAsset(second.id)
        return (model, model.items.map(\.id))
    }

    private func canvas(_ size: PixelSize) -> CanvasSpec {
        CanvasSpec(width: size.width, height: size.height, fps: "30", fpsValue: 30)
    }

    private func item(source: PixelSize, geometry: ClipGeometry) -> AssemblyItem {
        AssemblyItem(url: URL(fileURLWithPath: "/fixtures/clip.mov"),
                     isImage: false,
                     trimStartFrame: 0, trimEndFrame: 30,
                     trimStart: 0, trimEnd: 1, duration: 1,
                     hasAudio: false,
                     sourceSize: source,
                     geometry: geometry)
    }
}
