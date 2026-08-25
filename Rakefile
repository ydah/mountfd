# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"
require "rspec/core/rake_task"

Rake::ExtensionTask.new("mountfd") do |extension|
  extension.lib_dir = "lib/mountfd"
end

RSpec::Core::RakeTask.new(:spec) do |task|
  task.pattern = "spec/mountfd_spec.rb"
end

RSpec::Core::RakeTask.new("spec:system") do |task|
  task.pattern = "spec/system/**/*_spec.rb"
end

namespace :test do
  task unit: :spec
  task system: :compile do
    ENV["MOUNTFD_SYSTEM"] = "1"
    Rake::Task["spec:system"].invoke
  end
end

namespace :research do
  desc "Probe idmapped-mount support for source-free filesystems"
  task idmap_support: :compile do
    ruby "-Ilib", "tools/research_idmap.rb"
  end
end

namespace :gen do
  desc "Dump mount constants from the installed Linux UAPI headers"
  task :constants do
    abort "Linux headers are required" unless RUBY_PLATFORM.include?("linux")

    FileUtils.mkdir_p("tmp")
    compiler = ENV.fetch("CC", "cc")
    sh compiler, "tools/dump_constants.c", "-o", "tmp/dump_constants"
    File.write("tmp/constants.txt", IO.popen(["tmp/dump_constants"], &:read))
  end
end

task spec: :compile
task default: "test:unit"
