# frozen_string_literal: true

require "test_helper"
require "ostruct"

module ConcurrentPipeline
  module Stores
    class YamlTest < Minitest::Test
      class ModelOne
        extend Model

        attribute :id
        attribute :state_1
        attribute :state_2
        attribute :state_3
      end

      def test_versioned
        dir = Dir.mktmpdir
        registry = Registry.new
        registry.register(:model_one, ModelOne)

        store = Yaml.build_writer(
          data: {},
          dir: dir,
          registry: registry
        )

        changeset = store.changeset
        changeset.create(:model_one, { id: 1, state_1: "value_1" })
        store.apply([changeset])
        model = store.reader.find(ModelOne, 1)
        assert_equal "value_1", model.state_1

        changeset_2 = store.changeset
        changeset_2.update(model, state_1: "value_2")
        store.apply([changeset_2])

        model = store.reader.find(ModelOne, 1)
        assert_equal "value_2", model.state_1

        history = Yaml.history(dir: dir, registry: registry)
        assert_equal 3, history.versions.count
        assert_equal({}, history.versions.first.store.to_h)
        assert_equal(
          { model_one: [{ id: 1, state_1: "value_1" }] },
          history.versions[1].store.to_h
        )
        assert_equal(
          { model_one: [{ id: 1, state_1: "value_2" }] },
          history.versions[2].store.to_h
        )
      end
    end
  end
end
