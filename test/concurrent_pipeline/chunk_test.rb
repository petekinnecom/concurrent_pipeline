# frozen_string_literal: true

require "test_helper"
require "ostruct"

module ConcurrentPipeline
  class ChunkTest < Minitest::Test
    class ChunkOne
      extend Chunk
      item :model_1

      ready { model_1.state == "ready" }
      done { model_1.state == "done" }
      perform { model_1.state = "performed" }
    end

    class ChunkTwo
      extend Chunk
      collection :models, type: :model

      ready { models.count == 0 }
      done { models.count == 1 }
      perform { models << "performed" }
    end

    class DummyStore
      def all(type)
        [ :model_1, :model_2 ]
      end
    end

    def test_flow_1
      pipeline = ChunkOne.new
      model = OpenStruct.new
      pipeline.target = model

      model.state = nil
      refute pipeline.ready?
      model.state = "ready"
      assert pipeline.ready?

      model.state = nil
      refute pipeline.done?
      model.state = "done"
      assert pipeline.done?

      model.state = nil
      pipeline.perform
      assert_equal "performed", model.state
    end

    def test_flow_2
      pipeline = ChunkTwo.new
      pipeline.target = []
      assert pipeline.ready?
      refute pipeline.done?
      pipeline.perform
      assert_equal ["performed"], pipeline.target
      refute pipeline.ready?
      assert pipeline.done?
    end

    def test_build_pipelineies
      store = DummyStore.new
      assert_equal [:model_1, :model_2], ChunkOne.build_pipelineies(store)
      assert_equal [[:model_1, :model_2]], ChunkTwo.build_pipelineies(store)
    end
  end
end
