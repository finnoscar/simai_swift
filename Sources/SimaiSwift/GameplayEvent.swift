// SPDX-License-Identifier: GPL-3.0-only
// Native Swift adaptation from Airmai. See THIRD_PARTY_NOTICES.md.
import Foundation

public enum GameplayNoteType: String, CaseIterable, Codable, Hashable, Sendable {
    case tap
    case breakNote
    case hold
    case slide
    case touch
    case touchHold
    case unknown
}

public enum GameplayJudge: String, CaseIterable, Codable, Hashable, Sendable {
    case criticalPerfect
    case perfect
    case great
    case good
    case miss
    case unknown
}

public enum GameplayEventKind: String, CaseIterable, Codable, Hashable, Sendable {
    case noteArrival
    case noteHit
    case holdStart
    case holdEnd
    case holdBreak
    case slideStart
    case slideCheckpoint
    case slideComplete
    case touch
}

public enum GameplayPositionRing: String, Codable, Hashable, Sendable {
    case lane
    case a
    case b
    case c
    case d
    case e
    case unknown
}

public struct GameplayPosition: Codable, Hashable, Sendable {
    public let ring: GameplayPositionRing
    public let index: Int
}

/// A game-agnostic event emitted by the chart player. Consumers must not depend
/// on SimaiNoteEvent so replay, diagnostics and external integrations can evolve
/// independently from the gameplay model.
public struct GameplayEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sourceNoteID: Int?
    public let timestamp: TimeInterval
    public let emittedAtUptime: TimeInterval
    public let kind: GameplayEventKind
    public let noteType: GameplayNoteType
    /// The chart's actual note shape when `noteType` is the BREAK flag.
    public let baseNoteType: GameplayNoteType?
    public let lane: Int?
    public let position: GameplayPosition?
    public let judge: GameplayJudge?
    public let timingOffsetMs: Double?
    public let duration: TimeInterval?

    public init(
        id: UUID = UUID(), sourceNoteID: Int? = nil, timestamp: TimeInterval,
        emittedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime, kind: GameplayEventKind,
        noteType: GameplayNoteType, baseNoteType: GameplayNoteType? = nil, lane: Int?,
        position: GameplayPosition? = nil, judge: GameplayJudge?, timingOffsetMs: Double?, duration: TimeInterval?
    ) {
        self.id = id
        self.sourceNoteID = sourceNoteID
        self.timestamp = timestamp
        self.emittedAtUptime = emittedAtUptime
        self.kind = kind
        self.noteType = noteType
        self.baseNoteType = baseNoteType
        self.lane = lane
        self.position = position
        self.judge = judge
        self.timingOffsetMs = timingOffsetMs
        self.duration = duration
    }

    public var debugLine: String {
        let laneText =
            lane.map { "Lane \($0)" } ?? position.map { "\($0.ring.rawValue.uppercased())\($0.index)" } ?? "No Lane"
        let judgeText = judge?.rawValue.uppercased() ?? "ARRIVAL"
        let offsetText = timingOffsetMs.map { String(format: "%+.1fms", $0) } ?? ""
        return String(
            format: "%.3f  %@  %@  %@ %@", timestamp, laneText, noteType.rawValue.uppercased(), judgeText, offsetText
        ).trimmingCharacters(in: .whitespaces)
    }
}
