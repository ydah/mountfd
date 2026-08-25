# frozen_string_literal: true

require_relative "mountfd/version"

module Mountfd
  class Error < StandardError; end
  class UnsupportedError < Error; end

  class ConfigError < Error
    attr_reader :diagnostics

    def initialize(message, diagnostics = [])
      @diagnostics = diagnostics
      super([message, *diagnostics.map(&:to_s)].join("\n"))
    end
  end

  class MountError < ConfigError; end
  class IdmapError < Error; end
end

begin
  require "mountfd/mountfd"
rescue LoadError
  require_relative "../ext/mountfd/mountfd"
end

require_relative "mountfd/attributes"
require_relative "mountfd/user_namespace"
require_relative "mountfd/mount_info"
require_relative "mountfd/namespace"
require_relative "mountfd/core"
