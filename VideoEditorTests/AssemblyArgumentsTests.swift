import Foundation
import XCTest
@testable import VideoEditor

@MainActor
final class AssemblyArgumentsTests: XCTestCase {
    func testDeterministicEncodingProfileIsPinned() throws {
        let input = videoItem(path: "/fixtures/input.mov", hasAudio: true)
        let output = URL(fileURLWithPath: "/exports/result.mp4")

        let args = FFTools.assembleArgs(
            items: [input],
            audioURL: nil,
            canvas: CanvasSpec(width: 1920, height: 1080, fps: "30000/1001", fpsValue: 29.97),
            output: output
        )

        XCTAssertEqual(args.value(after: "-filter_threads"), "1")
        XCTAssertEqual(args.value(after: "-filter_complex_threads"), "1")
        XCTAssertEqual(args.value(after: "-cpuflags"), "0")
        XCTAssertEqual(args.value(after: "-sws_flags"), "bicubic+accurate_rnd+bitexact")
        XCTAssertEqual(args.value(after: "-preset"), "medium")
        XCTAssertEqual(args.value(after: "-crf"), "18")
        XCTAssertEqual(args.value(after: "-x264-params"),
                       "threads=1:lookahead-threads=1:deterministic=1:cpu-independent=1")
        XCTAssertEqual(args.value(after: "-aac_coder"), "twoloop")
        XCTAssertEqual(args.value(after: "-flags:v"), "+bitexact")
        XCTAssertEqual(args.value(after: "-flags:a"), "+bitexact")
        XCTAssertEqual(args.last, output.path)

        let filter = try XCTUnwrap(args.value(after: "-filter_complex"))
        XCTAssertTrue(filter.contains("flags=bicubic+accurate_rnd+bitexact:sws_dither=none"))
        XCTAssertTrue(filter.contains("internal_sample_fmt=s32p:dither_method=none:exact_rational=1"))

        // One per input plus one output-side occurrence. This protects against
        // accidentally applying the final per-file flag to the last input only.
        XCTAssertEqual(args.values(after: "-fflags"), ["+bitexact", "+bitexact"])
        let outputFFlags = try XCTUnwrap(args.lastIndex(of: "-fflags"))
        XCTAssertGreaterThan(outputFFlags, try XCTUnwrap(args.lastIndex(of: "-map_chapters")))
        XCTAssertLessThan(outputFFlags, args.endIndex - 1)
    }

    func testOriginalAudioAssemblyPreservesInputAndFrameMappings() throws {
        let video = videoItem(
            path: "/fixtures/a.mov",
            startFrame: 7,
            endFrame: 19,
            trimStart: 1.25,
            trimEnd: 2.75,
            duration: 1.5,
            hasAudio: true
        )
        let image = AssemblyItem(
            url: URL(fileURLWithPath: "/fixtures/b.png"),
            isImage: true,
            trimStartFrame: 0,
            trimEndFrame: 0,
            trimStart: 0,
            trimEnd: 2,
            duration: 2,
            hasAudio: false
        )

        let args = FFTools.assembleArgs(
            items: [video, image],
            audioURL: nil,
            canvas: CanvasSpec(width: 1280, height: 720, fps: "25", fpsValue: 25),
            output: URL(fileURLWithPath: "/exports/result.mp4")
        )

        XCTAssertEqual(args.values(after: "-i"), [video.url.path, image.url.path])
        XCTAssertEqual(args.values(after: "-map"), ["[vout]", "[aout]"])

        let filter = try XCTUnwrap(args.value(after: "-filter_complex"))
        XCTAssertTrue(filter.contains("[0:v]trim=start_frame=7:end_frame=19"))
        XCTAssertTrue(filter.contains("[0:a]atrim=start=1.250000:end=2.750000"))
        XCTAssertTrue(filter.contains("[1:v]scale=1280:720"))
        XCTAssertTrue(filter.contains("anullsrc=channel_layout=stereo:sample_rate=44100,atrim=0:2.000000"))
        XCTAssertTrue(filter.contains("[v0][a0][v1][a1]concat=n=2:v=1:a=1[vout][aout]"))
    }

    func testBackgroundAudioUsesFollowingInputAndExactTimelineDuration() throws {
        let first = videoItem(path: "/fixtures/a.mov", duration: 1.5, hasAudio: true)
        let second = videoItem(path: "/fixtures/b.mov", duration: 2.25, hasAudio: true)
        let music = URL(fileURLWithPath: "/fixtures/music.m4a")

        let args = FFTools.assembleArgs(
            items: [first, second],
            audioURL: music,
            canvas: CanvasSpec(width: 1920, height: 1080, fps: "30", fpsValue: 30),
            output: URL(fileURLWithPath: "/exports/result.mp4")
        )

        XCTAssertEqual(args.values(after: "-i"), [first.url.path, second.url.path, music.path])
        XCTAssertEqual(args.values(after: "-fflags"),
                       ["+bitexact", "+bitexact", "+bitexact", "+bitexact"])

        let filter = try XCTUnwrap(args.value(after: "-filter_complex"))
        XCTAssertTrue(filter.contains("[v0][v1]concat=n=2:v=1:a=0[vout]"))
        XCTAssertTrue(filter.contains("[2:a]aresample="))
        XCTAssertTrue(filter.contains("apad,atrim=0:3.750000"))
        XCTAssertFalse(filter.contains("[0:a]atrim="), "Background music must override source audio")
    }

    private func videoItem(
        path: String,
        startFrame: Int = 0,
        endFrame: Int = 30,
        trimStart: Double = 0,
        trimEnd: Double = 1,
        duration: Double = 1,
        hasAudio: Bool
    ) -> AssemblyItem {
        AssemblyItem(
            url: URL(fileURLWithPath: path),
            isImage: false,
            trimStartFrame: startFrame,
            trimEndFrame: endFrame,
            trimStart: trimStart,
            trimEnd: trimEnd,
            duration: duration,
            hasAudio: hasAudio
        )
    }
}

private extension Array where Element == String {
    func value(after option: String) -> String? {
        guard let index = firstIndex(of: option), index + 1 < endIndex else { return nil }
        return self[index + 1]
    }

    func values(after option: String) -> [String] {
        indices.compactMap { index in
            self[index] == option && index + 1 < endIndex ? self[index + 1] : nil
        }
    }
}
