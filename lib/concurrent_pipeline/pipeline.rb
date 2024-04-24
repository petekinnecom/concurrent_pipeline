require "securerandom"

module ConcurrentPipeline
  class Pipeline
    def self.define(&block)
      schema = Pipelines::Schema.new
      schema.instance_exec(&block)

      new(schema)
    end

    attr_reader :schema, :processor
    def initialize(schema)
      @schema = schema
      @processor = nil
    end

    def process(store)
      @processor = schema.build_processor(store)
      @processor.call
    end

    def errors
      @processor&.errors || []
    end
  end
end
