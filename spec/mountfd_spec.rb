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
end
