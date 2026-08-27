#!/usr/bin/env ruby
# Removes stale Patrol *Swift Package Manager* wiring from Runner.xcodeproj.
# Idempotent. Run from ios/ (or pass the project path).
#   ruby ios_spm_cleanup.rb [Runner.xcodeproj]
#
# Why: the bootstrap disables SPM (Patrol's iOS setup is CocoaPods-based), so
# Flutter stops generating ios/Flutter/ephemeral/Packages/.packages/patrol-<v>/.
# A project that previously wired Patrol as a local Swift package still points
# at that path and xcodebuild then fails before building anything:
#   xcodebuild: error: Could not resolve package dependencies:
#     the package at '.../patrol-4.8.0' cannot be accessed
# Removes the XCLocalSwiftPackageReference, the matching
# XCSwiftPackageProductDependency and its Frameworks build-phase entry.
require 'xcodeproj'

project_path = ARGV[0] || 'Runner.xcodeproj'
unless File.exist?(project_path)
  puts 'xcodeproj: skipped (nothing to clean)'
  exit 0
end

PATROL_PATH = 'patrol-'.freeze

project = Xcodeproj::Project.open(project_path)
removed = []

# 1. Local package references whose relativePath points at a patrol package.
stale_refs = project.root_object.package_references.select do |ref|
  ref.isa == 'XCLocalSwiftPackageReference' &&
    ref.respond_to?(:relative_path) &&
    ref.relative_path.to_s.include?(PATROL_PATH)
end

# 2. Product dependencies on those references. A local package dependency can
#    carry no `package` back-reference, so also match the product name.
stale_deps = []
project.targets.each do |target|
  next unless target.respond_to?(:package_product_dependencies)
  target.package_product_dependencies.to_a.each do |dep|
    matches = stale_refs.include?(dep.package) ||
              (dep.package.nil? && dep.product_name.to_s.downcase.start_with?('patrol'))
    next unless matches
    stale_deps << dep
    # 3. Its Frameworks build-phase entry (a build file with no file_ref).
    target.build_phases.each do |phase|
      next unless phase.respond_to?(:files)
      phase.files.to_a.each do |bf|
        next unless bf.respond_to?(:product_ref) && bf.product_ref == dep
        phase.remove_build_file(bf)
        removed << "#{target.name}: Frameworks entry for #{dep.product_name}"
      end
    end
    target.package_product_dependencies.delete(dep)
    removed << "#{target.name}: package product dependency #{dep.product_name}"
  end
end

stale_deps.each { |dep| dep.remove_from_project }
stale_refs.each do |ref|
  project.root_object.package_references.delete(ref)
  removed << "local package reference #{ref.relative_path}"
  ref.remove_from_project
end

if removed.empty?
  puts 'xcodeproj: skipped (nothing to clean)'
else
  project.save
  removed.each { |r| puts "xcodeproj: removed stale patrol SPM #{r}" }
end
