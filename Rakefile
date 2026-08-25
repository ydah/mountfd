# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"
require "rspec/core/rake_task"
require "yard"

Rake::ExtensionTask.new("mountfd") do |extension|
  extension.lib_dir = "lib/mountfd"
end

RSpec::Core::RakeTask.new(:spec) do |task|
  task.pattern = "spec/mountfd_spec.rb"
end

RSpec::Core::RakeTask.new("spec:system") do |task|
  task.pattern = "spec/system/**/*_spec.rb"
end

RSpec::Core::RakeTask.new("spec:ext4") do |task|
  task.pattern = "spec/ext4/**/*_spec.rb"
end

YARD::Rake::YardocTask.new(:yard)

desc "Validate RBS signatures"
task :rbs do
  sh "rbs", "-I", "sig", "validate"
end

namespace :test do
  task unit: :spec
  task system: :compile do
    ENV["MOUNTFD_SYSTEM"] = "1"
    Rake::Task["spec:system"].invoke
  end
  task adversarial: :compile do
    ENV["MOUNTFD_SYSTEM"] = ENV["MOUNTFD_EXTENSIVE"] = "1"
    Rake::Task["spec:system"].invoke
  end
  task ext4: :compile do
    ENV["MOUNTFD_EXT4"] = "1"
    Rake::Task["spec:ext4"].invoke
  end
end

namespace :research do
  desc "Probe idmapped-mount support for source-free filesystems"
  task idmap_support: :compile do
    ruby "-Ilib", "tools/research_idmap.rb"
  end
end

namespace :benchmark do
  desc "Compare statmount with mountinfo parsing in a 1000-mount namespace"
  task mounts: :compile do
    ruby "-Ilib", "benchmark/mounts.rb"
  end
end

namespace :gen do
  desc "Generate mount constants from the installed Linux UAPI headers"
  task :constants do
    ruby "tools/generate_constants.rb"
  end
end

task spec: :compile
task default: "test:unit"
