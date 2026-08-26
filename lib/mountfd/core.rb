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
        new(level || :info, level && !separator.empty? ? text : line) unless line.empty?
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
      if exclusive && !Mountfd.features.include?(:create_excl)
        raise UnsupportedError, "exclusive fsconfig creation requires Linux 6.6 or newer"
      end

      command = exclusive ? Native::FSCONFIG_CMD_CREATE_EXCL : Native::FSCONFIG_CMD_CREATE
      configure(command, nil, nil, 0)
    end

    def reconfigure! = configure(Native::FSCONFIG_CMD_RECONFIGURE, nil, nil, 0)

    def mount(attrs: {})
      attr_set, attr_clr = Attributes.build(attrs)
      raise ArgumentError, "idmap must be applied to a detached mount with a user namespace" if
        ((attr_set | attr_clr) & Native::MOUNT_ATTR_IDMAP).positive?

      handle = with_diagnostics("fsmount", MountError) do
        Native.fsmount(@handle, Native::FSMOUNT_CLOEXEC, attr_set)
      end
      DetachedMount.new(handle)
    end

    def close = @handle.close

    private

    def configure(command, key, value, aux)
      with_diagnostics("fsconfig") { Native.fsconfig(@handle, command, key&.to_s, value, aux) }
      self
    end

    def with_diagnostics(operation, error_class = ConfigError)
      result = yield
      drain_diagnostics
      result
    rescue SystemCallError => error
      begin
        drain_diagnostics
      rescue SystemCallError
        nil
      end
      raise error_class.new("#{operation}: #{error.message}", diagnostics), cause: error
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
      set_flags = Attributes.flags(set)
      clear_flags = Attributes.flags(clr)
      has_idmap = (set_flags & Native::MOUNT_ATTR_IDMAP).positive?
      raise ArgumentError, "an idmapped mount cannot be cleared" if
        (clear_flags & Native::MOUNT_ATTR_IDMAP).positive?
      raise ArgumentError, "MOUNT_ATTR_IDMAP and a user namespace must be provided together" if
        has_idmap == idmap.nil?

      Native.mount_setattr(
        @handle, "", flags, set_flags, clear_flags,
        Attributes.propagation(propagation), idmap && Mountfd.fileno(idmap)
      )
      self
    rescue SystemCallError => error
      exception = idmap ? IdmapError : MountError
      raise exception, "mount_setattr: #{error.message}", cause: error
    end

    def idmap!(userns) = set_attributes(set: [:idmap], idmap: userns)

    def attach(path, beneath: false)
      target = File.path(path)
      flags = Native::MOVE_MOUNT_F_EMPTY_PATH
      flags |= Native::MOVE_MOUNT_BENEATH if beneath
      begin
        Native.move_mount(@handle, "", AT_FDCWD, target, flags)
      rescue SystemCallError => error
        raise MountError, "move_mount: #{error.message}", cause: error
      end
      close
      AttachedMount.new(target)
    end

    def close
      @handle.close
      nil
    ensure
      Mountfd.__send__(:untrack, self) if @handle.closed?
    end
  end

  AttachedMount = Data.define(:path)

  class << self
    def supported? = Native.syscall_available?("fsopen")

    def features
      return [] unless supported?

      values = [:new_mount_api]
      values.concat([:mount_setattr, :idmap]) if Native.syscall_available?("mount_setattr")
      values << :statmount if %w[statmount listmount].all? { Native.syscall_available?(_1) }
      values << :move_mount_beneath if kernel_at_least?(6, 5)
      values << :create_excl if kernel_at_least?(6, 6)
      values
    end

    def pending_mounts = (@pending_mounts || []).reject(&:closed?).dup

    def mounts(ns: nil, backend: nil)
      selected = backend || preferred_mounts_backend(ns)
      if selected == :statmount
        @mounts_backend = :statmount
        values = if ns.nil?
                   Native.statmounts(nil)
                 elsif ns.respond_to?(:fileno)
                   Native.statmounts(fileno(ns))
                 else
                   File.open("/proc/#{Integer(ns)}/ns/mnt") { Native.statmounts(_1.fileno) }
                 end
        return values.map { mount_info_from_statmount(_1) }
      end

      raise ArgumentError, "backend must be :statmount or :mountinfo" unless selected == :mountinfo
      if ns&.respond_to?(:fileno)
        raise UnsupportedError, "mount namespace descriptors require statmount on Linux 6.11 or newer"
      end

      @mounts_backend = :mountinfo
      pid = ns.nil? ? "self" : Integer(ns)
      read_mountinfo(pid)
    rescue SystemCallError, UnsupportedError
      raise if backend == :statmount || ns&.respond_to?(:fileno)

      @mounts_backend = :mountinfo
      read_mountinfo(ns ? Integer(ns) : "self")
    end

    def mounts_backend = @mounts_backend || preferred_mounts_backend(nil)

    def mount_at(path, **options)
      target = File.expand_path(File.path(path))
      mounts(**options).find { File.expand_path(_1.mount_point) == target }
    end

    def open_tree(path, recursive: false)
      flags = Native::OPEN_TREE_CLONE | Native::OPEN_TREE_CLOEXEC
      flags |= Native::AT_RECURSIVE if recursive
      mount = DetachedMount.new(Native.open_tree(AT_FDCWD, File.path(path), flags))
      return mount unless block_given?

      begin
        yield mount
      ensure
        mount.discard unless mount.closed?
      end
    end

    def mount(source, target, type: source, options: {}, attrs: {})
      detached = nil
      FsContext.open(type) do |context|
        context.set("source", source) unless source.to_s == type.to_s
        options.each { |key, value| context.set(key, value) }
        context.create!
        detached = context.mount(attrs: attrs)
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
      target = File.path(path)
      detached = yield
      raise ArgumentError, "replace block must return a DetachedMount" unless detached.is_a?(DetachedMount)

      detached.attach(target, beneath: true)
      umount(target)
      AttachedMount.new(target)
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
      (namespace.nil? || kernel_at_least?(6, 11)) && Native.syscall_available?("statmount") &&
        Native.syscall_available?("listmount") ? :statmount : :mountinfo
    end

    def read_mountinfo(pid)
      mounts = MountInfoParser.parse(File.read("/proc/#{pid}/mountinfo"))
      mounts.reverse.uniq(&:mount_point).reverse
    end

    def mount_info_from_statmount(value)
      options = value[:options]&.split(",") || []
      attrs = Attributes::VALUES.filter_map do |name, flag|
        name if (value[:attrs] & flag).positive?
      end
      Attributes::ATIME.each do |name, flag|
        attrs << name if flag.positive? && (value[:attrs] & flag).positive?
      end
      propagation = {}
      Attributes::PROPAGATION.each do |name, flag|
        propagation[name] = true if (value[:propagation] & flag).positive?
      end
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
