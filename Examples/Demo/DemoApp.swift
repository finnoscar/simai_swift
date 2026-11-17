// SPDX-License-Identifier: GPL-3.0-only
import SimaiSwift
import SwiftUI

@main struct SimaiDemoApp: App { var body: some Scene { WindowGroup { DemoRoot() } } }

@MainActor private struct DemoRoot: View {
    @State private var controller: SimaiPlayerController?
    @State private var mode: SimaiPlayerMode = .preview
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            Picker("模式", selection: $mode) {
                Text("预览").tag(SimaiPlayerMode.preview)
                Text("游玩").tag(SimaiPlayerMode.gameplay)
            }.pickerStyle(.segmented).padding(.horizontal, 16)
            if let controller {
                SimaiPlayerView(controller: controller, mode: mode)
            } else if let error {
                Text(error)
            } else {
                ProgressView("准备演示谱面")
            }
        }.foregroundStyle(.white).background(.black).task {
            guard controller == nil else { return }
            do {
                let audio = try await Task.detached { try DemoAudio.make() }.value
                let notation = "(120){4}1,2,3,4,5,6,7,8,1/5,2/6,3h[4:1],4,5-1[4:2],,A1,C1,1b,2x,3,4,5,6,7,8,E"
                let chart = try SimaiChartParser.parse(notation: notation, offset: 2)
                controller = SimaiPlayerController(chart: chart, audioURL: audio)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// The demo generates its own metronome, so the repository needs no song assets.
private enum DemoAudio {
    static func make() throws -> URL {
        let sampleRate = 48_000
        let frameCount = sampleRate * 20
        var pcm = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let beatTime = time.truncatingRemainder(dividingBy: 0.5)
            let envelope = max(0, 1 - beatTime / 0.025)
            let sample = Int16(sin(time * 2 * .pi * 1_000) * envelope * 3_000)
            append(sample, to: &pcm)
        }
        var wav = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt32(sampleRate), to: &wav)
        append(UInt32(sampleRate * 2), to: &wav)
        append(UInt16(2), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        append(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simai-swift-demo.wav")
        try wav.write(to: url, options: .atomic)
        return url
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
