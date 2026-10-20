import Foundation
import XCTest
@testable import VideoEditor

/// What the toolbar's six adjustments act on, when each has nothing to, and
/// how the two ways into a panel find its subject.
@MainActor
final class AdjustmentTests: XCTestCase {
    /// A four-second video with sound — a second of it past the last frame
    /// when `tail` is set — then a three-second still.
    private func project(tail: Double = 0) -> (EditorModel, video: ClipItem.ID, still: ClipItem.ID) {
        let video = LibraryAsset(
            url: URL(fileURLWithPath: "/fixtures/talk.mp4"),
            kind: .video, width: 1920, height: 1080,
            duration: 4 + tail, fps: 25, fpsRational: "25",
            hasAudio: true, frameTimes: [0, 1, 2, 3], frameEndTime: 4,
            audioStartTime: 0, audioDuration: 4 + tail
        )
        let image = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/still.png"),
                                 kind: .image, width: 640, height: 480)
        let model = EditorModel()
        model.library = [video, image]
        model.imageDefaultDuration = 3
        model.insertLibraryAsset(video.id)
        model.insertLibraryAsset(image.id)
        return (model, model.items[0].id, model.items[1].id)
    }

    private func available(_ model: EditorModel) -> Set<EditorModel.Adjustment> {
        Set(EditorModel.Adjustment.allCases.filter(model.canAdjust))
    }

    /// With nothing selected the tools act on the clip under the playhead, and
    /// say so; each offers only what that clip has.
    func testWithNothingSelectedTheToolsActOnTheClipUnderThePlayhead() {
        let (model, video, still) = project()
        model.clearSelection()
        model.seekTimeline(to: 0.5)

        XCTAssertEqual(model.adjustmentSubject.clips, [video])
        XCTAssertTrue(model.adjustmentSubject.isUnderPlayhead)
        XCTAssertEqual(available(model), [.crop, .rotate, .sound, .info],
                       "A video has sound but no display time, and this one no tail")

        model.seekTimeline(to: 5)
        XCTAssertEqual(model.adjustedClip?.id, still)
        XCTAssertEqual(available(model), [.crop, .rotate, .length, .info],
                       "A still has a display time and no sound")
    }

    /// The selection wins over the playhead, as it does for R and M.
    func testTheSelectionWinsOverThePlayhead() {
        let (model, _, still) = project()
        model.seekTimeline(to: 0.5)
        model.selectOnly(still)

        XCTAssertEqual(model.adjustedClip?.id, still)
        XCTAssertFalse(model.adjustmentSubject.isUnderPlayhead)
        XCTAssertTrue(model.canAdjust(.length))
    }

    /// A piece of the track has sound and facts, nothing else.
    func testASelectedPieceOffersItsSoundAndItsInfo() {
        let (model, _, _) = project()
        let music = LibraryAsset(url: URL(fileURLWithPath: "/fixtures/music.m4a"), kind: .audio, duration: 10)
        model.library.append(music)
        model.seekTimeline(to: 0.5)
        model.insertLibraryAsset(music.id)
        let piece = model.audioClips[0].id

        XCTAssertEqual(model.adjustmentSubject.pieces, [piece])
        XCTAssertEqual(model.adjustedPiece?.id, piece)
        XCTAssertNil(model.adjustedClip)
        XCTAssertEqual(available(model), [.sound, .info])
    }

    /// Several clips turn together and have their sound shaped together, but
    /// the panels that describe one clip have none to describe.
    func testSeveralClipsShareTheTurnAndTheSoundButNotTheOneClipPanels() {
        let (model, video, still) = project()
        model.selectOnly(still)
        model.toggleSelection(video)

        XCTAssertEqual(model.adjustmentSubject.clips, [video, still], "Timeline order, not the order of the clicks")
        XCTAssertNil(model.adjustedClip)
        XCTAssertEqual(model.adjustedSoundClips, [video], "Only the video has sound of its own")
        XCTAssertEqual(available(model), [.rotate, .sound])
    }

    /// 尾端 is there only while there is a tail to speak of.
    func testTheTailToolLastsAsLongAsTheTail() {
        let (model, video, _) = project(tail: 1)
        model.selectOnly(video)
        XCTAssertTrue(model.canAdjust(.tail))

        model.dismissTrailingOverhang(for: video)
        XCTAssertFalse(model.canAdjust(.tail))
    }

    /// 進入裁切 opens the workspace on the clip its panel describes, taking the
    /// playhead there first, and the panel goes with the toolbar.
    func testEnteringTheCropFromItsPanelGoesToTheClipItDescribes() {
        let (model, _, still) = project()
        model.seekTimeline(to: 0.5)
        model.selectOnly(still)
        model.openAdjustment = .crop

        model.beginGeometryEditing(on: still)

        XCTAssertTrue(model.isGeometryEditing)
        XCTAssertEqual(model.activeItem?.id, still)
        XCTAssertNil(model.openAdjustment)
    }

    /// The toolbar can only be read, not told, where its items go: the gap
    /// after the tools grows by however far right of the preview's middle
    /// they landed, and is left alone once they are within a point of it.
    func testTheGapAfterTheToolsBringsThemOntoThePreviewsMiddle() {
        XCTAssertEqual(AdjustmentAlignment.gap(current: 0, groupMidX: 1001, targetMidX: 790.5), 211)
        XCTAssertEqual(AdjustmentAlignment.gap(current: 211, groupMidX: 790.2, targetMidX: 790.5), 211)
        XCTAssertEqual(AdjustmentAlignment.gap(current: 100, groupMidX: 760, targetMidX: 790), 70,
                       "Too far left gives some of the gap back")
        XCTAssertEqual(AdjustmentAlignment.gap(current: 10, groupMidX: 700, targetMidX: 790), 0,
                       "A gap cannot go below nothing; the tools then stand as far right as they can")
    }
}
