// SPDX-License-Identifier: GPL-3.0-only
// Native Swift adaptation from Airmai. See THIRD_PARTY_NOTICES.md.
import SwiftUI

@MainActor public final class SimaiPreviewHitSoundController: ObservableObject {
    private var previousChartTime: TimeInterval?
    private var nextEventIndex: Int?

    public func prepare(settings: SimaiPlaybackSettings) {
        SimaiHitSoundEngine.shared.prepare(
            hitVolume: settings.hitSoundVolume, answerVolume: settings.answerSoundVolume,
            judgementVolume: settings.judgementSoundVolume)
    }

    public func update(currentTime: TimeInterval, chart: SimaiChart, settings: SimaiPlaybackSettings, isPlaying: Bool) {
        let chartTime = currentTime + settings.audioTimingOffset
        guard isPlaying, settings.answerSoundEnabled else {
            previousChartTime = chartTime
            nextEventIndex = nil
            return
        }

        let previousTime = previousChartTime ?? max(chartTime - 0.2, -0.2)
        previousChartTime = chartTime

        // Seeking and scrubbing should reposition the scheduler without replaying
        // every note crossed by the jump.
        let elapsed = chartTime - previousTime
        guard elapsed >= 0, elapsed <= 0.25 else {
            nextEventIndex = firstEventIndex(after: chartTime, in: chart.events)
            return
        }

        var index = nextEventIndex ?? firstEventIndex(after: previousTime + 0.000_001, in: chart.events)
        var lastTriggeredTime: TimeInterval?
        while index < chart.events.count, chart.events[index].time <= chartTime + 0.002 {
            let event = chart.events[index]
            guard event.isScorable else {
                index += 1
                continue
            }
            if let lastTriggeredTime, abs(event.time - lastTriggeredTime) <= 0.000_1 {
                index += 1
                continue
            }
            SimaiHitSoundEngine.shared.playAnswer(volume: settings.answerSoundVolume)
            lastTriggeredTime = event.time
            index += 1
        }
        nextEventIndex = index
    }

    private func firstEventIndex(after time: TimeInterval, in events: [SimaiNoteEvent]) -> Int {
        var lower = 0
        var upper = events.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if events[middle].time > time { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }
}
