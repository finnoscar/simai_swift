// Compiled alongside the actual engine by Tools/test_native_regressions.rb. All audio
// is rendered offline into memory; no speaker, microphone or account is used.
extension SimaiHitSoundEngine {
    static func offlineGainRegression() throws -> String {
        let sound = SimaiHitSoundEngine.shared
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        sound.engine.stop()
        try sound.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try sound.engine.start()
        defer { sound.engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var checks = 0, failures = 0
        var lines: [String] = []

        func render(frames: Int) throws -> (peak: Double, energy: Double) {
            var remaining = frames, peak = 0.0, energy = 0.0
            while remaining > 0 {
                let count = AVAudioFrameCount(min(1024, remaining))
                let status = try sound.engine.renderOffline(count, to: output)
                guard status == .success else { throw CocoaError(.fileReadUnknown) }
                for frame in 0..<Int(output.frameLength) {
                    let sample = Double(output.floatChannelData![0][frame])
                    peak = max(peak, abs(sample))
                    energy += sample * sample
                }
                remaining -= Int(count)
            }
            return (peak, energy)
        }

        func verify(_ cue: Cue, gain: Float) throws -> Double {
            guard let source = sound.buffers[cue], let samples = source.floatChannelData?[0] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            var expectedPeak = 0.0, expectedEnergy = 0.0
            for frame in 0..<Int(source.frameLength) {
                let sample = Double(samples[frame] * gain)
                expectedPeak = max(expectedPeak, abs(sample))
                expectedEnergy += sample * sample
            }
            sound.playPreparedSound(cue, volume: gain)
            let voice = sound.players[(sound.cursor - 1) % sound.players.count]
            guard voice.volume == 1 else { throw CocoaError(.fileReadUnknown) }
            // Offline rendering can advance faster than the player's command
            // queue. A data-rendered marker waits for the actual cue and keeps
            // its samples inside this check when a VM delays scheduling.
            let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            marker.frameLength = 1
            marker.floatChannelData![0][0] = 0
            let completion = DispatchSemaphore(value: 0)
            voice.scheduleBuffer(marker, completionCallbackType: .dataRendered) { _ in completion.signal() }
            var rendered = (peak: 0.0, energy: 0.0)
            var completed = false
            for _ in 0..<240 {
                let block = try render(frames: 1024)
                rendered.peak = max(rendered.peak, block.peak)
                rendered.energy += block.energy
                if completion.wait(timeout: .now() + .milliseconds(1)) == .success {
                    completed = true
                    break
                }
            }
            guard completed else { throw CocoaError(.fileReadUnknown) }
            let tail = try render(frames: 4096)
            rendered.peak = max(rendered.peak, tail.peak)
            rendered.energy += tail.energy
            checks += 1
            if abs(rendered.peak - expectedPeak) > max(0.000_001, expectedPeak * 0.001)
                || abs(rendered.energy - expectedEnergy) > max(0.000_001, expectedEnergy * 0.001) {
                failures += 1
                if failures <= 6 {
                    lines.append("Mismatch \(checks), \(cue), gain \(gain): peak \(rendered.peak)/\(expectedPeak), energy \(rendered.energy)/\(expectedEnergy)")
                }
            }
            return rendered.peak
        }

        _ = try render(frames: 4096)
        for cue in [Cue.hit, .answer, .perfect, .great, .good, .miss] {
            var first = 0.0, reused = 0.0
            for index in 0..<96 {
                let peak = try verify(cue, gain: 0.2)
                if index == 0 { first = peak }
                if index == 64 { reused = peak }
            }
            lines.append("\(cue): first=\(first), reused=\(reused)")
        }
        // A shared voice must not inherit a previous cue's gain. Repeated
        // changes also exercise eviction/replacement of each cue's gain cache.
        for index in 0..<96 {
            for (cue, gain) in [(Cue.hit, Float(index.isMultiple(of: 2) ? 0.8 : 0.1)),
                                (.answer, Float(index.isMultiple(of: 3) ? 0.2 : 0.6)),
                                (.perfect, Float(index.isMultiple(of: 4) ? 1 : 0.3))] {
                _ = try verify(cue, gain: gain)
            }
        }
        lines.append("\(failures == 0 ? "PASS" : "FAIL"): \(checks) native offline peak/energy checks, \(failures) mismatches")
        return lines.joined(separator: "\n")
    }
}

#if !os(iOS)
@main struct SimaiHitSoundTestRunner {
    static func main() throws {
        let report = try SimaiHitSoundEngine.offlineGainRegression()
        print(report)
        if report.contains("FAIL:") { exit(1) }
    }
}
#endif
