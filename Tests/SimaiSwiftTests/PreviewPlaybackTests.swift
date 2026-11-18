// SPDX-License-Identifier: GPL-3.0-only
#if canImport(UIKit)
import AVFoundation
import SimaiSwift
import XCTest

final class PreviewPlaybackTests: XCTestCase {
    @MainActor func testPreviewScrubbingPreservesPlaybackState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestAudio(to: url)
        let chart = try SimaiChartParser.parse(notation: "(120){4}1,2,3,4,5,6,7,8,E", offset: 1)
        let controller = SimaiPlayerController(chart: chart, audioURL: url)
        defer { controller.stop() }
        await controller.prepare()
        XCTAssertNotNil(controller.chart, controller.errorMessage ?? "Missing chart")

        controller.scrub(to: 1)
        XCTAssertEqual(controller.clock.currentTime, 1)
        controller.finishScrubbing(at: 2)
        XCTAssertEqual(controller.clock.currentTime, 2)
        XCTAssertFalse(controller.isPlaying)

        controller.play()
        XCTAssertTrue(controller.isPlaying)
        try await waitForClock(controller, past: 2.1)

        controller.scrub(to: 0.5)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.clock.currentTime, 0.5)
        controller.scrub(to: 1)
        XCTAssertEqual(controller.clock.currentTime, 1)
        controller.finishScrubbing(at: 1.5)
        XCTAssertEqual(controller.clock.currentTime, 1.5)
        XCTAssertTrue(controller.isPlaying)
        try await waitForClock(controller, past: 1.6, floor: 1.5)
    }

    @MainActor private func waitForClock(
        _ controller: SimaiPlayerController, past target: TimeInterval, floor: TimeInterval = 0
    ) async throws {
        for _ in 0..<100 {
            let time = controller.clock.currentTime
            XCTAssertGreaterThanOrEqual(time, floor, "Playback jumped behind the released scrubber")
            if time > target { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Presentation clock did not advance past \(target)")
    }

    private func writeTestAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<10 { try file.write(from: buffer) }
    }
}
#endif
