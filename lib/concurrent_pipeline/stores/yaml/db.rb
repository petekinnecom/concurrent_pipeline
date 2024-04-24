# frozen_string_literal: true

require "securerandom"
require "yaml"

module ConcurrentPipeline
  module Stores
    module Yaml
      class Db
        Reader = Struct.new(:store) do
          def find(...)
            store.find(...)
          end

          def all(...)
            store.all(...)
          end

          def everything(...)
            store.everything(...)
          end

          def to_h(...)
            store.to_h(...)
          end

          def changeset
            store.changeset
          end

          def reader?
            true
          end
        end

        attr_reader :data, :registry, :after_apply
        def initialize(data:, registry:, after_apply: nil)
          @data = data
          @registry = registry
          @after_apply = after_apply
        end

        def changeset
          Changeset.new(registry: registry)
        end

        def apply(chgs)
          changesets = chgs.is_a?(Array) ? chgs : [chgs]
          results = changesets.flat_map { _1.apply(self) }
          diffed = results.any?(&:diff?)
          after_apply&.call(changesets) if diffed
          diffed
        end

        def reader?
          false
        end

        def reader
          Reader.new(self)
        end

        def to_h
          data
        end

        def everything
          data.each_with_object({}) do |(type, subdata), all_of_it|
            all_of_it[type] = subdata.map { |attrs| registry.build(type, attrs) }
          end
        end

        def all(type)
          type = registry.type_for(type)

          data
            .fetch(type, [])
            .map { registry.build(type, _1) }
        end

        def find(type, id)
          type = registry.type_for(type)
          attrs = (data[type] || []).find { |attrs| attrs[:id] == id }
          registry.build(type, attrs)
        end

        def set(data)
          @data = data
        end

        def create(type:, attributes:)
          type = registry.type_for(type)

          data[type] ||= []
          data[type] << attributes
        end

        def update(id:, type:, attributes:)
          type = registry.type_for(type)
          attrs = (data[type] || []).find { |attrs| attrs[:id] == id }
          raise "Not found" unless attrs

          was_updated = attributes.any? { |k, v| attrs[k] != v }
          attrs.merge!(attributes)
          was_updated
        end
      end
    end
  end
end
