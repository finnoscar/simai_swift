// SPDX-License-Identifier: GPL-3.0-only
// Native Swift adaptation from Airmai. See THIRD_PARTY_NOTICES.md.
import AVFoundation
import QuartzCore
import SwiftUI

#if canImport(UIKit)
import UIKit
private struct SimaiPlaybackResource { let chart: SimaiChart }
@MainActor private final class SimaiDisplayLinkProxy: NSObject {
    weak var owner: SimaiPlayerController?
    init(owner: SimaiPlayerController) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) {
        if let owner { owner.updatePlaybackTime(link) } else { link.invalidate() }
    }
}
@MainActor public final class SimaiPlaybackClock: ObservableObject {
    @Published public fileprivate(set) var currentTime: TimeInterval = 0
}

private struct SimaiPlaybackTimeMapping {
    let hostTime: TimeInterval
    let presentationTime: TimeInterval
    let rate: Double
    let duration: TimeInterval

    func presentationTime(atSystemUptime timestamp: TimeInterval) -> TimeInterval {
        let predicted = presentationTime + (timestamp - hostTime) * rate
        return max(0, min(predicted, duration))
    }
}

@MainActor public final class SimaiPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private let sourceChart: SimaiChart
    private let audioURL: URL
    private var loadGeneration = UUID()
    @Published public var settings: SimaiPlaybackSettings
    @Published public private(set) var playbackID = UUID()
    public let events = GameplayEventBus()

    public init(chart: SimaiChart, audioURL: URL, settings: SimaiPlaybackSettings = .init()) {
        self.sourceChart = chart
        self.audioURL = audioURL
        self.settings = settings
        super.init()
    }

    deinit {
        displayLink?.invalidate()
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
    }

    public func presentationTime(atSystemUptime timestamp: TimeInterval) -> TimeInterval {
        playbackTimeMapping().presentationTime(atSystemUptime: timestamp)
    }
    @Published private var resource: SimaiPlaybackResource?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isPlaying = false

    public let clock = SimaiPlaybackClock()

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private var isScrubbing = false
    private var resumesPlaybackAfterScrubbing = false
    private var routeChangeObserver: NSObjectProtocol?
    private var audioPresentationLatency: TimeInterval = SimaiPlayerController.audioPlayerPipelineLatency
    private var playbackVisualFloor: TimeInterval?

    // Preserve the existing device calibration baseline while driving every
    // song from the same local audio-device clock. Route-reported latency can
    // be larger (for example, AirPlay), so the larger value still wins.
    private static let audioPlayerPipelineLatency: TimeInterval = 0.085
    private static let scheduledStartLeadTime: TimeInterval = 0.02

    public var chart: SimaiChart? { resource?.chart }
    public var duration: TimeInterval { resource?.chart.duration ?? 1 }
    public var currentTime: TimeInterval { clock.currentTime }
    public var livePresentationTime: TimeInterval {
        playbackTimeMapping().presentationTime(atSystemUptime: ProcessInfo.processInfo.systemUptime)
    }
    public var hitSoundClockTime: TimeInterval {
        guard let rawTime = rawPlaybackTime(atSystemUptime: ProcessInfo.processInfo.systemUptime) else {
            return clock.currentTime + audioPresentationLatency
        }
        return max(0, min(rawTime, duration))
    }

    public func prepare() async {
        stop()
        let generation = loadGeneration
        playbackID = UUID()
        isLoading = true
        errorMessage = nil
        let chart = sourceChart
        let mirror = settings.mirror
        do {
            guard audioURL.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            await Task.detached(priority: .userInitiated) {
                SimaiSlidePathGeometry.prepare(chart: chart, mirror: mirror)
            }.value
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            try configurePlayer(url: audioURL, volume: settings.musicVolume)
            resource = SimaiPlaybackResource(chart: chart)
            SimaiHitSoundEngine.shared.prepare(
                hitVolume: settings.hitSoundVolume, answerVolume: settings.answerSoundVolume,
                judgementVolume: settings.judgementSoundVolume)
        } catch {
            guard loadGeneration == generation else { return }
            resource = nil
            errorMessage = error.localizedDescription
        }
        if loadGeneration == generation { isLoading = false }
    }

    public func setVolume(_ value: Double) { player?.volume = Float(max(0, min(value, 1))) }

    public func togglePlayback() { isPlaying ? pause() : play() }

    public func play() {
        guard resource != nil, let player else { return }
        if currentTime >= duration - 0.1 { seek(to: 0) }
        playbackVisualFloor = currentTime
        let startTime = player.deviceCurrentTime + Self.scheduledStartLeadTime
        if player.play(atTime: startTime) {
            isPlaying = true
            displayLink?.isPaused = false
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        displayLink?.isPaused = true
        playbackVisualFloor = nil
    }

    public func seek(to time: TimeInterval, precise: Bool = true) {
        _ = precise
        let clamped = max(0, min(time, duration))
        player?.currentTime = clamped
        clock.currentTime = clamped
        playbackVisualFloor = isPlaying ? clamped : nil
    }

    public func scrub(to time: TimeInterval) {
        if !isScrubbing {
            isScrubbing = true
            resumesPlaybackAfterScrubbing = isPlaying
            player?.pause()
            isPlaying = false
            displayLink?.isPaused = true
        }

        clock.currentTime = max(0, min(time, duration))
    }

    public func finishScrubbing(at time: TimeInterval) {
        if !isScrubbing {
            isScrubbing = true
            resumesPlaybackAfterScrubbing = isPlaying
            player?.pause()
            isPlaying = false
            displayLink?.isPaused = true
        }

        let clamped = max(0, min(time, duration))
        let shouldResume = resumesPlaybackAfterScrubbing
        clock.currentTime = clamped

        guard let player else {
            isScrubbing = false
            resumesPlaybackAfterScrubbing = false
            return
        }

        player.currentTime = clamped
        isScrubbing = false
        resumesPlaybackAfterScrubbing = false
        if shouldResume {
            playbackVisualFloor = clamped
            let startTime = player.deviceCurrentTime + Self.scheduledStartLeadTime
            if player.play(atTime: startTime) {
                isPlaying = true
                displayLink?.isPaused = false
            }
        }
    }

    public func stop() {
        loadGeneration = UUID()
        isLoading = false
        isScrubbing = false
        resumesPlaybackAfterScrubbing = false
        player?.stop()
        player?.delegate = nil
        isPlaying = false
        displayLink?.isPaused = true
        clock.currentTime = 0
        resource = nil
        errorMessage = nil
        displayLink?.invalidate()
        displayLink = nil
        player = nil
        playbackVisualFloor = nil
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        routeChangeObserver = nil
    }

    private func configurePlayer(url: URL, volume: Double) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? audioSession.setPreferredSampleRate(48_000)
        try? audioSession.setPreferredIOBufferDuration(0.005)
        try? audioSession.setActive(true)
        updateAudioPresentationLatency(using: audioSession)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.enableRate = true
        player.rate = 1
        player.volume = Float(max(0, min(volume, 1)))
        player.prepareToPlay()
        self.player = player

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: .main
        ) { [weak self, weak audioSession] _ in
            guard let audioSession else { return }
            Task { @MainActor in self?.updateAudioPresentationLatency(using: audioSession) }
        }

        let displayLink = CADisplayLink(
            target: SimaiDisplayLinkProxy(owner: self), selector: #selector(SimaiDisplayLinkProxy.tick(_:)))
        displayLink.preferredFramesPerSecond = 60
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    fileprivate func updatePlaybackTime(_ displayLink: CADisplayLink) {
        guard !isScrubbing, isPlaying, player != nil else { return }
        // Render for the frame that is about to reach the display. The same
        // host-time mapping is used for touch judgement, so both stay on the
        // local audio-device timeline after changing songs or seeking.
        var presentationTime = playbackTimeMapping().presentationTime(atSystemUptime: displayLink.targetTimestamp)
        if let playbackVisualFloor {
            presentationTime = max(presentationTime, playbackVisualFloor)
            if presentationTime > playbackVisualFloor + 0.001 { self.playbackVisualFloor = nil }
        }
        clock.currentTime = presentationTime
    }

    fileprivate func playbackTimeMapping() -> SimaiPlaybackTimeMapping {
        let hostTime = ProcessInfo.processInfo.systemUptime
        let rawTime =
            rawPlaybackTime(atSystemUptime: hostTime) ?? min(clock.currentTime + audioPresentationLatency, duration)
        let effectiveRate = player?.isPlaying == true ? Double(player?.rate ?? 1) : 0
        return SimaiPlaybackTimeMapping(
            hostTime: hostTime, presentationTime: max(0, min(rawTime - audioPresentationLatency, duration)),
            rate: effectiveRate, duration: duration)
    }

    private func rawPlaybackTime(atSystemUptime timestamp: TimeInterval) -> TimeInterval? {
        guard let player else { return nil }
        let sampledHostTime = ProcessInfo.processInfo.systemUptime
        let sampledAudioTime = player.currentTime
        guard sampledAudioTime.isFinite else { return nil }
        let rate = player.isPlaying ? Double(player.rate) : 0
        return sampledAudioTime + (timestamp - sampledHostTime) * rate
    }

    private func updateAudioPresentationLatency(using session: AVAudioSession) {
        let routeLatency = session.outputLatency + session.ioBufferDuration
        audioPresentationLatency = max(Self.audioPlayerPipelineLatency, routeLatency)
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let activePlayer = self.player, ObjectIdentifier(activePlayer) == playerID else { return }
            self.isPlaying = false
            self.displayLink?.isPaused = true
            self.playbackVisualFloor = nil
            self.clock.currentTime = self.duration
        }
    }
}

#endif
