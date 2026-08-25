# frozen_string_literal: true

require "fileutils"
require "mountfd"
require "tmpdir"

abort "Linux statmount support is required" unless Mountfd.features.include?(:statmount)

Mountfd::Namespace.reexec_user!
Mountfd::Namespace.unshare_mount!
count = Integer(ENV.fetch("MOUNTFD_BENCH_MOUNTS", "1000"))
iterations = Integer(ENV.fetch("MOUNTFD_BENCH_ITERATIONS", "10"))

measure = lambda do |label, &work|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  work.call
  puts format("%-20s %8.3f ms", label, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000)
end

Dir.mktmpdir do |directory|
  targets = count.times.map { File.join(directory, _1.to_s) }
  targets.each { Dir.mkdir(_1); Mountfd.mount("tmpfs", _1) }
  puts "#{Mountfd.mounts(backend: :statmount).length} visible mounts (#{count} created)"
  measure.call("statmount/listmount") { iterations.times { Mountfd.mounts(backend: :statmount) } }
  measure.call("parse mountinfo") do
    iterations.times { Mountfd::MountInfoParser.parse(File.read("/proc/self/mountinfo")) }
  end
ensure
  targets&.reverse_each do |target|
    Mountfd.umount(target)
  rescue Errno::EINVAL, Errno::ENOENT
    nil
  end
end
