# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe "Mountfd system", :system do
  def mountinfo(path) = Mountfd.mount_at(path, backend: :mountinfo)

  def unmount(*paths)
    paths.compact.each { Mountfd.umount(_1) if File.exist?(_1) && mountinfo(_1) }
  end

  before(:context) do
    skip "set MOUNTFD_SYSTEM=1 to run mount tests" unless ENV["MOUNTFD_SYSTEM"]
    skip "Linux is required" unless Mountfd::Native.linux?

    Mountfd::Namespace.unshare_user!
    Mountfd::Namespace.unshare_mount!
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

  it "creates a read-only detached bind mount" do
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
    GC.start
    baseline = Dir.children("/proc/self/fd").length
    1_000.times { Mountfd::FsContext.new("tmpfs").close }
    expect(Dir.children("/proc/self/fd").length).to eq(baseline)

    previous = GC.stress
    GC.stress = true
    50.times { Mountfd::FsContext.new("tmpfs") }
    GC.start
    expect(Dir.children("/proc/self/fd").length).to eq(baseline)
  ensure
    GC.stress = previous unless previous.nil?
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

  it "changes mount propagation" do
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

  it "returns the same visible mounts through statmount and mountinfo" do
    skip "statmount is unavailable" unless Mountfd.features.include?(:statmount)

    project = ->(mount) { [mount.mount_point, mount.fs_type, mount.dev_major, mount.dev_minor] }
    expect(Mountfd.mounts(backend: :statmount).map(&project).sort)
      .to eq(Mountfd.mounts(backend: :mountinfo).map(&project).sort)
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
end
