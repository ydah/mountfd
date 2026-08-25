# frozen_string_literal: true

require "mountfd"

abort "Linux is required" unless Mountfd::Native.linux?

Mountfd::Namespace.reexec_user!
Mountfd::Namespace.unshare_mount!
namespace = nil
begin
  namespace = Mountfd::UserNamespace.create(helper: false)
  # ponytail: arbitrary nodev probes can block in get_tree; extend this list
  # only with filesystems proven to be source-free in an isolated VM.
  filesystems = %w[tmpfs ramfs hugetlbfs] & File.read("/proc/filesystems").split

  puts "| filesystem | idmap |"
  puts "|---|---|"
  filesystems.each do |filesystem|
    supported = false
    mount = nil
    begin
      Mountfd::FsContext.open(filesystem) do |context|
        context.create!
        mount = context.mount
        mount.idmap!(namespace)
        supported = true
      end
    rescue Mountfd::Error, SystemCallError
      # A source-free probe cannot configure every filesystem.
    ensure
      mount&.discard unless mount&.closed?
    end
    puts "| #{filesystem} | #{supported ? 'yes' : 'no/unavailable'} |"
  end
ensure
  namespace&.close
end
