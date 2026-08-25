# frozen_string_literal: true

require "etc"

module Mountfd
  AT_FDCWD = -100

  Diagnostic = Data.define(:level, :text) do
    PREFIXES = {"e" => :error, "w" => :warning, "i" => :info}.freeze

    def self.parse(raw)
      raw.lines(chomp: true).filter_map do |line|
        prefix, separator, text = line.partition(" ")
        level = PREFIXES[prefix]
        new(level || :info, separator.empty? ? line : text) unless line.empty?
      end
    end

    def to_s = "#{level}: #{text}"
  end

  class FsContext
    attr_reader :diagnostics

    def self.open(filesystem, flags: 0)
      context = new(filesystem, flags: flags)
      return context unless block_given?

      begin
        yield context
      ensure
        context.close unless context.closed?
      end
    end

    def self.pick(path, flags: 0)
      new(nil, handle: Native.fspick(AT_FDCWD, path.to_path, flags | Native::FSPICK_CLOEXEC))
    end

    def initialize(filesystem, flags: 0, handle: nil)
      @handle = handle || Native.fsopen(filesystem.to_s, flags | Native::FSOPEN_CLOEXEC)
      @diagnostics = []
    end

    def fileno = @handle.fileno
    def closed? = @handle.closed?
    def warnings = diagnostics.select { _1.level == :warning }

    def set(key, value = nil)
      return set_flag(key) if value.nil? || value == true

      configure(Native::FSCONFIG_SET_STRING, key, value.to_s, 0)
    end

    def set_flag(key) = configure(Native::FSCONFIG_SET_FLAG, key, nil, 0)
    def set_path(key, path, dfd: AT_FDCWD) = configure(Native::FSCONFIG_SET_PATH, key, path.to_path, dfd)
    def set_fd(key, io) = configure(Native::FSCONFIG_SET_FD, key, nil, Mountfd.fileno(io))
    def set_binary(key, bytes) = configure(Native::FSCONFIG_SET_BINARY, key, String(bytes), bytes.bytesize)

    def create!(exclusive: false)
      command = exclusive ? Native::FSCONFIG_CMD_CREATE_EXCL : Native::FSCONFIG_CMD_CREATE
      configure(command, nil, nil, 0)
    end

    def reconfigure! = configure(Native::FSCONFIG_CMD_RECONFIGURE, nil, nil, 0)

    def mount(attrs: {})
      attr_set, = Attributes.build(attrs)
      handle = with_diagnostics("fsmount") { Native.fsmount(@handle, Native::FSMOUNT_CLOEXEC, attr_set) }
      DetachedMount.new(handle)
    end

    def close = @handle.close

    private

    def configure(command, key, value, aux)
      with_diagnostics("fsconfig") { Native.fsconfig(@handle, command, key&.to_s, value, aux) }
      self
    end

    def with_diagnostics(operation)
      result = yield
      drain_diagnostics
      result
    rescue SystemCallError => error
      drain_diagnostics
      raise ConfigError.new("#{operation}: #{error.message}", diagnostics), cause: error
    end

    def drain_diagnostics
      @diagnostics.concat(Diagnostic.parse(Native.read_diagnostics(@handle)))
    end
  end

  class DetachedMount
    def initialize(handle)
      @handle = handle
      Mountfd.__send__(:track, self)
    end

    def fileno = @handle.fileno
    def closed? = @handle.closed?
    def discard = close

    def attach(path, beneath: false)
      flags = Native::MOVE_MOUNT_F_EMPTY_PATH
      flags |= Native::MOVE_MOUNT_BENEATH if beneath
      Native.move_mount(@handle, "", AT_FDCWD, path.to_path, flags)
      close
      AttachedMount.new(path.to_path)
    rescue SystemCallError => error
      raise MountError, "move_mount: #{error.message}", cause: error
    end

    def close
      @handle.close
      Mountfd.__send__(:untrack, self)
      nil
    end
  end

  AttachedMount = Data.define(:path)

  class << self
    def supported? = Native.syscall_available?("fsopen")

    def features
      return [] unless supported?

      values = [:new_mount_api]
      values.concat([:mount_setattr, :idmap]) if Native.syscall_available?("mount_setattr")
      values << :statmount if Native.syscall_available?("statmount")
      values << :move_mount_beneath if kernel_at_least?(6, 5)
      values << :create_excl if kernel_at_least?(6, 6)
      values
    end

    def pending_mounts = (@pending_mounts || []).reject(&:closed?).dup

    def open_tree(path, recursive: false)
      flags = Native::OPEN_TREE_CLONE | Native::OPEN_TREE_CLOEXEC
      flags |= Native::AT_RECURSIVE if recursive
      DetachedMount.new(Native.open_tree(AT_FDCWD, path.to_path, flags))
    end

    def umount(path, detach: true, force: false)
      flags = (detach ? 2 : 0) | (force ? 1 : 0)
      Native.umount2(path.to_path, flags)
    end

    def fileno(value) = value.respond_to?(:fileno) ? value.fileno : Integer(value)

    private

    def track(mount) = (@pending_mounts ||= []) << mount
    def untrack(mount) = @pending_mounts&.delete(mount)

    def kernel_at_least?(major, minor)
      current = Etc.uname[:release].scan(/\A(\d+)\.(\d+)/).flatten.map(&:to_i)
      Native.linux? && (current <=> [major, minor]) >= 0
    end
  end
end
