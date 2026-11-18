// SPDX-License-Identifier: GPL-3.0-only
// Native Swift adaptation from Airmai. See THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Foundation

public struct SimaiChart: Sendable {
    public let title: String
    public let artist: String
    public let designer: String
    public let level: String
    public let bpm: Double
    public let firstPlayableTime: TimeInterval
    public let duration: TimeInterval
    public let source: String
    public let events: [SimaiNoteEvent]
    public let eventByID: [Int: SimaiNoteEvent]
    // Sorted once by effect time, so a long TOUCH HOLD does not require scanning
    // the complete chart to find the fireworks at its end.
    public let fireworkEvents: [SimaiNoteEvent]
    // Authored simultaneous notes do not change when one head is resolved.
    // Compute once during parsing, never regroup visible notes every frame.
    public let eachEventIDs: Set<Int>
    public let maximumEventDuration: TimeInterval
    public let timelineDensity: [Double]
    public let timelineNoteBuckets: [SimaiTimelineNoteBucket]

    public var noteCount: Int { events.count }

    public var timingChanges: [SimaiTimingChange] {
        var result: [SimaiTimingChange] = []
        for event in events {
            guard result.last?.bpm != event.bpm || result.last?.subdivision != event.subdivision else { continue }
            result.append(SimaiTimingChange(time: event.time, bpm: event.bpm, subdivision: event.subdivision))
        }
        return result
    }

    public func eventIndex(at time: TimeInterval) -> Int? {
        guard !events.isEmpty else { return nil }
        let index = events.partitioningIndex { $0.time >= time }
        return min(index, events.count - 1)
    }

    public func latestEventIndex(at time: TimeInterval) -> Int? {
        let upper = events.partitioningIndex { $0.time > time }
        return upper > 0 ? upper - 1 : nil
    }

    public func events(from lowerTime: TimeInterval, through upperTime: TimeInterval) -> ArraySlice<SimaiNoteEvent> {
        guard !events.isEmpty, lowerTime <= upperTime else { return events[0..<0] }
        let lower = events.partitioningIndex { $0.time >= lowerTime }
        let upper = events.partitioningIndex { $0.time > upperTime }
        return events[lower..<upper]
    }

    public func fireworks(from lowerTime: TimeInterval, through upperTime: TimeInterval) -> ArraySlice<SimaiNoteEvent> {
        guard lowerTime.isFinite, upperTime.isFinite, lowerTime <= upperTime else { return fireworkEvents[0..<0] }
        let lower = fireworkEvents.partitioningIndex { $0.fireworkTime >= lowerTime }
        let upper = fireworkEvents.partitioningIndex { $0.fireworkTime > upperTime }
        return fireworkEvents[lower..<upper]
    }

    public func previousEventTime(before time: TimeInterval) -> TimeInterval {
        events.last(where: { $0.time < time - 0.03 })?.time ?? 0
    }

    public func nextEventTime(after time: TimeInterval) -> TimeInterval {
        events.first(where: { $0.time > time + 0.03 })?.time ?? duration
    }

    public func measureNumber(at time: TimeInterval) -> Int {
        guard bpm > 0 else { return 1 }
        let secondsPerMeasure = 240 / bpm
        return max(Int(time / secondsPerMeasure) + 1, 1)
    }

    public func measureStart(before time: TimeInterval) -> TimeInterval {
        guard bpm > 0 else { return 0 }
        let secondsPerMeasure = 240 / bpm
        return max(floor((time - 0.03) / secondsPerMeasure) * secondsPerMeasure, 0)
    }

    public func nextMeasureStart(after time: TimeInterval) -> TimeInterval {
        guard bpm > 0 else { return duration }
        let secondsPerMeasure = 240 / bpm
        return min((floor(time / secondsPerMeasure) + 1) * secondsPerMeasure, duration)
    }
}

public struct SimaiTimingChange: Sendable, Hashable {
    public let time: TimeInterval
    public let bpm: Double
    public let subdivision: Double
}

public struct SimaiTimelineNoteBucket: Sendable, Hashable {
    public var tap = 0
    public var hold = 0
    public var slide = 0
    public var touch = 0
    public var breakNote = 0

    public var total: Int { tap + hold + slide + touch + breakNote }

    public mutating func add(_ event: SimaiNoteEvent) {
        if event.flags.contains(.breakNote) {
            breakNote += 1
            return
        }

        switch event.kind {
        case .tap: tap += 1
        case .hold, .touchHold: hold += 1
        case .slide: slide += 1
        case .touch: touch += 1
        }
    }
}

public struct SimaiNoteEvent: Identifiable, Sendable, Hashable {
    public let id: Int
    public let time: TimeInterval
    public let bpm: Double
    public let subdivision: Double
    public let location: SimaiLocation
    public let kind: SimaiNoteKind
    public let duration: TimeInterval
    public let flags: SimaiNoteFlags
    public let slidePaths: [SimaiSlidePath]
    public let source: String

    public var fireworkTime: TimeInterval { time + max(duration, 0) }

    public var endTime: TimeInterval {
        switch kind {
        case .slide: return max(slidePaths.map(\.endTime).max() ?? time, time + duration)
        case .hold, .touchHold: return time + duration
        default: return time
        }
    }
}

public enum SimaiNoteKind: String, Sendable, Hashable {
    case tap
    case hold
    case slide
    case touch
    case touchHold
}

public struct SimaiNoteFlags: OptionSet, Sendable, Hashable {
    public init(rawValue: Int) { self.rawValue = rawValue }
    public let rawValue: Int

    public static let breakNote = SimaiNoteFlags(rawValue: 1 << 0)
    public static let ex = SimaiNoteFlags(rawValue: 1 << 1)
    public static let fireworks = SimaiNoteFlags(rawValue: 1 << 2)
    public static let star = SimaiNoteFlags(rawValue: 1 << 3)
    public static let mine = SimaiNoteFlags(rawValue: 1 << 4)
    public static let spinningStar = SimaiNoteFlags(rawValue: 1 << 5)
    public static let normalHead = SimaiNoteFlags(rawValue: 1 << 6)
    public static let invalidate = SimaiNoteFlags(rawValue: 1 << 7)
    public static let fadeInSlide = SimaiNoteFlags(rawValue: 1 << 8)
}

public enum SimaiSensorRing: String, Sendable, Hashable {
    case lane
    case a
    case b
    case c
    case d
    case e
}

public struct SimaiLocation: Sendable, Hashable {
    public let ring: SimaiSensorRing
    public let index: Int

    public static func parse(_ value: Substring) -> (location: SimaiLocation, consumed: Int)? {
        guard let first = value.first else { return nil }
        if let lane = first.wholeNumberValue, (1...8).contains(lane) {
            return (SimaiLocation(ring: .lane, index: lane), 1)
        }

        guard let ring = SimaiSensorRing(rawValue: String(first).lowercased()) else { return nil }
        if ring == .c {
            if value.count > 1, let number = value[value.index(after: value.startIndex)].wholeNumberValue {
                return (SimaiLocation(ring: .c, index: max(number, 1)), 2)
            }
            return (SimaiLocation(ring: .c, index: 1), 1)
        }

        guard value.count > 1, let number = value[value.index(after: value.startIndex)].wholeNumberValue,
            (1...8).contains(number)
        else { return nil }
        return (SimaiLocation(ring: ring, index: number), 2)
    }

    public func normalizedPoint(mirror: SimaiMirrorMode = .none) -> CGPoint {
        let mirroredIndex = mirror.map(location: self).index
        switch ring {
        case .lane: return Self.radialPoint(index: mirroredIndex, radius: 1)
        case .a: return Self.radialPoint(index: mirroredIndex, radius: 4.0 / 4.8)
        case .b: return Self.radialPoint(index: mirroredIndex, radius: 2.2 / 4.8)
        case .c: return .zero
        case .d: return Self.radialPoint(index: mirroredIndex, radius: 4.1 / 4.8, angleOffset: -.pi / 8)
        case .e: return Self.radialPoint(index: mirroredIndex, radius: 3.1 / 4.8, angleOffset: -.pi / 8)
        }
    }

    private static func radialPoint(index: Int, radius: CGFloat, angleOffset: CGFloat = 0) -> CGPoint {
        let angle = (-CGFloat.pi * 3 / 8) + CGFloat(index - 1) * (.pi / 4) + angleOffset
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }
}

public enum SimaiMirrorMode: String, CaseIterable, Identifiable, Sendable, Hashable {
    case none
    case leftRight
    case upDown
    case rotate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "无"
        case .leftRight: return "左右"
        case .upDown: return "上下"
        case .rotate: return "全反转"
        }
    }

    public func map(location: SimaiLocation) -> SimaiLocation {
        guard self != .none, location.ring != .c else { return location }
        var zeroBased = ((location.index - 1) % 8 + 8) % 8
        let shifted = location.ring == .lane || location.ring == .a || location.ring == .b

        if self == .leftRight || self == .rotate { zeroBased = shifted ? 7 - zeroBased : (8 - zeroBased) % 8 }
        if self == .upDown || self == .rotate {
            let shiftedMap = [3, 2, 1, 0, 7, 6, 5, 4]
            let halfSectorMap = [4, 3, 2, 1, 0, 7, 6, 5]
            zeroBased = (shifted ? shiftedMap : halfSectorMap)[zeroBased]
        }
        return SimaiLocation(ring: location.ring, index: zeroBased + 1)
    }

    public func map(shape: SimaiSlideShape) -> SimaiSlideShape {
        guard self == .leftRight || self == .upDown else { return shape }
        switch shape {
        case .clockwise: return .counterclockwise
        case .counterclockwise: return .clockwise
        case .curveLeft: return .curveRight
        case .curveRight: return .curveLeft
        case .edgeCurveLeft: return .edgeCurveRight
        case .edgeCurveRight: return .edgeCurveLeft
        case .zigzagLeft: return .zigzagRight
        case .zigzagRight: return .zigzagLeft
        default: return shape
        }
    }
}

public struct SimaiSlideSegment: Sendable, Hashable {
    public let shape: SimaiSlideShape
    public let start: SimaiLocation
    public let end: SimaiLocation
    public let via: SimaiLocation?
}

public struct SimaiSlidePath: Sendable, Hashable {
    public let segments: [SimaiSlideSegment]
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public var isBreak = false

    public var endTime: TimeInterval { startTime + duration }
    public var start: SimaiLocation { segments.first?.start ?? SimaiLocation(ring: .lane, index: 1) }
    public var end: SimaiLocation { segments.last?.end ?? start }
    public var containsFan: Bool { segments.contains(where: { $0.shape == .fan }) }
}

extension SimaiNoteEvent {
    // simai's forceInvalidate and mine decorations are visual-only, not MISSes.
    public var isScorable: Bool { !flags.contains(.invalidate) && !flags.contains(.mine) }
    public var hasHoldHead: Bool { kind == .hold || kind == .touchHold || (kind == .slide && duration > 0) }
    public var headScoreTime: TimeInterval { hasHoldHead ? time + duration : time }
    public var headScoringType: SimaiScoringType {
        if flags.contains(.breakNote) { return .breakNote }
        if hasHoldHead { return .hold }
        return location.ring == .lane ? .tap : .touch
    }
}

public enum SimaiScoringType: String, CaseIterable, Sendable {
    case tap = "Tap"
    case hold = "Hold"
    case slide = "Slide"
    case touch = "Touch"
    case breakNote = "Break"

    public var weight: Double {
        switch self {
        case .tap, .touch: return 1
        case .hold: return 2
        case .slide: return 3
        case .breakNote: return 5
        }
    }
}

// Pure chart-clock motion shared by rendering and offline regression tests.
// Ratios follow simai_flutter 0.5 NoteMotion/BaseNoteComponent (MIT).
public enum SimaiNoteMotion {
    public static func approachTime(speed: Double) -> TimeInterval { 3.75 / min(max(speed.isFinite ? speed : 8, 3), 9) }

    public static func ringState(progress: Double) -> (radius: Double, scale: Double) {
        if progress < 0.5 { return (0.25, max(0, min(1, progress / 0.5))) }
        let movement = max(0, min(1, (progress - 0.5) / 0.5))
        let radius = 0.25 + 0.75 * movement
        // The late judgement window keeps a head hittable, not moving outward.
        // Park its center on the line without clipping the note or hit effects.
        return (radius, 1)
    }

    public static func headStarRotation(
        elapsed: Double, pathLength: Double?, duration: Double?, spinning: Bool, rotates: Bool
    ) -> Double {
        guard rotates else { return -.pi / 2 }
        if let pathLength, let duration, duration > 0 {
            return -.pi / 2 - min(pathLength * 2.4 / duration, 6 * .pi) * max(0, elapsed)
        }
        return -.pi / 2 - (spinning ? 2 * .pi * max(0, elapsed) : 0)
    }

    public static func guideState(time: Double, headTime: Double, start: Double, end: Double) -> (
        scale: Double, opacity: Double
    ) {
        guard time >= headTime, time < end else { return (0, 0) }
        let progress = start > headTime ? max(0, min(1, (time - headTime) / (start - headTime))) : 1
        return (0.5 + 0.5 * progress, progress)
    }
}

public enum SimaiSlideShape: String, Sendable, Hashable {
    case straight = "-"
    case clockwise = ">"
    case counterclockwise = "<"
    case arc = "^"
    case centerFold = "v"
    case edgeFold = "V"
    case curveLeft = "p"
    case curveRight = "q"
    case edgeCurveLeft = "pp"
    case edgeCurveRight = "qq"
    case zigzagLeft = "s"
    case zigzagRight = "z"
    case fan = "w"
}

public enum SimaiChartParseError: LocalizedError {
    case missingChart
    case emptyChart

    public var errorDescription: String? {
        switch self {
        case .missingChart: return airMaiLocalized("未找到所选难度的谱面")
        case .emptyChart: return airMaiLocalized("谱面内容为空")
        }
    }
}

public enum SimaiChartParser {
    private static let slideOperatorCharacters = Set("-<>^vVszwpq")

    public static func parse(maidata: String, levelIndex: Int) throws -> SimaiChart {
        let fields = maidataFields(from: maidata)
        let chartKey = "inote_\(levelIndex + 2)"
        guard let source = fields[chartKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else {
            throw SimaiChartParseError.missingChart
        }

        let defaultBPM = positiveDouble(fields["bpm"]) ?? 120
        let chartNumber = levelIndex + 2
        let firstOffset = finiteDouble(fields["first_\(chartNumber)"]) ?? finiteDouble(fields["first"]) ?? 0
        let (events, eachEventIDs) = parseEvents(source: source, initialBPM: defaultBPM, initialTime: firstOffset)
        guard !events.isEmpty else { throw SimaiChartParseError.emptyChart }

        let firstTime = events.first?.time ?? 0
        let endTime = events.map(\.endTime).max() ?? firstTime
        let duration = max(endTime + 2, 1)
        let timelineBucketCount = 42
        var timelineDensity = Array(repeating: 0.0, count: timelineBucketCount)
        for event in events {
            let index = min(max(Int(event.time / duration * Double(timelineBucketCount)), 0), timelineBucketCount - 1)
            timelineDensity[index] += 1
        }
        let maximumBucket = timelineDensity.max() ?? 1
        if maximumBucket > 0 { timelineDensity = timelineDensity.map { $0 / maximumBucket } }
        let detailedBucketCount = 120
        var timelineNoteBuckets = Array(repeating: SimaiTimelineNoteBucket(), count: detailedBucketCount)
        for event in events {
            let index = min(max(Int(event.time / duration * Double(detailedBucketCount)), 0), detailedBucketCount - 1)
            timelineNoteBuckets[index].add(event)
        }
        return SimaiChart(
            title: fields["title"] ?? "-", artist: fields["artist"] ?? "-",
            designer: fields["des_\(levelIndex + 2)"] ?? "-", level: fields["lv_\(levelIndex + 2)"] ?? "-",
            bpm: defaultBPM, firstPlayableTime: firstTime, duration: duration, source: source, events: events,
            eventByID: Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) }),
            fireworkEvents: events.filter { $0.flags.contains(.fireworks) && !$0.flags.contains(.invalidate) }.sorted {
                $0.fireworkTime == $1.fireworkTime ? $0.id < $1.id : $0.fireworkTime < $1.fireworkTime
            }, eachEventIDs: eachEventIDs, maximumEventDuration: events.map { max($0.endTime - $0.time, 0) }.max() ?? 0,
            timelineDensity: timelineDensity, timelineNoteBuckets: timelineNoteBuckets)
    }

    private static func maidataFields(from maidata: String) -> [String: String] {
        let normalized = maidata.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var fields: [String: String] = [:]
        var currentKey: String?
        var valueLines: [String] = []

        func commit() {
            guard let key = currentKey else { return }
            fields[key] = valueLines.joined(separator: "\n")
        }

        for line in normalized.components(separatedBy: "\n") {
            if line.hasPrefix("&"), let equal = line.firstIndex(of: "=") {
                commit()
                currentKey = String(line[line.index(after: line.startIndex)..<equal]).lowercased()
                valueLines = [String(line[line.index(after: equal)...])]
            } else if currentKey != nil {
                valueLines.append(line)
            }
        }
        commit()
        return fields
    }

    private static func parseEvents(source: String, initialBPM: Double, initialTime: TimeInterval) -> (
        events: [SimaiNoteEvent], eachEventIDs: Set<Int>
    ) {
        let cleaned = source.components(separatedBy: "\n").map { line -> String in
            if let comment = line.range(of: "||") { return String(line[..<comment.lowerBound]) }
            return line
        }.joined()

        var cursor = cleaned.startIndex
        var bpm = initialBPM
        var subdivision = 4.0
        // `first` belongs to the chart/audio pair, not to the user's device
        // calibration. Applying it here keeps every event on the audio file's
        // absolute timeline while the global timing settings remain reusable
        // across songs.
        var currentTime = initialTime
        var rawEvents: [SimaiNoteEvent] = []
        var eachEventIDs: Set<Int> = []
        var eventID = 0

        while cursor < cleaned.endIndex {
            let character = cleaned[cursor]
            if character.isWhitespace {
                cursor = cleaned.index(after: cursor)
                continue
            }

            if character == "(" {
                if let closing = cleaned[cursor...].firstIndex(of: ")") {
                    let text = cleaned[cleaned.index(after: cursor)..<closing]
                    if let value = Double(text), value > 0 { bpm = value }
                    cursor = cleaned.index(after: closing)
                    continue
                }
            }

            if character == "{" {
                if let closing = cleaned[cursor...].firstIndex(of: "}") {
                    let text = String(cleaned[cleaned.index(after: cursor)..<closing])
                    if text.hasPrefix("#"), let seconds = Double(text.dropFirst()), seconds > 0 {
                        // simai_flutter's SubdivisionReader treats {#x} as an
                        // explicit number of seconds per time step.
                        bpm = 60 / seconds
                        subdivision = 4
                    } else if let value = Double(text), value > 0 {
                        subdivision = value
                    }
                    cursor = cleaned.index(after: closing)
                    continue
                }
            }

            if character == "," {
                currentTime += secondsPerStep(bpm: bpm, subdivision: subdivision)
                cursor = cleaned.index(after: cursor)
                continue
            }

            if character == "E" || character == "e" {
                let next = cleaned.index(after: cursor)
                let isTouchLocation = next < cleaned.endIndex && cleaned[next].isNumber
                if !isTouchLocation { break }
            }

            let statementEnd = nextTopLevelComma(in: cleaned, from: cursor)
            let statement = cleaned[cursor..<statementEnd]
            let (components, suppressesEach) = splitBeat(statement)
            let firstEventID = eventID
            for component in components {
                for note in compactNoteComponents(component) {
                    guard
                        let parsed = parseComponent(
                            note, time: currentTime, bpm: bpm, subdivision: subdivision, startingID: eventID)
                    else { continue }
                    rawEvents.append(contentsOf: parsed)
                    eventID += parsed.count
                }
            }
            if !suppressesEach, eventID - firstEventID > 1 { eachEventIDs.formUnion(firstEventID..<eventID) }
            cursor = statementEnd
        }

        let sortedEvents = rawEvents.sorted {
            if $0.time == $1.time { return $0.id < $1.id }
            return $0.time < $1.time
        }
        return (sortedEvents, eachEventIDs)
    }

    private static func parseComponent(
        _ raw: Substring, time: TimeInterval, bpm: Double, subdivision: Double, startingID: Int
    ) -> [SimaiNoteEvent]? {
        var component = raw.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard !component.isEmpty, let locationResult = SimaiLocation.parse(component) else { return nil }
        let location = locationResult.location
        component = component.dropFirst(locationResult.consumed)

        var flags: SimaiNoteFlags = []
        var isHold = false
        var holdDuration: TimeInterval = 0
        var slideFragments: [Substring] = []
        var fragmentStart = component.startIndex
        var bracketDepth = 0

        for index in component.indices {
            let character = component[index]
            if character == "[" { bracketDepth += 1 }
            if character == "]" { bracketDepth = max(bracketDepth - 1, 0) }
            if character == "*" && bracketDepth == 0 {
                slideFragments.append(component[fragmentStart..<index])
                fragmentStart = component.index(after: index)
            }
        }
        slideFragments.append(component[fragmentStart..<component.endIndex])

        let prefix = slideFragments.first ?? ""
        let prefixText = String(prefix)
        let headEnd =
            earliestOperator(
                in: prefixText, operators: ["pp", "qq", "-", ">", "<", "^", "v", "V", "s", "z", "w", "p", "q"])?
            .lowerBound ?? prefixText.endIndex
        let headText = prefixText[..<headEnd]
        for character in headText {
            switch character {
            case "b": flags.insert(.breakNote)
            case "x": flags.insert(.ex)
            case "f": flags.insert(.fireworks)
            case "$":
                if flags.contains(.star) { flags.insert(.spinningStar) }
                flags.insert(.star)
                flags.remove(.normalHead)
            case "@":
                flags.insert(.normalHead)
                flags.remove([.star, .spinningStar])
            case "!":
                flags.insert(.invalidate)
                flags.remove(.fadeInSlide)
            case "?": flags.insert([.invalidate, .fadeInSlide])
            case "m": flags.insert(.mine)
            default: break
            }
        }

        if headText.contains("h") {
            isHold = true
            if let durationText = firstBracketContent(in: headText) {
                holdDuration = parseDuration(durationText, bpm: bpm)
            }
        }

        var paths: [SimaiSlidePath] = []
        for fragment in slideFragments {
            paths.append(contentsOf: parseSlideChain(fragment, start: location, time: time, bpm: bpm))
        }

        if !paths.isEmpty {
            // NoteReader in simai_flutter gives a Hold+Slide head one beat of
            // hold length when the slide token is encountered.
            if isHold { holdDuration = 60 / max(bpm, 1) }
            if !flags.contains(.normalHead) { flags.insert(.star) }
            return [
                SimaiNoteEvent(
                    id: startingID, time: time, bpm: bpm, subdivision: subdivision, location: location, kind: .slide,
                    duration: holdDuration, flags: flags, slidePaths: paths, source: String(raw))
            ]
        }

        let isTouch = location.ring != .lane
        let kind: SimaiNoteKind = isHold ? (isTouch ? .touchHold : .hold) : (isTouch ? .touch : .tap)
        return [
            SimaiNoteEvent(
                id: startingID, time: time, bpm: bpm, subdivision: subdivision, location: location, kind: kind,
                duration: holdDuration, flags: flags, slidePaths: [], source: String(raw))
        ]
    }

    private static func parseSlideChain(_ raw: Substring, start: SimaiLocation, time: TimeInterval, bpm: Double)
        -> [SimaiSlidePath]
    {
        let text = String(raw)
        let operators = ["pp", "qq", "-", ">", "<", "^", "v", "V", "s", "z", "w", "p", "q"]
        guard let firstRange = earliestOperator(in: text, operators: operators) else { return [] }
        var cursor = firstRange.lowerBound
        var currentLocation = start
        var segments: [SimaiSlideSegment] = []
        var slideDelay = 60 / max(bpm, 1)
        var slideDuration: TimeInterval = 0

        while cursor < text.endIndex {
            guard let found = operatorAtOrAfter(in: text, from: cursor, operators: operators) else { break }
            let symbol = found.symbol
            var valueCursor = found.range.upperBound
            let end: SimaiLocation
            var via: SimaiLocation?
            if symbol == "-", let center = SimaiLocation.parse(text[valueCursor...]), center.location.ring == .c {
                end = center.location
                valueCursor = text.index(valueCursor, offsetBy: center.consumed)
            } else {
                var digits = ""
                let digitLimit = symbol == "V" ? 2 : 1
                while valueCursor < text.endIndex, digits.count < digitLimit, text[valueCursor].isNumber {
                    digits.append(text[valueCursor])
                    valueCursor = text.index(after: valueCursor)
                }
                guard let last = digits.last?.wholeNumberValue else {
                    cursor = found.range.upperBound
                    continue
                }
                if symbol == "V", digits.count == 2 {
                    via = SimaiLocation(ring: .lane, index: digits.first?.wholeNumberValue ?? last)
                }
                end = SimaiLocation(ring: .lane, index: last)
            }

            let bracket = bracketContent(in: text, from: valueCursor)
            if let bracket {
                let timing = parseSlideTiming(bracket.content, bpm: bpm)
                slideDelay = timing.delay
                slideDuration += timing.duration
            }
            let shape = resolvedSlideShape(symbol, start: currentLocation, end: end)
            segments.append(SimaiSlideSegment(shape: shape, start: currentLocation, end: end, via: via))
            currentLocation = end
            cursor = bracket?.range.upperBound ?? valueCursor
        }
        guard !segments.isEmpty else { return [] }
        if slideDuration <= 0 { slideDuration = 60 / max(bpm, 1) }
        return [
            SimaiSlidePath(
                segments: segments, startTime: time + slideDelay, duration: max(slideDuration, 0.05),
                isBreak: text[firstRange.lowerBound...].contains("b"))
        ]
    }

    private static func parseDuration(_ raw: String, bpm: Double) -> TimeInterval {
        let pieces = raw.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        let effectiveBPM = pieces.dropLast().reversed().compactMap(Double.init).first ?? bpm
        guard let durationPart = pieces.last else { return 60 / bpm }
        if durationPart.contains(":") {
            let values = durationPart.split(separator: ":").compactMap { Double($0) }
            if values.count >= 2, values[0] > 0 { return (60 / max(effectiveBPM, 1)) * (4 / values[0]) * values[1] }
        }
        if raw.hasPrefix("#"), let seconds = Double(durationPart), seconds > 0 { return seconds }
        return Double(durationPart).map { max($0, 0.05) } ?? (60 / max(bpm, 1))
    }

    private static func parseSlideTiming(_ raw: String, bpm: Double) -> (delay: TimeInterval, duration: TimeInterval) {
        let defaultDelay = 60 / max(bpm, 1)
        let firstHash = raw.firstIndex(of: "#")
        let lastHash = raw.lastIndex(of: "#")

        guard let firstHash, let lastHash else { return (defaultDelay, parseDuration(raw, bpm: bpm)) }

        let durationText = String(raw[raw.index(after: lastHash)...])
        if firstHash == raw.startIndex, firstHash == lastHash {
            return (defaultDelay, Double(durationText).map { max($0, 0.05) } ?? defaultDelay)
        }

        let leading = String(raw[..<firstHash])
        if firstHash != lastHash {
            let explicitDelay = Double(leading).map { max($0, 0) } ?? defaultDelay
            return (explicitDelay, parseDuration(durationText, bpm: bpm))
        }

        let overrideBPM = Double(leading).flatMap { $0 > 0 ? $0 : nil } ?? bpm
        return (60 / max(overrideBPM, 1), parseDuration(durationText, bpm: overrideBPM))
    }

    private static func resolvedSlideShape(_ symbol: String, start: SimaiLocation, end: SimaiLocation)
        -> SimaiSlideShape
    {
        switch symbol {
        case ">": return ((start.index - 1 + 2) % 8) >= 4 ? .counterclockwise : .clockwise
        case "<": return ((start.index - 1 + 2) % 8) >= 4 ? .clockwise : .counterclockwise
        case "^":
            let difference = (end.index - 1) - (start.index - 1)
            let rotation = difference >= 0 ? (difference > 4 ? -1 : 1) : (difference < -4 ? 1 : -1)
            return rotation > 0 ? .clockwise : .counterclockwise
        default: return SimaiSlideShape(rawValue: symbol) ?? .straight
        }
    }

    private static func firstBracketContent(in text: Substring) -> String? {
        guard let open = text.firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    private static func bracketContent(in text: String, from start: String.Index) -> (
        content: String, range: Range<String.Index>
    )? {
        // A later segment can carry the only duration in a chained slide.
        guard start < text.endIndex, let open = text[start...].firstIndex(of: "["),
            !text[start..<open].contains(where: { slideOperatorCharacters.contains($0) }),
            let close = text[open...].firstIndex(of: "]")
        else { return nil }
        return (String(text[text.index(after: open)..<close]), open..<text.index(after: close))
    }

    private static func earliestOperator(in text: String, operators: [String]) -> Range<String.Index>? {
        operators.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func operatorAtOrAfter(in text: String, from start: String.Index, operators: [String]) -> (
        symbol: String, range: Range<String.Index>
    )? {
        let matches = operators.compactMap { symbol -> (String, Range<String.Index>)? in
            guard let range = text.range(of: symbol, range: start..<text.endIndex) else { return nil }
            return (symbol, range)
        }
        return matches.min {
            if $0.1.lowerBound == $1.1.lowerBound { return $0.0.count > $1.0.count }
            return $0.1.lowerBound < $1.1.lowerBound
        }
    }

    private static func splitBeat(_ text: Substring) -> (components: [Substring], suppressesEach: Bool) {
        var result: [Substring] = []
        var suppressesEach = false
        var start = text.startIndex
        var depth = 0
        for index in text.indices {
            let character = text[index]
            if character == "[" || character == "(" || character == "{" { depth += 1 }
            if character == "]" || character == ")" || character == "}" { depth = max(depth - 1, 0) }
            if depth == 0, character == "/" || character == "`" {
                if character == "`" { suppressesEach = true }
                result.append(text[start..<index])
                start = text.index(after: index)
            }
        }
        result.append(text[start..<text.endIndex])
        return (result, suppressesEach)
    }

    private static func compactNoteComponents(_ text: Substring) -> [Substring] {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
            let location = SimaiLocation.parse(text[first...])
        else { return [text] }

        var result: [Substring] = []
        var start = first
        var cursor = text.index(first, offsetBy: location.consumed)
        var depth = 0
        while cursor < text.endIndex {
            let character = text[cursor]
            if depth == 0 {
                // Slide destinations (including the two vertices of V) are not note heads.
                if slideOperatorCharacters.contains(character) || character == "*" { break }
                if let lane = character.wholeNumberValue, (1...8).contains(lane) {
                    result.append(text[start..<cursor])
                    start = cursor
                }
            }
            if character == "[" || character == "(" || character == "{" { depth += 1 }
            if character == "]" || character == ")" || character == "}" { depth = max(depth - 1, 0) }
            cursor = text.index(after: cursor)
        }
        result.append(text[start...])
        return result
    }

    private static func nextTopLevelComma(in text: String, from start: String.Index) -> String.Index {
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "[" || character == "(" || character == "{" { depth += 1 }
            if character == "]" || character == ")" || character == "}" { depth = max(depth - 1, 0) }
            if character == "," && depth == 0 { return index }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    private static func secondsPerStep(bpm: Double, subdivision: Double) -> TimeInterval {
        (60 / max(bpm, 1)) * (4 / max(subdivision, 1))
    }

    private static func positiveDouble(_ value: String?) -> Double? {
        guard let value, let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
            return nil
        }
        return parsed
    }

    private static func finiteDouble(_ value: String?) -> Double? {
        guard let value, let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite
        else { return nil }
        return parsed
    }
}

extension Array {
    fileprivate func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
