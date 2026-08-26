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
    PROPAGATION = {
      unbindable: Native::MS_UNBINDABLE,
      private: Native::MS_PRIVATE,
      slave: Native::MS_SLAVE,
      shared: Native::MS_SHARED
    }.freeze

    def self.build(attributes)
      set = clr = 0
      seen = {}
      attributes.each do |name, value|
        key = name.respond_to?(:to_sym) ? name.to_sym : name
        raise ArgumentError, "duplicate mount attribute: #{name.inspect}" if seen[key]

        seen[key] = true
        if key == :atime
          mode = value.respond_to?(:to_sym) ? value.to_sym : value
          raise ArgumentError, "unknown atime mode: #{value.inspect}" unless ATIME.key?(mode)

          clr |= Native::MOUNT_ATTR__ATIME
          set |= ATIME.fetch(mode)
          next
        end

        flag = VALUES.fetch(key) { raise ArgumentError, "unknown mount attribute: #{name.inspect}" }
        value ? set |= flag : clr |= flag
      end
      [set, clr]
    end

    def self.flags(names)
      return names if names.is_a?(Integer)

      Array(names).reduce(0) do |flags, name|
        key = name.respond_to?(:to_sym) ? name.to_sym : name
        flags | VALUES.fetch(key) { raise ArgumentError, "unknown mount attribute: #{name.inspect}" }
      end
    end

    def self.propagation(value)
      return 0 if value.nil?

      key = value.respond_to?(:to_sym) ? value.to_sym : value
      PROPAGATION.fetch(key) { raise ArgumentError, "unknown propagation: #{value.inspect}" }
    end
  end
end
