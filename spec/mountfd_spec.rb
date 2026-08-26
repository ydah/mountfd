# frozen_string_literal: true

RSpec.describe Mountfd do
  it "has a version number" do
    expect(Mountfd::VERSION).not_to be nil
  end

  it "retains diagnostics on mount errors" do
    expect(Mountfd::MountError.new("failed", [Mountfd::Diagnostic.new(:error, "detail")]).diagnostics.length).to eq(1)
  end

  it "loads without Linux syscall support" do
    expect(Mountfd.supported?).to be(false) unless RUBY_PLATFORM.include?("linux")
  end

  it "parses kernel diagnostics" do
    diagnostics = Mountfd::Diagnostic.parse("e bad option\nw deprecated\ni note\nunknown\n")

    expect(diagnostics.map(&:level)).to eq(%i[error warning info info])
    expect(diagnostics.map(&:text)).to eq(["bad option", "deprecated", "note", "unknown"])
  end

  it "parses captured filesystem diagnostics" do
    %w[tmpfs ext4 overlay].each do |filesystem|
      raw = File.read(File.join(__dir__, "fixtures/diagnostics/#{filesystem}.txt"))
      diagnostic = Mountfd::Diagnostic.parse(raw).fetch(0)
      expect(diagnostic.level).to eq(:error)
      expect(diagnostic.text).to include(filesystem, "Unknown parameter")
    end
  end

  it "dispatches typed fsconfig values" do
    handle = instance_double(Mountfd::Native::Handle, fileno: 9)
    context = Mountfd::FsContext.new(nil, handle: handle)
    allow(Mountfd::Native).to receive(:read_diagnostics).and_return("")
    expect(Mountfd::Native).to receive(:fsconfig)
      .with(handle, Mountfd::Native::FSCONFIG_SET_PATH, "lowerdir", "/lower", Mountfd::AT_FDCWD)
    expect(Mountfd::Native).to receive(:fsconfig)
      .with(handle, Mountfd::Native::FSCONFIG_SET_FD, "source", nil, 12)
    expect(Mountfd::Native).to receive(:fsconfig)
      .with(handle, Mountfd::Native::FSCONFIG_SET_BINARY, "blob", "a\0b", 3)

    context.set_path(:lowerdir, "/lower")
    context.set_fd(:source, instance_double(IO, fileno: 12))
    context.set_binary(:blob, "a\0b")
  end

  it "preserves diagnostics from successful configuration" do
    handle = instance_double(Mountfd::Native::Handle)
    context = Mountfd::FsContext.new(nil, handle: handle)
    allow(Mountfd::Native).to receive(:fsconfig)
    allow(Mountfd::Native).to receive(:read_diagnostics).and_return("w adjusted option\n")

    context.set("size", "1M")

    expect(context.warnings.map(&:text)).to eq(["adjusted option"])
  end

  it "assembles lifecycle flags" do
    context_handle = instance_double(Mountfd::Native::Handle, close: nil, closed?: false)
    picked_handle = instance_double(Mountfd::Native::Handle, close: nil)
    mount_handle = instance_double(Mountfd::Native::Handle, close: nil, closed?: false)
    expect(Mountfd::Native).to receive(:fsopen)
      .with("tmpfs", Mountfd::Native::FSOPEN_CLOEXEC | 8).and_return(context_handle)
    allow(Mountfd::Native).to receive(:read_diagnostics).and_return("")
    expect(Mountfd::Native).to receive(:fsmount)
      .with(context_handle, Mountfd::Native::FSMOUNT_CLOEXEC, Mountfd::Native::MOUNT_ATTR_NOSUID)
      .and_return(mount_handle)
    expect(Mountfd::Native).to receive(:fspick)
      .with(Mountfd::AT_FDCWD, "/existing", Mountfd::Native::FSPICK_CLOEXEC | 4)
      .and_return(picked_handle)
    expect(Mountfd::Native).to receive(:move_mount).with(
      mount_handle, "", Mountfd::AT_FDCWD, "/target",
      Mountfd::Native::MOVE_MOUNT_F_EMPTY_PATH | Mountfd::Native::MOVE_MOUNT_BENEATH
    )
    expect(Mountfd::Native).to receive(:umount2).with("/target", 3)

    context = Mountfd::FsContext.new("tmpfs", flags: 8)
    context.mount(attrs: {nosuid: true}).attach("/target", beneath: true)
    Mountfd::FsContext.pick("/existing", flags: 4).close
    Mountfd.umount("/target", detach: true, force: true)
    context.close
  end

  it "normalizes atime attributes" do
    set, clear = Mountfd::Attributes.build(rdonly: true, atime: :noatime)

    expect(set).to eq(Mountfd::Native::MOUNT_ATTR_RDONLY | Mountfd::Native::MOUNT_ATTR_NOATIME)
    expect(clear).to eq(Mountfd::Native::MOUNT_ATTR__ATIME)
  end

  it "validates propagation names" do
    expect(Mountfd::Attributes.propagation(:private)).to eq(Mountfd::Native::MS_PRIVATE)
    expect { Mountfd::Attributes.propagation(:mystery) }.to raise_error(ArgumentError)
  end

  it "normalizes namespace mapping forms" do
    expect(Mountfd::UserNamespace.normalize(0 => [100_000, 65_536])).to eq([[0, 100_000, 65_536]])
    expect(Mountfd::UserNamespace.normalize([[1_000, 1_000, 1], [0, 100_000, 1]])).to eq(
      [[0, 100_000, 1], [1_000, 1_000, 1]]
    )
    expect(Mountfd::UserNamespace.normalize(0 => 1_000)).to eq([[0, 1_000, 1]])
  end

  it "rejects unsafe namespace mappings" do
    expect { Mountfd::UserNamespace.normalize(0 => [-1, 1]) }.to raise_error(ArgumentError)
    expect { Mountfd::UserNamespace.normalize(0 => [1, 2, 3]) }.to raise_error(ArgumentError)
    expect { Mountfd::UserNamespace.normalize([[0, 1]]) }.to raise_error(ArgumentError)
    expect { Mountfd::UserNamespace.normalize(2**32 => 0) }.to raise_error(ArgumentError)
    expect { Mountfd::UserNamespace.normalize([[0, 1_000, 2], [1, 2_000, 1]]) }
      .to raise_error(ArgumentError, /overlapping inside/)
    expect { Mountfd::UserNamespace.normalize([[0, 1_000, 2], [10, 1_001, 1]]) }
      .to raise_error(ArgumentError, /overlapping outside/)
    expect { Mountfd::UserNamespace.create(helper: :sometimes) }.to raise_error(ArgumentError)
  end

  it "parses mountinfo escapes and optional fields" do
    line = "42 21 8:1 /root\\040dir\\011tab /mnt\\040point\\012line rw,nosuid shared:7 master:2 - ext4 /dev/a\\134b ro,errors=remount-ro\n"
    mount = Mountfd::MountInfoParser.parse(line).fetch(0)

    expect(mount.mnt_id).to eq(42)
    expect(mount.mnt_root).to eq("/root dir\ttab")
    expect(mount.mount_point).to eq("/mnt point\nline")
    expect(mount.source).to eq("/dev/a\\b")
    expect(mount.propagation).to eq(shared: 7, master: 2)
    expect(mount).to be_readonly
  end

  it "ignores unknown and malformed mountinfo fields" do
    future = "42 21 8:1 / /mnt rw shared:7 future:value unbindable - ext4 /dev/a rw\n"
    malformed = "42 21 broken / /mnt rw - ext4 /dev/a rw\n"

    expect(Mountfd::MountInfoParser.parse(future).fetch(0).propagation)
      .to eq(shared: 7, unbindable: true)
    expect(Mountfd::MountInfoParser.parse(malformed)).to be_empty
  end

  it "coerces an attachment path only before changing the mount tree" do
    path = Class.new do
      attr_reader :calls
      def initialize = @calls = 0
      def to_path
        @calls += 1
        raise "coerced twice" if @calls > 1

        "/target"
      end
    end.new
    handle = instance_double(Mountfd::Native::Handle, close: nil, closed?: true)
    expect(Mountfd::Native).to receive(:move_mount).with(
      handle, "", Mountfd::AT_FDCWD, "/target", Mountfd::Native::MOVE_MOUNT_F_EMPTY_PATH
    )

    expect(Mountfd::DetachedMount.new(handle).attach(path).path).to eq("/target")
    expect(path.calls).to eq(1)
  end

  it "assembles recursive open_tree and mount_setattr flags" do
    handle = instance_double(Mountfd::Native::Handle, close: nil, closed?: false)
    tree_flags = Mountfd::Native::OPEN_TREE_CLONE | Mountfd::Native::OPEN_TREE_CLOEXEC | Mountfd::Native::AT_RECURSIVE
    expect(Mountfd::Native).to receive(:open_tree).with(Mountfd::AT_FDCWD, "/source", tree_flags).and_return(handle)
    expect(Mountfd::Native).to receive(:mount_setattr).with(
      handle, "", Mountfd::Native::AT_EMPTY_PATH | Mountfd::Native::AT_RECURSIVE,
      Mountfd::Native::MOUNT_ATTR_RDONLY, 0, 0, nil
    )

    mount = Mountfd.open_tree("/source", recursive: true)
    mount.set_attributes(set: [:rdonly], recursive: true)
    mount.discard
  end

  it "ignores malformed mountinfo lines" do
    expect(Mountfd::MountInfoParser.parse("not mountinfo\n")).to be_empty
  end

  it "reports only the visible mount when mountinfo contains overmounts" do
    hidden = "40 20 0:1 / /same rw - tmpfs old rw\n"
    visible = "41 20 0:2 / /same ro - tmpfs new ro\n"
    allow(File).to receive(:read).and_return(hidden + visible)

    mounts = Mountfd.mounts(backend: :mountinfo)
    expect(mounts.map(&:mnt_id)).to eq([41])
    expect(mounts.first).to be_readonly
  end

  it "passes mount namespace descriptors to statmount" do
    namespace = instance_double(IO, fileno: 42)
    expect(Mountfd::Native).to receive(:statmounts).with(42).and_return([])

    expect(Mountfd.mounts(ns: namespace, backend: :statmount)).to be_empty
  end

  it "rejects mount namespace descriptors with the mountinfo backend" do
    namespace = instance_double(IO, fileno: 42)

    expect { Mountfd.mounts(ns: namespace, backend: :mountinfo) }
      .to raise_error(Mountfd::UnsupportedError, /Linux 6\.11/)
  end

  it "validates namespace propagation before changing namespaces" do
    expect { Mountfd::Namespace.unshare_mount!(propagation: :mystery) }.to raise_error(ArgumentError)
  end

  it "does not re-exec after entering a user namespace" do
    previous = ENV["MOUNTFD_IN_USERNS"]
    ENV["MOUNTFD_IN_USERNS"] = "1"
    expect(Mountfd::Namespace.reexec_user!).to be_nil
  ensure
    ENV["MOUNTFD_IN_USERNS"] = previous
  end

  it "requires a detached mount for atomic replacement" do
    expect { Mountfd.replace("/tmp") { nil } }.to raise_error(ArgumentError)
  end
end
