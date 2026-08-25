# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe "Mountfd ext4 idmap", :system do
  before(:context) do
    skip "set MOUNTFD_EXT4=1 to run the loopback test" unless ENV["MOUNTFD_EXT4"]
    skip "root on Linux is required" unless Mountfd::Native.linux? && Process.euid.zero?

    Mountfd::Namespace.unshare_mount!
  end

  it "maps an ext4 owner and reports an unmapped owner as overflow" do
    Dir.mktmpdir do |directory|
      image = File.join(directory, "ext4.img")
      source = File.join(directory, "source")
      target = File.join(directory, "target")
      FileUtils.mkdir_p([source, target])
      File.open(image, "wb") { _1.truncate(64 * 1024 * 1024) }
      expect(system("mkfs.ext4", "-q", image)).to be(true)
      expect(system("mount", "-o", "loop", image, source)).to be(true)

      File.write(File.join(source, "mapped"), "mapped")
      File.chown(1_000, 1_000, File.join(source, "mapped"))
      File.write(File.join(source, "overflow"), "overflow")
      File.chown(1_001, 1_001, File.join(source, "overflow"))
      Mountfd.bind(source, target, idmap: {
        uid: {1_000 => [0, 1]}, gid: {1_000 => [0, 1]}, helper: false
      })

      expect(File.stat(File.join(target, "mapped")).uid).to eq(0)
      expect(File.stat(File.join(target, "overflow")).uid).to eq(65_534)
    ensure
      Mountfd.umount(target) if target && Mountfd.mount_at(target, backend: :mountinfo)
      system("umount", source) if source && Mountfd.mount_at(source, backend: :mountinfo)
    end
  end
end
