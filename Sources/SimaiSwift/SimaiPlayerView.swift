// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

#if canImport(UIKit)
import UIKit

public enum SimaiPlayerMode: String, Sendable {
    case preview
    case gameplay
}

/// A value snapshot suitable for a host's own results UI or persistence.
public struct SimaiGameplayResult: Sendable {
    public let achievement: Double
    public let achievementFrom101: Double
    public let dxScore: Int
    public let totalDXScore: Int
    public let maxCombo: Int
    public let fastCount: Int
    public let lateCount: Int
    public let judgements: [SimaiJudgement: Int]

    @MainActor public init(session: SimaiGameplaySession) {
        achievement = session.achievement
        achievementFrom101 = session.achievementFrom101
        dxScore = session.dxScore
        totalDXScore = session.totalDXScore
        maxCombo = session.maxCombo
        fastCount = session.fastCount
        lateCount = session.lateCount
        judgements = Dictionary(uniqueKeysWithValues: SimaiJudgement.allCases.map { ($0, session.counts(for: $0)) })
    }
}

/// Local-file playback with the native playfield, touch input and transport.
@MainActor public struct SimaiPlayerView: View {
    @ObservedObject private var controller: SimaiPlayerController
    private let mode: SimaiPlayerMode
    private let onComplete: (SimaiGameplayResult) -> Void

    public init(
        controller: SimaiPlayerController, mode: SimaiPlayerMode = .preview,
        onComplete: @escaping (SimaiGameplayResult) -> Void = { _ in }
    ) {
        self.controller = controller
        self.mode = mode
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 16) {
            if let chart = controller.chart {
                SimaiPlayerStage(chart: chart, controller: controller, mode: mode, onComplete: onComplete).id(
                    controller.playbackID)
                SimaiPlayerTransport(controller: controller, mode: mode)
            } else if let error = controller.errorMessage {
                Text(error).multilineTextAlignment(.center)
                Button("重试") { Task { await controller.prepare() } }.buttonStyle(.borderedProminent)
            } else {
                ProgressView("准备谱面与音频")
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white).tint(.cyan).background(
            .black
        ).task(id: mode) { await controller.prepare() }.onDisappear { controller.stop() }.onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in controller.pause() }.onReceive(controller.$settings) { settings in
            controller.setVolume(settings.musicVolume)
        }
    }
}

@MainActor private struct SimaiPlayerStage: View {
    let chart: SimaiChart
    @ObservedObject var controller: SimaiPlayerController
    let mode: SimaiPlayerMode
    let onComplete: (SimaiGameplayResult) -> Void
    @StateObject private var session: SimaiGameplaySession

    init(
        chart: SimaiChart, controller: SimaiPlayerController, mode: SimaiPlayerMode,
        onComplete: @escaping (SimaiGameplayResult) -> Void
    ) {
        self.chart = chart
        self.controller = controller
        self.mode = mode
        self.onComplete = onComplete
        _session = StateObject(wrappedValue: SimaiGameplaySession(chart: chart, gameplayEventBus: controller.events))
    }

    var body: some View {
        VStack(spacing: 12) {
            SimaiClockStage(
                chart: chart, controller: controller, clock: controller.clock, session: session, mode: mode,
                onComplete: onComplete)
            if mode == .gameplay { SimaiScoreSummary(session: session) }
        }
    }
}

@MainActor private struct SimaiClockStage: View {
    let chart: SimaiChart
    let controller: SimaiPlayerController
    @ObservedObject var clock: SimaiPlaybackClock
    @ObservedObject var session: SimaiGameplaySession
    let mode: SimaiPlayerMode
    let onComplete: (SimaiGameplayResult) -> Void
    @StateObject private var previewSound = SimaiPreviewHitSoundController()
    @State private var didComplete = false

    var body: some View {
        ZStack {
            SimaiChartRenderer(
                chart: chart, currentTime: clock.currentTime, settings: controller.settings,
                judgedEventIDs: mode == .gameplay ? session.judgedEventIDs : [],
                resolvedHeadEventIDs: mode == .gameplay ? session.resolvedHeadEventIDs : [],
                headFeedbackByEventID: mode == .gameplay ? session.headFeedbackByEventID : [:],
                judgementFeedback: mode == .gameplay ? session.judgementFeedback : [],
                pressedHoldEventIDs: mode == .gameplay ? session.pressedHoldEventIDs : [],
                slideVisualProgress: mode == .gameplay ? session.slideVisualProgress : [:],
                isGameplay: mode == .gameplay)
            if mode == .gameplay, controller.isPlaying, !session.isFinished {
                SimaiMultiTouchSurface { frame in
                    if frame.phase == .began, !frame.changed.isEmpty, controller.settings.hitSoundEnabled {
                        SimaiHitSoundEngine.shared.playHit(volume: controller.settings.hitSoundVolume)
                    }
                    session.handle(
                        frame: frame, playbackTimeAtSystemUptime: controller.presentationTime(atSystemUptime:),
                        settings: controller.settings)
                }.accessibilityLabel("谱面游玩区域")
            }
        }.aspectRatio(1, contentMode: .fit).onReceive(clock.$currentTime) { time in
            if mode == .preview {
                previewSound.update(
                    currentTime: controller.hitSoundClockTime, chart: chart, settings: controller.settings,
                    isPlaying: controller.isPlaying)
            } else if controller.isPlaying || time >= controller.duration {
                session.update(
                    time: time >= controller.duration ? controller.duration : controller.livePresentationTime,
                    settings: controller.settings)
                if session.isFinished, !didComplete {
                    didComplete = true
                    controller.pause()
                    onComplete(SimaiGameplayResult(session: session))
                }
            }
        }.onReceive(controller.$isPlaying.removeDuplicates()) { playing in
            if !playing {
                session.releaseAllInputs(time: controller.livePresentationTime, settings: controller.settings)
            }
        }
    }
}

@MainActor private struct SimaiPlayerTransport: View {
    @ObservedObject var controller: SimaiPlayerController
    let mode: SimaiPlayerMode

    var body: some View {
        HStack(spacing: 24) {
            Button {
                Task {
                    await controller.prepare()
                    controller.play()
                }
            } label: {
                Label("重播", systemImage: "backward.end.fill")
            }.labelStyle(.iconOnly)
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(
                    minWidth: 44, minHeight: 44)
            }.accessibilityLabel(controller.isPlaying ? "暂停" : "播放").buttonStyle(.borderedProminent)
            if mode == .preview {
                Button {
                    if let chart = controller.chart {
                        controller.seek(to: chart.nextEventTime(after: controller.currentTime))
                    }
                } label: {
                    Label("下一个音符", systemImage: "forward.frame.fill")
                }.labelStyle(.iconOnly)
            }
        }.controlSize(.large)
    }
}

@MainActor private struct SimaiScoreSummary: View {
    @ObservedObject var session: SimaiGameplaySession

    var body: some View {
        VStack(spacing: 6) {
            Text(session.achievement / 100, format: .percent.precision(.fractionLength(4))).font(
                .system(.title, design: .rounded, weight: .bold)
            ).monospacedDigit()
            Text("Combo \(session.combo) · DX \(session.dxScore) / \(session.totalDXScore)").font(.subheadline)
                .foregroundStyle(.secondary)
            if session.isFinished { Text("游玩结束").font(.headline) }
        }.accessibilityElement(children: .combine)
    }
}
#endif
