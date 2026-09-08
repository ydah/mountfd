# frozen_string_literal: true

require_relative "lib/mountfd/version"

Gem::Specification.new do |spec|
  spec.name = "mountfd"
  spec.version = Mountfd::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Ruby bindings for the Linux file-descriptor mount API"
  spec.description = "Build, configure, inspect, and attach Linux mounts as file descriptors."
  spec.homepage = "https://github.com/ydah/mountfd#readme"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ydah/mountfd"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ site/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/mountfd/extconf.rb"]

  spec.add_development_dependency "rake-compiler", "~> 1.3"
  spec.add_development_dependency "rbs", "~> 4.0"
  spec.add_development_dependency "yard", "~> 0.9"

end
