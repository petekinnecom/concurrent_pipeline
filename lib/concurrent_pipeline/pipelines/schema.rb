require "securerandom"

module ConcurrentPipeline
  module Pipelines
    class Schema
      PROCESSORS = {
        sync: Processors::Synchronous,
        async: Processors::Asynchronous,
      }

      Producer = Struct.new(:query, :block) do
        def call(*a, **p)
          instance_exec(*a, **p, &block)
        end

        def shell
          Shell
        end

        def records(store)
          if query.is_a?(Proc)
            query.call
          else
            # Query is a hash with record_name and filters
            store.where(query[:record_name], **query[:filters])
          end
        end
      end

      def producers
        @producers ||= []
      end

      def processor(type, **attrs)
        @processor = {type:, attrs:}
      end

      def build_processor(store)
        PROCESSORS
          .fetch(@processor.fetch(:type))
          .new(store:, producers:, **@processor.fetch(:attrs))
      end

      def process(query_or_record_name, **filters, &block)
        if query_or_record_name.is_a?(Proc)
          # Lambda-based query (current behavior)
          producers << Producer.new(query: query_or_record_name, block:)
        else
          # Record name with filters
          query = { record_name: query_or_record_name, filters: }
          producers << Producer.new(query:, block:)
        end
      end
    end
  end
end
