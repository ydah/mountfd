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
    expect { Mountfd::UserNamespace.create(helper: :sometimes) }.to raise_error(ArgumentError)
  end

  it "parses mountinfo escapes and optional fields" do
    line = "42 21 8:1 /root\\040dir /mnt\\040point rw,nosuid shared:7 master:2 - ext4 /dev/sda1 ro,errors=remount-ro\n"
    mount = Mountfd::MountInfoParser.parse(line).fetch(0)

    expect(mount.mnt_id).to eq(42)
    expect(mount.mnt_root).to eq("/root dir")
    expect(mount.mount_point).to eq("/mnt point")
    expect(mount.propagation).to eq(shared: 7, master: 2)
    expect(mount).to be_readonly
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

  it "validates namespace propagation before changing namespaces" do
    expect { Mountfd::Namespace.unshare_mount!(propagation: :mystery) }.to raise_error(ArgumentError)
  end

  it "requires a detached mount for atomic replacement" do
    expect { Mountfd.replace("/tmp") { nil } }.to raise_error(ArgumentError)
  end
end
