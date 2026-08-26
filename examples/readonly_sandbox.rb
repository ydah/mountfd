# frozen_string_literal: true

require "mountfd"
require "rbconfig"
require "tmpdir"
require "landlock" if ENV["MOUNTFD_LANDLOCK"] == "1"

rootfs = File.expand_path(ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} ROOTFS [COMMAND ...]" })
command = ARGV.drop(1)
command = ["/bin/sh"] if command.empty?
abort "#{rootfs}/tmp must exist" unless File.directory?(File.join(rootfs, "tmp"))

Mountfd::Namespace.reexec_user!
root = ENV["MOUNTFD_SANDBOX_ROOT"]
unless root
  status = Dir.mktmpdir("mountfd-sandbox") do |directory|
    pid = Process.spawn({"MOUNTFD_SANDBOX_ROOT" => directory}, RbConfig.ruby, $PROGRAM_NAME, *ARGV)
    Process.wait2(pid).last
  end
  exit(status.exitstatus || 128 + status.termsig)
end

Mountfd::Namespace.unshare_mount!
Mountfd.bind(rootfs, root, recursive: true, attrs: {rdonly: true})
Mountfd.mount("tmpfs", File.join(root, "tmp"), attrs: {nosuid: true, nodev: true})
Dir.chdir(root)
Mountfd.pivot_root(".", ".")
Mountfd.umount(".")
Dir.chdir("/")
if ENV["MOUNTFD_LANDLOCK"] == "1"
  Landlock.restrict!(read: ["/"], write: ["/tmp", "/dev/null"], execute: ["/"], allow_all_known: true)
end
exec(*command)
