# frozen_string_literal: true

require "fileutils"
require "mountfd"
require "tmpdir"

rootfs = File.expand_path(ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} ROOTFS [COMMAND ...]" })
command = ARGV.drop(1)
command = ["/bin/sh"] if command.empty?

Mountfd::Namespace.unshare_user!
Mountfd::Namespace.unshare_mount!
Dir.mktmpdir("mountfd-sandbox") do |root|
  Mountfd.bind(rootfs, root, recursive: true)
  FileUtils.mkdir_p(File.join(root, ".old_root"))
  Mountfd.set_attributes(root, attrs: {rdonly: true, nosuid: true, nodev: true}, recursive: true)
  Dir.chdir(root) do
    Mountfd.pivot_root(".", ".old_root")
    Dir.chdir("/")
    Mountfd.umount("/.old_root")
    exec(*command)
  end
end
