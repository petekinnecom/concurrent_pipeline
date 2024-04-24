# frozen_string_literal: true

require "securerandom"
require "yaml"

require_relative "db"

module ConcurrentPipeline
  module Stores
    module Yaml
      class History
        class Version
          attr_reader :index, :registry, :changesets
          def initialize(index:, changesets:, registry:)
            @index = index
            @changesets = changesets[0..index]
            @registry = registry
          end

          def store
            @store ||= (
              Db
                .new(data: {}, registry: registry)
                .tap { _1.apply(changesets) }
                .reader
            )
          end

          def diff
            changesets.last.as_json
          end
        end

        attr_reader :path, :registry
        def initialize(registry:, path:)
          @registry = registry
          @path = path
        end

        def versions
          @versions ||= (
            changesets
              .count
              .times
              .map { |i|
                Version.new(
                  index: i,
                  changesets: changesets,
                  registry: registry
                )
              }
          )
        end

        private

        def changesets
          @changesets ||= (
            YAML
              .load_stream(File.read(path))
              .map { |v| Changeset.from_json(json: v, registry: registry) }
          )
        end
      end
    end
  end
end
