# frozen_string_literal: true

module Mountfd
  module Namespace
    def self.unshare_mount!(propagation: :private)
      raise ArgumentError, "propagation must be :private or nil" unless propagation.nil? || propagation == :private

      warn_unless_main_thread
      Native.unshare(Native::CLONE_NEWNS)
      Native.change_propagation("/", Native::MS_PRIVATE | Native::MS_REC) if propagation == :private
      nil
    end

    def self.unshare_user!(map_root: true)
      warn_unless_main_thread
      Native.unshare_user(map_root)
    end

    def self.warn_unless_main_thread
      warn("Mountfd namespace changes affect only the calling OS thread") unless Thread.current == Thread.main
    end
    private_class_method :warn_unless_main_thread
  end
end
