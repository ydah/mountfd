# frozen_string_literal: true

module Mountfd
  module Attributes
    VALUES = {
      rdonly: Native::MOUNT_ATTR_RDONLY,
      nosuid: Native::MOUNT_ATTR_NOSUID,
      nodev: Native::MOUNT_ATTR_NODEV,
      noexec: Native::MOUNT_ATTR_NOEXEC,
      nodiratime: Native::MOUNT_ATTR_NODIRATIME,
      nosymfollow: Native::MOUNT_ATTR_NOSYMFOLLOW,
      idmap: Native::MOUNT_ATTR_IDMAP
    }.freeze
    ATIME = {
      relatime: Native::MOUNT_ATTR_RELATIME,
      noatime: Native::MOUNT_ATTR_NOATIME,
      strictatime: Native::MOUNT_ATTR_STRICTATIME
    }.freeze

    def self.build(attributes)
      set = clr = 0
      attributes.each do |name, value|
        if name.to_sym == :atime
          mode = value.to_sym
          raise ArgumentError, "unknown atime mode: #{value.inspect}" unless ATIME.key?(mode)

          clr |= Native::MOUNT_ATTR__ATIME
          set |= ATIME.fetch(mode)
          next
        end

        flag = VALUES.fetch(name.to_sym) { raise ArgumentError, "unknown mount attribute: #{name.inspect}" }
        value ? set |= flag : clr |= flag
      end
      [set, clr]
    end
  end
end
