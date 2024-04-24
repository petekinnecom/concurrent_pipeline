# frozen_string_literal: true

module ConcurrentPipeline
  class Changeset
    Result = Struct.new(:diff) do
      alias diff? diff
    end

    InitialDelta = Struct.new(:data, :dup, keyword_init: true) do
      def apply(store)
        # We fully dup the data to avoid mutating the input
        dup_data = YAML.unsafe_load(data.to_yaml)
        store.set(dup_data)
        Result.new(true)
      end

      def self.from_json(json)
        new(data: json.fetch(:delta), dup: true)
      end

      def as_json(...)
        {
          action: :initial,
          delta: data
        }
      end
    end

    CreateDelta = Struct.new(:type, :attributes, keyword_init: true) do
      def apply(store)
        store.create(type: type, attributes: attributes)
        Result.new(true)
      end

      def self.from_json(json)
        new(
          type: json.fetch(:type),
          attributes: json.fetch(:attributes)
        )
      end

      def as_json(...)
        {
          action: :create,
          type: type,
          attributes: attributes
        }
      end
    end

    UpdateDelta = Struct.new(:id, :type, :delta, keyword_init: true) do
      def apply(store)
        current_model = store.find(type, id)

        # Todo: detect if changed underfoot

        Result.new(
          store.update(
            id: id,
            type: type,
            attributes: current_model.attributes.merge(delta)
          )
        )
      end

      def self.from_json(json)
        new(
          id: json.fetch(:id),
          type: json.fetch(:type),
          delta: json.fetch(:delta),
        )
      end

      def as_json
        {
          action: :update,
          id: id,
          type: type,
          delta: delta
        }
      end
    end

    def self.from_json(registry:, json:)
      type_map = {
        initial: InitialDelta,
        create: CreateDelta,
        update: UpdateDelta,
      }

      new(
        registry: registry
      ).tap do |changeset|
        json.fetch(:changes).each do |change|
          type_map
            .fetch(change.fetch(:action))
            .from_json(change)
            .then { changeset.deltas << _1 }
        end
      end
    end

    attr_reader :deltas, :registry
    def initialize(registry:)
      @registry = registry
      @deltas = []
    end

    def deltas?
      !@deltas.empty?
    end

    def create(type, attributes)
      with_id = { id: SecureRandom.uuid }.merge(attributes)
      @deltas << CreateDelta.new(type: type, attributes: with_id)
    end

    def update(model, delta)
      type = registry.type_for(model.class)
      @deltas << UpdateDelta.new(id: model.id, type: type, delta: delta)
    end

    def apply(...)
      deltas.map { _1.apply(...) }
    end

    def as_json(...)
      {
        changes: deltas.map { _1.as_json(...) }
      }
    end
  end
end
