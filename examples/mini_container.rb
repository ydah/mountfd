# frozen_string_literal: true

require "fileutils"
require "mountfd"
require "tmpdir"

lower = File.expand_path(ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} ROOTFS [COMMAND ...]" })
command = ARGV.drop(1)
command = ["/bin/sh"] if command.empty?

Mountfd::Namespace.unshare_user!
Mountfd::Namespace.unshare_mount!

Dir.mktmpdir("mountfd-container") do |directory|
  upper, work, root = %w[upper work root].map { |name| File.join(directory, name) }
  FileUtils.mkdir_p([upper, work, root])
  Mountfd.mount(
    "overlay", root,
    options: {lowerdir: lower, upperdir: upper, workdir: work},
    attrs: {nosuid: true, nodev: true}
  )
  FileUtils.mkdir_p(File.join(root, ".old_root"))
  Dir.chdir(root) do
    Mountfd.pivot_root(".", ".old_root")
    Dir.chdir("/")
    Mountfd.umount("/.old_root")
    Dir.rmdir("/.old_root")
    exec(*command)
  end
end
