# frozen_string_literal: true

require_relative "lib/concurrent_pipeline/version"

Gem::Specification.new do |spec|
  spec.name = "concurrent_pipeline"
  spec.version = ConcurrentPipeline::VERSION
  spec.authors = ["Pete Kinnecom"]
  spec.email = ["git@k7u7.com"]

  spec.summary = <<~TEXT.strip
    Define a pipeline of tasks, run them concurrently, and see a versioned \
    history of all changes along the way.
  TEXT
  spec.homepage = "https://github.com/petekinnecom/concurrent_pipeline"
  spec.license = "WTFPL"
  spec.required_ruby_version = ">= 3.0.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .circleci appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("zeitwerk")
  spec.add_dependency("yaml")
  spec.add_dependency("async")
end
