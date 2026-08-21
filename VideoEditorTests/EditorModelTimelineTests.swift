import Foundation
import XCTest
@testable import VideoEditor

@MainActor
final class EditorModelTimelineTests: XCTestCase {
    func testImageDurationSliderGestureRegistersOneUndoStep() {
        let image = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/still.png"),
            kind: .image,
            width: 640,
            height: 480
        )
        let model = EditorModel()
        model.library = [image]
        model.imageDefaultDuration = 3
        model.insertLibraryAsset(image.id)
        let itemID = model.items[0].id

        model.beginImageDurationEditing(for: itemID)
        model.setImageDuration(4, for: itemID)
        model.setImageDuration(5, for: itemID)
        model.setImageDuration(6, for: itemID)
        model.endImageDurationEditing(for: itemID)

        model.undo()
        XCTAssertEqual(model.items[0].displayDuration, 3, accuracy: 1e-12)
        model.undo()
        XCTAssertTrue(model.items.isEmpty,
                      "The slider ticks must not displace the preceding insert undo step")
    }

    /// The output frame is the crop, with nothing in between. This is the whole
    /// point of dropping the canvas: what you frame is what the file is.
    func testOutputFrameIsTheFirstClipsCrop() throws {
        let image = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/still.png"),
                                 kind: .image, width: 1920, height: 1080)
        let model = EditorModel()
        model.library = [image]
        model.insertLibraryAsset(image.id)
        let itemID = model.items[0].id

        // Untouched, the output is the whole frame.
        XCTAssertEqual(model.canvas.width, 1920)
        XCTAssertEqual(model.canvas.height, 1080)

        // Crop to an odd, deliberately awkward rectangle: the file follows it
        // exactly rather than being rounded to an even size or fitted onto a
        // canvas of somebody else's choosing.
        model.setFraming(.window(PixelRect(x: 300, y: 40, width: 615, height: 820)),
                         for: itemID)
        XCTAssertEqual(model.canvas.width, 615)
        XCTAssertEqual(model.canvas.height, 820)
        XCTAssertTrue(model.canvas.hasOddDimension)

        // And the placement crops without scaling or padding: no black anywhere.
        let placement = try XCTUnwrap(model.placement(for: model.items[0]))
        XCTAssertEqual(placement.sourceCrop,
                       PixelRect(x: 300, y: 40, width: 615, height: 820))
        XCTAssertEqual(placement.scaledSize, PixelSize(width: 615, height: 820))
        XCTAssertEqual(placement.padOrigin, .zero)
    }

    func testTimelineIndexStaysCorrectAfterInsertTrimAndReorder() throws {
        let firstImage = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/first.png"),
            kind: .image,
            width: 640,
            height: 480
        )
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/video.mov"),
            kind: .video,
            width: 1920,
            height: 1080,
            duration: 2,
            fps: 2,
            fpsRational: "2",
            hasAudio: false,
            frameTimes: [0, 0.5, 1, 1.5]
        )
        let lastImage = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/last.png"),
            kind: .image,
            width: 800,
            height: 600
        )
        let model = EditorModel()
        model.library = [firstImage, video, lastImage]

        model.imageDefaultDuration = 2
        model.insertLibraryAsset(firstImage.id)
        model.insertLibraryAsset(video.id)
        model.imageDefaultDuration = 1
        model.insertLibraryAsset(lastImage.id)

        let firstID = model.items[0].id
        let videoID = model.items[1].id
        let lastID = model.items[2].id
        XCTAssertEqual(model.totalOutputDuration, 5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: firstID)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: videoID)), 2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: lastID)), 4, accuracy: 1e-12)

        model.setTrimStart(0.5, for: videoID)

        XCTAssertEqual(model.totalOutputDuration, 4.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: firstID)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: videoID)), 2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: lastID)), 3.5, accuracy: 1e-12)

        model.moveItems([lastID], to: 0)

        XCTAssertEqual(model.items.map(\.id), [lastID, firstID, videoID])
        XCTAssertEqual(model.totalOutputDuration, 4.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: lastID)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: firstID)), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.timelineStart(for: videoID)), 3, accuracy: 1e-12)
    }

    func testSubFrameAudioAndContainerTailIsVisibleAndAlignsWithoutDeletingVideo() {
        // Shorter than the 0.08 s frame, longer than the half-frame reporting
        // floor: still a sub-frame tail, still worth surfacing.
        let tail = 0.060_134
        let videoEnd = 0.16
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/short-tail.mp4"),
            kind: .video,
            width: 1920,
            height: 1080,
            duration: videoEnd + tail,
            fps: 12.5,
            fpsRational: "25/2",
            hasAudio: true,
            frameTimes: [0, 0.08],
            frameEndTime: videoEnd,
            audioStartTime: 0,
            audioDuration: videoEnd + tail
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)

        XCTAssertEqual(model.items[0].grid.frameCount, 2)
        XCTAssertEqual(model.items[0].outPoint, videoEnd, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].audioTailDuration, tail, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].containerTailDuration, tail, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].trailingOverhangDuration, tail, accuracy: 1e-12)
        XCTAssertEqual(model.totalOutputDuration, videoEnd, accuracy: 1e-12,
                       "A source tail is an overlay, not a fake output frame")
        let automaticExport = model.assemblyItemsForExport()
        XCTAssertEqual(automaticExport[0].trimEnd, videoEnd, accuracy: 1e-12,
                       "Export must cap unaligned source audio at the video boundary")
        XCTAssertEqual(try XCTUnwrap(automaticExport[0].audioEndTime), videoEnd + tail,
                       accuracy: 1e-12)
        XCTAssertEqual(automaticExport[0].duration, videoEnd, accuracy: 1e-12)

        let frameTimesBefore = model.items[0].frameTimes
        model.dismissTrailingOverhang(for: model.items[0].id)

        XCTAssertEqual(model.items[0].trailingOverhangDuration, 0, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].outPoint, videoEnd, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].frameTimes, frameTimesBefore)
        XCTAssertEqual(model.totalOutputDuration, videoEnd, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.assemblyItemsForExport()[0].audioEndTime),
                       videoEnd, accuracy: 1e-12,
                       "Dismissing records the cap the export already applied")

        model.undo()
        XCTAssertEqual(model.items[0].trailingOverhangDuration, tail, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].frameTimes, frameTimesBefore)
    }

    func testContainerOnlyTailCanBeAlignedIndependently() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/container-tail.mp4"),
            kind: .video,
            width: 640,
            height: 480,
            duration: 1.03,
            fps: 25,
            fpsRational: "25",
            hasAudio: false,
            frameTimes: [0, 0.96],
            frameEndTime: 1.0
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)

        XCTAssertEqual(model.items[0].audioTailDuration, 0, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].containerTailDuration, 0.03, accuracy: 1e-12)
        model.dismissTrailingOverhang(for: model.items[0].id)
        XCTAssertEqual(model.items[0].containerTailDuration, 0, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].grid.frameCount, 2)

        model.seekTimeline(to: 0.96)
        model.splitAtPlayhead()
        XCTAssertEqual(model.items.count, 2)
        XCTAssertTrue(model.items.allSatisfy { $0.containerTailDuration == 0 },
                      "Splitting an aligned clip must not resurrect its container tail")
    }

    func testMicrosecondContainerRoundingDoesNotBecomeAVisibleTail() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/edit-list-rounding.mp4"),
            kind: .video,
            width: 640,
            height: 480,
            duration: 1.000_001,
            fps: 25,
            fpsRational: "25",
            hasAudio: false,
            frameTimes: [0, 0.96],
            frameEndTime: 1.0
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)

        XCTAssertEqual(model.items[0].containerTailDuration, 0, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].trailingOverhangDuration, 0, accuracy: 1e-12)
    }

    func testOrdinaryVideoTrimDoesNotPermanentlyDismissSourceTail() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/reversible-trim.mp4"),
            kind: .video,
            width: 640,
            height: 480,
            duration: 1.04,
            fps: 25,
            fpsRational: "25",
            hasAudio: true,
            frameTimes: [0, 0.5, 0.96],
            frameEndTime: 1,
            audioStartTime: 0,
            audioDuration: 1.04
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        let id = model.items[0].id

        model.setTrimEnd(0.5, for: id)
        XCTAssertEqual(model.items[0].trailingOverhangDuration, 0, accuracy: 1e-12)
        XCTAssertNil(model.items[0].audioOutPoint)
        XCTAssertNil(model.items[0].containerOutPoint)

        model.setTrimEnd(1, for: id)
        XCTAssertEqual(model.items[0].trailingOverhangDuration, 0.04, accuracy: 1e-12)
        XCTAssertNil(model.items[0].audioOutPoint)
        XCTAssertNil(model.items[0].containerOutPoint)
    }

    func testMissingAudioDurationDoesNotTurnSourceAudioIntoSilence() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/audio-duration-missing.mkv"),
            kind: .video,
            width: 640,
            height: 480,
            duration: 1,
            fps: 25,
            fpsRational: "25",
            hasAudio: true,
            frameTimes: [0, 0.96],
            frameEndTime: 1,
            audioStartTime: 0.25,
            audioDuration: nil
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)

        XCTAssertNil(model.items[0].sourceAudioEndTime)
        XCTAssertEqual(model.items[0].audioTailDuration, 0, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].effectiveAudioOutPoint, 1, accuracy: 1e-12,
                       "Unknown timing should keep the lane, not model zero-length audio")
        let item = model.assemblyItemsForExport()[0]
        XCTAssertTrue(item.hasAudio)
        XCTAssertEqual(item.trimStart, 0, accuracy: 1e-12)
        XCTAssertEqual(item.trimEnd, 1, accuracy: 1e-12)
        XCTAssertEqual(item.inputStartTime, 0, accuracy: 1e-12)
        XCTAssertEqual(item.audioStartTime, 0.25, accuracy: 1e-12)
        XCTAssertNil(item.audioEndTime,
                     "Unknown source duration must remain unknown through export mapping")
    }

    func testDelayedAudioMetadataFlowsIntoSafeExportMapping() throws {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/delayed-audio.mov"),
            kind: .video,
            width: 640,
            height: 480,
            duration: 2,
            fps: 25,
            fpsRational: "25",
            hasAudio: true,
            frameTimes: [0, 1.96],
            frameEndTime: 2,
            audioStartTime: 0.5,
            audioDuration: 0.75
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)

        XCTAssertEqual(try XCTUnwrap(model.items[0].sourceAudioEndTime), 1.25, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].effectiveAudioOutPoint, 1.25, accuracy: 1e-12)
        let item = model.assemblyItemsForExport()[0]
        XCTAssertTrue(item.hasAudio)
        XCTAssertEqual(item.trimStart, 0, accuracy: 1e-12)
        XCTAssertEqual(item.trimEnd, 2, accuracy: 1e-12,
                       "Probe metadata must not produce an empty/shifted source-audio input")
        XCTAssertEqual(item.audioStartTime, 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(item.audioEndTime), 1.25, accuracy: 1e-12)
    }

    func testNonzeroTrackStartUsesAbsoluteEndsAndDurationSizedFallback() throws {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/nonzero-start.mp4"),
            kind: .video,
            width: 640,
            height: 480,
            duration: 2.04,
            fps: 25,
            fpsRational: "25",
            hasAudio: true,
            frameTimes: [],
            containerStartTime: 10,
            videoStartTime: 10,
            videoDuration: 2,
            frameEndTime: 12,
            audioStartTime: 10,
            audioDuration: 2.04
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        let clip = model.items[0]

        XCTAssertEqual(clip.grid.frameCount, 50)
        XCTAssertEqual(clip.inPoint, 10, accuracy: 1e-12)
        XCTAssertEqual(clip.outPoint, 12, accuracy: 1e-12)
        XCTAssertEqual(clip.sourceContainerEndTime, 12.04, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(clip.sourceAudioEndTime), 12.04, accuracy: 1e-12)
        XCTAssertEqual(clip.trailingOverhangDuration, 0.04, accuracy: 1e-12)
        XCTAssertEqual(model.totalOutputDuration, 2, accuracy: 1e-12)

        let item = model.assemblyItemsForExport()[0]
        XCTAssertTrue(item.hasAudio)
        XCTAssertEqual(item.trimStart, 10, accuracy: 1e-12)
        XCTAssertEqual(item.trimEnd, 12, accuracy: 1e-12)
        XCTAssertEqual(item.duration, 2, accuracy: 1e-12)
        XCTAssertEqual(item.inputStartTime, 10, accuracy: 1e-12)
        XCTAssertEqual(item.audioStartTime, 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(item.audioEndTime), 12.04, accuracy: 1e-12)
    }

    /// A tail shorter than half a frame can never reach the output — export caps
    /// original audio at the video boundary — so surfacing it only teaches people
    /// to dismiss warnings without reading them.
    func testTailShorterThanHalfAFrameIsNotReported() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/sub-half-frame.mp4"),
            kind: .video,
            width: 640,
            height: 480,
            duration: 1.016,
            fps: 25,
            fpsRational: "25",
            hasAudio: true,
            frameTimes: [0, 0.96],
            frameEndTime: 1,
            audioStartTime: 0,
            audioDuration: 1.016
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)

        XCTAssertEqual(model.items[0].tailReportingTolerance, 0.02, accuracy: 1e-12)
        XCTAssertEqual(model.items[0].trailingOverhangDuration, 0, accuracy: 1e-12)
        XCTAssertNil(model.items[0].tailSource)
        XCTAssertEqual(model.clipsWithTrailingOverhang, 0)
        XCTAssertEqual(try XCTUnwrap(model.assemblyItemsForExport()[0].audioEndTime),
                       1.016, accuracy: 1e-12,
                       "An unreported tail is still capped by the exporter, not deleted")
    }

    func testDismissingEveryTailDoesNotChangeWhatIsExported() throws {
        let model = EditorModel()
        model.library = (0..<2).map { index in
            LibraryAsset(
                url: URL(fileURLWithPath: "/fixtures/bulk-\(index).mp4"),
                kind: .video, width: 640, height: 480,
                duration: 1.05, fps: 25, fpsRational: "25",
                hasAudio: true, frameTimes: [0, 0.96], frameEndTime: 1,
                audioStartTime: 0, audioDuration: 1.05
            )
        }
        for asset in model.library { model.insertLibraryAsset(asset.id) }
        XCTAssertEqual(model.clipsWithTrailingOverhang, 2)

        let before = model.assemblyItemsForExport()
        model.dismissAllTrailingOverhangs()

        XCTAssertEqual(model.clipsWithTrailingOverhang, 0)
        XCTAssertEqual(model.totalOutputDuration, 2, accuracy: 1e-12)
        let after = model.assemblyItemsForExport()
        for (old, new) in zip(before, after) {
            XCTAssertEqual(old.duration, new.duration, accuracy: 1e-12)
            XCTAssertEqual(old.trimEnd, new.trimEnd, accuracy: 1e-12)
            // The recorded cap moves down to a boundary the exporter already
            // enforced, so the audio that actually survives is unchanged.
            XCTAssertEqual(min(old.trimEnd, try XCTUnwrap(old.audioEndTime)),
                           min(new.trimEnd, try XCTUnwrap(new.audioEndTime)),
                           accuracy: 1e-12)
        }
        model.undo()
        XCTAssertEqual(model.clipsWithTrailingOverhang, 2)
    }

    func testExtendingVideoLengthensTheMovieAndKeepsTheAudioTail() throws {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/long-tail.mp4"),
            kind: .video, width: 640, height: 480,
            duration: 1.4, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 0.96], frameEndTime: 1,
            audioStartTime: 0, audioDuration: 1.4
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        let id = model.items[0].id

        XCTAssertEqual(model.items[0].trailingOverhangDuration, 0.4, accuracy: 1e-12)
        XCTAssertTrue(model.canExtendVideoToAudioTail)
        model.extendVideoToAudioTail(for: id)

        let clip = model.items[0]
        XCTAssertEqual(clip.videoPadDuration, 0.4, accuracy: 1e-12)
        XCTAssertEqual(clip.contentDuration, 1, accuracy: 1e-12,
                       "Padding must not invent frames")
        XCTAssertEqual(clip.displayDuration, 1.4, accuracy: 1e-12)
        XCTAssertEqual(clip.outPoint, 1, accuracy: 1e-12)
        XCTAssertEqual(clip.trailingOverhangDuration, 0, accuracy: 1e-12,
                       "The pad resolves the tail it was created for")
        XCTAssertEqual(model.totalOutputDuration, 1.4, accuracy: 1e-12)

        let item = model.assemblyItemsForExport()[0]
        XCTAssertEqual(item.duration, 1.4, accuracy: 1e-12)
        XCTAssertEqual(item.trimEnd, 1, accuracy: 1e-12,
                       "The picture still stops at the final real frame")
        XCTAssertEqual(item.padDuration, 0.4, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(item.audioEndTime), 1.4, accuracy: 1e-12)

        model.undo()
        XCTAssertEqual(model.items[0].videoPadDuration, 0, accuracy: 1e-12)
        XCTAssertEqual(model.totalOutputDuration, 1, accuracy: 1e-12)
    }

    func testBlackPadPreviewBeginsAtTheExclusiveVideoBoundary() throws {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/pad-boundary.mp4"),
            kind: .video, width: 640, height: 480,
            duration: 1.4, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 0.96], frameEndTime: 1,
            audioStartTime: 0, audioDuration: 1.4)
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        model.extendVideoToAudioTail(for: model.items[0].id)

        model.seekTimeline(to: 1 - 1e-6)
        XCTAssertFalse(model.isPlayheadInVideoPad)
        model.updateTimelineHover(at: 1 - 1e-6)
        XCTAssertFalse(try XCTUnwrap(model.timelinePreview).isBlackPad)

        model.seekTimeline(to: 1)
        XCTAssertEqual(model.timelineTime, 1, accuracy: 1e-12)
        XCTAssertTrue(model.isPlayheadInVideoPad)
        model.updateTimelineHover(at: 1)
        XCTAssertTrue(try XCTUnwrap(model.timelinePreview).isBlackPad)
    }

    func testPadFollowsTheHalfThatStillEndsOnTheFinalFrame() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/split-pad.mp4"),
            kind: .video, width: 640, height: 480,
            duration: 1.4, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 0.5, 0.96], frameEndTime: 1,
            audioStartTime: 0, audioDuration: 1.4
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        model.extendVideoToAudioTail(for: model.items[0].id)

        model.seekTimeline(to: 0.5)
        model.splitAtPlayhead()

        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.items[0].videoPadDuration, 0, accuracy: 1e-12)
        XCTAssertEqual(model.items[1].videoPadDuration, 0.4, accuracy: 1e-12)
        XCTAssertEqual(model.totalOutputDuration, 1.4, accuracy: 1e-12)

        // Re-trimming the padded half retires the black: it existed to carry
        // audio past one specific final frame.
        model.setTrimEnd(0.96, for: model.items[1].id)
        XCTAssertEqual(model.items[1].videoPadDuration, 0, accuracy: 1e-12)
    }

    func testSelectAllThenDeleteClearsTheTimelineAsOneUndoStep() {
        let image = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/still.png"),
            kind: .image, width: 640, height: 480
        )
        let model = EditorModel()
        model.library = [image]
        model.insertLibraryAsset(image.id)
        model.insertLibraryAsset(image.id)
        model.insertLibraryAsset(image.id)

        model.selectAllItems()
        XCTAssertEqual(model.selectedIDs.count, 3)
        XCTAssertTrue(model.timelineHasFocus)

        model.removeSelectedItems()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.selectedIDs.isEmpty)

        model.undo()
        XCTAssertEqual(model.items.count, 3,
                       "A bulk delete must come back in a single undo step")
    }

    func testLibrarySelectAllSkipsFilteredOutAssets() {
        let png = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/still.png"),
            kind: .image, width: 640, height: 480
        )
        let mov = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/take.mov"),
            kind: .video, width: 1920, height: 1080,
            duration: 1, fps: 1, fpsRational: "1", hasAudio: false, frameTimes: [0]
        )
        let model = EditorModel()
        model.library = [png, mov]
        model.focusedPane = .library

        model.libraryKindFilter = .video
        XCTAssertTrue(model.selectAllInFocusedPane())
        XCTAssertEqual(model.selectedLibraryIDs, [mov.id],
                       "A hidden asset must not end up selected — Delete would remove it unseen")

        model.libraryKindFilter = nil
        model.librarySearchText = "still"
        model.selectAllLibraryAssets()
        XCTAssertEqual(model.selectedLibraryIDs, [png.id])

        // Nothing matching means nothing to select, and ⌘A stays free.
        model.librarySearchText = "nothing-matches-this"
        model.clearSelection()
        XCTAssertFalse(model.selectAllInFocusedPane())
        XCTAssertTrue(model.selectedLibraryIDs.isEmpty)
    }

    func testClickingALibraryCardReleasesAStuckSearchField() {
        let png = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/still.png"),
            kind: .image, width: 640, height: 480
        )
        let model = EditorModel()
        model.library = [png]

        // A search field that keeps focus after the pointer moves on would
        // swallow ⌘A and every single-key shortcut.
        model.isTextEditing = true
        model.selectLibraryAsset(png.id)
        XCTAssertFalse(model.isTextEditing)
    }

    func testSelectAllStaysOutOfTheLibraryPane() {
        let image = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/still.png"),
            kind: .image, width: 640, height: 480
        )
        let model = EditorModel()
        model.library = [image]
        model.insertLibraryAsset(image.id)

        // A selected library card owns Delete, so it must own ⌘A too.
        model.selectLibraryAsset(image.id)
        XCTAssertFalse(model.timelineHasFocus)

        // Clicking blank space clears both domains; the last-clicked pane decides.
        model.clearSelection()
        model.focusedPane = .library
        XCTAssertFalse(model.timelineHasFocus)
        model.focusedPane = .timeline
        XCTAssertTrue(model.timelineHasFocus)

        model.selectAllItems()
        XCTAssertEqual(model.selectedIDs, [model.items[0].id])
        XCTAssertTrue(model.selectedLibraryIDs.isEmpty)
    }
}
