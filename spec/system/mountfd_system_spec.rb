# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe "Mountfd system", :system do
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
      Mountfd.umount(target) if target && Mountfd.mount_at(target)
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
      Mountfd.umount(target) if target && Mountfd.mount_at(target)
      Mountfd.umount(source) if source && Mountfd.mount_at(source)
    end
  end
end
