# frozen_string_literal: true

require "fileutils"
require "mountfd"

source, target, outside = ARGV
abort "usage: #{$PROGRAM_NAME} SOURCE TARGET OUTSIDE_UID" unless outside
FileUtils.mkdir_p(target)

Mountfd.bind(
  File.expand_path(source), File.expand_path(target), recursive: true,
  idmap: {
    uid: {0 => [Integer(outside), 65_536]},
    gid: {0 => [Integer(outside), 65_536]}
  }
)
