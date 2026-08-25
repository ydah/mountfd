# frozen_string_literal: true

require "mountfd"

abort "Linux is required" unless Mountfd::Native.linux?

Mountfd::Namespace.unshare_mount!
namespace = nil
begin
  namespace = Mountfd::UserNamespace.create(helper: false)
  filesystems = File.readlines("/proc/filesystems", chomp: true).filter_map do |line|
    kind, name = line.split
    name if kind == "nodev"
  end

  puts "| filesystem | idmap |"
  puts "|---|---|"
  filesystems.each do |filesystem|
    supported = false
    begin
      Mountfd::FsContext.open(filesystem) do |context|
        context.create!
        mount = context.mount
        mount.idmap!(namespace)
        supported = true
        mount.discard
      end
    rescue Mountfd::Error, SystemCallError
      # A source-free probe cannot configure every filesystem.
    end
    puts "| #{filesystem} | #{supported ? 'yes' : 'no/unavailable'} |"
  end
ensure
  namespace&.close
end
