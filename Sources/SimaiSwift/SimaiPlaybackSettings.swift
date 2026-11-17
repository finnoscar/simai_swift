// SPDX-License-Identifier: GPL-3.0-only
// Native Swift adaptation from Airmai. See THIRD_PARTY_NOTICES.md.
import Foundation

public enum SimaiChartBackgroundStyle: String, CaseIterable, Identifiable {
    case artwork
    case gradient
    case black

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .artwork: return "曲绘"
        case .gradient: return "渐变"
        case .black: return "纯黑"
        }
    }
}

public enum SimaiCenterDisplayMode: String, CaseIterable, Identifiable {
    case achievement
    case achievementFrom101
    case combo
    case remaining

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .achievement: return "达成率"
        case .achievementFrom101: return "101% 递减"
        case .combo: return "连击"
        case .remaining: return "剩余音符"
        }
    }
}

public struct SimaiPlaybackSettings: Equatable {
    public init() {}
    public var noteSpeed = 8.0
    public var audioTimingOffset = 0.0
    public var visualTimingOffset = 0.0
    public var musicVolume = 0.78
    public var hitSoundVolume = 0.2
    public var hitSoundEnabled = true
    public var answerSoundVolume = 0.2
    public var answerSoundEnabled = true
    public var judgementSoundVolume = 0.2
    public var judgementSoundEnabled = true
    public var showApproachLine = true
    public var showEffects = true
    public var rotateSlideStar = true
    public var mirror: SimaiMirrorMode = .none
    public var backgroundStyle: SimaiChartBackgroundStyle = .artwork
    public var backgroundDim = 0.58
    public var centerDisplay: SimaiCenterDisplayMode = .achievement

    public var approachTime: TimeInterval { SimaiNoteMotion.approachTime(speed: noteSpeed) }
}
