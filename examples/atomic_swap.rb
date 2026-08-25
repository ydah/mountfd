# frozen_string_literal: true

require "mountfd"

target = File.expand_path(ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} TARGET" })
Mountfd.replace(target) do
  Mountfd::FsContext.open("tmpfs") do |context|
    context.set("size", "64M")
    context.create!
    context.mount(attrs: {nosuid: true, nodev: true})
  end
end
