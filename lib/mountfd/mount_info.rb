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
    ESCAPE = /\\([0-7]{3})/

    def self.parse(content)
      content.lines.filter_map { parse_line(_1) }
    end

    def self.parse_line(line)
      fields = line.split
      separator = fields.index("-")
      return unless separator && separator >= 6 && fields.length >= separator + 4

      major, minor = fields[2].split(":", 2).map { Integer(_1, 10) }
      mount_options = fields[5].split(",")
      super_options = fields[separator + 3].split(",")
      optional = fields[6...separator]
      MountInfo.new(
        Integer(fields[0], 10), Integer(fields[1], 10), decode(fields[3]), decode(fields[4]),
        decode(fields[separator + 1]), decode(fields[separator + 2]),
        (mount_options + super_options).uniq.freeze, parse_propagation(optional),
        parse_attrs(mount_options, optional), major, minor
      )
    rescue ArgumentError
      nil
    end

    def self.decode(value) = value.gsub(ESCAPE) { Regexp.last_match(1).to_i(8).chr }

    def self.parse_propagation(fields)
      fields.to_h do |field|
        name, value = field.split(":", 2)
        [name.to_sym, value ? Integer(value, 10) : true]
      end.freeze
    end

    def self.parse_attrs(options, optional)
      values = []
      values << :rdonly if options.include?("ro")
      values << :idmap if optional.include?("idmapped")
      values.freeze
    end
  end
end
