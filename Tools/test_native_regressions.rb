#!/usr/bin/env ruby
require 'tmpdir'
require 'rbconfig'

root = File.expand_path('..', __dir__)
sdk = IO.popen(%w[xcrun --sdk macosx --show-sdk-path], &:read).strip
architecture = RbConfig::CONFIG.fetch('host_cpu')
target = "#{architecture}-apple-macos13.0"
sources = %w[SimaiChartModels.swift SimaiPlaybackSettings.swift GameplayEvent.swift
             GameplayEventBus.swift SimaiChartRenderer.swift Localization.swift]
combined = sources.map { |name| File.read(File.join(root, 'Sources/SimaiSwift', name)) }.join("\n")
Dir.mktmpdir('simai-swift-regression-') do |temporary|
  %w[GameplayRegression AudioRegression].each do |name|
    file = File.join(temporary, "#{name}.swift")
    File.write(file, combined + "\n" + File.read(File.join(root, 'Regression', "#{name}.swift")))
    binary = File.join(temporary, name)
    abort "Compilation failed for #{name}" unless system('xcrun', 'swiftc', '-sdk', sdk,
      '-target', target, '-swift-version', '5', '-O', '-parse-as-library', file, '-o', binary)
    abort "Regression failed for #{name}" unless system(binary)
  end
end
