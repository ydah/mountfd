# frozen_string_literal: true

module Mountfd
  MountInfo = Data.define(
    :mnt_id, :parent_id, :mnt_root, :mount_point, :fs_type, :source,
    :options, :propagation, :attrs, :dev_major, :dev_minor
  ) do
    def idmapped? = attrs.include?(:idmap) || options.include?("idmapped")
    def readonly? = attrs.include?(:rdonly) || options.include?("ro")
  end

  module MountInfoParser
    ESCAPE = /\\([0-3][0-7]{2})/
    UINT32_MAX = 2**32 - 1
    UINT64_MAX = 2**64 - 1

    def self.parse(content)
      content.b.lines.filter_map { parse_line(_1) }
    end

    def self.parse_line(line)
      fields = line.split
      separator = fields.index("-")
      return unless separator && separator >= 6 && fields.length >= separator + 4

      device = fields[2].split(":", -1)
      return unless device.length == 2

      mnt_id, parent_id = fields.first(2).map { Integer(_1, 10) }
      major, minor = device.map { Integer(_1, 10) }
      return unless mnt_id.between?(0, UINT64_MAX) && parent_id.between?(0, UINT64_MAX) &&
        major.between?(0, UINT32_MAX) && minor.between?(0, UINT32_MAX)

      mount_options = fields[5].split(",")
      super_options = fields[separator + 3].split(",")
      optional = fields[6...separator]
      MountInfo.new(
        mnt_id, parent_id, decode(fields[3]), decode(fields[4]),
        decode(fields[separator + 1]), decode(fields[separator + 2]),
        (mount_options + super_options).uniq.freeze, parse_propagation(optional),
        parse_attrs(mount_options + super_options, optional), major, minor
      )
    rescue ArgumentError, TypeError
      nil
    end

    def self.decode(value)
      value.gsub(ESCAPE) { Regexp.last_match(1).to_i(8).chr(Encoding::BINARY) }
    end

    def self.parse_propagation(fields)
      propagation = fields.filter_map do |field|
        name, value = field.split(":", 2)
        case name
        when "shared", "master", "propagate_from"
          [name.to_sym, Integer(value, 10)] if value
        when "unbindable"
          [:unbindable, true]
        end
      end.to_h
      propagation[:slave] = true if propagation.key?(:master)
      propagation[:private] = true if propagation.empty?
      propagation.freeze
    end

    def self.parse_attrs(options, optional)
      names = {
        "ro" => :rdonly, "nosuid" => :nosuid, "nodev" => :nodev,
        "noexec" => :noexec, "nodiratime" => :nodiratime,
        "nosymfollow" => :nosymfollow, "noatime" => :noatime,
        "strictatime" => :strictatime
      }
      values = options.filter_map { names[_1] }
      values << :idmap if optional.include?("idmapped")
      values.uniq.freeze
    end
  end
end
