require "securerandom"

module ConcurrentPipeline
  module Pipelines
    class Schema
      PROCESSORS = {
        sync: Processors::Synchronous,
        async: Processors::Asynchronous,
      }

      Step = Struct.new(:value, :queue_size, :label, keyword_init: true)
      Timer = Data.define(:interval, :block)
      Stats = Struct.new(:queue_size, :completed, :time, keyword_init: true)

      Producer = Struct.new(:query, :block, :label, keyword_init: true) do
        def call(*a, **p)
          instance_exec(*a, **p, &block)
        end

        def assert(val)
          raise Errors::AssertionFailure.new("Post condition failed") unless val
        end

        def shell
          Shell
        end

        def records(store)
          if query.is_a?(Proc)
            query.call
          elsif query.is_a?(ActiveRecord::Relation)
            query.reload.to_a
          else
            raise "Invalid processor query type: #{query.inspect}"
          end
        end
      end

      def producers
        @producers ||= []
      end

      def arounds
        @arounds ||= []
      end

      def timers
        @timers ||= []
      end

      def before_process_hooks
        @before_process_hooks ||= []
      end

      def processor(type, **attrs)
        @processor = {type:, attrs:}
      end

      def build_processor(store)
        PROCESSORS
          .fetch(@processor.fetch(:type))
          .new(store:, producers:, before_process_hooks:, timers:, **@processor.fetch(:attrs))
      end

      def process(query, label: nil, &block)
        producers << Producer.new(query:, block:, label:)
      end

      def around(&block)
        arounds << block
      end

      def before_process(&block)
        before_process_hooks << block
      end

      def timer(interval, &block)
        timers << Timer.new(interval:, block:)
      end
    end
  end
end
