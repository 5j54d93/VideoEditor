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

    /// The preview plays a padded clip's sound on under its black, so the fades
    /// have to be read over the span the export shapes: picture and black
    /// together. A fade-out set on the clip finishes at the end of the black.
    func testAPaddedClipsOwnSoundFadesOverItsBlackAsTheExportDoes() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/fading-tail.mp4"),
            kind: .video, width: 640, height: 480,
            duration: 1.4, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 0.96], frameEndTime: 1,
            audioStartTime: 0, audioDuration: 1.4)
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        let id = model.items[0].id
        model.extendVideoToAudioTail(for: id)
        model.setOriginalAudioFades(in: 0, out: 0.8, for: id)

        let clip = model.items[0]
        XCTAssertEqual(clip.audioLevel(at: 0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(clip.audioLevel(at: 1.0), 0.5, accuracy: 1e-12,
                       "Where the picture stops the fade is only half done")
        XCTAssertEqual(clip.audioLevel(at: 1.2), 0.25, accuracy: 1e-12)
        XCTAssertEqual(clip.audioLevel(at: 1.4), 0, accuracy: 1e-12)

        // The curve the export writes over the clip's segment, point for point.
        let item = model.assemblyItemsForExport()[0]
        for offset in stride(from: 0.0, through: 1.4, by: 0.1) {
            XCTAssertEqual(clip.audioLevel(at: offset),
                           audioGain(at: offset, duration: item.duration, gain: item.audioGain,
                                     fadeIn: item.audioFadeIn, fadeOut: item.audioFadeOut),
                           accuracy: 1e-12, "at \(offset)")
        }
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

    /// A split is a cut through one clip, not a fresh import: both halves keep
    /// the framing the whole clip had, and the output size stays with them.
    func testSplitKeepsTheCropOnBothHalves() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/split-crop.mp4"),
            kind: .video, width: 1920, height: 1080,
            duration: 1, fps: 25, fpsRational: "25",
            hasAudio: false, frameTimes: [0, 0.5, 0.96], frameEndTime: 1
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        model.setFraming(.window(PixelRect(x: 300, y: 40, width: 615, height: 820)),
                         for: model.items[0].id)
        let geometry = model.items[0].geometry
        XCTAssertFalse(geometry.isIdentity)

        model.seekTimeline(to: 0.5)
        model.splitAtPlayhead()

        XCTAssertEqual(model.items.count, 2)
        XCTAssertNotEqual(model.items[0].id, model.items[1].id)
        XCTAssertEqual(model.items[0].geometry, geometry)
        XCTAssertEqual(model.items[1].geometry, geometry,
                       "The second half must not fall back to the whole frame")
        XCTAssertEqual(model.items[0].outPoint, 0.5, accuracy: 1e-12)
        XCTAssertEqual(model.items[1].inPoint, 0.5, accuracy: 1e-12)
        XCTAssertEqual(model.canvas.width, 615)
        XCTAssertEqual(model.canvas.height, 820)
    }

    // MARK: A drag in flight

    /// A 1920×1080 still on the timeline with the crop workspace open — the
    /// state every drag starts from.
    private func reframingModel() -> (EditorModel, ClipItem.ID) {
        let image = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/still.png"),
                                 kind: .image, width: 1920, height: 1080)
        let model = EditorModel()
        model.library = [image]
        model.insertLibraryAsset(image.id)
        model.beginGeometryEditing()
        return (model, model.items[0].id)
    }

    /// A drag is shown as it happens but stored once, when it lets go. Writing
    /// each step into `items` re-laid out the whole window per pointer event,
    /// which is what made the rectangle stutter under the hand.
    func testDragIsShownLiveButStoredOnceWhenItLetsGo() {
        let (model, id) = reframingModel()
        let first = PixelRect(x: 100, y: 50, width: 800, height: 600)
        let last = PixelRect(x: 120, y: 60, width: 801, height: 601)

        model.beginGeometryGesture(for: id)
        model.previewFraming(first, for: id)
        model.previewFraming(last, for: id)

        XCTAssertTrue(model.items[0].geometry.isIdentity,
                      "Nothing reaches the project until the drag ends")
        XCTAssertEqual(model.displayedWindow(for: model.items[0]), last)
        XCTAssertEqual(model.displayedCanvas.width, 801,
                       "The output size follows the drag while it is in flight")
        XCTAssertEqual(model.displayedCanvas.height, 601)
        XCTAssertEqual(model.canvas.width, 1920)

        model.endGeometryGesture()
        XCTAssertNil(model.geometryDraft)
        XCTAssertEqual(model.window(for: model.items[0]), last)
        XCTAssertEqual(model.canvas.width, 801)

        model.undo()
        XCTAssertTrue(model.items[0].geometry.isIdentity,
                      "The whole drag comes back in one undo step")
    }

    /// What the stage shows mid-drag has to be what gets stored, so the draft
    /// is clamped by the same rule as the stored window.
    func testDraftIsClampedExactlyAsTheStoredWindowIs() {
        let (model, id) = reframingModel()
        let overhanging = PixelRect(x: 1700, y: -40, width: 400, height: 300)

        model.beginGeometryGesture(for: id)
        model.previewFraming(overhanging, for: id)
        let shown = model.displayedWindow(for: model.items[0])
        XCTAssertEqual(shown, overhanging.clampedWindow(in: PixelSize(width: 1920, height: 1080)))

        model.endGeometryGesture()
        XCTAssertEqual(model.window(for: model.items[0]), shown)
    }

    /// 取消 throws the session away, a drag still in the hand included.
    func testCancellingMidDragKeepsNothing() {
        let (model, id) = reframingModel()
        model.beginGeometryGesture(for: id)
        model.previewFraming(PixelRect(x: 100, y: 50, width: 800, height: 600), for: id)

        model.cancelGeometryEditing()
        XCTAssertNil(model.geometryDraft)
        XCTAssertTrue(model.items[0].geometry.isIdentity)

        model.undo()
        XCTAssertTrue(model.items.isEmpty,
                      "The insert must be the only step left behind")
    }

    /// 完成 keeps what is on screen, even when it is pressed before the drag
    /// has let go — and it is still one undo step.
    func testFinishingMidDragKeepsWhatTheHandPlaced() {
        let (model, id) = reframingModel()
        let placed = PixelRect(x: 100, y: 50, width: 800, height: 600)
        model.beginGeometryGesture(for: id)
        model.previewFraming(placed, for: id)

        model.endGeometryEditing()
        XCTAssertFalse(model.isGeometryEditing)
        XCTAssertEqual(model.window(for: model.items[0]), placed)

        model.undo()
        XCTAssertTrue(model.items[0].geometry.isIdentity)
    }

    /// ⌘Z mid-drag abandons the drag: the rest of it moves nothing, and
    /// letting go afterwards stores nothing either.
    func testUndoMidDragAbandonsTheRestOfIt() {
        let (model, id) = reframingModel()
        let earlier = PixelRect(x: 10, y: 10, width: 1000, height: 500)
        model.setFraming(.window(earlier), for: id)

        model.beginGeometryGesture(for: id)
        model.previewFraming(PixelRect(x: 100, y: 50, width: 800, height: 600), for: id)
        model.undo()
        XCTAssertTrue(model.items[0].geometry.isIdentity)

        model.previewFraming(PixelRect(x: 300, y: 200, width: 640, height: 360), for: id)
        XCTAssertNil(model.geometryDraft)
        model.endGeometryGesture()
        XCTAssertTrue(model.items[0].geometry.isIdentity)

        model.redo()
        XCTAssertEqual(model.window(for: model.items[0]), earlier,
                       "The abandoned drag must not have touched the history")
    }

    // MARK: The whole frame is not an edit

    /// A click inside the crop rectangle is a drag that moves nothing, and what
    /// it proposes is the frame it started from. That must not count as
    /// reframing: `isIdentity` is what marks a clip touched in the clip rail,
    /// what enables 回到整張畫面, and what sends export down the untouched path.
    func testADragThatProposesTheWholeFrameIsNotAnEdit() {
        let (model, id) = reframingModel()
        let whole = PixelRect(x: 0, y: 0, width: 1920, height: 1080)

        model.beginGeometryGesture(for: id)
        model.previewFraming(whole, for: id)
        XCTAssertNil(model.displayedPlacement(for: model.items[0])?.sourceCrop,
                     "Mid-drag, the stage must already resolve it as the whole frame")
        model.endGeometryGesture()

        XCTAssertTrue(model.items[0].geometry.isIdentity)
        XCTAssertNil(model.placement(for: model.items[0])?.sourceCrop,
                     "Export must take the whole-frame path, not crop to the frame")
        model.undo()
        XCTAssertTrue(model.items.isEmpty, "A drag that changed nothing costs no history")
    }

    /// Typing the frame's own numbers back in — or dragging the rectangle out
    /// past the edges — is the way back to an untouched clip, and has to arrive
    /// at exactly the default rather than at a rectangle that merely matches it.
    func testAWindowCoveringTheWholeFrameIsStoredAsTheDefault() {
        let (model, id) = reframingModel()
        model.setFraming(.window(PixelRect(x: 100, y: 50, width: 800, height: 600)), for: id)
        XCTAssertFalse(model.items[0].geometry.isIdentity)
        XCTAssertEqual(model.canvas.width, 800)

        model.setFraming(.window(PixelRect(x: 0, y: 0, width: 1920, height: 1080)), for: id)
        XCTAssertTrue(model.items[0].geometry.isIdentity)
        XCTAssertEqual(model.canvas.width, 1920)
        XCTAssertEqual(model.canvas.height, 1080)

        // Overhanging every edge, the clamp brings it back to the frame, and
        // the frame is the default.
        model.setFraming(.window(PixelRect(x: -20, y: -20, width: 2000, height: 1200)), for: id)
        XCTAssertTrue(model.items[0].geometry.isIdentity)
    }

    /// Nudging a window that already covers the frame has nowhere to go.
    func testNudgingTheWholeFrameChangesNothing() {
        let (model, _) = reframingModel()
        model.nudgeGeometry(dx: 1, dy: 0)
        model.nudgeGeometry(dx: 0, dy: -1, coarse: true)
        XCTAssertTrue(model.items[0].geometry.isIdentity)
        model.undo()
        XCTAssertTrue(model.items.isEmpty, "Nothing moved, so nothing was recorded")
    }

    /// Copying a crop onto a smaller clip that it covers entirely leaves that
    /// clip untouched, rather than cropped to its own edges.
    func testApplyingACropThatCoversASmallerClipLeavesItUntouched() {
        let large = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/large.png"),
                                 kind: .image, width: 3840, height: 2160)
        let small = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/small.png"),
                                 kind: .image, width: 1280, height: 720)
        let model = EditorModel()
        model.library = [large, small]
        model.insertLibraryAsset(large.id)
        model.insertLibraryAsset(small.id)
        model.setFraming(.window(PixelRect(x: 0, y: 0, width: 1920, height: 1080)),
                         for: model.items[0].id)

        model.applyGeometryToAllItems(from: model.items[0].id)

        XCTAssertFalse(model.items[0].geometry.isIdentity)
        XCTAssertTrue(model.items[1].geometry.isIdentity,
                      "A 1920×1080 window clamped to a 1280×720 frame is that frame")
    }

    // MARK: The audio track

    /// A three-second still with a ten-second piece of music under it from
    /// 0.5 s, the music selected — the state every track test starts from.
    private func trackModel() -> (EditorModel, AudioClip.ID) {
        let image = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/still.png"),
                                 kind: .image, width: 640, height: 480)
        let music = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/music.m4a"),
                                 kind: .audio, duration: 10)
        let model = EditorModel()
        model.library = [image, music]
        model.imageDefaultDuration = 3
        model.insertLibraryAsset(image.id)
        model.seekTimeline(to: 0.5)
        model.insertLibraryAsset(music.id)
        return (model, model.audioClips[0].id)
    }

    /// Sound joins the movie under the playhead and leaves its length alone:
    /// the track is heard under the picture, never appended to it.
    func testAudioLandsUnderThePlayheadWithoutLengtheningTheMovie() {
        let (model, id) = trackModel()

        XCTAssertEqual(model.audioClips.count, 1)
        XCTAssertEqual(model.audioClips[0].timelineStart, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.audioClips[0].duration, 10, accuracy: 1e-9)
        XCTAssertEqual(model.totalOutputDuration, 3, accuracy: 1e-9)
        XCTAssertEqual(model.selectedAudioIDs, [id])
        XCTAssertTrue(model.selectedIDs.isEmpty, "Selecting sound deselects the picture")

        model.undo()
        XCTAssertTrue(model.audioClips.isEmpty)
        XCTAssertEqual(model.items.count, 1)
    }

    /// Before there is any picture there is nothing to put sound under, so a
    /// drop starts it with the movie wherever it lands — where the library's
    /// add puts it too. Once there is a picture, a drop puts it where it was
    /// dropped.
    func testSoundDroppedBeforeThereIsAPictureStartsWithTheMovie() {
        let image = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/still.png"),
                                 kind: .image, width: 640, height: 480)
        let music = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/music.m4a"),
                                 kind: .audio, duration: 10)
        let model = EditorModel()
        model.library = [image, music]
        model.imageDefaultDuration = 3

        model.insertAudioClip(from: music, at: 4.2)
        model.insertAudioClip(from: music, at: 1.5)
        model.insertLibraryAsset(music.id)
        XCTAssertEqual(model.audioClips.map(\.timelineStart), [0, 0, 0],
                       "Sound alone is no picture to place more sound against")

        model.insertLibraryAsset(image.id)
        model.insertAudioClip(from: music, at: 1.5)
        XCTAssertEqual(model.audioClips.last?.timelineStart ?? -1, 1.5, accuracy: 1e-9)
    }

    /// S cuts whatever is selected under the playhead. With sound selected
    /// that is the sound: the halves stay where they were on the movie, and
    /// the fades stay with the ends they belong to.
    func testSplittingSoundKeepsItInPlaceAndTheFadesWithTheirEnds() {
        let (model, id) = trackModel()
        model.setAudioClipFades(in: 0.4, out: 0.6, for: id)
        model.seekTimeline(to: 2)

        model.splitAtPlayhead()

        XCTAssertEqual(model.items.count, 1, "The picture under the sound is not cut")
        XCTAssertEqual(model.audioClips.count, 2)
        let left = model.audioClips[0], right = model.audioClips[1]
        XCTAssertEqual(left.timelineStart, 0.5, accuracy: 1e-9)
        XCTAssertEqual(left.outPoint, 1.5, accuracy: 1e-9)
        XCTAssertEqual(right.inPoint, 1.5, accuracy: 1e-9)
        XCTAssertEqual(right.timelineStart, 2, accuracy: 1e-9)
        XCTAssertEqual(right.outPoint, 10, accuracy: 1e-9)
        XCTAssertEqual(left.fadeIn, 0.4, accuracy: 1e-9)
        XCTAssertEqual(left.fadeOut, 0)
        XCTAssertEqual(right.fadeIn, 0)
        XCTAssertEqual(right.fadeOut, 0.6, accuracy: 1e-9)
        XCTAssertEqual(model.selectedAudioIDs, [right.id])
    }

    /// Trimming the head moves the start with the in point, so the sound stays
    /// where it was heard; a reach past the file or before the movie is held
    /// at the edge rather than obeyed.
    func testTrimmingSoundIsClampedToTheFileAndTheMovie() {
        let (model, id) = trackModel()

        model.trimAudioClip(id, inPoint: 1, outPoint: 4, timelineStart: 1.5)
        XCTAssertEqual(model.audioClips[0].inPoint, 1, accuracy: 1e-9)
        XCTAssertEqual(model.audioClips[0].outPoint, 4, accuracy: 1e-9)
        XCTAssertEqual(model.audioClips[0].timelineStart, 1.5, accuracy: 1e-9)

        model.trimAudioClip(id, inPoint: -2, outPoint: 50, timelineStart: -1)
        XCTAssertEqual(model.audioClips[0].inPoint, 0, accuracy: 1e-9)
        XCTAssertEqual(model.audioClips[0].outPoint, 10, accuracy: 1e-9)
        XCTAssertEqual(model.audioClips[0].timelineStart, 0, accuracy: 1e-9)

        model.moveAudioClip(id, to: 2.25)
        XCTAssertEqual(model.audioClips[0].timelineStart, 2.25, accuracy: 1e-9)
        XCTAssertEqual(model.audioClips[0].inPoint, 0, accuracy: 1e-9,
                       "Moving changes where the sound starts, not what plays")
    }

    /// Detaching puts the clip's sound on the track as a piece of its own and
    /// silences the clip, level and all — export hears it from the track only.
    func testDetachingSoundMovesItToTheTrackAndSilencesTheClip() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/talk.mp4"),
            kind: .video, width: 1920, height: 1080,
            duration: 4, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 1, 2, 3], frameEndTime: 4, audioDuration: 4
        )
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        let id = model.items[0].id
        model.setOriginalAudioGain(0.5, for: id)
        XCTAssertTrue(model.canDetachSoundTarget, "⌃⇧S reaches the clip under the playhead")

        model.detachOriginalAudio(from: id)

        XCTAssertTrue(model.items[0].isAudioMuted)
        XCTAssertEqual(model.items[0].effectiveAudioGain, 0)
        XCTAssertEqual(model.audioClips.count, 1)
        let clip = model.audioClips[0]
        XCTAssertEqual(clip.url, model.items[0].url)
        XCTAssertEqual(clip.inPoint, 0, accuracy: 1e-9)
        XCTAssertEqual(clip.outPoint, 4, accuracy: 1e-9)
        XCTAssertEqual(clip.timelineStart, 0, accuracy: 1e-9)
        XCTAssertEqual(clip.gain, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.assemblyItemsForExport()[0].audioGain, 0)
        XCTAssertEqual(model.assemblyAudioClipsForExport()[0].gain, 0.5, accuracy: 1e-9)

        model.undo()
        XCTAssertFalse(model.items[0].isAudioMuted)
        XCTAssertTrue(model.audioClips.isEmpty)
    }

    /// ⌫ takes the selected sound and nothing else, and comes back in one step.
    func testDeletingSelectedSoundLeavesThePictureAndUndoes() {
        let (model, id) = trackModel()

        model.removeSelectedItems()
        XCTAssertTrue(model.audioClips.isEmpty)
        XCTAssertEqual(model.items.count, 1)

        model.undo()
        XCTAssertEqual(model.audioClips.map(\.id), [id])
    }

    /// Removing an asset takes its sound off the track with it.
    func testRemovingAnAssetTakesItsSoundOffTheTrack() throws {
        let (model, _) = trackModel()
        let music = try XCTUnwrap(model.library.first { $0.kind == .audio })

        model.removeFromLibrary(music.id)

        XCTAssertTrue(model.audioClips.isEmpty)
        XCTAssertFalse(model.isSourceMedia(music.url))
    }

    /// ↑ and ↓ move the playhead between cuts: back to the start of the clip it
    /// is in, or of the one before when it already sits on a cut; on to the
    /// next clip's start, and past the last one to the movie's end.
    func testTheArrowsJumpBetweenCuts() {
        func video(_ name: String) -> LibraryAsset {
            LibraryAsset(url: URL(fileURLWithPath: "/fixtures/\(name).mp4"),
                         kind: .video, width: 640, height: 480,
                         duration: 1, fps: 25, fpsRational: "25",
                         hasAudio: true, frameTimes: [0, 0.96], frameEndTime: 1,
                         audioStartTime: 0, audioDuration: 1)
        }
        let first = video("cut-a"), last = video("cut-b")
        let still = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/cut-still.png"),
                                 kind: .image, width: 640, height: 480)
        let model = EditorModel()
        model.library = [first, still, last]
        model.imageDefaultDuration = 3
        model.insertLibraryAsset(first.id)
        model.insertLibraryAsset(still.id)
        model.insertLibraryAsset(last.id)
        XCTAssertEqual(model.cutTimes, [0, 1, 4, 5])

        model.seekTimeline(to: 2.5)
        XCTAssertFalse(model.canSplitAtPlayhead, "A still has no frames to cut between")
        model.jumpToPreviousCut()
        XCTAssertEqual(model.timelineTime, 1, accuracy: 1e-9, "Back to the start of the clip it is in")
        model.jumpToPreviousCut()
        XCTAssertEqual(model.timelineTime, 0, accuracy: 1e-9, "On a cut, back to the one before")
        model.jumpToPreviousCut()
        XCTAssertEqual(model.timelineTime, 0, accuracy: 1e-9)

        model.jumpToNextCut()
        XCTAssertEqual(model.timelineTime, 1, accuracy: 1e-9)
        model.jumpToNextCut()
        XCTAssertEqual(model.timelineTime, 4, accuracy: 1e-9)
        model.jumpToNextCut()
        XCTAssertEqual(model.timelineTime, model.totalOutputDuration, accuracy: 1e-9,
                       "Past the last clip, the movie's end")

        model.seekTimeline(to: 0.5)
        XCTAssertTrue(model.canSplitAtPlayhead)
    }

    /// What the 剪輯 menu offers, and what it calls an item, follows what the
    /// key would do.
    func testTheEditMenuFollowsWhatTheKeysWouldDo() {
        let (model, piece) = trackModel()
        XCTAssertTrue(model.canShapeSoundTargets)
        XCTAssertFalse(model.soundTargetsAreQuiet)
        model.toggleMuteForSoundTargets()
        XCTAssertTrue(model.soundTargetsAreQuiet, "Muted, the item offers to bring it back")
        XCTAssertFalse(model.canDetachSoundTarget, "A piece of the track has no picture to come off")

        model.selectOnly(model.items[0].id)
        XCTAssertFalse(model.canShapeSoundTargets, "A still has no sound to shape")

        model.selectAudioClip(piece)
        XCTAssertTrue(model.canDeleteSelection)
        model.deleteSelection()
        XCTAssertTrue(model.audioClips.isEmpty, "⌫ on the timeline takes the selected sound")
        XCTAssertFalse(model.canDeleteSelection, "Nothing left selected, nothing for ⌫ to take")
    }

    /// A slider drag is one undo step, however many values it sends.
    func testAGainDragIsOneUndoStep() {
        let (model, id) = trackModel()
        let key = "audio-gain:\(id)"

        model.beginContinuousEdit(key)
        model.setAudioClipGain(0.8, for: id)
        model.setAudioClipGain(0.6, for: id)
        model.setAudioClipGain(0.4, for: id)
        model.endContinuousEdit(key)
        XCTAssertEqual(model.audioClips[0].gain, 0.4, accuracy: 1e-9)

        model.undo()
        XCTAssertEqual(model.audioClips[0].gain, 1, accuracy: 1e-9)
        XCTAssertEqual(model.audioClips.count, 1, "The step before the drag was the insert, not a tick of it")
    }

    /// Sound is kept the way its labels read it — whole percents, hundredths
    /// of a second — and a pair of fades never overlaps: the one being moved
    /// stops at the other instead of pushing it.
    func testSoundIsKeptAsItsLabelsReadIt() {
        let (model, id) = trackModel()
        model.setAudioClipGain(0.8349, for: id)
        XCTAssertEqual(model.audioClips[0].gain, 0.83)

        model.setAudioClipFades(in: 6, out: 0, for: id)
        model.setAudioClipFades(in: 6, out: 7, for: id)
        XCTAssertEqual(model.audioClips[0].fadeIn, 6)
        XCTAssertEqual(model.audioClips[0].fadeOut, 4, accuracy: 1e-9, "The fade-out stops at the fade-in")
        model.setAudioClipFades(in: 8, out: 4, for: id)
        XCTAssertEqual(model.audioClips[0].fadeIn, 6, accuracy: 1e-9, "And the fade-in at the fade-out")
        model.setAudioClipFades(in: 1.234, out: 4, for: id)
        XCTAssertEqual(model.audioClips[0].fadeIn, 1.23)
    }

    /// A clip's own fades follow the same rule over the clip's span.
    func testAClipsOwnFadesStopAtEachOther() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/own-fades.mp4"),
            kind: .video, width: 640, height: 480,
            duration: 1, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 0.96], frameEndTime: 1,
            audioStartTime: 0, audioDuration: 1)
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        let id = model.items[0].id

        model.setOriginalAudioFades(in: 0.7, out: 0, for: id)
        model.setOriginalAudioFades(in: 0.7, out: 0.6, for: id)
        XCTAssertEqual(model.items[0].audioFadeIn, 0.7)
        XCTAssertEqual(model.items[0].audioFadeOut, 0.3, accuracy: 1e-9)
        model.setOriginalAudioGain(1.456, for: id)
        XCTAssertEqual(model.items[0].audioGain, 1.46)
    }

    /// A menu opened on a selection shapes all of it, each change one undo
    /// step, and passes over what has no sound of its own.
    func testShapingSeveralSoundsAtOnceIsOneStepEach() {
        let (model, id) = trackModel()
        let still = model.items[0].id
        model.setAudioClipGain(0.5, for: id)
        model.setAudioClipFades(in: 1, out: 2, for: id)
        let shaped = model.audioClips[0]

        model.setSoundMuted(true, pieces: [id], clips: [still])
        XCTAssertTrue(model.audioClips[0].isMuted)
        XCTAssertFalse(model.items[0].isAudioMuted, "A still has no sound to mute")
        model.resetSoundGain(pieces: [id], clips: [])
        model.removeSoundFades(pieces: [id], clips: [])
        XCTAssertEqual(model.audioClips[0].gain, 1)
        XCTAssertEqual(model.audioClips[0].fadeIn, 0)
        XCTAssertEqual(model.audioClips[0].fadeOut, 0)

        model.undo()
        model.undo()
        model.undo()
        XCTAssertEqual(model.audioClips[0], shaped)
    }

    /// The same for a clip's own sound.
    func testAClipsOwnSoundMutesFromItsMenu() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/menu-mute.mp4"),
            kind: .video, width: 640, height: 480,
            duration: 1, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 0.96], frameEndTime: 1,
            audioStartTime: 0, audioDuration: 1)
        let model = EditorModel()
        model.library = [video]
        model.insertLibraryAsset(video.id)
        let id = model.items[0].id

        model.setSoundMuted(true, pieces: [], clips: [id])
        XCTAssertTrue(model.items[0].isAudioMuted)
        model.undo()
        XCTAssertFalse(model.items[0].isAudioMuted)
    }

    /// M, ⌃= ⌃− and ⌃⇧S act on the selection, and with nothing selected on
    /// the clip being heard — the rule R has. M quiets everything it reaches
    /// unless all of it is already quiet; a muted sound keeps its level.
    func testTheSoundKeysActOnTheSelectionOrTheClipBeingHeard() {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/keys.mp4"),
            kind: .video, width: 640, height: 480,
            duration: 1, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 0.96], frameEndTime: 1,
            audioStartTime: 0, audioDuration: 1)
        let music = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/keys.m4a"),
                                 kind: .audio, duration: 10)
        let model = EditorModel()
        model.library = [video, music]
        model.insertLibraryAsset(video.id)
        let clip = model.items[0].id
        model.insertLibraryAsset(music.id)
        let piece = model.audioClips[0].id

        XCTAssertEqual(model.soundTargets.pieces, [piece], "The piece just laid down is selected")
        model.toggleMuteForSoundTargets()
        XCTAssertTrue(model.audioClips[0].isMuted)
        XCTAssertFalse(model.items[0].isAudioMuted)

        model.clearSelection()
        XCTAssertEqual(model.soundTargets.clips, [clip], "With nothing selected, the clip being heard")
        model.nudgeGainForSoundTargets(by: 0.05)
        XCTAssertEqual(model.items[0].audioGain, 1.05)
        model.nudgeGainForSoundTargets(by: -0.05)
        model.nudgeGainForSoundTargets(by: -0.05)
        XCTAssertEqual(model.items[0].audioGain, 0.95)

        model.selectOnly(clip)
        model.toggleAudioSelection(piece)
        model.toggleMuteForSoundTargets()
        XCTAssertTrue(model.items[0].isAudioMuted, "One of them was sounding, so both go quiet")
        XCTAssertTrue(model.audioClips[0].isMuted)
        model.nudgeGainForSoundTargets(by: 0.05)
        XCTAssertEqual(model.items[0].audioGain, 0.95, "A muted sound keeps its level")
        model.toggleMuteForSoundTargets()
        XCTAssertFalse(model.items[0].isAudioMuted, "All were quiet, so all come back")
        XCTAssertFalse(model.audioClips[0].isMuted)

        model.selectOnly(clip)
        model.detachSoundTarget()
        XCTAssertEqual(model.audioClips.count, 2, "⌃⇧S puts the clip's own sound on the track")
        XCTAssertTrue(model.items[0].isAudioMuted)

        model.selectLibraryAsset(video.id)
        XCTAssertTrue(model.soundTargets.pieces.isEmpty && model.soundTargets.clips.isEmpty,
                      "Over the library the sound keys reach nothing")
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
