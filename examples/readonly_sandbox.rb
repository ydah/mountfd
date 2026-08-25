# frozen_string_literal: true

require "mountfd"
require "tmpdir"
require "landlock" if ENV["MOUNTFD_LANDLOCK"] == "1"

rootfs = File.expand_path(ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} ROOTFS [COMMAND ...]" })
command = ARGV.drop(1)
command = ["/bin/sh"] if command.empty?
abort "#{rootfs}/tmp must exist" unless File.directory?(File.join(rootfs, "tmp"))

Mountfd::Namespace.reexec_user!
Mountfd::Namespace.unshare_mount!
Dir.mktmpdir("mountfd-sandbox") do |root|
  Mountfd.bind(rootfs, root, recursive: true)
  tmp = File.join(root, "tmp")
  Mountfd.set_attributes(root, attrs: {rdonly: true}, recursive: true)
  Mountfd.mount("tmpfs", tmp, attrs: {nosuid: true, nodev: true})
  Dir.chdir(root)
  Mountfd.pivot_root(".", ".")
  Mountfd.umount(".")
  Dir.chdir("/")
  if ENV["MOUNTFD_LANDLOCK"] == "1"
    Landlock.restrict!(read: ["/"], write: ["/tmp", "/dev/null"], execute: ["/"], allow_all_known: true)
  end
  exec(*command)
end
