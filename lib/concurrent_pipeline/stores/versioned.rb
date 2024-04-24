# frozen_string_literal: true

require "securerandom"
require "yaml"

module ConcurrentPipeline
  module Stores
    class Versioned
      Version = Struct.new(:data, :registry, keyword_init: true)
        include Yaml::QueryMethods
      end

      attr_reader :data, :registry
      def initialize(data:, registry:)
        @data = data
        @registry = registry
      end

      def versions

      end
    end
  end
end
