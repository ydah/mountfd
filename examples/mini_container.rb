# frozen_string_literal: true

require "fileutils"
require "mountfd"
require "rbconfig"
require "tmpdir"

lower = File.expand_path(ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} ROOTFS [COMMAND ...]" })
command = ARGV.drop(1)
command = ["/bin/sh"] if command.empty?

Mountfd::Namespace.reexec_user!
directory = ENV["MOUNTFD_CONTAINER_ROOT"]
unless directory
  status = Dir.mktmpdir("mountfd-container") do |root|
    pid = Process.spawn({"MOUNTFD_CONTAINER_ROOT" => root}, RbConfig.ruby, $PROGRAM_NAME, *ARGV)
    Process.wait2(pid).last
  end
  exit(status.exitstatus || 128 + status.termsig)
end

Mountfd::Namespace.unshare_mount!
upper, work, root = %w[upper work root].map { |name| File.join(directory, name) }
FileUtils.mkdir_p([upper, work, root])
Mountfd.mount(
  "overlay", root,
  options: {lowerdir: lower, upperdir: upper, workdir: work},
  attrs: {nosuid: true, nodev: true}
)
Dir.chdir(root)
Mountfd.pivot_root(".", ".")
Mountfd.umount(".")
Dir.chdir("/")
exec(*command)
