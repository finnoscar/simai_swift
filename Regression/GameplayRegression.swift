// Native engine regressions. Compiled by Tools/test_native_regressions.rb.
@main @MainActor
struct SimaiGameplayRegressionTests {
    static var settings: SimaiPlaybackSettings {
        var value = SimaiPlaybackSettings()
        value.answerSoundEnabled = false
        value.judgementSoundEnabled = false
        value.hitSoundEnabled = false
        return value
    }

    static func chart(_ text: String) throws -> SimaiChart {
        try SimaiChartParser.parse(maidata: "&bpm=120\n&first=1\n&inote_2=\(text),E", levelIndex: 0)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            fflush(stdout)
            preconditionFailure(message)
        }
    }

    static func input(_ session: SimaiGameplaySession, _ point: CGPoint, _ time: Double, _ phase: SimaiTouchFrame.Phase, id: Int = 1, settings playbackSettings: SimaiPlaybackSettings? = nil) {
        let contact = SimaiTouchContact(id: id, point: point, timestamp: time)
        session.handle(frame: SimaiTouchFrame(active: phase == .ended || phase == .cancelled ? [] : [contact], changed: [contact], phase: phase), playbackTimeAtSystemUptime: { $0 }, settings: playbackSettings ?? settings)
    }

    static func tap(_ session: SimaiGameplaySession, _ event: SimaiNoteEvent, offset: Double = 0) {
        let point = event.location.normalizedPoint()
        input(session, point, event.time + offset, .began)
        input(session, point, event.time + offset + 0.001, .ended)
    }

    static func swipe(_ session: SimaiGameplaySession, _ path: SimaiSlidePath, additionalPaths: [SimaiSlidePath] = [], hz: Int = 120, batch: Int = 1) {
        let branches = ([path] + additionalPaths).flatMap { SimaiSlidePathGeometry.geometry(for: $0, mirror: .none).branches }
        let count = max(1, Int(path.duration * Double(hz)))
        input(session, branches[0].sample(at: 0).point, path.startTime, .began)
        var pending: [SimaiTouchContact] = []
        for i in 1...count {
            let progress = Double(i) / Double(count)
            let time = path.startTime + progress * path.duration
            for (index, branch) in branches.enumerated() {
                pending.append(SimaiTouchContact(id: index + 1, point: branch.sample(at: progress).point, timestamp: time))
            }
            if i % batch == 0 || i == count {
                let active = branches.enumerated().map { index, branch in SimaiTouchContact(id: index + 1, point: branch.sample(at: progress).point, timestamp: time) }
                session.handle(frame: SimaiTouchFrame(active: active, changed: pending, phase: .moved), playbackTimeAtSystemUptime: { $0 }, settings: settings)
                pending.removeAll()
                session.update(time: time, settings: settings)
            }
        }
        input(session, branches[0].sample(at: 1).point, path.endTime + 0.001, .ended)
    }

    static func endpointHandoffRegression() throws {
        let c = try chart("1-5[4:1]")
        let event = c.events[0]
        let path = event.slidePaths[0]
        var cases = 0
        for mirror in SimaiMirrorMode.allCases {
            var playbackSettings = settings
            playbackSettings.mirror = mirror
            let geometry = SimaiSlidePathGeometry.geometry(for: path, mirror: mirror)
            let groups = SimaiInputMapper.slideGroups(for: path, geometry: geometry, mirror: mirror)[0]
            let endpoint = geometry.branches[0].sample(at: 1).point
            let head = mirror.map(location: event.location).normalizedPoint()
            for offset in [0.0, 0.300, 0.601] {
                for movement in [nil, Optional(0.0), Optional(0.001)] {
                    let session = SimaiGameplaySession(chart: c)
                    input(session, head, event.time, .began, settings: playbackSettings)
                    input(session, head, event.time + 0.001, .ended, settings: playbackSettings)
                    // Legitimate handoffs: each earlier sensor is pressed and
                    // released in order, without the movement fallback.
                    for (index, group) in groups.dropLast().enumerated() {
                        let point: CGPoint
                        switch group.targets.first! {
                        case .lane(let lane): point = SimaiLocation(ring: .lane, index: lane).normalizedPoint()
                        case .sensor(let location): point = location.normalizedPoint()
                        }
                        let time = path.startTime + Double(index) * path.duration / Double(groups.count - 1)
                        input(session, point, time, .began, id: index + 2, settings: playbackSettings)
                        input(session, point, time + 0.001, .ended, id: index + 2, settings: playbackSettings)
                    }
                    expect(session.scoreRecords.filter { $0.slot.pathIndex != nil }.isEmpty, "Slide completed before its endpoint")
                    let arrivedAt = path.endTime + offset
                    input(session, endpoint, arrivedAt, .began, id: 99, settings: playbackSettings)
                    let arrived = session.scoreRecords.filter { $0.slot.pathIndex != nil }
                    if offset > 0.600 {
                        expect(arrived.isEmpty, "Endpoint accepted a touch beyond the original Slide window")
                        if let movement {
                            input(session, CGPoint(x: endpoint.x + movement, y: endpoint.y), arrivedAt + 0.001, .moved, id: 99, settings: playbackSettings)
                        }
                        session.update(time: path.endTime + 0.660, settings: playbackSettings)
                        let expired = session.scoreRecords.filter { $0.slot.pathIndex != nil }
                        expect(expired.count == 1 && expired[0].judgement == .good
                               && abs(expired[0].offset - 0.600) < 1e-9,
                               "Late endpoint changed the existing one-remaining-group timeout rule")
                        cases += 1
                        continue
                    }
                    expect(arrived.count == 1, "Stationary endpoint handoff still waits for movement or release: \(mirror)")
                    expect(abs(arrived[0].offset - offset) < 1e-9, "Endpoint used release time instead of touch-down time")
                    expect(arrived[0].judgement == (offset == 0 ? .criticalPerfect : .great), "Endpoint widened the judgement window")
                    if let movement {
                        input(session, CGPoint(x: endpoint.x + movement, y: endpoint.y), arrivedAt + 0.001, .moved, id: 99, settings: playbackSettings)
                    }
                    session.update(time: arrivedAt + 0.300, settings: playbackSettings)
                    input(session, endpoint, arrivedAt + 0.350, .ended, id: 99, settings: playbackSettings)
                    let final = session.scoreRecords.filter { $0.slot.pathIndex != nil }
                    expect(final.count == 1 && abs(final[0].offset - offset) < 1e-9, "Holding/moving/releasing the endpoint changed or duplicated its result")
                    cases += 1
                }
            }
            // A terminal touch alone must not bypass an untouched route.
            let unplayed = SimaiGameplaySession(chart: c)
            input(unplayed, head, event.time, .began, settings: playbackSettings)
            input(unplayed, head, event.time + 0.001, .ended, settings: playbackSettings)
            input(unplayed, endpoint, path.endTime, .began, id: 99, settings: playbackSettings)
            expect(unplayed.scoreRecords.filter { $0.slot.pathIndex != nil }.isEmpty, "Endpoint bypassed the route in \(mirror)")
            input(unplayed, endpoint, path.endTime + 0.350, .ended, id: 99, settings: playbackSettings)
            unplayed.update(time: path.endTime + 0.660, settings: playbackSettings)
            expect(unplayed.scoreRecords.filter { $0.slot.pathIndex != nil }.first?.judgement == .miss, "Unplayed route no longer misses")
        }
        print("PASS: \(cases) endpoint handoffs across mirrors, movement and timing; held results stable; endpoint-only/window bypasses rejected")
    }

    static func fireworksRegression() throws {
        let c = try chart("Cf/A1f/B3f/D5f/E7f/1f,Chf[4:8],Cf,1,2!f-6[4:1]")
        expect(c.fireworkEvents.count == 8, "Firework index includes ordinary/invalidated heads or loses a sensor ring")
        expect(c.fireworkEvents.last?.kind == .touchHold, "Firework index must sort by HOLD completion, not head arrival")
        for event in c.fireworkEvents {
            expect(SimaiFireworkEffect.startTime(for: event, feedback: nil, isGameplay: false) == event.fireworkTime,
                   "Preview firework clock does not follow the chart")
            expect(SimaiFireworkEffect.startTime(for: event, feedback: nil, isGameplay: true) == nil,
                   "Gameplay fireworks triggered without input")
            for grade in SimaiJudgement.allCases {
                for isHead in [true, false] {
                    let feedback = SimaiJudgementFeedback(eventID: event.id, pathIndex: nil, judgement: grade,
                        targetTime: event.fireworkTime, judgedTime: event.fireworkTime + 0.04,
                        offset: 0.04, location: event.location, isHead: isHead)
                    let start = SimaiFireworkEffect.startTime(for: event, feedback: feedback, isGameplay: true)
                    expect((start != nil) == (grade != .miss && isHead == !event.hasHoldHead),
                           "Firework ignored head/end distinction or a Miss")
                    if let start { expect(start == feedback.judgedTime, "Effect changed judgement timing") }
                }
            }
        }
        expect(c.fireworks(from: 1.001, through: 1.499).isEmpty, "Future fireworks leak into preview")
        expect(c.fireworks(from: 0, through: 100).count == 8, "Firework time range lost events")
        expect(c.fireworks(from: .nan, through: .infinity).isEmpty, "Nonfinite clocks were accepted")
        let ordinary = try chart("C,1").events[0]
        expect(SimaiFireworkEffect.startTime(for: ordinary, feedback: nil, isGameplay: false) == nil,
               "Ordinary notes acquired fireworks")
        let slide = try chart("1f-5[4:1]").events[0]
        let pathFeedback = SimaiJudgementFeedback(eventID: slide.id, pathIndex: 0, judgement: .perfect,
            targetTime: slide.endTime, judgedTime: slide.endTime, offset: 0, location: slide.location, isHead: false)
        expect(SimaiFireworkEffect.startTime(for: slide, feedback: pathFeedback, isGameplay: true) == nil,
               "Slide path duplicated its head's fireworks")
        for age in [-0.1, SimaiFireworkEffect.duration, .infinity, .nan] {
            expect(SimaiFireworkEffect.age(at: age, since: 0) == nil, "Expired/nonfinite effect survived")
        }
        expect(SimaiFireworkEffect.age(at: 0.2, since: 0) == 0.2, "Live effect missing")
        expect(SimaiFireworkEffect.sparks.count == 24 && SimaiFireworkEffect.maximumVisibleBursts == 12,
               "Firework rendering budget became unbounded")
        for spark in SimaiFireworkEffect.sparks {
            let reducedStart = SimaiFireworkEffect.sample(spark, age: 0, reducedMotion: true)
            let reducedEnd = SimaiFireworkEffect.sample(spark, age: 0.6, reducedMotion: true)
            expect(reducedStart.tip == reducedEnd.tip && reducedStart.tip == reducedStart.tail,
                   "Reduce Motion still moves sparks")
            for age in stride(from: 0.0, through: 0.65, by: 1.0 / 120) {
                let first = SimaiFireworkEffect.sample(spark, age: age, reducedMotion: false)
                let repeated = SimaiFireworkEffect.sample(spark, age: age, reducedMotion: false)
                expect(first.tip == repeated.tip && first.tail == repeated.tail, "Seek/pause changes particle positions")
                expect(first.tip.x.isFinite && first.tip.y.isFinite && hypot(first.tip.x, first.tip.y) < 1.2,
                       "Firework geometry is unbounded")
            }
        }
        print("PASS: indexed f fireworks; all sensor rings; preview/gameplay clocks; HOLD completion; no Miss/ordinary/path duplicates; fixed budget and Reduce Motion")
    }

    static func main() async throws {
        try fireworksRegression()
        try endpointHandoffRegression()
        expect(SimaiJudgement.criticalPerfect.displayTitle == "CRITICAL", "Critical feedback label is no longer compact")
        expect(SimaiJudgement.criticalPerfect.rawValue == "CRITICAL PERFECT", "Display-only rename changed the grading identity")
        for grade in SimaiJudgement.allCases where grade != .criticalPerfect {
            expect(grade.displayTitle == grade.rawValue, "Unrelated grade label changed")
        }
        let each = try chart("1h[4:2]/3-7[4:1],5")
        expect(each.eachEventIDs == [each.events[0].id, each.events[1].id], "Authored EACH grouping was not prepared independently of resolution")
        for text in ["1-5[4:1]", "1p5[4:1]", "1pp5[4:1]", "1s5[4:1]", "1w5[4:1]", "1v5[4:1]"] {
            let source = try chart(text).events[0].slidePaths[0]
            for mirror in SimaiMirrorMode.allCases {
                let geometry = SimaiSlidePathGeometry.geometry(for: source, mirror: mirror)
                let repeated = SimaiSlidePath(segments: source.segments, startTime: 999, duration: 0.2, isBreak: !source.isBreak)
                let firstGroups = SimaiInputMapper.slideGroups(for: source, geometry: geometry, mirror: mirror)
                let repeatedGroups = SimaiInputMapper.slideGroups(for: repeated, geometry: geometry, mirror: mirror)
                expect(firstGroups.count == repeatedGroups.count, "Timing/BREAK changed cached input branches")
                for (first, second) in zip(firstGroups, repeatedGroups) {
                    expect(first.count == second.count && zip(first, second).allSatisfy {
                        $0.targets == $1.targets && $0.blocksSkip == $1.blocksSkip && $0.pathProgress == $1.pathProgress
                    }, "Timing/BREAK changed immutable input groups")
                }
                for branch in geometry.branches {
                    var distance: CGFloat = 0
                    var index = 0
                    while distance < branch.length {
                        let sample = branch.sample(distance: distance)
                        let vertices: [CGPoint] = [CGPoint(x: -18.5 / 300, y: -20 / 300), CGPoint(x: -1.5 / 300, y: -20 / 300),
                            CGPoint(x: 18.5 / 300, y: 0), CGPoint(x: -1.5 / 300, y: 20 / 300),
                            CGPoint(x: -18.5 / 300, y: 20 / 300), CGPoint(x: 1.5 / 300, y: 0)]
                        let cosine = CoreGraphics.cos(sample.angle)
                        let sine = CoreGraphics.sin(sample.angle)
                        let reference = vertices.map { point -> CGPoint in
                            CGPoint(x: sample.point.x + point.x * cosine - point.y * sine,
                                    y: sample.point.y + point.x * sine + point.y * cosine)
                        }
                        var actual: [CGPoint] = []
                        branch.slideArrows[index].cgPath.applyWithBlock { element in
                            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                                actual.append(element.pointee.points[0])
                            }
                        }
                        expect(actual.count == reference.count, "Chevron vertex count changed")
                        expect(zip(actual, reference).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.000_001 }, "Cached chevron changed shape")
                        distance += 25 / 300
                        index += 1
                    }
                    expect(branch.slideArrows.count >= index && branch.slideArrows.count <= index + 2,
                           "Unexpected terminal chevron templates")
                }
                if source.containsFan {
                    expect(!geometry.fanCrossbars.isEmpty && geometry.branches.count == 3, "WiFi crossbars were not prepared")
                }
            }
        }
        print("PASS: precomputed authored EACH membership; chevron vertices/count across paths/mirrors; connected WiFi cache")
        let tapChart = try chart("1")
        let event = tapChart.events[0]
        for delayed in [false, true] {
            let session = SimaiGameplaySession(chart: tapChart)
            if delayed { session.update(time: 1.16, settings: settings) }
            tap(session, event, offset: 0.14)
            expect(session.counts(for: .good) == 1, "A valid late-delivered touch became MISS")
        }
        let outside = SimaiGameplaySession(chart: tapChart)
        outside.update(time: 1.16, settings: settings)
        tap(outside, event, offset: 0.151)
        outside.update(time: 1.201, settings: settings)
        expect(outside.counts(for: .miss) == 1, "Grace widened the logical hit window")
        print("PASS: input delivery grace preserves original windows")

        let ordered = SimaiGameplaySession(chart: try chart("{16}1,2"))
        tap(ordered, ordered.chart.events[1], offset: -0.025)
        expect(ordered.judgedCount == 0 && ordered.combo == 0, "Later score committed before unresolved earlier slot")
        tap(ordered, ordered.chart.events[0], offset: 0.14)
        expect(ordered.scoreRecords.map { $0.slot.eventID } == [0, 1] && ordered.combo == 2, "Callback order changed score / combo order")
        let shortHold = SimaiGameplaySession(chart: try chart("1h[#0.05]"))
        shortHold.update(time: 1.16, settings: settings)
        tap(shortHold, shortHold.chart.events[0], offset: 0.14)
        shortHold.update(time: 1.21, settings: settings)
        expect(shortHold.counts(for: .great) == 1 && shortHold.counts(for: .miss) == 0, "Short HOLD resolved before late head delivery")
        print("PASS: score commit order and short-HOLD delivery deadline")

        for text in ["1b-5[4:1]", "1-5b[4:1]", "1-5[4:1]*-7b[4:1]"] {
            let c = try chart(text)
            let e = c.events[0]
            expect(e.flags.contains(.breakNote) == text.hasPrefix("1b"), "Head BREAK leaked from a path")
            expect(e.slidePaths.last!.isBreak == !text.hasPrefix("1b"), "Per-path BREAK lost")
        }
        let star = try chart("1$/2$$/3@-7[4:1]/4!-8[4:1]/5?-1[4:1]")
        expect(star.events[0].flags.contains(.star) && !star.events[0].flags.contains(.spinningStar), "Static star lost")
        expect(star.events[1].flags.contains(.spinningStar), "Spinning star lost")
        expect(star.events[2].flags.contains(.normalHead), "Forced normal appearance lost")
        expect(!star.events[3].isScorable && !star.events[4].isScorable, "Decorative notes counted")
        print("PASS: independent path BREAK and appearance parsing")

        let slide = try chart("1-5[4:1]")
        let hitHead = SimaiGameplaySession(chart: slide)
        tap(hitHead, slide.events[0])
        expect(hitHead.combo == 1 && hitHead.judgedCount == 1, "Slide head did not score independently")
        hitHead.update(time: 2.7, settings: settings)
        expect(hitHead.counts(for: .criticalPerfect) == 1 && hitHead.counts(for: .miss) == 1, "Path MISS erased head points")
        expect(abs(hitHead.achievement - 25) < 0.001, "Slide type weights incorrect")
        let missedHead = SimaiGameplaySession(chart: slide)
        missedHead.update(time: 1.201, settings: settings)
        swipe(missedHead, slide.events[0].slidePaths[0])
        expect(missedHead.counts(for: .miss) == 1 && missedHead.counts(for: .criticalPerfect) == 1, "Path success erased head MISS")
        expect(abs(missedHead.achievement - 75) < 0.001, "Missed head still achieved full score")
        let doubleSlide = try chart("1-5[4:1]*-7[4:1]")
        expect(SimaiGameplaySession(chart: doubleSlide).noteCount == 3, "Multi-path scoring slots merged")
        let endpointOnly = SimaiGameplaySession(chart: slide)
        tap(endpointOnly, slide.events[0])
        let path = slide.events[0].slidePaths[0]
        let endpoint = SimaiSlidePathGeometry.geometry(for: path, mirror: .none).branches[0].sample(at: 1).point
        input(endpointOnly, endpoint, path.endTime, .began)
        input(endpointOnly, endpoint, path.endTime + 0.001, .ended)
        endpointOnly.update(time: path.endTime + 0.66, settings: settings)
        expect(endpointOnly.counts(for: .miss) == 1, "Endpoint tap cleared an unplayed path")
        let interrupted = SimaiGameplaySession(chart: slide)
        tap(interrupted, slide.events[0])
        let branch = SimaiSlidePathGeometry.geometry(for: path, mirror: .none).branches[0]
        input(interrupted, branch.sample(at: 0).point, path.startTime, .began)
        for i in 1...30 {
            let progress = Double(i) / 120
            input(interrupted, branch.sample(at: progress).point, path.startTime + path.duration * progress, .moved)
        }
        interrupted.releaseAllInputs(time: path.startTime + path.duration * 0.25, settings: settings)
        interrupted.update(time: path.endTime + 0.66, settings: settings)
        expect(interrupted.counts(for: .miss) == 1 && interrupted.averageOffsetMilliseconds == 0, "Interrupted path completed or polluted head offset")
        print("PASS: slide heads and paths have independent weighted score slots")

        let perfectBreak = SimaiGameplaySession(chart: try chart("1b"))
        tap(perfectBreak, perfectBreak.chart.events[0])
        expect(perfectBreak.achievement == 101 && perfectBreak.dxScore == 3, "BREAK bonus / critical DX points missing")
        let perfect2 = SimaiGameplaySession(chart: try chart("1b"))
        tap(perfect2, perfect2.chart.events[0], offset: 0.04)
        expect(perfect2.achievement == 100.5 && perfect2.dxScore == 2 && perfect2.lateCount == 1, "PERFECT band / bonus incorrect")
        expect(perfect2.scoreRecords[0].band == .perfect2, "Timing band lost")
        let holdChart = try chart("1h[4:1]")
        let hold = SimaiGameplaySession(chart: holdChart)
        input(hold, holdChart.events[0].location.normalizedPoint(), 1, .began)
        hold.update(time: 1.56, settings: settings)
        expect(hold.noteCount == 1 && hold.dxScore == 3, "HOLD score or resolution incorrect")
        print("PASS: critical / bands / BREAK extra / DX score / HOLD")

        let sequence = (0..<200).map { $0 % 2 == 0 ? "1" : "5" }.joined(separator: ",")
        let long = SimaiGameplaySession(chart: try chart(sequence))
        for (index, event) in long.chart.events.enumerated() {
            tap(long, event, offset: index < 100 ? 0.04 : 0)
            long.update(time: event.time + 0.06, settings: settings)
        }
        expect(long.judgementFeedback.count < 200, "Feedback cache no longer bounded")
        expect(abs((long.averageOffsetMilliseconds ?? -1) - 20) < 0.00001, "Average offset depends on trimmed visual cache")
        expect(long.judgedCount == 200 && long.dxScore == 500, "Full score ledger truncated")
        let tail = SimaiGameplaySession(chart: tapChart)
        tap(tail, event)
        tail.update(time: 1.01, settings: settings)
        expect(!tail.isFinished, "Results interrupted last judgement")
        tail.update(time: 1.81, settings: settings)
        expect(tail.isFinished, "Feedback tail never completed")
        print("PASS: cumulative offset and end-of-chart feedback tail")

        var trajectories = 0
        for text in ["1-5[4:1]", "1p5[4:1]", "1pp5[4:1]", "1s5[4:1]", "1z5[4:1]", "1w5[4:1]", "3v2[4:1]", "1-5[4:1]*-7[4:1]"] {
            for hz in [60, 120, 240] {
                for batch in [1, 12] {
                    let c = try chart(text)
                    let session = SimaiGameplaySession(chart: c)
                    tap(session, c.events[0])
                    swipe(session, c.events[0].slidePaths[0], additionalPaths: Array(c.events[0].slidePaths.dropFirst()), hz: hz, batch: batch)
                    session.update(time: c.events[0].endTime + 0.7, settings: settings)
                    expect(session.counts(for: .miss) == 0 && session.perfectCount == 1 + c.events[0].slidePaths.count, "Ideal trajectory regressed: \(text), \(hz), \(batch)")
                    trajectories += 1
                }
            }
        }
        print("PASS: \(trajectories) ideal trajectories, including WiFi, loops, coalesced input, center fold")

        expect(abs(settings.approachTime - 0.46875) < 1e-9, "NoteMotion speed conversion incorrect")
        expect(SimaiNoteMotion.ringState(progress: 0.25).scale == 0.5, "Scale-in phase incorrect")
        expect(SimaiNoteMotion.ringState(progress: 0.5).radius == 0.25, "Initial radius incorrect")
        expect(SimaiNoteMotion.ringState(progress: 0.75).radius == 0.625, "Move phase incorrect")
        expect(SimaiNoteMotion.ringState(progress: 1).radius == 1, "Note did not arrive at the judge line")
        for speed in [3.0, 6.0, 8.0, 9.0] {
            let approach = SimaiNoteMotion.approachTime(speed: speed)
            for late in [0.001, 1.0 / 60, 0.10, 0.15, 0.20, 1.0] {
                let motion = SimaiNoteMotion.ringState(progress: 1 + late / approach)
                expect(motion.radius == 1 && motion.scale == 1, "Late note flew outside judge line at speed \(speed)")
            }
        }
        for step in -100...300 {
            let motion = SimaiNoteMotion.ringState(progress: Double(step) / 100)
            expect((0.25...1).contains(motion.radius) && (0...1).contains(motion.scale), "Note motion left playfield bounds")
        }
        let guide = SimaiNoteMotion.guideState(time: 1.25, headTime: 1, start: 1.5, end: 2)
        expect(guide.scale == 0.75 && guide.opacity == 0.5, "Waiting guide scale/alpha incorrect")
        expect(SimaiNoteMotion.guideState(time: 2, headTime: 1, start: 1.5, end: 2).opacity == 0, "Guide stayed at endpoint")
        expect(SimaiNoteMotion.headStarRotation(elapsed: 1, pathLength: 2, duration: 1, spinning: true, rotates: false) == -.pi / 2, "Nonrotating star did not point up")
        print("PASS: chart-clock approach; late heads stay on judge line at every speed; guide phases unchanged")

        let bus = GameplayEventBus()
        let stream = bus.events()
        let consumer = Task { () -> [GameplayEvent] in
            var values: [GameplayEvent] = []
            for await value in stream { values.append(value) }
            return values
        }
        let hardwareReplay = SimaiGameplaySession(chart: slide, gameplayEventBus: bus)
        tap(hardwareReplay, slide.events[0])
        swipe(hardwareReplay, slide.events[0].slidePaths[0])
        hardwareReplay.update(time: 2.9, settings: settings)
        let cancellation = Task {
            try? await Task.sleep(nanoseconds: 10_000_000)
            consumer.cancel()
        }
        let emitted = await consumer.value
        await cancellation.value
        expect(emitted.filter { $0.kind == .noteArrival }.count == 1, "Duplicate arrival publication")
        expect(emitted.filter { $0.kind == .slideStart }.count == 1, "Duplicate slide head hardware publication")
        expect(emitted.filter { $0.kind == .slideComplete }.count == 1, "Score slots duplicated hardware completion")
        expect(emitted.count == 3, "Unexpected additional hardware events")
        print("PASS: independent score slots do not duplicate framework events")
    }
}
