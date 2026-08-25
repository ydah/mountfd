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
      new(nil, handle: Native.fspick(AT_FDCWD, File.path(path), flags | Native::FSPICK_CLOEXEC))
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
    def set_path(key, path, dfd: AT_FDCWD) = configure(Native::FSCONFIG_SET_PATH, key, File.path(path), dfd)
    def set_fd(key, io) = configure(Native::FSCONFIG_SET_FD, key, nil, Mountfd.fileno(io))
    def set_binary(key, bytes)
      value = String(bytes)
      configure(Native::FSCONFIG_SET_BINARY, key, value, value.bytesize)
    end

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

    def set_attributes(set: [], clr: [], propagation: nil, idmap: nil, recursive: false)
      flags = Native::AT_EMPTY_PATH
      flags |= Native::AT_RECURSIVE if recursive
      Native.mount_setattr(
        @handle, "", flags, Attributes.flags(set), Attributes.flags(clr),
        Attributes.propagation(propagation), idmap && Mountfd.fileno(idmap)
      )
      self
    rescue SystemCallError => error
      exception = idmap ? IdmapError : MountError
      raise exception, "mount_setattr: #{error.message}", cause: error
    end

    def idmap!(userns) = set_attributes(set: [:idmap], idmap: userns)

    def attach(path, beneath: false)
      flags = Native::MOVE_MOUNT_F_EMPTY_PATH
      flags |= Native::MOVE_MOUNT_BENEATH if beneath
      Native.move_mount(@handle, "", AT_FDCWD, File.path(path), flags)
      close
      AttachedMount.new(File.path(path))
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

    def mounts(ns: nil, backend: nil)
      selected = backend || preferred_mounts_backend(ns)
      if selected == :statmount
        @mounts_backend = :statmount
        return Native.statmounts.map { mount_info_from_statmount(_1) }
      end

      raise ArgumentError, "backend must be :statmount or :mountinfo" unless selected == :mountinfo

      @mounts_backend = :mountinfo
      pid = ns.nil? ? "self" : Integer(ns)
      MountInfoParser.parse(File.read("/proc/#{pid}/mountinfo"))
    rescue SystemCallError, UnsupportedError
      raise if backend == :statmount

      @mounts_backend = :mountinfo
      MountInfoParser.parse(File.read("/proc/#{ns ? Integer(ns) : 'self'}/mountinfo"))
    end

    def mounts_backend = @mounts_backend || preferred_mounts_backend(nil)

    def mount_at(path, **options)
      target = File.expand_path(File.path(path))
      mounts(**options).find { File.expand_path(_1.mount_point) == target }
    end

    def open_tree(path, recursive: false)
      flags = Native::OPEN_TREE_CLONE | Native::OPEN_TREE_CLOEXEC
      flags |= Native::AT_RECURSIVE if recursive
      DetachedMount.new(Native.open_tree(AT_FDCWD, File.path(path), flags))
    end

    def mount(source, target, type: source, options: {}, attrs: {})
      detached = nil
      FsContext.open(type) do |context|
        context.set("source", source) unless source.to_s == type.to_s
        options.each { |key, value| context.set(key, value) }
        context.create!
        detached = context.mount(attrs: attrs)
        apply_attributes(detached, attrs)
        detached.attach(target)
      end
    rescue StandardError
      detached&.discard unless detached&.closed?
      raise
    end

    def bind(source, target, recursive: false, attrs: {}, idmap: nil)
      namespace = UserNamespace.create(**idmap) if idmap.is_a?(Hash)
      detached = open_tree(source, recursive: recursive)
      apply_attributes(detached, attrs, recursive: recursive)
      detached.idmap!(namespace || idmap) if idmap
      detached.attach(target)
    rescue StandardError
      detached&.discard unless detached&.closed?
      raise
    ensure
      namespace&.close unless namespace&.closed?
    end

    def umount(path, detach: true, force: false)
      flags = (detach ? 2 : 0) | (force ? 1 : 0)
      Native.umount2(File.path(path), flags)
    end

    def pivot_root(new_root, put_old) = Native.pivot_root(File.path(new_root), File.path(put_old))

    def set_attributes(path, attrs: {}, propagation: nil, recursive: false)
      set, clr = Attributes.build(attrs)
      flags = recursive ? Native::AT_RECURSIVE : 0
      Native.mount_setattr(
        AT_FDCWD, File.path(path), flags, set, clr, Attributes.propagation(propagation), nil
      )
      nil
    rescue SystemCallError => error
      raise MountError, "mount_setattr: #{error.message}", cause: error
    end

    def replace(path)
      detached = yield
      raise ArgumentError, "replace block must return a DetachedMount" unless detached.is_a?(DetachedMount)

      detached.attach(path, beneath: true)
      umount(path)
      AttachedMount.new(File.path(path))
    rescue StandardError
      detached&.discard unless detached&.closed?
      raise
    end

    def fileno(value) = value.respond_to?(:fileno) ? value.fileno : Integer(value)

    private

    def track(mount) = (@pending_mounts ||= []) << mount
    def untrack(mount) = @pending_mounts&.delete(mount)

    def apply_attributes(mount, attributes, recursive: false)
      set, clr = Attributes.build(attributes)
      mount.set_attributes(set: set, clr: clr, recursive: recursive) if (set | clr).positive?
      mount
    end

    def preferred_mounts_backend(namespace)
      namespace.nil? && Native.syscall_available?("statmount") &&
        Native.syscall_available?("listmount") ? :statmount : :mountinfo
    end

    def mount_info_from_statmount(value)
      options = value[:options]&.split(",") || []
      attrs = []
      attrs << :rdonly if (value[:attrs] & Native::MOUNT_ATTR_RDONLY).positive?
      attrs << :idmap if (value[:attrs] & Native::MOUNT_ATTR_IDMAP).positive?
      propagation = {}
      Attributes::PROPAGATION.each { |name, flag| propagation[name] = true if value[:propagation] == flag }
      propagation[:shared] = value[:peer_group] if value[:peer_group].positive?
      propagation[:master] = value[:master] if value[:master].positive?
      propagation[:propagate_from] = value[:propagate_from] if value[:propagate_from].positive?
      MountInfo.new(
        value[:mnt_id], value[:parent_id], value[:mnt_root], value[:mount_point],
        value[:fs_type], value[:source], options.freeze, propagation.freeze, attrs.freeze,
        value[:dev_major], value[:dev_minor]
      )
    end

    def kernel_at_least?(major, minor)
      current = Etc.uname[:release].scan(/\A(\d+)\.(\d+)/).flatten.map(&:to_i)
      Native.linux? && (current <=> [major, minor]) >= 0
    end
  end
end
