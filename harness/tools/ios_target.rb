#!/usr/bin/env ruby
# Adds the Patrol RunnerUITests target to Runner.xcodeproj and registers it
# in the shared Runner scheme's test action. Idempotent. Run from ios/.
#   ruby ios_target.rb <bundle_id>      (the app's PRODUCT_BUNDLE_IDENTIFIER)
require 'xcodeproj'

bundle_id = ARGV[0] or abort 'usage: ios_target.rb <app bundle id>'

project_path = 'Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'RunnerUITests' }
if target
  puts 'xcodeproj: RunnerUITests target already exists'
else
  runner = project.targets.find { |t| t.name == 'Runner' }
  raise 'Runner target not found' unless runner

  deployment = runner.build_configurations.first
                     .resolve_build_setting('IPHONEOS_DEPLOYMENT_TARGET') || '13.0'
  target = project.new_target(:ui_test_bundle, 'RunnerUITests', :ios, deployment)
  target.add_dependency(runner)

  group = project.main_group.find_subpath('RunnerUITests', true)
  group.set_source_tree('<group>')
  group.set_path('RunnerUITests')
  file_ref = group.new_reference('RunnerUITests.m')
  target.add_file_references([file_ref])

  puts 'xcodeproj: RunnerUITests target created'
end

# Enforce build settings even on an existing target so re-runs repair a
# partially configured project.
changed = false
target.build_configurations.each do |config|
  {
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'TEST_TARGET_NAME' => 'Runner',
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{bundle_id}.RunnerUITests",
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'CURRENT_PROJECT_VERSION' => '1',
    'MARKETING_VERSION' => '1.0',
  }.each do |k, v|
    next if config.build_settings[k] == v
    config.build_settings[k] = v
    changed = true
  end
end
if changed
  project.save
  puts 'xcodeproj: RunnerUITests build settings updated'
end

scheme_dir = Xcodeproj::XCScheme.shared_data_dir(project_path)
scheme_path = File.join(scheme_dir, 'Runner.xcscheme')
raise "shared scheme not found at #{scheme_path}" unless File.exist?(scheme_path)
scheme = Xcodeproj::XCScheme.new(scheme_path)
already = scheme.test_action.testables.any? do |t|
  t.buildable_references.any? { |r| r.target_name == 'RunnerUITests' }
end
if already
  puts 'scheme: RunnerUITests already in test action'
else
  project = Xcodeproj::Project.open(project_path)
  ui_target = project.targets.find { |t| t.name == 'RunnerUITests' }
  testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(ui_target)
  scheme.test_action.add_testable(testable)
  scheme.save!
  puts 'scheme: RunnerUITests added to test action'
end
