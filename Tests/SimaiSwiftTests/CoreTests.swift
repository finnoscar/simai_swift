import CoreGraphics
import SimaiSwift
import XCTest

final class CoreTests: XCTestCase {
    func testRawNotationAndMaidataDifficulty() throws {
        let raw = try SimaiChartParser.parse(notation: "(120){4}1,2,3,4,E", offset: 1)
        XCTAssertEqual(raw.noteCount, 4)
        XCTAssertEqual(raw.events.first?.time ?? -1, 1, accuracy: 0.000001)
        let maidata = "&title=Example\n&bpm=120\n&inote_2=1,E\n&inote_5=2,3,E"
        let master = try SimaiChartParser.parse(maidata: maidata, levelIndex: 3)
        XCTAssertEqual(master.title, "Example")
        XCTAssertEqual(master.noteCount, 2)
        XCTAssertThrowsError(try SimaiChartParser.parse(maidata: maidata, levelIndex: 4))
        XCTAssertThrowsError(try SimaiChartParser.parse(notation: "E"))
        XCTAssertThrowsError(try SimaiChartParser.parse(notation: "1,E", bpm: .nan))
    }

    func testFlagsSlideGeometryAndLateNoteBounds() throws {
        let chart = try SimaiChartParser.parse(notation: "(120){4}1b,2x,3h[4:1],4-8[4:1],E")
        XCTAssertTrue(chart.events[0].flags.contains(.breakNote))
        XCTAssertTrue(chart.events[1].flags.contains(.ex))
        XCTAssertEqual(chart.events[2].kind, .hold)
        let path = try XCTUnwrap(chart.events.last?.slidePaths.first)
        let geometry = SimaiSlidePathGeometry.geometry(for: path, mirror: .none)
        XCTAssertFalse(geometry.branches.isEmpty)
        XCTAssertGreaterThan(geometry.branches[0].length, 0)
        let late = SimaiNoteMotion.ringState(progress: 2)
        XCTAssertEqual(late.radius, 1)
        XCTAssertEqual(late.scale, 1)
    }

    @MainActor func testPublicTouchInputAndScoring() async throws {
        let chart = try SimaiChartParser.parse(notation: "(120){4}1,2,E", offset: 1)
        let session = SimaiGameplaySession(chart: chart, gameplayEventBus: GameplayEventBus())
        var settings = SimaiPlaybackSettings()
        settings.hitSoundEnabled = false
        settings.answerSoundEnabled = false
        settings.judgementSoundEnabled = false
        let event = chart.events[0]
        let contact = SimaiTouchContact(id: 1, point: event.location.normalizedPoint(), timestamp: event.time)
        session.handle(
            frame: SimaiTouchFrame(active: [contact], changed: [contact], phase: .began),
            playbackTimeAtSystemUptime: { $0 }, settings: settings)
        XCTAssertEqual(session.lastJudgement, .criticalPerfect)
        XCTAssertEqual(session.combo, 1)
        XCTAssertEqual(session.dxScore, 3)
        session.reset()
        XCTAssertEqual(session.combo, 0)
        XCTAssertEqual(session.judgedCount, 0)
    }

    func testIndependentEventStream() async throws {
        let bus = GameplayEventBus()
        var iterator = bus.events().makeAsyncIterator()
        bus.publish(
            GameplayEvent(
                timestamp: 1, kind: .noteHit, noteType: .tap, lane: 1, judge: .criticalPerfect, timingOffsetMs: 0,
                duration: nil))
        let event = await iterator.next()
        XCTAssertEqual(event?.kind, .noteHit)
        XCTAssertEqual(event?.lane, 1)
        XCTAssertEqual(event?.judge, .criticalPerfect)
    }
}
