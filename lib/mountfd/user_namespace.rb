# frozen_string_literal: true

module Mountfd
  class UserNamespace
    MAX_RANGES = 340

    def self.create(uid: {0 => Process.uid}, gid: {0 => Process.gid}, helper: :auto)
      uid_map = normalize(uid)
      gid_map = normalize(gid)
      use_helper = case helper
                   when :auto then helpers_available? && !Process.euid.zero?
                   when true, false then helper
                   else raise ArgumentError, "helper must be :auto, true, or false"
                   end
      new(Native.user_namespace(format(uid_map), format(gid_map), use_helper))
    rescue SystemCallError => error
      raise IdmapError, "user namespace: #{error.message}", cause: error
    end

    def self.from_pid(pid) = from_path("/proc/#{Integer(pid)}/ns/user")
    def self.from_path(path) = new(Native.open_handle(File.path(path)))

    def self.normalize(mapping)
      ranges = if mapping.is_a?(Hash)
                 mapping.map do |inside, outside|
                   outside, length = outside.is_a?(Array) ? outside : [outside, 1]
                   [inside, outside, length]
                 end
               elsif mapping.is_a?(Array) && mapping.length == 3 && mapping.none? { _1.is_a?(Array) }
                 [mapping]
               else
                 Array(mapping)
               end
      ranges = ranges.map { |range| range.map { Integer(_1) } }.sort_by(&:first)
      raise ArgumentError, "a namespace mapping requires at least one range" if ranges.empty?
      raise ArgumentError, "namespace mappings are limited to #{MAX_RANGES} ranges" if ranges.length > MAX_RANGES

      ranges.each do |inside, outside, length|
        raise ArgumentError, "mapping IDs must be non-negative" if inside.negative? || outside.negative?
        raise ArgumentError, "mapping length must be positive" unless length.positive?
      end
      validate_non_overlapping!(ranges, 0, "inside")
      validate_non_overlapping!(ranges, 1, "outside")
      ranges
    end

    def self.format(ranges) = ranges.map { _1.join(" ") }.join("\n") << "\n"

    def self.validate_non_overlapping!(ranges, index, label)
      sorted = ranges.sort_by { _1[index] }
      sorted.each_cons(2) do |left, right|
        raise ArgumentError, "overlapping #{label} mapping ranges" if left[index] + left[2] > right[index]
      end
    end
    private_class_method :format, :validate_non_overlapping!

    def self.helpers_available?
      %w[newuidmap newgidmap].all? do |program|
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
          File.executable?(File.join(directory, program))
        end
      end
    end
    private_class_method :helpers_available?

    def initialize(handle)
      @handle = handle
    end

    def fileno = @handle.fileno
    def closed? = @handle.closed?
    def close = @handle.close
  end
end
