#!/usr/bin/env ruby
# An allowlisted, reproducible source extraction. Never reads Git history,
# account data, configuration, chart downloads or app containers.
require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'

abort 'Usage: ruby Tools/export_from_airmai.rb /path/to/airmai' unless ARGV.length == 1
source_root = File.expand_path(ARGV.fetch(0))
package_root = File.expand_path('..', __dir__)
target = File.join(package_root, 'Sources/SimaiSwift')
FileUtils.mkdir_p(target)

def section(source, first, last)
  start = source.index(first) or abort("Missing source marker #{first}")
  finish = source.index(last, start) or abort("Missing source marker #{last}")
  source[start...finish]
end

def replace!(source, before, after)
  abort "Source changed; missing #{before.lines.first.strip}" unless source.include?(before)
  source.sub!(before, after)
end

paths = {
  'models' => 'MaimaiScoreTracker/Services/Models/SimaiChartModels.swift',
  'renderer' => 'MaimaiScoreTracker/Views/SimaiChartRenderer.swift',
  'experience' => 'MaimaiScoreTracker/Views/SimaiChartExperienceView.swift',
  'events' => 'MaimaiScoreTracker/Coyote/GameplayEvent.swift',
  'bus' => 'MaimaiScoreTracker/Coyote/GameplayEventBus.swift'
}
inputs = paths.transform_values { |path| File.read(File.join(source_root, path)) }
models = inputs.fetch('models').dup
replace!(models, '落雪没有提供所选难度的谱面', '未找到所选难度的谱面')
replace!(models, "struct SimaiNoteFlags: OptionSet, Sendable, Hashable {",
         "struct SimaiNoteFlags: OptionSet, Sendable, Hashable {\n    init(rawValue: Int) { self.rawValue = rawValue }")

renderer = inputs.fetch('renderer').dup
replace!(renderer, "import UIKit", "#if canImport(UIKit)\nimport UIKit\n#endif")
replace!(renderer, 'struct SimaiMultiTouchSurface:', "#if canImport(UIKit)\nstruct SimaiMultiTouchSurface:")
replace!(renderer, 'enum SimaiJudgement:', "#endif\n\nenum SimaiJudgement:")
replace!(renderer, "    private init() {\n        // AVAudioEngine", "    init(answerData: Data? = nil) {\n        // AVAudioEngine")
replace!(renderer, 'if let data = NSDataAsset(name: "SimaiAnswer")?.data,', 'if let data = answerData,')
replace!(renderer, "        guard !buffers.isEmpty else { return }\n        for _ in 0..<32 {",
         "        if buffers[.answer] == nil {\n            buffers[.answer] = Self.makeSynthesizedBuffer(cue: .hit, format: format)\n        }\n        guard !buffers.isEmpty else { return }\n        for _ in 0..<32 {")
replace!(renderer, 'struct SimaiTouchContact: Hashable {', <<~SWIFT.chomp)
  struct SimaiTouchContact: Hashable {
      init(id: Int, point: CGPoint, timestamp: TimeInterval) {
          self.id = id
          self.point = point
          self.timestamp = timestamp
      }
SWIFT
replace!(renderer, 'struct SimaiTouchFrame {', <<~SWIFT.chomp)
  struct SimaiTouchFrame {
      init(active: [SimaiTouchContact], changed: [SimaiTouchContact], phase: Phase) {
          self.active = active
          self.changed = changed
          self.phase = phase
      }
SWIFT
replace!(renderer, 'struct SimaiMultiTouchSurface: UIViewRepresentable {', <<~SWIFT.chomp)
  struct SimaiMultiTouchSurface: UIViewRepresentable {
      init(onTouches: @escaping (SimaiTouchFrame) -> Void) { self.onTouches = onTouches }
SWIFT
replace!(renderer, 'struct SimaiChartRenderer: View {', <<~SWIFT.chomp)
  struct SimaiChartRenderer: View {
      init(chart: SimaiChart, currentTime: TimeInterval, settings: SimaiPlaybackSettings = .init(),
           judgedEventIDs: Set<Int> = [], resolvedHeadEventIDs: Set<Int> = [],
           headFeedbackByEventID: [Int: SimaiJudgementFeedback] = [:],
           judgementFeedback: [SimaiJudgementFeedback] = [], pressedHoldEventIDs: Set<Int> = [],
           slideVisualProgress: [String: [Double]] = [:], isGameplay: Bool = false) {
          self.chart = chart
          self.currentTime = currentTime
          self.settings = settings
          self.judgedEventIDs = judgedEventIDs
          self.resolvedHeadEventIDs = resolvedHeadEventIDs
          self.headFeedbackByEventID = headFeedbackByEventID
          self.judgementFeedback = judgementFeedback
          self.pressedHoldEventIDs = pressedHoldEventIDs
          self.slideVisualProgress = slideVisualProgress
          self.isGameplay = isGameplay
      }
SWIFT

player = section(inputs.fetch('experience'), "@MainActor\nfinal class SimaiPlaybackClock:", 'private struct SimaiPlaybackClockReader')
player.gsub!('SimaiChartPlayerModel', 'SimaiPlayerController')
replace!(player, '@Published private(set) var resource: LXNSChartResource?', '@Published private var resource: SimaiPlaybackResource?')
replace!(player, 'final class SimaiPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {', <<~'SWIFT'.chomp)
  final class SimaiPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
      private let sourceChart: SimaiChart
      private let audioURL: URL
      private var loadGeneration = UUID()
      @Published var settings: SimaiPlaybackSettings
      @Published private(set) var playbackID = UUID()
      let events = GameplayEventBus()

      init(chart: SimaiChart, audioURL: URL, settings: SimaiPlaybackSettings = .init()) {
          self.sourceChart = chart
          self.audioURL = audioURL
          self.settings = settings
          super.init()
      }

      deinit {
          displayLink?.invalidate()
          if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
      }

      func presentationTime(atSystemUptime timestamp: TimeInterval) -> TimeInterval {
          playbackTimeMapping().presentationTime(atSystemUptime: timestamp)
      }
SWIFT
old_load = section(player, '    func load(songID:', '    func setVolume(')
replace!(player, old_load, <<~'SWIFT')
      func prepare() async {
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
              SimaiHitSoundEngine.shared.prepare(hitVolume: settings.hitSoundVolume,
                  answerVolume: settings.answerSoundVolume, judgementVolume: settings.judgementSoundVolume)
          } catch {
              guard loadGeneration == generation else { return }
              resource = nil
              errorMessage = error.localizedDescription
          }
          if loadGeneration == generation { isLoading = false }
      }

SWIFT
replace!(player, "    func stop() {", "    func stop() {\n        loadGeneration = UUID()\n        isLoading = false")
# CADisplayLink must not keep the controller alive after a host drops it.
replace!(player, 'CADisplayLink(target: self, selector: #selector(updatePlaybackTime(_:)))',
         'CADisplayLink(target: SimaiDisplayLinkProxy(owner: self), selector: #selector(SimaiDisplayLinkProxy.tick(_:)))')
replace!(player, '@objc private func updatePlaybackTime', 'fileprivate func updatePlaybackTime')
player = <<~SWIFT + player + <<~SWIFT
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
SWIFT
  #endif
SWIFT
preview_sound = "import SwiftUI\n" + section(inputs.fetch('experience'),
  "@MainActor\nprivate final class SimaiPreviewHitSoundController:", 'struct SimaiChartExperienceView:')
preview_sound.sub!('private final class SimaiPreviewHitSoundController', 'final class SimaiPreviewHitSoundController')

settings = "import Foundation\n" + section(inputs.fetch('experience'), 'enum SimaiChartBackgroundStyle:', 'private enum SimaiPlaybackSettingsStore')
replace!(settings, 'struct SimaiPlaybackSettings: Equatable {', "struct SimaiPlaybackSettings: Equatable {\n    init() {}")
events = inputs.fetch('events')
bus = inputs.fetch('bus').dup
replace!(bus, 'final class GameplayEventBus: @unchecked Sendable {', "final class GameplayEventBus: @unchecked Sendable {\n    init() {}")

source_files = {
  'SimaiChartModels.swift' => models,
  'SimaiChartRenderer.swift' => renderer,
  'SimaiPlaybackSettings.swift' => settings,
  'GameplayEvent.swift' => events,
  'GameplayEventBus.swift' => bus
}
source_files['SimaiPlayerController.swift'] = player
source_files['SimaiPreviewHitSoundController.swift'] = preview_sound
renderer.gsub!('AIRMAI_GAMEPLAY_METRICS', 'SIMAI_SWIFT_GAMEPLAY_METRICS')
renderer.gsub!('Airmai gameplay %@', 'SimaiSwift gameplay %@')
renderer.gsub!('com.airmai.simai-hit-sound', 'org.simai.swift.hit-sound')
replace!(renderer, 'let currentRadius = radius * motion.radius',
         'let currentRadius = radius * CGFloat(motion.radius)')
toolchain = IO.popen(%w[xcrun --find swiftc], &:read).strip
host = File.expand_path('../lib/swift/host', File.dirname(toolchain))
sdk = IO.popen(%w[xcrun --sdk macosx --show-sdk-path], &:read).strip
Dir.mktmpdir('simai-swift-export-') do |temporary|
  rewriter = File.join(temporary, 'publicize')
  success = system(toolchain, '-sdk', sdk, '-target', 'arm64-apple-macos15.0', '-I', host, '-L', host,
                   '-Xlinker', '-rpath', '-Xlinker', host,
                   File.join(__dir__, 'Publicize.swift'), '-o', rewriter)
  abort 'Could not compile the access-control adapter' unless success
  source_files.each do |name, source|
    input = File.join(temporary, name)
    File.write(input, source)
    public_source = IO.popen([rewriter, input], &:read)
    abort "Public API export failed for #{name}" unless $?.success?
    header = "// SPDX-License-Identifier: GPL-3.0-only\n// Native Swift adaptation from Airmai. See THIRD_PARTY_NOTICES.md.\n"
    File.write(File.join(target, name), header + public_source)
  end
end
abort 'Source formatting failed' unless system('xcrun', 'swift-format', 'format', '--in-place',
  *source_files.keys.map { |name| File.join(target, name) })

manifest = {
  'extracted_at' => '2026-11-17',
  'upstream_reference' => 'Project-Fukakai/simai_flutter@f15acddffc6a43d0c0f74beeb91fc282fcb9bf2c',
  'source_files' => paths.map { |name, path| { 'path' => path, 'sha256' => Digest::SHA256.hexdigest(inputs.fetch(name)) } },
  'adaptations' => [
    'Public Swift access control for reusable types and their existing members',
    'UIKit touch surface compiled only on UIKit platforms',
    'Caller-supplied answer audio with a synthesized default',
    'Generic missing-chart error message and explicit public initializers',
    'Playback settings extracted without app preferences or app-specific UI',
    'Local-file playback replaces source-specific fetching, with cancellation generations and a weak display-link proxy',
    'Explicit renderer and UIKit input initializers, and the existing preview sound scheduler',
    'Explicit CGFloat conversion for cross-toolchain renderer compatibility'
  ]
}
File.write(File.join(package_root, 'SOURCE_PROVENANCE.json'), JSON.pretty_generate(manifest) + "\n")
regression_dir = File.join(package_root, 'Regression')
FileUtils.mkdir_p(regression_dir)
regression = File.read(File.join(source_root, 'Tests/SimaiGameplayRegressionTests.swift'))
app_result_tests = section(regression, '        let result = AirMaiDXPlayResult(', '        let bus = GameplayEventBus()')
replace!(regression, app_result_tests, '')
regression.gsub!('Coyote hardware events', 'framework events')
replace!(regression, 'let reference = [CGPoint(x: -18.5 / 300',
         'let vertices: [CGPoint] = [CGPoint(x: -18.5 / 300')
replace!(regression, <<~SWIFT.strip, <<~SWIFT.strip)
  CGPoint(x: 1.5 / 300, y: 0)].map { point in
                                  CGPoint(x: sample.point.x + point.x * cos(sample.angle) - point.y * sin(sample.angle),
                                          y: sample.point.y + point.x * sin(sample.angle) + point.y * cos(sample.angle))
                              }
SWIFT
  CGPoint(x: 1.5 / 300, y: 0)]
                          let cosine = CoreGraphics.cos(sample.angle)
                          let sine = CoreGraphics.sin(sample.angle)
                          let reference = vertices.map { point -> CGPoint in
                              CGPoint(x: sample.point.x + point.x * cosine - point.y * sine,
                                      y: sample.point.y + point.x * sine + point.y * cosine)
                          }
SWIFT
regression.sub!('// Consumed by tools/test_simai_gameplay.rb against current production sources.',
                '// Native engine regressions. Compiled by Tools/test_native_regressions.rb.')
File.write(File.join(regression_dir, 'GameplayRegression.swift'), regression)
# AudioRegression.swift is maintained here with offline completion markers.
# Its waveform expectations are evaluated against the exported engine above.
puts "Exported #{source_files.length} native source files"
