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

    /// 4:2:0 cannot describe an odd picture, so an odd canvas is written in
    /// 4:4:4 rather than rounded to an even size the user never asked for. An
    /// even canvas must keep 4:2:0: it is the hardware-decodable format, and
    /// changing it would change the bytes of every project already exported.
    func testDeliveryPixelFormatFollowsCanvasParity() throws {
        let input = videoItem(path: "/fixtures/input.mov", hasAudio: true)
        let output = URL(fileURLWithPath: "/exports/result.mp4")

        let odd = FFTools.assembleArgs(
            items: [input], audioURL: nil,
            canvas: CanvasSpec(width: 615, height: 820, fps: "30", fpsValue: 30),
            output: output)
        XCTAssertEqual(odd.value(after: "-pix_fmt"), "yuv444p")

        let even = FFTools.assembleArgs(
            items: [input], audioURL: nil,
            canvas: CanvasSpec(width: 1920, height: 1080, fps: "30", fpsValue: 30),
            output: output)
        XCTAssertEqual(even.value(after: "-pix_fmt"), "yuv420p")
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
        XCTAssertTrue(filter.contains("apad=whole_len=66150,atrim=end_sample=66150,asetpts=N/SR/TB[a0]"))
        XCTAssertFalse(filter.contains("adelay="), "A track already covering the video start needs no silence prefix")
        XCTAssertTrue(filter.contains("[1:v]scale=1280:720"))
        XCTAssertTrue(filter.contains("anullsrc=channel_layout=stereo:sample_rate=44100,atrim=end_sample=88200"))
        XCTAssertTrue(filter.contains("[v0][a0][v1][a1]concat=n=2:v=1:a=1[vout][aout]"))
    }

    func testDelayedAudioKeepsItsVideoRelativeOffset() throws {
        let video = videoItem(
            path: "/fixtures/delayed.mov",
            trimStart: 10,
            trimEnd: 14,
            duration: 4,
            hasAudio: true,
            inputStartTime: 10,
            audioStartTime: 12,
            audioEndTime: 14
        )

        let filter = try filter(for: video)

        XCTAssertTrue(filter.contains("[0:a]atrim=start=2.000000:end=4.000000"),
                      "Absolute source timestamps must be translated to ffmpeg's input-local clock")
        XCTAssertTrue(filter.contains("adelay=88200S:all=1"),
                      "Two seconds of leading silence must be expressed in exact samples")
        XCTAssertTrue(filter.contains("apad=whole_len=176400,atrim=end_sample=176400"))
    }

    func testAudioStartingBeforeVideoTrimsWithoutLeadingDelay() throws {
        let video = videoItem(
            path: "/fixtures/early.mov",
            trimStart: 10,
            trimEnd: 12,
            duration: 2,
            hasAudio: true,
            inputStartTime: 9,
            audioStartTime: 9,
            audioEndTime: 13
        )

        let filter = try filter(for: video)

        XCTAssertTrue(filter.contains("[0:a]atrim=start=1.000000:end=3.000000"))
        XCTAssertFalse(filter.contains("adelay="))
        XCTAssertTrue(filter.contains("apad=whole_len=88200,atrim=end_sample=88200"))
    }

    func testAudioEndingBeforeVideoIsPaddedToSegmentDuration() throws {
        let video = videoItem(
            path: "/fixtures/short-audio.mov",
            trimStart: 0,
            trimEnd: 2,
            duration: 2,
            hasAudio: true,
            audioStartTime: 0,
            audioEndTime: 1
        )

        let filter = try filter(for: video)

        XCTAssertTrue(filter.contains("[0:a]atrim=start=0.000000:end=1.000000"))
        XCTAssertTrue(filter.contains("apad=whole_len=88200,atrim=end_sample=88200"))
    }

    func testAudioOutsideVideoSelectionUsesSilentConcatSegment() throws {
        let video = videoItem(
            path: "/fixtures/no-overlap.mov",
            trimStart: 0,
            trimEnd: 2,
            duration: 2,
            hasAudio: true,
            audioStartTime: 3,
            audioEndTime: 4
        )

        let filter = try filter(for: video)

        XCTAssertFalse(filter.contains("[0:a]atrim="),
                       "An empty real-audio stream would make concat fail")
        XCTAssertTrue(filter.contains("anullsrc=channel_layout=stereo:sample_rate=44100,atrim=end_sample=88200"))
        XCTAssertTrue(filter.contains("[v0][a0]concat=n=1:v=1:a=1[vout][aout]"))
    }

    func testUnknownAudioDurationKeepsSourceThroughVideoBoundary() throws {
        let video = videoItem(
            path: "/fixtures/unknown-duration.mkv",
            trimStart: 0.25,
            trimEnd: 1.25,
            duration: 1,
            hasAudio: true,
            audioStartTime: 0.5,
            audioEndTime: nil
        )

        let filter = try filter(for: video)

        XCTAssertTrue(filter.contains("[0:a]atrim=start=0.500000:end=1.250000"))
        XCTAssertTrue(filter.contains("adelay=11025S:all=1"))
        XCTAssertFalse(filter.contains("anullsrc=channel_layout=stereo:sample_rate=44100"))
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

    func testProbeParsersRetainTrackAndFinalPacketTiming() throws {
        let packets = FFTools.parseFramePackets("0,48\n48,48\n96,24\n", timeBase: 1.0 / 600)
        XCTAssertEqual(packets.times, [0, 0.08, 0.16])
        XCTAssertEqual(try XCTUnwrap(packets.endTime), 0.20, accuracy: 1e-12)

        let missingDuration = FFTools.parseFramePackets("0,48\n48,\n96,24\n", timeBase: 1.0 / 600)
        XCTAssertEqual(missingDuration.times, [0, 0.08, 0.16])
        XCTAssertNil(missingDuration.endTime,
                     "One unknown packet duration must make probe use the stream-level end")
        let nonPositiveDuration = FFTools.parseFramePackets("0,48\n48,0\n96,24\n", timeBase: 1.0 / 600)
        XCTAssertEqual(nonPositiveDuration.times, [0, 0.08, 0.16])
        XCTAssertNil(nonPositiveDuration.endTime)

        let timing = try XCTUnwrap(FFTools.streamTiming([
            "start_time": "0.125",
            "duration": "1.500"
        ]))
        XCTAssertEqual(timing.start, 0.125, accuracy: 1e-12)
        XCTAssertEqual(timing.duration, 1.5, accuracy: 1e-12)
        XCTAssertEqual(timing.end, 1.625, accuracy: 1e-12)
        XCTAssertNil(FFTools.streamTiming(["start_time": "0.500"]),
                     "A missing duration is unknown timing, not a zero-length track")
        XCTAssertEqual(try XCTUnwrap(FFTools.finiteDouble("10.25")), 10.25, accuracy: 1e-12)
    }

    func testProbeDimensionsFollowDisplayRotation() {
        let portrait = FFTools.displayDimensions(
            codedWidth: 1920, codedHeight: 1080,
            stream: ["side_data_list": [["rotation": -90]]])
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)

        let upsideDown = FFTools.displayDimensions(
            codedWidth: 1920, codedHeight: 1080,
            stream: ["side_data_list": [["rotation": 180]]])
        XCTAssertEqual(upsideDown.width, 1920)
        XCTAssertEqual(upsideDown.height, 1080)

        let legacy = FFTools.displayDimensions(
            codedWidth: 640, codedHeight: 480,
            stream: ["tags": ["rotate": "90"]])
        XCTAssertEqual(legacy.width, 480)
        XCTAssertEqual(legacy.height, 640)

        let orientedStill = FFTools.displayDimensions(
            codedWidth: 120, codedHeight: 80,
            metadataSources: [
                ["side_data_list": [["rotation": -90]]],
                ["width": 120, "height": 80],
            ])
        XCTAssertEqual(orientedStill.width, 80)
        XCTAssertEqual(orientedStill.height, 120)
    }

    func testBlackPadLengthensThePictureAndRaisesTheAudioCeiling() throws {
        let video = videoItem(
            path: "/fixtures/padded-tail.mp4",
            trimStart: 0,
            trimEnd: 1,
            duration: 1.4,
            hasAudio: true,
            audioStartTime: 0,
            audioEndTime: 1.4,
            padDuration: 0.4
        )

        let filter = try filter(for: video)

        XCTAssertTrue(filter.contains("format=yuv420p,tpad=stop_mode=add:" +
                                      "stop_duration=0.400000:color=black[v0]"),
                      "Black is generated on the canvas lattice, after the fit chain")
        XCTAssertTrue(filter.contains("[0:a]atrim=start=0.000000:end=1.400000"),
                      "The pad exists so real audio may outrun the final frame")
        // 1.4 s at 44.1 kHz — the segment, black included, is sample-exact.
        XCTAssertTrue(filter.contains("apad=whole_len=61740,atrim=end_sample=61740"))
    }

    func testUnpaddedSegmentsCarryNoPadFilter() throws {
        let video = videoItem(path: "/fixtures/plain.mp4", hasAudio: true,
                              audioStartTime: 0, audioEndTime: 1)

        XCTAssertFalse(try filter(for: video).contains("tpad"))
    }

    private func videoItem(
        path: String,
        startFrame: Int = 0,
        endFrame: Int = 30,
        trimStart: Double = 0,
        trimEnd: Double = 1,
        duration: Double = 1,
        hasAudio: Bool,
        inputStartTime: Double = 0,
        audioStartTime: Double = 0,
        audioEndTime: Double? = nil,
        padDuration: Double = 0
    ) -> AssemblyItem {
        AssemblyItem(
            url: URL(fileURLWithPath: path),
            isImage: false,
            trimStartFrame: startFrame,
            trimEndFrame: endFrame,
            trimStart: trimStart,
            trimEnd: trimEnd,
            duration: duration,
            hasAudio: hasAudio,
            inputStartTime: inputStartTime,
            audioStartTime: audioStartTime,
            audioEndTime: audioEndTime,
            padDuration: padDuration
        )
    }

    private func filter(for item: AssemblyItem) throws -> String {
        let args = FFTools.assembleArgs(
            items: [item],
            audioURL: nil,
            canvas: CanvasSpec(width: 1280, height: 720, fps: "25", fpsValue: 25),
            output: URL(fileURLWithPath: "/exports/result.mp4")
        )
        return try XCTUnwrap(args.value(after: "-filter_complex"))
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
