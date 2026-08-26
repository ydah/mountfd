# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe "Mountfd system", :system do
  def mountinfo(path) = Mountfd.mount_at(path, backend: :mountinfo)

  def require_mount_setattr
    skip "mount_setattr is unavailable" unless Mountfd.features.include?(:mount_setattr)
  end

  def kernel_at_least?(major, minor)
    (Etc.uname[:release].scan(/\A(\d+)\.(\d+)/).flatten.map(&:to_i) <=> [major, minor]) >= 0
  end

  def unmount(*paths)
    paths.compact.each { Mountfd.umount(_1) if File.exist?(_1) && mountinfo(_1) }
  end

  before(:context) do
    skip "set MOUNTFD_SYSTEM=1 to run mount tests" unless ENV["MOUNTFD_SYSTEM"]
    skip "Linux is required" unless Mountfd::Native.linux?

    Mountfd::Namespace.unshare_user! unless ENV["MOUNTFD_IN_USERNS"]
    Mountfd::Namespace.unshare_mount!
  end

  around do |example|
    unless ENV["MOUNTFD_SYSTEM"] && Mountfd::Native.linux?
      example.run
      next
    end

    before = Mountfd.mounts(backend: :mountinfo).map { [_1.mnt_id, _1.mount_point] }
    example.run
  ensure
    if before
      after = Mountfd.mounts(backend: :mountinfo).map { [_1.mnt_id, _1.mount_point] }
      expect(after).to eq(before), "mount leaked from #{example.full_description}"
    end
  end

  it "mounts, writes to, and unmounts tmpfs" do
    Dir.mktmpdir do |target|
      Mountfd.mount("tmpfs", target, options: {size: "1M"}, attrs: {nosuid: true, nodev: true})
      File.write(File.join(target, "file"), "ok")
      expect(File.read(File.join(target, "file"))).to eq("ok")
    ensure
      unmount(target)
    end
  end

  it "includes kernel diagnostics in configuration errors" do
    context = Mountfd::FsContext.new("tmpfs")
    expect { context.set("sizee", "1M") }
      .to raise_error(Mountfd::ConfigError) { |error| expect(error.diagnostics).not_to be_empty }
  ensure
    context&.close
  end

  it "creates a filesystem context exclusively when supported" do
    Mountfd::FsContext.open("tmpfs") do |context|
      unless Mountfd.features.include?(:create_excl)
        expect { context.create!(exclusive: true) }.to raise_error(Mountfd::UnsupportedError)
        next
      end

      context.create!(exclusive: true)
      context.mount.discard
    end
  end

  it "picks and reconfigures an existing mount" do
    Dir.mktmpdir do |target|
      Mountfd.mount("tmpfs", target, options: {size: "1M"})
      context = Mountfd::FsContext.pick(target)
      context.set("size", "2M")
      context.reconfigure!
      expect(mountinfo(target).options).to include("size=2048k")
    ensure
      context&.close unless context&.closed?
      unmount(target)
    end
  end

  it "creates a read-only detached bind mount" do
    require_mount_setattr

    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      target = File.join(directory, "target")
      FileUtils.mkdir_p([source, target])
      Mountfd.mount("tmpfs", source)
      File.write(File.join(source, "file"), "ok")
      Mountfd.bind(source, target, attrs: {rdonly: true})
      expect { File.write(File.join(target, "new"), "no") }.to raise_error(Errno::EROFS)
    ensure
      unmount(target, source)
    end
  end

  it "does not leak file descriptors under explicit close or GC" do
    skip "fd stress is covered by the adversarial suite" if ENV["MOUNTFD_MATRIX"]

    GC.start
    baseline = Dir.children("/proc/self/fd").length
    (ENV["MOUNTFD_EXTENSIVE"] ? 1_000 : 50).times { Mountfd::FsContext.new("tmpfs").close }
    expect(Dir.children("/proc/self/fd").length).to eq(baseline)

    previous = GC.stress
    GC.stress = true
    (ENV["MOUNTFD_EXTENSIVE"] ? 50 : 5).times { Mountfd::FsContext.new("tmpfs") }
    GC.start
    expect(Dir.children("/proc/self/fd").length).to eq(baseline)
  ensure
    GC.stress = previous unless previous.nil?
  end

  it "does not reuse a descriptor after close reports an error" do
    context = Mountfd::FsContext.new("tmpfs")
    IO.new(context.fileno).close

    expect { context.close }.to raise_error(Errno::EBADF)
    expect(context).to be_closed
  ensure
    context&.close unless context&.closed?
  end

  it "keeps coerced syscall arguments alive through GC compaction" do
    skip "GC compaction is unavailable" unless GC.respond_to?(:compact)

    string = Class.new do
      def initialize(value) = @value = value
      def to_str
        GC.compact
        @value.dup
      end
    end
    integer = Class.new do
      def initialize(value) = @value = value
      def to_int
        GC.compact
        @value
      end
    end

    20.times do
      handle = Mountfd::Native.fsopen(string.new("tmpfs"), integer.new(Mountfd::Native::FSOPEN_CLOEXEC))
      Mountfd::Native.fsconfig(
        handle, integer.new(Mountfd::Native::FSCONFIG_SET_STRING),
        string.new("size"), string.new("1M"), integer.new(0)
      )
    ensure
      handle&.close unless handle&.closed?
    end
  end

  it "rejects unsafe native string lengths and embedded NUL bytes" do
    context = Mountfd::FsContext.new("tmpfs")
    expect do
      Mountfd::Native.fsconfig(
        context.fileno, Mountfd::Native::FSCONFIG_SET_BINARY, "blob", "x", 2
      )
    end.to raise_error(ArgumentError, /length/)
    expect do
      Mountfd::Native.fsconfig(
        context.fileno, Mountfd::Native::FSCONFIG_SET_BINARY, "blob", "x", -1
      )
    end.to raise_error(ArgumentError, /length/)
    expect { Mountfd::Native.fsopen("tmpfs\0suffix", 0) }.to raise_error(ArgumentError)
    expect do
      Mountfd::Native.mount_setattr(
        Mountfd::AT_FDCWD, "/", 0, Mountfd::Native::MOUNT_ATTR_IDMAP, 0, 0, nil
      )
    end.to raise_error(ArgumentError, /user namespace/)
  ensure
    context&.close unless context&.closed?
  end

  it "discards an unattached mount when its fd closes" do
    detached = Mountfd::FsContext.open("tmpfs") do |context|
      context.create!
      context.mount
    end
    expect(Mountfd.pending_mounts).to include(detached)
    detached.discard
    expect(detached).to be_closed
    expect(Mountfd.pending_mounts).not_to include(detached)
  end

  it "changes and clears attributes on an attached mount" do
    require_mount_setattr

    Dir.mktmpdir do |target|
      Mountfd.mount("tmpfs", target)
      Mountfd.set_attributes(target, attrs: {nosuid: true})
      expect(mountinfo(target).options).to include("nosuid")
      Mountfd.set_attributes(target, attrs: {nosuid: false})
      expect(mountinfo(target).options).not_to include("nosuid")
    ensure
      unmount(target)
    end
  end

  it "makes a recursive bind and its submount read-only" do
    require_mount_setattr

    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      nested = File.join(source, "nested")
      target = File.join(directory, "target")
      FileUtils.mkdir_p([nested, target])
      Mountfd.mount("tmpfs", source)
      FileUtils.mkdir_p(nested)
      Mountfd.mount("tmpfs", nested)
      Mountfd.bind(source, target, recursive: true, attrs: {rdonly: true})

      expect { File.write(File.join(target, "root"), "no") }.to raise_error(Errno::EROFS)
      expect { File.write(File.join(target, "nested", "child"), "no") }.to raise_error(Errno::EROFS)
    ensure
      unmount(target, nested, source)
    end
  end

  it "keeps tmp writable inside a read-only sandbox" do
    require_mount_setattr

    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      target = File.join(directory, "target")
      sandbox_tmp = File.join(target, "tmp")
      FileUtils.mkdir_p([source, target])
      Mountfd.mount("tmpfs", source)
      FileUtils.mkdir_p(File.join(source, "tmp"))
      Mountfd.bind(source, target, recursive: true, attrs: {rdonly: true})
      Mountfd.mount("tmpfs", sandbox_tmp, attrs: {nosuid: true, nodev: true})

      expect { File.write(File.join(target, "blocked"), "no") }.to raise_error(Errno::EROFS)
      File.write(File.join(sandbox_tmp, "allowed"), "yes")
      expect(File.read(File.join(sandbox_tmp, "allowed"))).to eq("yes")
    ensure
      unmount(sandbox_tmp, target, source)
    end
  end

  it "changes mount propagation" do
    require_mount_setattr

    Dir.mktmpdir do |target|
      Mountfd.mount("tmpfs", target)
      Mountfd.set_attributes(target, propagation: :private)
      expect(mountinfo(target).propagation).not_to include(:shared, :master)
      Mountfd.set_attributes(target, propagation: :shared)
      expect(mountinfo(target).propagation).to include(:shared)
      Mountfd.set_attributes(target, propagation: :slave)
      expect(mountinfo(target).propagation).not_to include(:shared)
    ensure
      unmount(target)
    end
  end

  it "joins mount propagation peer groups" do
    skip "MOVE_MOUNT_SET_GROUP requires Linux 5.15 or newer" unless kernel_at_least?(5, 15)

    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      target = File.join(directory, "target")
      FileUtils.mkdir_p([source, target])
      Mountfd.mount("tmpfs", source)
      Mountfd.bind(source, target)
      Mountfd.set_attributes(source, propagation: :shared)
      expect(mountinfo(target).propagation).not_to include(:shared)

      Mountfd::Native.move_mount(
        Mountfd::AT_FDCWD, source, Mountfd::AT_FDCWD, target,
        Mountfd::Native::MOVE_MOUNT_SET_GROUP
      )

      expect(mountinfo(target).propagation[:shared]).to eq(mountinfo(source).propagation[:shared])
    ensure
      unmount(target, source)
    end
  end

  it "returns the same visible mounts through statmount and mountinfo" do
    skip "statmount is unavailable" unless Mountfd.features.include?(:statmount)

    project = ->(mount) { [mount.mount_point, mount.fs_type, mount.dev_major, mount.dev_minor] }
    expect(Mountfd.mounts(backend: :statmount).map(&project).sort)
      .to eq(Mountfd.mounts(backend: :mountinfo).map(&project).sort)

    Dir.mktmpdir do |target|
      Mountfd.mount("tmpfs", target, attrs: {nosuid: true, nodev: true})
      statmount = Mountfd.mount_at(target, backend: :statmount)
      mountinfo = Mountfd.mount_at(target, backend: :mountinfo)
      expect(statmount.mnt_root).to eq(mountinfo.mnt_root)
      expect(statmount.attrs.sort).to eq(mountinfo.attrs.sort)
      expect(statmount.propagation).to eq(mountinfo.propagation)
    ensure
      unmount(target)
    end
  end

  it "enumerates a selected mount namespace through statmount" do
    skip "statmount is unavailable" unless Mountfd.features.include?(:statmount)

    File.open("/proc/self/ns/mnt") do |namespace|
      expected = Mountfd.mounts(backend: :statmount).map(&:mount_point).sort
      expect(Mountfd.mounts(ns: namespace, backend: :statmount).map(&:mount_point).sort).to eq(expected)
      expect(Mountfd.mounts(ns: Process.pid, backend: :statmount).map(&:mount_point).sort).to eq(expected)
    end
  rescue Errno::ENOTTY
    skip "mount namespace selection requires Linux 6.11 or newer"
  end

  it "paginates listmount beyond one kernel response" do
    skip "set MOUNTFD_EXTENSIVE=1 to run boundary tests" unless ENV["MOUNTFD_EXTENSIVE"]
    skip "statmount is unavailable" unless Mountfd.features.include?(:statmount)

    Dir.mktmpdir do |directory|
      targets = 270.times.map { File.join(directory, _1.to_s) }
      targets.each { Dir.mkdir(_1); Mountfd.mount("tmpfs", _1) }
      points = Mountfd.mounts(backend: :statmount).map(&:mount_point)
      expect(points & targets).to contain_exactly(*targets)
    ensure
      unmount(*targets.reverse)
    end
  end

  it "grows the statmount buffer for long mount paths" do
    skip "set MOUNTFD_EXTENSIVE=1 to run boundary tests" unless ENV["MOUNTFD_EXTENSIVE"]
    skip "statmount is unavailable" unless Mountfd.features.include?(:statmount)

    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      source_path = File.join(source, *Array.new(18, "s" * 200))
      target = File.join(directory, *Array.new(18, "t" * 200))
      FileUtils.mkdir_p([source, target])
      Mountfd.mount("tmpfs", source)
      FileUtils.mkdir_p(source_path)
      Mountfd.bind(source_path, target)
      expect(mountinfo(target).mnt_root.bytesize + target.bytesize).to be > 4_096
      expect(Mountfd.mount_at(target, backend: :statmount).mnt_root).to eq(mountinfo(target).mnt_root)
    ensure
      unmount(target, source)
    end
  end

  it "atomically replaces an attached mount" do
    skip "MOVE_MOUNT_BENEATH is unavailable" unless Mountfd.features.include?(:move_mount_beneath)

    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      target = File.join(directory, "target")
      FileUtils.mkdir_p([source, target])
      Mountfd.mount("tmpfs", source)
      Mountfd.mount("tmpfs", target)
      File.write(File.join(source, "value"), "new")
      File.write(File.join(target, "value"), "old")
      Mountfd.replace(target) { Mountfd.open_tree(source) }
      expect(File.read(File.join(target, "value"))).to eq("new")
    ensure
      unmount(target, source)
    end
  end

  it "applies an idmap and rejects invalid idmap transitions" do
    skip "idmapped mounts are unavailable" unless Mountfd.features.include?(:idmap)
    skip "tmpfs idmapped mounts require Linux 6.3 or newer" unless kernel_at_least?(6, 3)

    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      target = File.join(directory, "target")
      FileUtils.mkdir_p([source, target])
      Mountfd.mount("tmpfs", source)
      File.write(File.join(source, "value"), "mapped")
      mapping = {uid: {0 => [0, 1]}, gid: {0 => [0, 1]}}
      Mountfd.bind(source, target, idmap: mapping)
      expect(File.stat(File.join(target, "value")).uid).to eq(0)

      overflow = File.join(directory, "overflow")
      FileUtils.mkdir_p(overflow)
      Mountfd.bind(source, overflow, idmap: {uid: {1 => [0, 1]}, gid: {1 => [0, 1]}})
      expect(File.stat(File.join(overflow, "value")).uid).to eq(65_534)

      namespace = Mountfd::UserNamespace.create(**mapping)
      detached = Mountfd.open_tree(source)
      detached.idmap!(namespace)
      expect { detached.idmap!(namespace) }.to raise_error(Mountfd::IdmapError)
      expect { Mountfd::Native.mount_setattr(Mountfd::AT_FDCWD, target, 0,
        Mountfd::Native::MOUNT_ATTR_IDMAP, 0, 0, namespace.fileno) }.to raise_error(SystemCallError)
      proc_mount = Mountfd.open_tree("/proc")
      expect { proc_mount.idmap!(namespace) }.to raise_error(Mountfd::IdmapError)
    ensure
      proc_mount&.discard unless proc_mount&.closed?
      detached&.discard unless detached&.closed?
      namespace&.close unless namespace&.closed?
      unmount(overflow, target, source)
    end
  end

  it "reports mount_setattr as unsupported on older kernels" do
    skip "mount_setattr is available" if Mountfd.features.include?(:mount_setattr)

    expect do
      Mountfd::Native.mount_setattr(Mountfd::AT_FDCWD, "/", 0, 0, 0, 0, nil)
    end.to raise_error(Mountfd::UnsupportedError)
  end
end
