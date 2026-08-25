# frozen_string_literal: true

RSpec.describe Mountfd do
  it "has a version number" do
    expect(Mountfd::VERSION).not_to be nil
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
    expect { Mountfd::UserNamespace.normalize([[0, 1_000, 2], [1, 2_000, 1]]) }
      .to raise_error(ArgumentError, /overlapping inside/)
    expect { Mountfd::UserNamespace.create(helper: :sometimes) }.to raise_error(ArgumentError)
  end
end
