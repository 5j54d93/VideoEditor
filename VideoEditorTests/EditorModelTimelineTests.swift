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
}
