# frozen_string_literal: true

require "test_helper"
require "ostruct"

module ConcurrentPipeline
  class ProducerTest < Minitest::Test
    class Collector
      class << self
        def messages
          @messages
        end

        def clear
          @messages = []
        end
      end
    end

    class ModelOne
      extend Model

      attribute :id
      attribute :state_1
      attribute :state_2
      attribute :state_3
    end

    class PipelineOne < ConcurrentPipeline::Pipeline
      steps(
        :update_state_1,
        [:update_state_2, :update_state_3]
      )

      def update_state_1
        sleep 1
        changeset.update(record, state_1: "performed")
      end

      def update_state_2
        sleep 3
        changeset.update(record, state_2: "performed")
      end

      def update_state_3
        sleep 3
        changeset.update(record, state_3: "performed")
      end
    end

    class ProducerOne < ConcurrentPipeline::Producer
      stream do
        on(:stdout) do |payload|
          Collector.messages << payload
        end
      end

      model ModelOne

      model(:model_two) do
        attribute :id
        attribute :state
      end

      pipeline(PipelineOne, each: :ModelOne, concurrency: 100)

      pipeline(:pipeline_two) do
        steps(:update_state)

        def update_state
          store.all(:model_two).each do |model|
            stream(:stdout, "performing: #{model.id}")
            sleep 1
            changeset.update(model, state: "performed: #{model.id}")
          end
        end
      end
    end

    def setup
      Collector.clear
    end

    def test_stream_config
      producer = ProducerOne.new(data: data)
      producer.call
      refute Collector.messages.empty?

      @received = false
      stream = ConcurrentPipeline::Producer::Stream.new
      stream.on(:stdout) { @received = true }

      producer = ProducerOne.new(data: data, stream: stream)
      producer.call

      assert @received = true
    end

    def test_data_config
      stream = ConcurrentPipeline::Producer::Stream.new
      stream.on(:stdout) {}

      producer = ProducerOne.new(stream: stream) do |changeset|
        data.each do |model_type, records|
          records.each do |attrs|
            changeset.create(model_type, attrs)
          end
        end
      end
      producer.call
      verify_results(producer)

      p2 = ProducerOne.new(data: data, stream: stream)
      p2.call
      verify_results(p2)

      restart_producer = ProducerOne.new(
        store: p2.history.versions[4].store,
        stream: stream
      )
      restart_producer.call
      verify_results(restart_producer)
    end

    def test_concurrency
      producer = ProducerOne.new(data: data)

      start_time = Time.now.to_i
      producer.call do |stream|
        stream.on(:stdout) {}
      end
      elapsed_seconds = Time.now.to_i - start_time
      assert(
        elapsed_seconds < 5,
        "elapsed_seconds: #{elapsed_seconds}"
      )
      verify_results(producer)
    end

    def verify_results(producer)
      results = producer.data
      assert_equal ["performed"], results[:ModelOne].map { _1[:state_1] }.uniq
      assert_equal ["performed"], results[:ModelOne].map { _1[:state_2] }.uniq
      assert_equal ["performed"], results[:ModelOne].map { _1[:state_3] }.uniq

      assert_equal "performed: 0", results[:model_two][0][:state]
      assert_equal "performed: 1", results[:model_two][1][:state]
      assert_equal "performed: 2", results[:model_two][2][:state]
    end

    def data
      {
        ModelOne: [
          {
            id: 0,
            state_1: "ready",
            state_2: "ready",
            state_3: "ready"
          },
          {
            id: 1,
            state_1: "ready",
            state_2: "ready",
            state_3: "ready"
          },
          {
            id: 2,
            state_1: "ready",
            state_2: "ready",
            state_3: "ready"
          },
        ],
        model_two: [
          {
            id: 0,
            state: "pending",
          },
          {
            id: 1,
            state: "pending",
          },
          {
            id: 2,
            state: "pending",
          },
        ]
      }
    end
  end
end
