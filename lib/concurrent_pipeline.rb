# frozen_string_literal: true

require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.setup

module ConcurrentPipeline
  class Error < StandardError; end

  class << self
    def store(type = :yaml, &)
      Store.define(&)
    end

    def pipeline(&)
      Pipeline.define(&)
    end
  end
end
