#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Compare selected declarations, never copy app files or print private source.
abort 'Usage: ruby Tools/check_airmai_preview_parity.rb AIRMAI_CHECKOUT' unless ARGV.length == 1

app_root = File.expand_path(ARGV.fetch(0))
package_root = File.expand_path('../Sources/SimaiSwift', __dir__)
read = ->(root, file) { File.read(File.join(root, file), encoding: 'UTF-8') }
app = read.call(app_root, 'MaimaiScoreTracker/Views/SimaiChartExperienceView.swift')
app_model = read.call(app_root, 'MaimaiScoreTracker/Services/Models/SimaiChartModels.swift')
controller = read.call(package_root, 'SimaiPlayerController.swift')
settings = read.call(package_root, 'SimaiPlaybackSettings.swift')
model = read.call(package_root, 'SimaiChartModels.swift')
timeline = read.call(package_root, 'SimaiPreviewTimeline.swift')
sound = read.call(package_root, 'SimaiPreviewHitSoundController.swift')

def normalize(source)
  source.lines.reject { |line| line.lstrip.start_with?('//') }.join.gsub(/\s+|;/, '')
end

def declaration(source, signature)
  lines = source.lines
  index = lines.index { |line| line.include?(signature) }
  return unless index

  indent = lines[index][/\A */]
  return lines[index].split(signature, 2).last if !lines[index].include?('{') && !lines[index].rstrip.end_with?('(')

  head = lines[index].split(signature, 2).last
  return head if head.rstrip.end_with?('}')

  tail = lines[(index + 1)..].take_while { |line| line != "#{indent}}\n" }
  head + tail.join
end

pairs = [
  [app, controller, %w[
    play() pause() seek(to scrub(to finishScrubbing(at configurePlayer( updatePlaybackTime(_
    playbackTimeMapping() updateAudioPresentationLatency(using rawPlaybackTime(atSystemUptime
    audioPlayerDidFinishPlaying(_
  ].map { |signature| "func #{signature}" }],
  [app, controller, ['let audioPlayerPipelineLatency:', 'let scheduledStartLeadTime:', 'var hitSoundClockTime:']],
  [app, controller, ['struct SimaiPlaybackTimeMapping {']],
  [app, settings, ['var audioTimingOffset =', 'var visualTimingOffset =']],
  [app_model, model, ['func parse(maidata:']],
  [app, timeline, ['var simultaneousEvents:', 'var selectedEvent:', 'var selectedSourceText:',
                   'var selectedEventDescription:', 'func drawTimeline(', 'func time(at x:',
                   'func timeMarkerInterval(', 'enum SimaiTimelineCategory:']],
  [app, sound, ['func update(', 'func firstEventIndex(after time:']]
]

mismatches = []
pairs.each do |reference, exported, signatures|
  signatures.each do |signature|
    left = declaration(reference, signature)
    right = declaration(exported, signature)
    if left && right
      left, right = [left, right].map { |body| normalize(body) }
      if signature == 'func configurePlayer('
        # The package uses a weak target proxy; both callbacks call updatePlaybackTime.
        right = right.sub('CADisplayLink(target:SimaiDisplayLinkProxy(owner:self),selector:#selector(SimaiDisplayLinkProxy.tick(_:)))',
                          'CADisplayLink(target:self,selector:#selector(updatePlaybackTime(_:)))')
      end
    end
    mismatches << signature unless left && right && left == right
  end
end

unless mismatches.empty?
  warn "Preview source parity check failed: #{mismatches.join(', ')}"
  warn 'Review the differences and reconcile timing changes before publishing.'
  exit 1
end

puts "Preview source parity passed (#{pairs.sum { |_, _, signatures| signatures.count }} declarations)."
