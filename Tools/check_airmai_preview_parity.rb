#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Compare selected declarations, never copy app files or print private source.
abort 'Usage: ruby Tools/check_airmai_preview_parity.rb AIRMAI_CHECKOUT' unless ARGV.length == 1

app_root = File.expand_path(ARGV.fetch(0))
package_root = File.expand_path('../Sources/SimaiSwift', __dir__)
read = ->(root, file) { File.read(File.join(root, file), encoding: 'UTF-8') }
app = read.call(app_root, 'MaimaiScoreTracker/Views/SimaiChartExperienceView.swift')
app_model = read.call(app_root, 'MaimaiScoreTracker/Services/Models/SimaiChartModels.swift')
app_renderer = read.call(app_root, 'MaimaiScoreTracker/Views/SimaiChartRenderer.swift')
controller = read.call(package_root, 'SimaiPlayerController.swift')
settings = read.call(package_root, 'SimaiPlaybackSettings.swift')
model = read.call(package_root, 'SimaiChartModels.swift')
renderer = read.call(package_root, 'SimaiChartRenderer.swift')
timeline = read.call(package_root, 'SimaiPreviewTimeline.swift')
sound = read.call(package_root, 'SimaiPreviewHitSoundController.swift')

def normalize(source)
  source.lines.reject { |line| line.lstrip.start_with?('//') }.join.gsub(/,\s*(?=[\]\)])/, '').gsub(/\s+|;/, '')
end

def declaration(source, signature)
  lines = source.lines
  index = lines.index { |line| line.include?(signature) }
  return unless index

  indent = lines[index][/\A */]
  head = lines[index].split(signature, 2).fetch(1)
  return head if !lines[index].include?('{') && !signature.start_with?('func ')
  return head if lines[index].rstrip.end_with?('}')
  # Signatures can wrap in different places in Airmai and the package.
  tail = lines[(index + 1)..].take_while { |line| line.rstrip != "#{indent}}" }
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
  [app_model, model, ['let slideOperatorCharacters =', 'func parse(maidata:'] + %w[
    parseEvents parseComponent parseSlideChain bracketContent splitBeat compactNoteComponents
  ].map { |name| "func #{name}(" }],
  [app_renderer, renderer, ['struct SimaiSlideInteractionGroup {'] + %w[
    processSlides resolveExpiredSlides trackSlideFinger makeSlideGroups segmentGroups groupsWithPathProgress
  ].map { |name| "func #{name}(" }],
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
  warn "Simai source parity check failed: #{mismatches.join(', ')}"
  warn 'Review the differences before publishing.'
  exit 1
end

puts "Simai source parity passed (#{pairs.sum { |_, _, signatures| signatures.count }} declarations)."
