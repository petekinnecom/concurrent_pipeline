require "securerandom"

module ConcurrentPipeline
  class Pipeline
    def self.define(&block)
      schema = Pipelines::Schema.new
      schema.instance_exec(&block)

      Class.new(Pipeline) do
        define_singleton_method(:process) { |store| new(schema).process(store) }
      end
    end

    attr_reader :schema
    def initialize(schema)
      @schema = schema
    end

    def process(store)
      schema.build_processor(store).call
    end
  end
end
