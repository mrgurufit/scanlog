#!/usr/bin/env ruby
# Adds HealthKitBridge.swift to the App target's Compile Sources, and wires
# App.entitlements as the target's Code Signing Entitlements for every build
# configuration - the two things Xcode's own "+ Capability" button and
# drag-and-drop-file-add would otherwise do by hand. Safe to run more than
# once: it checks for an existing reference/build-file before adding either.
#
# Usage (from the ios-build/ directory on the Mac, after `git pull`):
#   gem install --user-install xcodeproj   # one-time, no sudo/admin needed
#   ruby add_healthkit.rb ../projects/scanlogapk/ios/App/App.xcodeproj
#
# Also copies HealthKitBridge.swift and App.entitlements into
# ios/App/App/ (next to Info.plist / AppDelegate.swift) if they are not
# already there, since Xcode expects the referenced file to physically
# exist relative to the project.

require 'xcodeproj'
require 'fileutils'

project_path = ARGV[0] or abort "usage: ruby add_healthkit.rb path/to/App.xcodeproj"
here = File.dirname(__FILE__)
app_dir = File.join(File.dirname(project_path), 'App')

swift_src  = File.join(here, 'HealthKitBridge.swift')
ent_src    = File.join(here, 'App.entitlements')
swift_dest = File.join(app_dir, 'HealthKitBridge.swift')
ent_dest   = File.join(app_dir, 'App.entitlements')

FileUtils.cp(swift_src, swift_dest) unless File.exist?(swift_dest) && FileUtils.compare_file(swift_src, swift_dest)
FileUtils.cp(ent_src, ent_dest) unless File.exist?(ent_dest) && FileUtils.compare_file(ent_src, ent_dest)
puts "copied HealthKitBridge.swift -> #{swift_dest}"
puts "copied App.entitlements -> #{ent_dest}"

project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'App' } or abort "no target named 'App' found"
app_group = project.main_group.find_subpath('App', true)

# --- add the Swift file to the target, if not already present ---
existing = app_group.files.find { |f| f.path == 'HealthKitBridge.swift' }
if existing
  puts "HealthKitBridge.swift already in project group"
  file_ref = existing
else
  file_ref = app_group.new_reference('HealthKitBridge.swift')
  puts "added file reference for HealthKitBridge.swift"
end

already_in_sources = target.source_build_phase.files.any? { |bf| bf.file_ref == file_ref }
if already_in_sources
  puts "HealthKitBridge.swift already in Compile Sources"
else
  target.source_build_phase.add_file_reference(file_ref)
  puts "added HealthKitBridge.swift to Compile Sources"
end

# --- entitlements file reference + build setting on every config ---
ent_ref = app_group.files.find { |f| f.path == 'App.entitlements' } || app_group.new_reference('App.entitlements')

target.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'App/App.entitlements'
end
puts "set CODE_SIGN_ENTITLEMENTS = App/App.entitlements on #{target.build_configurations.size} build configuration(s)"

project.save
puts "DONE: project saved. Build with:"
puts "  cd #{File.dirname(project_path)} && xcodebuild -project App.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build"
